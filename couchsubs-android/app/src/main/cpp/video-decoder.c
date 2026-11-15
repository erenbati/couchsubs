// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL
// chiaki-ng android/app/src/main/cpp/video-decoder.c'den uyarlandı (Florian Märkl ve chiaki-ng katkıcıları).
// Değişiklikler: yüzey değiştirme yok, yeni geri çağrı imzası (frames_lost, frame_recovered), düşük gecikme isteği.

#include "video-decoder.h"

#include <media/NdkMediaCodec.h>
#include <media/NdkMediaFormat.h>
#include <android/native_window_jni.h>
#include <sys/system_properties.h>

#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <unistd.h>

#define INPUT_BUFFER_TIMEOUT_MS 10
/* Başlık (SPS/PPS) bir kez gelir; yitirilmesin diye giriş arabelleği daha uzun beklenir. */
#define HEADER_INPUT_TIMEOUT_MS 500
/* Bu kadar art arda hatadan sonra donanım çözücü bırakılır, yazılım çözücüyle yeniden kurulur. */
#define CODEC_ERROR_LIMIT 30

static const char *const SOFTWARE_DECODERS[] = { "c2.android.avc.decoder", "OMX.google.h264.decoder", NULL };

static void *output_thread_func(void *user);

ChiakiErrorCode couchsubs_video_decoder_init(CouchSubsVideoDecoder *decoder, ChiakiLog *log, int32_t width, int32_t height)
{
	memset(decoder, 0, sizeof(*decoder));
	decoder->log = log;
	decoder->target_width = width;
	decoder->target_height = height;
	return chiaki_mutex_init(&decoder->codec_mutex, false);
}

static void kill_decoder(CouchSubsVideoDecoder *decoder)
{
	chiaki_mutex_lock(&decoder->codec_mutex);
	decoder->shutdown_output = true;
	ssize_t index = AMediaCodec_dequeueInputBuffer(decoder->codec, 1000);
	if(index >= 0)
	{
		AMediaCodec_queueInputBuffer(decoder->codec, (size_t)index, 0, 0, decoder->timestamp_cur++, AMEDIACODEC_BUFFER_FLAG_END_OF_STREAM);
		AMediaCodec_stop(decoder->codec);
		chiaki_mutex_unlock(&decoder->codec_mutex);
		chiaki_thread_join(&decoder->output_thread, NULL);
	}
	else
	{
		CHIAKI_LOGE(decoder->log, "Video decoder: no input buffer for shutdown");
		AMediaCodec_stop(decoder->codec);
		chiaki_mutex_unlock(&decoder->codec_mutex);
		chiaki_thread_join(&decoder->output_thread, NULL);
	}
	AMediaCodec_delete(decoder->codec);
	decoder->codec = NULL;
	decoder->shutdown_output = false;
}

void couchsubs_video_decoder_fini(CouchSubsVideoDecoder *decoder)
{
	if(decoder->codec)
		kill_decoder(decoder);
	if(decoder->window)
	{
		ANativeWindow_release(decoder->window);
		decoder->window = NULL;
	}
	chiaki_mutex_fini(&decoder->codec_mutex);
	free(decoder->header);
	decoder->header = NULL;
	decoder->header_size = 0;
}

/* Çözücüyü kurar ve çıkış iş parçacığını başlatır (kilit tutulurken, pencere hazırken). software: yazılım çözücü.
 * Bazı üreticilerin (ör. Honor/MagicOS) donanım çözücüsü kurulumda ya da çözerken hata verebilir; o zaman yazılım
 * çözücü denenir. Başarısızsa codec NULL kalır. */
