// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL
// chiaki-ng android/app/src/main/cpp/video-decoder.h'den uyarlandı (Florian Märkl ve chiaki-ng katkıcıları).
// Değişiklik: yüzey oturum başında bir kez verilir (ImageReader'ın yüzeyi; kareler yazı tanımaya gider).

#ifndef COUCHSUBS_VIDEO_DECODER_H
#define COUCHSUBS_VIDEO_DECODER_H

#include <jni.h>

#include <chiaki/thread.h>
#include <chiaki/log.h>

#include <stdbool.h>
#include <stdint.h>

typedef struct AMediaCodec AMediaCodec;
typedef struct ANativeWindow ANativeWindow;

typedef struct couchsubs_video_decoder_t
{
	ChiakiLog *log;
	ChiakiMutex codec_mutex;
	AMediaCodec *codec;
	ANativeWindow *window;
	uint64_t timestamp_cur;
	ChiakiThread output_thread;
	bool shutdown_output;
	int32_t target_width;
	int32_t target_height;
	/* Çözülüp yüzeye verilen kare sayısı (tanı için). */
	uint64_t frames_out;
	/* Art arda çözücü hatası; eşiği geçerse yazılım çözücüye geçilir. */
	uint32_t codec_errors;
	/* Yazılım çözücü (c2.android / OMX.google) kullanılıyor. */
	bool software;
	/* PS5'in akış başlığı (SPS/PPS). libchiaki onu yalnız bir kez verir ve dönüş değerine bakmaz; çözücü yeniden
	 * kurulunca (yazılım çözücüye geçiş) yeni çözücüye önce bu verilir, yoksa hiç kare çıkmaz. */
	uint8_t *header;
	size_t header_size;
	/* Açık çözücüye başlık henüz verilmedi. */
	bool header_pending;
} CouchSubsVideoDecoder;

ChiakiErrorCode couchsubs_video_decoder_init(CouchSubsVideoDecoder *decoder, ChiakiLog *log, int32_t width, int32_t height);
/* H.264 çözücüyü verilen yüzeyle başlatır; başarısızsa false. swap: üreticiye göre seçilen çözücü türünün tersiyle
 * başla (önceki oturumda hiç görüntü gelmediyse). */
bool couchsubs_video_decoder_start(CouchSubsVideoDecoder *decoder, JNIEnv *env, jobject surface, bool swap);
void couchsubs_video_decoder_fini(CouchSubsVideoDecoder *decoder);
bool couchsubs_video_decoder_video_sample(uint8_t *buf, size_t buf_size, int32_t frames_lost, bool frame_recovered, void *user);

#endif
