// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.tv.lg

import com.couchsubs.mobile.tv.samsung.SamsungDiagnostics

/**
 * LG: kurulumdan (ya da kapat-aç ile yeniden başlatmadan) sonra TV'de ÇALIŞAN uygulamanın sürümü kurulan sürüm mü?
 * beta.89 (Mac, LG): TV'ye 0.9.84 kurulmuştu, açık uygulama ise 0.9.81'di. TV uygulaması altyazı akışına bağlanırken
 * sürümünü bildirir (`/events?v=`); kurulan sürümden eskiyse uygulama bir kez daha kapatılıp açılır, yine eskiyse
 * kullanıcıya "TV'de CouchSubs'ı kapatıp yeniden açın" denir. Mac/iPhone (TVAppRunningCheck.swift) ve Windows ile aynı.
 */
class TvAppRunningCheck(val expected: String) {
    enum class Verdict {
        /** Çalışan uygulama kurulan sürümde (ya da daha yeni): denetim biter. */
        RUNNING,
        /** Çalışan uygulama eski: bir kez daha kapatılıp açılmalı. */
        RESTART_AGAIN,
        /** Kapatıp açtıktan sonra da eski: kullanıcıya söylenir. */
        STALE,
    }

    var restarted = false
        private set

    /** TV uygulaması sürümünü bildirdi (boş: sürüm bildirmeyen eski uygulama). */
    fun report(version: String): Verdict = when {
        !isStale(version, expected) -> Verdict.RUNNING
        restarted -> Verdict.STALE
        else -> {
            restarted = true
            Verdict.RESTART_AGAIN
        }
    }

    companion object {
        /** 0.9.69'den eski TV uygulamaları sürüm bildirmez; ekranda böyle görünür. */
        const val UNREPORTED = "< 0.9.69"

        /** Çalışan uygulamanın bildirdiği sürüm (boş: eski uygulama) kurulu paketten eski mi? */
        fun isStale(running: String, installed: String): Boolean =
            installed.isNotEmpty() && (running.isEmpty() || SamsungDiagnostics.isNewer(installed, running))
    }
}