static bool open_codec(CouchSubsVideoDecoder *decoder, bool software)
{
	const char *mime = "video/avc";
	for(int i = 0; software ? SOFTWARE_DECODERS[i] != NULL : i == 0; i++)
	{
		const char *name = software ? SOFTWARE_DECODERS[i] : "(default)";
		decoder->codec = software ? AMediaCodec_createCodecByName(name) : AMediaCodec_createDecoderByType(mime);
		if(!decoder->codec)
		{
			CHIAKI_LOGE(decoder->log, "Video decoder: no AMediaCodec %s for %s", name, mime);
			continue;
		}
		AMediaFormat *format = AMediaFormat_new();
		AMediaFormat_setString(format, AMEDIAFORMAT_KEY_MIME, mime);
		AMediaFormat_setInt32(format, AMEDIAFORMAT_KEY_WIDTH, decoder->target_width);
		AMediaFormat_setInt32(format, AMEDIAFORMAT_KEY_HEIGHT, decoder->target_height);
		/* Android 11+: düşük gecikmeli çözme (desteklemeyen cihaz yok sayar). */
		AMediaFormat_setInt32(format, "low-latency", 1);
		media_status_t r = AMediaCodec_configure(decoder->codec, format, decoder->window, NULL, 0);
		AMediaFormat_delete(format);
		if(r != AMEDIA_OK)
		{
			CHIAKI_LOGE(decoder->log, "AMediaCodec_configure() failed (%s): %d", name, (int)r);
			goto next;
		}
		r = AMediaCodec_start(decoder->codec);
		if(r != AMEDIA_OK)
		{
			CHIAKI_LOGE(decoder->log, "AMediaCodec_start() failed (%s): %d", name, (int)r);
			goto next;
		}
		decoder->shutdown_output = false;
		decoder->codec_errors = 0;
		/* Yeni çözücü başlığı (SPS/PPS) görmedi; elde varsa ilk örnekten önce verilir. */
		decoder->header_pending = decoder->header != NULL;
		if(chiaki_thread_create(&decoder->output_thread, output_thread_func, decoder) != CHIAKI_ERR_SUCCESS)
		{
			CHIAKI_LOGE(decoder->log, "Video decoder: output thread failed");
			AMediaCodec_stop(decoder->codec);
			goto next;
		}
		decoder->software = software;
		CHIAKI_LOGI(decoder->log, "Video decoder: %s started", software ? name : "hardware decoder");
		return true;
next:
		AMediaCodec_delete(decoder->codec);
		decoder->codec = NULL;
	}
	return false;
}

static bool prefers_software_decoder(void)
{
	char manufacturer[PROP_VALUE_MAX] = { 0 };
	__system_property_get("ro.product.manufacturer", manufacturer);
	return strcasecmp(manufacturer, "samsung") == 0;
}

bool couchsubs_video_decoder_start(CouchSubsVideoDecoder *decoder, JNIEnv *env, jobject surface, bool swap)
{
	if(!surface)
		return false;
	chiaki_mutex_lock(&decoder->codec_mutex);
	bool ok = false;
	decoder->window = ANativeWindow_fromSurface(env, surface);
	if(!decoder->window)
		goto beach;

	/* Samsung'da donanım çözücünün ImageReader'a verdiği kareler işlemciden güvenle okunamıyor: Image.getPlanes()
	 * boş adresle JNI'yi durduruyor (SIGABRT) ya da düzlem okunurken SIGSEGV oluyor (Crashlytics, Galaxy S22/S23/
	 * A54/M52; Exynos ve Snapdragon). Yazılım çözücü kareyi işlemciyle yazdığı için okunabilir arabellek verir;
	 * 1080p30 H.264 için yükü düşük. Yazılım çözücü açılamazsa donanım çözücü denenir. swap: önceki oturumda bu
	 * seçimle hiç görüntü gelmedi; öbür türle denenir (StreamSession). */
	bool software_first = prefers_software_decoder() != swap;
	CHIAKI_LOGI(decoder->log, "Video decoder: trying %s decoder first%s", software_first ? "software" : "hardware",
			swap ? " (swapped after no picture)" : "");
	ok = open_codec(decoder, software_first);
	if(!ok)
	{
		CHIAKI_LOGE(decoder->log, "Video decoder: %s decoder failed, trying %s decoder",
				software_first ? "software" : "hardware", software_first ? "hardware" : "software");
		ok = open_codec(decoder, !software_first);
	}
	if(!ok)
	{
		ANativeWindow_release(decoder->window);
		decoder->window = NULL;
	}

beach:
	chiaki_mutex_unlock(&decoder->codec_mutex);
	return ok;
}

