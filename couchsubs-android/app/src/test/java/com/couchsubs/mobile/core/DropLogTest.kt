// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.core

import com.couchsubs.mobile.translation.AiRequest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test

/** Düşen satır günlüğü: biçim, tekrar ve dakikalık sınır (Mac DropLogTests.swift, Windows DropLogTests.cs aynı). */
class DropLogTest {
    @Test fun formatsComponentReasonAndShortExcerpt() {
        var time = 0L
        val drops = DropLog({ time }) { }
        assertEquals("düşen satır [MissionLine] 3 sn dolmadan kalktı: \"Go to the marked location on …\"",
            drops.line("MissionLine", "3 sn dolmadan kalktı", "Go to the marked location on the map"))
        time += 1
        assertNull(drops.line("MissionLine", "3 sn dolmadan kalktı", "Go to the marked location on the map"))
        assertNotNull(drops.line("MissionLine", "başka neden", "Go to the marked location on the map"))
        time += DropLog.REPEAT_MS
        assertNotNull(drops.line("MissionLine", "3 sn dolmadan kalktı", "Go to the marked location on the map"))
    }

    @Test fun capsLinesPerMinuteAndReportsSuppressed() {
        var time = 0L
        val lines = mutableListOf<String>()
        val drops = DropLog({ time }) { lines.add(it) }
        for (index in 0 until DropLog.PER_MINUTE + 5) drops.note("SettledText", "neden", "satır $index")
        assertEquals(DropLog.PER_MINUTE, lines.size)
        time = 60_000
        drops.note("SettledText", "neden", "yeni satır")
        assertEquals("düşen satır [SettledText] neden: \"yeni satır\" (+5 satır sınır yüzünden yazılmadı)", lines.last())
    }

    @Test fun screenIssue() {
        assertNull(AiRequest.screenIssue("Open map", "Haritayı aç", 12))
        assertEquals("motor boş çeviri döndü", AiRequest.screenIssue("Open map", " ", 10))
        assertEquals("çeviri aslıyla aynı döndü, İngilizce kaldı", AiRequest.screenIssue("Open map", "open map", 10))
        assertNull(AiRequest.screenIssue("42", "42", 4))
        assertEquals("%115 sınırını aştı (17/10)", AiRequest.screenIssue("Open map", "Haritayı şimdi aç", 10))
    }
}
