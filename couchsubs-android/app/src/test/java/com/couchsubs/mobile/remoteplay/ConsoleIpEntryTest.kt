// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.remoteplay

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** "IP Adresi Gir" (Ayarlar > Konsol): kayıtlı PS5 yazılan adrese taşınır, anahtar korunur; geçersiz adres reddedilir. */
class ConsoleIpEntryTest {
    private val saved = RegisteredConsole("192.168.1.20", "PS5-123", ByteArray(8) { 1 }, ByteArray(16) { 2 })

    @Test fun movesTheSavedConsoleToTheTypedAddress() {
        val moved = ConsoleIpEntry.apply(saved, " 192,168,1,35 ")!!
        assertEquals("192.168.1.35", moved.host)
        assertEquals("PS5-123", moved.name)
        assertArrayEquals(saved.registKey, moved.registKey)
        assertArrayEquals(saved.morning, moved.morning)
    }

    @Test fun rejectsInvalidAddresses() {
        assertNull(ConsoleIpEntry.apply(saved, ""))
        assertNull(ConsoleIpEntry.apply(saved, "192.168.1"))
        assertNull(ConsoleIpEntry.apply(saved, "192.168.1.300"))
        assertNull(ConsoleIpEntry.apply(saved, "ps5.local"))
    }
}
