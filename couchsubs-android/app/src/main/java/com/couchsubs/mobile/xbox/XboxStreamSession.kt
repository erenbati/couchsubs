// SPDX-License-Identifier: AGPL-3.0-only
// Xbox ev yayını (Beta): Windows'taki XboxStreamSession + player.html'in telefondaki karşılığı. Görüntü yerel
// libwebrtc'yle alınır; kareler OCR hattına doğrudan parlaklık (Y) düzlemi olarak gider (bkz. docs/superpowers/specs/
// 2026-11-16-telefon-xbox-design.md). Ses çalınmaz, kumanda girdisi gönderilmez.
package com.couchsubs.mobile.xbox

import android.content.Context
import android.os.SystemClock
import android.util.Log
import com.couchsubs.mobile.account.Backend
import com.couchsubs.mobile.remoteplay.DisconnectKind
import com.couchsubs.mobile.remoteplay.FrameSource
import com.couchsubs.mobile.remoteplay.SessionState
import com.couchsubs.mobile.remoteplay.VideoFrame
import org.webrtc.DataChannel
import org.webrtc.DefaultVideoDecoderFactory
import org.webrtc.IceCandidate
import org.webrtc.MediaConstraints
import org.webrtc.MediaStream
import org.webrtc.MediaStreamTrack
import org.webrtc.PeerConnection
import org.webrtc.PeerConnectionFactory
import org.webrtc.RtpTransceiver
import org.webrtc.SdpObserver
import org.webrtc.SessionDescription
import org.webrtc.SoftwareVideoEncoderFactory
import org.webrtc.VideoSink
import org.webrtc.VideoTrack
import org.webrtc.audio.JavaAudioDeviceModule
import java.nio.ByteBuffer
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