/* Donanım çözücü art arda hata verdiyse yazılım çözücüyle yeniden kurar. Kilit tutulurken çağrılır, dönüşte de tutulur. */
static void fall_back_to_software(CouchSubsVideoDecoder *decoder)
{
	CHIAKI_LOGE(decoder->log, "Video decoder: %u errors in a row, switching to software decoder", (unsigned)decoder->codec_errors);
	decoder->shutdown_output = true;
	AMediaCodec_stop(decoder->codec);
	chiaki_mutex_unlock(&decoder->codec_mutex);
	chiaki_thread_join(&decoder->output_thread, NULL);
	chiaki_mutex_lock(&decoder->codec_mutex);
	AMediaCodec_delete(decoder->codec);
	decoder->codec = NULL;
	if(!open_codec(decoder, true))
	{
		/* Görüntü gelmez; PictureWatchdog oturumu yeniden kurar. Süreç çökmez. */
		CHIAKI_LOGE(decoder->log, "Video decoder: software decoder could not be opened");
		decoder->software = true;
		decoder->shutdown_output = false;
	}
}

/* Örnek H.264 akış başlığı mı (SPS ile başlıyor: libchiaki'nin profil başlığı SPS+PPS'tir). */
static bool is_stream_header(const uint8_t *buf, size_t size)
{
	size_t at;
	if(size >= 5 && buf[0] == 0 && buf[1] == 0 && buf[2] == 0 && buf[3] == 1)
		at = 4;
	else if(size >= 4 && buf[0] == 0 && buf[1] == 0 && buf[2] == 1)
		at = 3;
	else
		return false;
	return (buf[at] & 0x1f) == 7;
}

/* Örneği çözücüye verir (kilit tutulurken). Giriş arabelleği timeout_ms içinde gelmezse ya da hata olursa false. */
static bool queue_input(CouchSubsVideoDecoder *decoder, const uint8_t *buf, size_t buf_size, int timeout_ms)
{
	while(buf_size > 0)
	{
		ssize_t index = AMediaCodec_dequeueInputBuffer(decoder->codec, (int64_t)timeout_ms * 1000);
		if(index < 0)
		{
			/* TRY_AGAIN_LATER olağan; başka bir değer çözücü hatasıdır. */
			if(index != AMEDIACODEC_INFO_TRY_AGAIN_LATER)
				decoder->codec_errors++;
			/* libchiaki bozuk kare sayıp yeni anahtar kare ister. */
			return false;
		}
		size_t codec_buf_size;
		uint8_t *codec_buf = AMediaCodec_getInputBuffer(decoder->codec, (size_t)index, &codec_buf_size);
		if(!codec_buf || codec_buf_size == 0)
		{
			/* NDK belgesi: arabellek alınamazsa NULL döner; memcpy süreci çökertirdi. Kare atlanır. */
			CHIAKI_LOGE(decoder->log, "AMediaCodec_getInputBuffer() returned no buffer");
			AMediaCodec_queueInputBuffer(decoder->codec, (size_t)index, 0, 0, decoder->timestamp_cur++, 0);
			return false;
		}
		size_t size = buf_size > codec_buf_size ? codec_buf_size : buf_size;
		memcpy(codec_buf, buf, size);
		/* Zaman damgası yalnız birer artar: en gerçek zamanlı davranış. */
		media_status_t r = AMediaCodec_queueInputBuffer(decoder->codec, (size_t)index, 0, size, decoder->timestamp_cur++, 0);
		if(r != AMEDIA_OK)
		{
			CHIAKI_LOGE(decoder->log, "AMediaCodec_queueInputBuffer() failed: %d", (int)r);
			decoder->codec_errors++;
			return false;
		}
		buf += size;
		buf_size -= size;
	}
	return true;
}

