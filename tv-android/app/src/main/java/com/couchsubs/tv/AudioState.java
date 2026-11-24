// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.tv;

import java.util.LinkedHashSet;

/**
 * Bilgi panelindeki ses tanısı (TV uygulaması 0.9.98). X'te üç bildirim: Android TV'de (biri Hi-Level, ses AV
 * yükselticiden geçiyor) ve LG'de "TV uygulaması açıkken görüntü var, ses yok; PS5'in kendi girişine geçince ses geliyor".
 * Uygulama içinde HDMI sesi TvView'in oturumundadır; CouchSubs sesi kısmaz, ses odağı istemez, ses parçası seçmez,
 * tune'dan önce TvView'in ses düzeyini 1 yapar (MainActivity.tune). Kök neden doğrulanmadı; tahmin, TV'nin uygulama
 * içindeki HDMI ses yolunun harici ses cihazına (HDMI ARC/eARC) PS5'in sıkıştırılmış sesini (Dolby/DTS) geçirmemesi.
 * Bir sonraki bildirimde görülsün diye panelde: medya ses düzeyi, kısık mı, bağlı ses çıkışları, medyanın gittiği çıkış
 * (Android 13+) ve TvView'in bildirdiği ses parçaları.
 *
 * Örnek: "snd v7/15 out spk,arc to arc atr 1/1". Buradaki biçimleme Android'e bağlı değildir (bkz. AudioStateTest).
 */
final class AudioState {
    private AudioState() {}

    /** AudioDeviceInfo.TYPE_* değerlerinin kısa adı (sabitler Android'den bağımsız denensin diye sayıyla yazılı). */
    static String deviceName(int type) {
        switch (type) {
            case 2: return "spk";      // TYPE_BUILTIN_SPEAKER
            case 3: return "hs";       // TYPE_WIRED_HEADSET
            case 4: return "hp";       // TYPE_WIRED_HEADPHONES
            case 5: return "line";     // TYPE_LINE_ANALOG
            case 8: return "bt";       // TYPE_BLUETOOTH_A2DP
            case 9: return "hdmi";     // TYPE_HDMI
            case 10: return "arc";     // TYPE_HDMI_ARC
            case 11: return "usb";     // TYPE_USB_DEVICE
            case 13: return "dock";    // TYPE_DOCK
            case 14: return "spdif";   // TYPE_LINE_DIGITAL (optik/koaksiyel)
            case 19: return "aux";     // TYPE_AUX_LINE
            case 22: return "usbhs";   // TYPE_USB_HEADSET
            case 26: return "ble";     // TYPE_BLE_HEADSET
            case 27: return "bles";    // TYPE_BLE_SPEAKER
            case 29: return "earc";    // TYPE_HDMI_EARC
            case 30: return "bleb";    // TYPE_BLE_BROADCAST
            default: return "t" + type;
        }
    }

    /** Aygıt türleri listesi: kısa adlar, virgülle, tekrarsız; boşsa "-". */
    static String devices(int[] types) {
        if (types == null || types.length == 0) return "-";
        StringBuilder out = new StringBuilder();
        LinkedHashSet<String> seen = new LinkedHashSet<>();
        for (int type : types) seen.add(deviceName(type));
        for (String name : seen) {
            if (out.length() > 0) out.append(',');
            out.append(name);
        }
        return out.toString();
    }

    /**
     * Panel metni. volume/max: STREAM_MUSIC (max <= 0: okunamadı); outputs: bağlı ses çıkışları; routed: medyanın gittiği
     * çıkış (null: Android 12 ve öncesi ya da okunamadı); audioTracks: TvView'in bildirdiği ses parçası sayısı (-1: henüz
     * bildirmedi); audioSelected: seçili ses parçası var mı.
     */
    static String text(int volume, int max, boolean muted, int[] outputs, int[] routed, int audioTracks,
            boolean audioSelected) {
        StringBuilder text = new StringBuilder("snd");
        if (max > 0) text.append(" v").append(volume).append('/').append(max);
        if (muted) text.append(" muted");
        text.append(" out ").append(devices(outputs));
        if (routed != null) text.append(" to ").append(devices(routed));
        if (audioTracks >= 0) text.append(" atr ").append(audioSelected ? 1 : 0).append('/').append(audioTracks);
        return text.toString();
    }
}