class XboxStreamSession(
    context: Context,
    private val auth: XboxAuth,
    private val console: XboxConsole,
    private val onFrame: (VideoFrame) -> Unit,
    private val onState: (SessionState) -> Unit,
    /** Hatayı kullanıcının dilinde anlatır (Türkçe/İngilizce metinler hizmette). */
    private val describe: (XboxError) -> String,
) : FrameSource {
    private companion object {
        const val TAG = "CouchSubsXbox"
        const val ICE_GATHER_MS = 5000L
        const val KEEPALIVE_MS = 30_000L
        /** El sıkışmadan sonra bu sürede kare gelmezse oturum yeniden açılır. */
        const val FIRST_FRAME_MS = 20_000L
        /** OCR saniyede beş kez okur; her kareyi I420'ye çevirmeye gerek yok. */
        const val FRAME_INTERVAL_MS = 66L
    }

    private val appContext = context.applicationContext
    private val home = XboxHome(auth)
    private val machine = XboxSessionMachine()
    private val frameCounter = XboxFrameCounter()
    private val worker = Executors.newSingleThreadExecutor { Thread(it, "CouchSubs Xbox").apply { isDaemon = true } }
    private val timers = Executors.newSingleThreadScheduledExecutor { Thread(it, "CouchSubs Xbox timers").apply { isDaemon = true } }
    private val stopped = AtomicBoolean(false)
    private val started = AtomicBoolean(false)
    @Volatile private var sessionId: String? = null
    @Volatile private var peer: PeerConnection? = null
    @Volatile private var factory: PeerConnectionFactory? = null
    @Volatile private var ended: CountDownLatch? = null
    @Volatile private var endReason: String? = null
    @Volatile private var keepalive: ScheduledFuture<*>? = null
    @Volatile private var lastConverted = 0L
    @Volatile private var firstFrameAt = 0L
    private val channels = HashMap<String, DataChannel>()

    override val framesReceived: Long get() = frameCounter.totalFrames

    override fun start() {
        if (!started.compareAndSet(false, true)) return
        worker.execute(::run)
    }

    override fun dispose() {
        if (!stopped.compareAndSet(false, true)) return
        machine.stop()
        ended?.countDown()
        worker.execute {
            closePeer()
            stopRemote()
            onState(SessionState.Disconnected(DisconnectKind.STOPPED))
        }
        worker.shutdown()
        timers.shutdown()
    }

    private fun log(text: String) {
        Log.i(TAG, text)
        Backend.breadcrumb("xbox: $text")
    }

    private fun run() {
        while (!stopped.get()) {
            var action: XboxSessionMachine.Action = machine.start()
            onState(SessionState.Connecting)
            try {
                log("oturum açılıyor: ${console.name}")
                sessionId = home.play(console.id)
                action = machine.played()
                loop@ while (!stopped.get()) {
                    when (val step = action) {
                        is XboxSessionMachine.Action.PollState -> {
                            if (step.delayMs > 0) Thread.sleep(step.delayMs)
                            val status = home.state(requireNotNull(sessionId))
                            action = machine.status(status.state, status.errorDetails)
                            if (status.state != "Provisioning") log("durum: ${status.state}")
                        }
                        XboxSessionMachine.Action.Connect -> {
                            home.connect(requireNotNull(sessionId))
                            action = machine.connected()
                        }
                        XboxSessionMachine.Action.Negotiate -> {
                            negotiate(requireNotNull(sessionId))
                            break@loop
                        }
                        is XboxSessionMachine.Action.Retry -> throw XboxException((machine.phase as? XboxSessionMachine.Phase.Failed)?.kind
                            ?: XboxError.SERVICE, (machine.phase as? XboxSessionMachine.Phase.Failed)?.message ?: "Xbox")
                        else -> break@loop
                    }
                }
                if (!stopped.get()) throw XboxException(XboxError.NETWORK, endReason ?: "Xbox görüntü bağlantısı kapandı")
            } catch (error: InterruptedException) {
                if (stopped.get()) break
            } catch (error: XboxException) {
                action = machine.fail(error.kind, error.message ?: "")
                report(error.kind, error.message)
            } catch (error: Exception) {
                action = machine.fail(XboxError.SERVICE, error.message ?: error.javaClass.simpleName)
                report(XboxError.SERVICE, error.message)
            } finally {
                closePeer()
                stopRemote()
            }
            if (stopped.get()) break
            val retry = (action as? XboxSessionMachine.Action.Retry)?.delayMs ?: break
            try {
                Thread.sleep(retry)
            } catch (error: InterruptedException) {
                break
            }
        }
    }

    private fun report(kind: XboxError, detail: String?) {
        if (stopped.get()) return
        log("hata ($kind): $detail")
        onState(SessionState.Disconnected(DisconnectKind.OTHER, describe(kind)))
    }

    private fun stopRemote() {
        val id = sessionId ?: return
        sessionId = null
        try {
            home.stop(id)
        } catch (error: Exception) {
            // Kopan bağlantının kapatılacak oturumu yoktur.
        }
    }

    // --- WebRTC ---

    private fun createFactory(): PeerConnectionFactory {
        WebRtc.initialize(appContext)
        // Ses çalınmaz ve mikrofon açılmaz: yalnız görüntü okunur.
        val audio = JavaAudioDeviceModule.builder(appContext).createAudioDeviceModule().apply {
            setSpeakerMute(true)
            setMicrophoneMute(true)
        }
        return PeerConnectionFactory.builder()
            .setAudioDeviceModule(audio)
            // EGL bağlamı yok: donanım çözücüsü kareyi bellekte verir, Y düzlemi doğrudan okunur.
            .setVideoDecoderFactory(DefaultVideoDecoderFactory(null))
            .setVideoEncoderFactory(SoftwareVideoEncoderFactory())
            .createPeerConnectionFactory()
            .also { audio.release() }
    }

    private val sink = VideoSink { frame ->
        val sessionFrames = frameCounter.recordFrame()
        val now = SystemClock.elapsedRealtime()
        if (sessionFrames == 1L) {
            firstFrameAt = now
            log("ilk kare ${frame.buffer.width}x${frame.buffer.height}")
            if (machine.streaming()) onState(SessionState.Streaming)
        }
        if (now - lastConverted < FRAME_INTERVAL_MS) return@VideoSink
        lastConverted = now
        val i420 = frame.buffer.toI420() ?: return@VideoSink
        try {
            onFrame(VideoFrame(i420.dataY, i420.width, i420.height, i420.strideY))
        } finally {
            i420.release()
        }
    }

    private fun negotiate(id: String) {
        frameCounter.beginSession()
        val done = CountDownLatch(1).also { ended = it }
        endReason = null
        val pcFactory = createFactory().also { factory = it }
        val gathered = CountDownLatch(1)
        val local = ArrayList<XboxIceCandidate>()
        val config = PeerConnection.RTCConfiguration(listOf(
            PeerConnection.IceServer.builder("stun:stun.l.google.com:19302").createIceServer(),
            PeerConnection.IceServer.builder("stun:stun1.l.google.com:19302").createIceServer(),
        )).apply { sdpSemantics = PeerConnection.SdpSemantics.UNIFIED_PLAN }
        val connection = pcFactory.createPeerConnection(config, object : PeerConnection.Observer {
            override fun onSignalingChange(state: PeerConnection.SignalingState?) {}
            override fun onIceConnectionChange(state: PeerConnection.IceConnectionState?) { log("ICE: $state") }
            override fun onIceConnectionReceivingChange(receiving: Boolean) {}
            override fun onIceGatheringChange(state: PeerConnection.IceGatheringState?) {
                if (state == PeerConnection.IceGatheringState.COMPLETE) gathered.countDown()
            }
            override fun onIceCandidate(candidate: IceCandidate) {
                synchronized(local) { local += XboxIceCandidate(candidate.sdp, candidate.sdpMid, candidate.sdpMLineIndex) }
            }
            override fun onIceCandidatesRemoved(candidates: Array<out IceCandidate>?) {}
            override fun onAddStream(stream: MediaStream?) {}
            override fun onRemoveStream(stream: MediaStream?) {}
            override fun onDataChannel(channel: DataChannel?) {}
            override fun onRenegotiationNeeded() {}
            override fun onConnectionChange(state: PeerConnection.PeerConnectionState?) {
                log("bağlantı: $state")
                if (state == PeerConnection.PeerConnectionState.FAILED || state == PeerConnection.PeerConnectionState.CLOSED) {
                    endReason = "Xbox WebRTC bağlantısı kesildi ($state)"
                    done.countDown()
                }
            }
        }) ?: throw XboxException(XboxError.SERVICE, "WebRTC bağlantısı kurulamadı")
        peer = connection

        // Oynatıcıdaki sıra: önce veri kanalları, sonra ses (gönder-al) ve görüntü (yalnız al).
        for ((name, protocol) in XboxChannels.CHANNELS) {
            val init = DataChannel.Init().apply {
                ordered = true
                this.protocol = protocol
            }
            val channel = connection.createDataChannel(name, init) ?: throw XboxException(XboxError.SERVICE, "Veri kanalı açılamadı: $name")
            synchronized(channels) { channels[name] = channel }
            channel.registerObserver(ChannelObserver(name, channel, done))
        }
        val audio = connection.addTransceiver(MediaStreamTrack.MediaType.MEDIA_TYPE_AUDIO,
            RtpTransceiver.RtpTransceiverInit(RtpTransceiver.RtpTransceiverDirection.SEND_RECV))
        val video = connection.addTransceiver(MediaStreamTrack.MediaType.MEDIA_TYPE_VIDEO,
            RtpTransceiver.RtpTransceiverInit(RtpTransceiver.RtpTransceiverDirection.RECV_ONLY))
        audio?.receiver?.track()?.setEnabled(false)
        (video?.receiver?.track() as? VideoTrack)?.addSink(sink)
            ?: throw XboxException(XboxError.SERVICE, "Görüntü alıcısı kurulamadı")

        val offer = await<SessionDescription>("SDP teklifi") { result -> connection.createOffer(result.creating(), MediaConstraints()) }
        val munged = SessionDescription(SessionDescription.Type.OFFER, XboxChannels.mungeOffer(offer.description))
        await<Unit>("yerel SDP") { result -> connection.setLocalDescription(result.setting(), munged) }
        log("SDP gönderiliyor")
        val answer = home.sdp(id, munged.description)
        await<Unit>("Xbox SDP") { result -> connection.setRemoteDescription(result.setting(), SessionDescription(SessionDescription.Type.ANSWER, answer)) }
        // Yerel adaylar toplanana kadar (en çok 5 sn) beklenir; yavaş ağ bağdaştırıcılarının adayları da gitsin.
        gathered.await(ICE_GATHER_MS, TimeUnit.MILLISECONDS)
        val candidates = synchronized(local) { local.toList() }
        log("ICE: ${candidates.size} yerel aday gönderiliyor")
        val remote = home.ice(id, candidates)
        var added = 0
        for (candidate in remote) {
            val line = candidate.sdpLine ?: continue
            if (connection.addIceCandidate(IceCandidate(candidate.sdpMid ?: "", candidate.sdpMLineIndex, line))) added++
        }
        log("ICE: Xbox'tan ${remote.size} aday, $added eklendi")

        val negotiatedAt = SystemClock.elapsedRealtime()
        while (!stopped.get()) {
            if (done.await(1, TimeUnit.SECONDS)) break
            if (frameCounter.framesInSession == 0L && SystemClock.elapsedRealtime() - negotiatedAt > FIRST_FRAME_MS) {
                endReason = "Xbox'tan görüntü gelmedi"
                throw XboxException(XboxError.CONSOLE_UNAVAILABLE, endReason!!)
            }
        }
    }

    private inner class ChannelObserver(private val name: String, private val channel: DataChannel, private val done: CountDownLatch) : DataChannel.Observer {
        override fun onBufferedAmountChange(previous: Long) {}

        override fun onStateChange() {
            val state = channel.state()
            log("kanal $name: $state")
            when {
                state == DataChannel.State.OPEN && name == "message" -> sendText("message", XboxChannels.HANDSHAKE)
                state == DataChannel.State.OPEN && name == "input" -> startKeepalive()
                state == DataChannel.State.CLOSED && name == "input" -> {
                    endReason = "Xbox görüntü bağlantısı kapandı"
                    done.countDown()
                }
            }
        }

        override fun onMessage(buffer: DataChannel.Buffer) {
            if (name != "message" || buffer.binary) return
            val bytes = ByteArray(buffer.data.remaining()).also { buffer.data.get(it) }
            val text = String(bytes, Charsets.UTF_8)
            if (!XboxChannels.isHandshakeAck(text)) return
            log("el sıkışma tamam")
            sendText("control", XboxChannels.AUTHORIZATION)
            sendText("control", XboxChannels.GAMEPAD_ADDED)
            send("input", XboxChannels.clientMetadataPacket(0, SystemClock.elapsedRealtimeNanos() / 1e6), binary = true)
            XboxChannels.configurationMessages().forEach { sendText("message", it) }
        }
    }

    private fun sendText(name: String, text: String) = send(name, text.toByteArray(Charsets.UTF_8), binary = false)

    private fun send(name: String, bytes: ByteArray, binary: Boolean) {
        val channel = synchronized(channels) { channels[name] } ?: return
        if (channel.state() != DataChannel.State.OPEN) return
        channel.send(DataChannel.Buffer(ByteBuffer.wrap(bytes), binary))
    }

    private fun startKeepalive() {
        keepalive?.cancel(false)
        keepalive = timers.scheduleWithFixedDelay({
            val id = sessionId ?: return@scheduleWithFixedDelay
            try {
                home.keepalive(id)
            } catch (error: Exception) {
                log("canlı tutma: ${error.message}")
            }
        }, KEEPALIVE_MS, KEEPALIVE_MS, TimeUnit.MILLISECONDS)
    }

    private fun closePeer() {
        keepalive?.cancel(false)
        keepalive = null
        synchronized(channels) {
            channels.values.forEach { runCatching { it.unregisterObserver(); it.dispose() } }
            channels.clear()
        }
        peer?.let { runCatching { it.dispose() } }
        peer = null
        factory?.let { runCatching { it.dispose() } }
        factory = null
        ended = null
    }

    /** WebRTC'nin geri çağırmalı işlemini bekler (en çok 10 sn). */
    private fun <T> await(what: String, start: (SdpResult<T>) -> Unit): T {
        val result = SdpResult<T>()
        start(result)
        if (!result.latch.await(10, TimeUnit.SECONDS)) throw XboxException(XboxError.TIMEOUT, "$what zaman aşımı")
        result.error?.let { throw XboxException(XboxError.SERVICE, "$what: $it") }
        @Suppress("UNCHECKED_CAST")
        return result.value as T
    }

    private class SdpResult<T> {
        val latch = CountDownLatch(1)
        @Volatile var value: Any? = null
        @Volatile var error: String? = null

        fun creating() = object : SdpObserver {
            override fun onCreateSuccess(description: SessionDescription) { value = description; latch.countDown() }
            override fun onSetSuccess() {}
            override fun onCreateFailure(message: String?) { error = message ?: "?"; latch.countDown() }
            override fun onSetFailure(message: String?) {}
        }

        fun setting() = object : SdpObserver {
            override fun onCreateSuccess(description: SessionDescription?) {}
            override fun onSetSuccess() { value = Unit; latch.countDown() }
            override fun onCreateFailure(message: String?) {}
            override fun onSetFailure(message: String?) { error = message ?: "?"; latch.countDown() }
        }
    }
}

/** libwebrtc süreçte bir kez başlatılır. */
private object WebRtc {
    @Volatile private var ready = false

    @Synchronized
    fun initialize(context: Context) {
        if (ready) return
        PeerConnectionFactory.initialize(PeerConnectionFactory.InitializationOptions.builder(context).createInitializationOptions())
        ready = true
    }
}
