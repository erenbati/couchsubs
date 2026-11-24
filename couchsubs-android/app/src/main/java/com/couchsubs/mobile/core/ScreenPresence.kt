// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.core

import kotlin.math.abs
import kotlin.math.sqrt

/**
 * Ekran yazısı çevirisinin takibi (Mac/iPhone: ScreenPresence.swift, Windows: ScreenPresence.cs; aynı kural, aynı eşikler):
 * her karede, çevirisi gösterilen her öğenin kutusunun küçük gri izi ([COLS] x [ROWS]) ilk görüldüğü izle karşılaştırılır
 * (Pearson ilintisinin büyüklüğü; seçim gezince ters dönen renk aynı yazıdır). İz düzleşti ya da ilinti
 * [INSTANT_CORRELATION]'ın altında: çeviri aynı karede kalkar. [GONE_CORRELATION]'ın altında [SETTLE_FRAMES] kare kalırsa da
 * kalkar; [BACK_CORRELATION]'a [SETTLE_FRAMES] kare çıkarsa geri gelir. İlk izi düz öğe hemen yok sayılır. Telefon kartı,
 * balonlar, sohbet paneli ve özgün stili olmayan öğe izlenmez. Ortak deneme dosyası fixtures/screen-presence.json.
 */
class ScreenPresence {
    companion object {
        const val COLS = 24
        const val ROWS = 6
        const val GONE_CORRELATION = 0.5
        const val INSTANT_CORRELATION = 0.3
        const val BACK_CORRELATION = 0.8
        const val SETTLE_FRAMES = 2
        const val FLAT_DEVIATION = 6.0

        fun tracks(item: ScreenTranslation.Item): Boolean = item.look != null && ScreenFit.takesPart(item) && item.panel == null

        private fun key(item: ScreenTranslation.Item): String {
            fun r(v: Double) = Math.round(v * 1000)
            return "${item.source}|${r(item.box.left)},${r(item.box.top)},${r(item.box.right)},${r(item.box.bottom)}"
        }

        /** İki izin ilintisinin büyüklüğü (0…1); biri düzse null. */
        internal fun correlation(a: List<Int>, b: List<Int>): Double? {
            if (a.size != b.size || a.isEmpty()) return null
            val n = a.size.toDouble()
            val ma = a.sum() / n
            val mb = b.sum() / n
            var sab = 0.0
            var saa = 0.0
            var sbb = 0.0
            for (i in a.indices) {
                val x = a[i] - ma
                val y = b[i] - mb
                sab += x * y
                saa += x * x
                sbb += y * y
            }
            if (sqrt(saa / n) < FLAT_DEVIATION || sqrt(sbb / n) < FLAT_DEVIATION) return null
            return abs(sab / sqrt(saa * sbb))
        }

        private fun flat(a: List<Int>): Boolean {
            if (a.isEmpty()) return true
            val n = a.size.toDouble()
            val m = a.sum() / n
            return sqrt(a.sumOf { (it - m) * (it - m) } / n) < FLAT_DEVIATION
        }

        /** Kutunun izi: kutu [COLS] x [ROWS] ızgaraya bölünür, her hücrenin ortasının parlaklığı ([luma]: piksel, 0-255). */
        fun patch(box: TextBox, width: Int, height: Int, luma: (Int, Int) -> Int): List<Int>? {
            if (width <= 0 || height <= 0) return null
            val x0 = box.left * width
            val y0 = box.top * height
            val w = (box.right - box.left) * width
            val h = (box.bottom - box.top) * height
            if (w < 2 || h < 2) return null
            return (0 until COLS * ROWS).map { i ->
                val r = i / COLS
                val c = i % COLS
                val x = (x0 + (c + 0.5) * w / COLS).toInt().coerceIn(0, width - 1)
                val y = (y0 + (r + 0.5) * h / ROWS).toInt().coerceIn(0, height - 1)
                luma(x, y)
            }
        }
    }

    private class Entry(val reference: List<Int>, var visible: Boolean) {
        var streak = 0
    }

    private var entries = mutableMapOf<String, Entry>()

    /**
     * Bu karede görünür olan öğeler. [patch]: öğenin kutusunun bu karedeki izi (null: kutu karenin dışında, öğe görünür kalır).
     * Listede olmayan öğeler unutulur.
     */
    fun visible(items: List<ScreenTranslation.Item>, patch: (TextBox) -> List<Int>?): List<Boolean> {
        val kept = mutableMapOf<String, Entry>()
        val result = items.map { item ->
            if (!tracks(item)) return@map true
            val key = key(item)
            val now = patch(item.box)
            if (now == null) {
                entries[key]?.let { kept[key] = it }
                return@map entries[key]?.visible ?: true
            }
            val entry = kept[key] ?: entries[key]
            if (entry == null) {
                val fresh = Entry(now, !flat(now))
                kept[key] = fresh
                return@map fresh.visible
            }
            val score = correlation(entry.reference, now) ?: 0.0
            val flips = if (entry.visible) score < GONE_CORRELATION else score >= BACK_CORRELATION
            entry.streak = if (flips) entry.streak + 1 else 0
            // Yazı silindi (iz düz) ya da yerinde bambaşka yazı var: beklemeden, bu karede kalkar.
            val instant = entry.visible && score < INSTANT_CORRELATION
            if (instant || entry.streak >= SETTLE_FRAMES) {
                entry.visible = !entry.visible
                entry.streak = 0
            }
            kept[key] = entry
            entry.visible
        }
        entries = kept
        return result
    }

    /** Öğenin özgün yazısı kalktı mı (son karede yok sayıldı). */
    fun hidden(item: ScreenTranslation.Item): Boolean = tracks(item) && entries[key(item)]?.visible == false

    fun reset() {
        entries = mutableMapOf()
    }
}