bool couchsubs_video_decoder_video_sample(uint8_t *buf, size_t buf_size, int32_t frames_lost, bool frame_recovered, void *user)
{
	(void)frames_lost;
	(void)frame_recovered;
	bool result = true;
	CouchSubsVideoDecoder *decoder = user;
	chiaki_mutex_lock(&decoder->codec_mutex);
	/* libchiaki başlığı (SPS/PPS) profil başında bir kez verir ve dönüş değerine bakmaz: başlık yitirilirse ya da
	 * çözücü sonradan yeniden kurulursa (yazılım çözücüye geçiş) çözücü hiç kare çıkaramaz, bağlantı açıkken görüntü
	 * gelmez. Başlık saklanır, her yeni çözücüye ilk iş verilir. */
	bool header = is_stream_header(buf, buf_size);
	if(header)
	{
		uint8_t *copy = malloc(buf_size);
		if(copy)
		{
			memcpy(copy, buf, buf_size);
			free(decoder->header);
			decoder->header = copy;
			decoder->header_size = buf_size;
		}
		decoder->header_pending = true;
	}
	if(!decoder->software && decoder->codec && decoder->codec_errors >= CODEC_ERROR_LIMIT)
		fall_back_to_software(decoder);
	if(!decoder->codec || decoder->shutdown_output)
		goto beach;

	if(decoder->header_pending && decoder->header)
	{
		if(!queue_input(decoder, decoder->header, decoder->header_size, HEADER_INPUT_TIMEOUT_MS))
		{
			CHIAKI_LOGE(decoder->log, "Video decoder: stream header could not be queued");
			result = false;
			goto beach;
		}
		decoder->header_pending = false;
		if(header)
			goto beach;
	}
	if(!queue_input(decoder, buf, buf_size, INPUT_BUFFER_TIMEOUT_MS))
		result = false;

beach:
	chiaki_mutex_unlock(&decoder->codec_mutex);
	return result;
}

static void *output_thread_func(void *user)
{
	CouchSubsVideoDecoder *decoder = user;
	while(1)
	{
		AMediaCodecBufferInfo info;
		ssize_t status = AMediaCodec_dequeueOutputBuffer(decoder->codec, &info, 100000);
		if(status >= 0)
		{
			/* render=true: kare ImageReader'a gider. */
			AMediaCodec_releaseOutputBuffer(decoder->codec, (size_t)status, info.size != 0);
			if(info.size != 0)
				decoder->frames_out++;
			if(info.flags & AMEDIACODEC_BUFFER_FLAG_END_OF_STREAM)
				break;
			if(info.size != 0 && decoder->codec_errors)
			{
				chiaki_mutex_lock(&decoder->codec_mutex);
				decoder->codec_errors = 0;
				chiaki_mutex_unlock(&decoder->codec_mutex);
			}
		}
		else
		{
			/* TRY_AGAIN_LATER (-1), biçim (-2) ve arabellek (-3) değişimi olağan; daha küçükse çözücü hatası.
			 * Hata durumundaki çözücü hemen döner: dönerek işlemciyi yakmasın diye kısa beklenir. */
			bool failed = status < AMEDIACODEC_INFO_OUTPUT_BUFFERS_CHANGED;
			chiaki_mutex_lock(&decoder->codec_mutex);
			bool shutdown = decoder->shutdown_output;
			if(failed && !shutdown)
				decoder->codec_errors++;
			chiaki_mutex_unlock(&decoder->codec_mutex);
			if(shutdown)
				break;
			if(failed)
				usleep(10000);
		}
	}
	return NULL;
}
