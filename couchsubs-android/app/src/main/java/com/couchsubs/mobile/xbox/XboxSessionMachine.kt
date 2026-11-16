// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.xbox

import java.util.concurrent.atomic.AtomicLong

/**
 * Ev yayını oturumunun durum makinesi (ağdan bağımsız; birim testli). Windows'taki XboxStreamSession.RunAsync ile aynı
 * kurallar: `/state` saniyede bir, en çok 90 kez sorulur; `ReadyToConnect` görülünce aktarım jetonu gönderilir,
 * `Provisioned` olunca WebRTC el sıkışması başlar, `Failed` ya da hata olunca 5 sn sonra baştan denenir. Yeniden giriş
 * gerektiren hatalarda (ör. yenileme jetonu geçersiz) denenmez, durulur.
 */
class XboxSessionMachine(val maxPolls: Int = 90, val pollIntervalMs: Long = 1000, val retryDelayMs: Long = 5000) {
    sealed class Phase {
        data object Idle : Phase()
        data object Starting : Phase()
        data class Provisioning(val polls: Int, val connectSent: Boolean) : Phase()
        data object Negotiating : Phase()
        data object Streaming : Phase()
        data class Failed(val kind: XboxError, val message: String, val willRetry: Boolean) : Phase()
        data object Stopped : Phase()
    }

    sealed class Action {
        /** `/play` gönder. */
        data object Play : Action()
        /** [delayMs] bekle, `/state` sor. */
        data class PollState(val delayMs: Long) : Action()
        /** Aktarım jetonuyla `/connect` gönder, sonra yine sor. */
        data object Connect : Action()
        /** SDP ve ICE el sıkışması. */
        data object Negotiate : Action()
        /** Oturumu kapat ([delayMs] sonra baştan başla; null ise durul). */
        data class Retry(val delayMs: Long?) : Action()
        data object Nothing : Action()
    }

    @Volatile var phase: Phase = Phase.Idle
        private set

    fun start(): Action {
        if (phase == Phase.Stopped) return Action.Nothing
        phase = Phase.Starting
        return Action.Play
    }

    fun played(): Action {
        if (phase != Phase.Starting) return Action.Nothing
        phase = Phase.Provisioning(0, false)
        return Action.PollState(0)
    }

    /** `/state` yanıtı geldi. */
    fun status(state: String, errorDetails: String?): Action {
        val current = phase as? Phase.Provisioning ?: return Action.Nothing
        return when (state) {
            "Provisioned" -> {
                phase = Phase.Negotiating
                Action.Negotiate
            }
            "Failed" -> fail(classifyFailure(errorDetails), errorDetails ?: "Xbox yayını açılamadı")
            "ReadyToConnect" -> if (!current.connectSent) {
                phase = current.copy(connectSent = true)
                Action.Connect
            } else poll(current)
            else -> poll(current)
        }
    }

    /** `/connect` gönderildi. */
    fun connected(): Action {
        val current = phase as? Phase.Provisioning ?: return Action.Nothing
        return poll(current)
    }

    private fun poll(current: Phase.Provisioning): Action {
        val polls = current.polls + 1
        if (polls >= maxPolls) return fail(XboxError.TIMEOUT, "Xbox yayını hazır olmayı beklerken zaman aşımına uğradı")
        phase = current.copy(polls = polls)
        return Action.PollState(pollIntervalMs)
    }

    /** İlk kare geldi. */
    fun streaming(): Boolean {
        if (phase != Phase.Negotiating) return false
        phase = Phase.Streaming
        return true
    }

    fun fail(kind: XboxError, message: String): Action {
        if (phase == Phase.Stopped) return Action.Nothing
        val retry = kind !in FATAL
        phase = Phase.Failed(kind, message, retry)
        return Action.Retry(if (retry) retryDelayMs else null)
    }

    fun stop() {
        phase = Phase.Stopped
    }

    companion object {
        /** Yeniden denemenin işe yaramadığı hatalar: kullanıcı bir şey yapmalı. */
        val FATAL = setOf(XboxError.SIGN_IN_REQUIRED, XboxError.NO_XBOX_ACCOUNT)

        /** `errorDetails` içinden anlaşılan neden. */
        fun classifyFailure(details: String?): XboxError {
            val text = details.orEmpty()
            return when {
                text.contains("InUse", true) || text.contains("Busy", true) || text.contains("AlreadyStreaming", true) -> XboxError.BUSY
                text.contains("Offline", true) || text.contains("NotFound", true) || text.contains("Unavailable", true) ||
                    text.contains("PowerOff", true) || text.contains("StreamingDisabled", true) -> XboxError.CONSOLE_UNAVAILABLE
                else -> XboxError.CONSOLE_UNAVAILABLE
            }
        }
    }
}

/** Ömür boyu tanı sayacını korurken her yeni WebRTC bağlantısının ilk karesini ayrı tanır. */
internal class XboxFrameCounter {
    private val total = AtomicLong()
    private val currentSession = AtomicLong()

    val totalFrames: Long get() = total.get()
    val framesInSession: Long get() = currentSession.get()

    fun beginSession() {
        currentSession.set(0)
    }

    fun recordFrame(): Long {
        total.incrementAndGet()
        return currentSession.incrementAndGet()
    }
}
