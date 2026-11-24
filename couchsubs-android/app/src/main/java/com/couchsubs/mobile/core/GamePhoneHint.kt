// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.core

/**
 * "Telefon çevirisi kapalı, açmak ister misiniz?" ipucu (#1202): GTA 6 telefonu ayarı kapalıyken telefonun mesaj listesi
 * altyazı alanına düşünce altyazı yolu onu sahne yazısı sayıp atıyor ("eğik satır", "koyu yazı açık zeminde"), kullanıcı
 * telefonun neden çevrilmediğini anlamıyordu. Böyle bir ret oturumda bir kez ipucu doğurur. Mac/iPhone ve Windows
 * (GamePhoneHint) aynı kuralı uygular.
 */
class GamePhoneHint {
    /** Bu oturumda ipucu önerildi. */
    var offered = false
        private set

    /** Sahne yazısı reddi ipucu doğurur mu: telefon kapalı, oyun GTA 6, neden telefon listesine uyuyor; oturumda bir kez. */
    fun observe(reason: String, readsPhone: Boolean, game: String?): Boolean {
        if (offered || readsPhone || game == null || GameName.key(game) != "gta 6" || !isPhoneList(reason)) return false
        offered = true
        return true
    }

    /** Yeni oturum: ipucu yeniden önerilebilir. */
    fun reset() {
        offered = false
    }

    companion object {
        /** Telefonun mesaj listesinin altyazı yolunda aldığı ret nedenleri (eğik satır, açık zeminde koyu yazı). */
        fun isPhoneList(reason: String): Boolean = reason.startsWith("eğik satır") || reason == InkTone.REASON
    }
}
