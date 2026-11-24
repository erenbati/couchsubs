// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.remoteplay

import com.couchsubs.mobile.core.ManualAddress

/**
 * Ayarlar > Konsol'da "IP Adresi Gir": PS5'in ağdaki adresi değişince (modem yeni adres verdi) kayıtlı PS5 yazılan adrese
 * taşınır; kayıt anahtarı korunur, yeniden eşleme gerekmez. Eskiden elle adres yalnız ilk kurulumda giriliyordu (X'te
 * bildirim, beta.90). Yalnız IPv4 kabul edilir; geçersizse null (Mac, iPhone, Windows ile aynı kural).
 */
object ConsoleIpEntry {
    fun apply(console: RegisteredConsole, input: String): RegisteredConsole? {
        val host = ManualAddress.normalize(input) ?: return null
        if (!host.all { it.isDigit() || it == '.' }) return null
        return console.withHost(host)
    }
}
