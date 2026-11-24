// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.core

import kotlin.math.abs

/**
 * "Ekranı çevir" ve otomatik ekran yazısında çevirinin görünüşü oturum boyunca kararlı (Mac/iPhone: ScreenStyleLock.swift,
 * Windows: ScreenStyleLock.cs; aynı kural, aynı eşikler). Öğe türü başına (tuş ipucu, çok satırlı metin, BÜYÜK HARF
 * başlık/sekme, düz etiket) yazı boyu, kalınlık, dar aile ve renkler ilk ölçümde kilitlenir. Kilitli boya [SIZE_SHARE]
 * içinde yakın ölçüm kilitli boyla çizilir (öğe son çizildiği boyda kalır); aynı karede kilitli boya uyan öğe varken uymayan
 * öğe ayrı boydur, hemen kilitlenir. Türün hiçbir öğesi uymuyorsa değişim ancak kesintisiz [SETTLE_MS] sürerse benimsenir.
 * Renk çifti kilitli bir çifte [COLOR_SLACK] içinde yakınsa o çift çizilir. Telefon kartı, balonlar, sohbet paneli ve özgün
 * stili olmayan öğe kilide girmez. Ortak deneme dosyası fixtures/screen-style-lock.json.
 */
class ScreenStyleLock {
    companion object {
        const val SIZE_SHARE = PhonePanelSteady.SIZE_SHARE
        const val SETTLE_MS = PhonePanelSteady.SETTLE_MS
        const val SAME_LINE = ScreenFit.SAME_LINE
        const val COLOR_SLACK = 40
        internal const val PALETTE_LIMIT = 32
        internal const val SEEN_LIMIT = 256

        internal fun role(item: ScreenTranslation.Item): String? {
            val look = item.look ?: return null
            if (!ScreenFit.takesPart(item) || item.panel != null || item.lineHeight <= 0) return null
            if (!item.icons.isNullOrEmpty()) return "hint"
            if (item.rows > 1 || item.paragraphs) return "body"
            return if (look.upper) "caps" else "label"
        }

        /** Bir karedeki öğelerin boyları: yakın boylar ([SAME_LINE]) tek boyda, değeri ortanca öğeninki; her boyun öğeleri. */
        private fun tiers(items: List<ScreenTranslation.Item>): List<Pair<Tier, List<Int>>> {
            val groups = mutableListOf<MutableList<Int>>()
            for (i in items.indices.sortedBy { items[it].lineHeight }) {
                val last = groups.lastOrNull()
                if (last != null && items[i].lineHeight <= items[last[0]].lineHeight * (1 + SAME_LINE)) last.add(i)
                else groups.add(mutableListOf(i))
            }
            return groups.map { group ->
                val middle = items[group[(group.size - 1) / 2]]
                Tier(middle.lineHeight, middle.look?.bold ?: false, middle.look?.condensed ?: false) to group
            }
        }

        internal fun near(a: String, b: String): Boolean {
            val x = rgb(a) ?: return a == b
            val y = rgb(b) ?: return a == b
            return abs(x.first - y.first) <= COLOR_SLACK && abs(x.second - y.second) <= COLOR_SLACK &&
                abs(x.third - y.third) <= COLOR_SLACK
        }

        private fun rgb(hex: String): Triple<Int, Int, Int>? {
            if (hex.length != 7 || hex[0] != '#') return null
            val value = hex.substring(1).toIntOrNull(16) ?: return null
            return Triple((value shr 16) and 0xFF, (value shr 8) and 0xFF, value and 0xFF)
        }
    }

    private data class Tier(val line: Double, val bold: Boolean, val condensed: Boolean)

    private class Kind {
        val tiers = mutableListOf<Tier>()
        var since: Long? = null
        /** Öğenin (özgün yazısıyla) son çizildiği boy. */
        val seen = mutableMapOf<String, Int>()
    }

    private val kinds = mutableMapOf<String, Kind>()
    private val palettes = mutableMapOf<String, MutableList<TextSurface>>()

    /** Öğeler kilitli görünüşle. [now]: milisaniye (tekdüze saat). */
    fun steady(items: List<ScreenTranslation.Item>, now: Long): List<ScreenTranslation.Item> {
        val result = items.toMutableList()
        val roles = items.map { role(it) }
        for (role in roles.filterNotNull().distinct().sorted()) {
            val members = items.indices.filter { roles[it] == role }
            var kind = kinds[role] ?: Kind()
            fun off(line: Double, t: Int) = abs(line / kind.tiers[t].line - 1)
            // Öğenin boyu: önceki karede çizildiği boy hâlâ uyuyorsa o (eş boylar arasında gidip gelmesin), yoksa en yakın uyan boy.
            fun tierOf(i: Int): Int? {
                val line = items[i].lineHeight
                val seen = kind.seen[items[i].source]
                if (seen != null && seen < kind.tiers.size && off(line, seen) <= SIZE_SHARE) return seen
                return kind.tiers.indices.filter { off(line, it) <= SIZE_SHARE }.minByOrNull { off(line, it) }
            }
            fun adopt(fresh: List<Int>) {
                for ((tier, group) in tiers(fresh.map { items[it] })) {
                    for (k in group) kind.seen[items[fresh[k]].source] = kind.tiers.size
                    kind.tiers.add(tier)
                }
            }
            val matched = members.filter { tierOf(it) != null }
            if (kind.tiers.isEmpty()) {
                adopt(members)
            } else if (matched.isEmpty()) {
                // Türün hiçbir öğesi kilitli boya uymuyor: ölçek değişimi adayı.
                val since = kind.since
                if (since != null && now - since >= SETTLE_MS) {
                    kind = Kind()
                    adopt(members)
                } else if (since == null) {
                    kind.since = now
                }
            } else {
                kind.since = null
                // Uyan öğe varken uymayan öğe aynı ekranda başka boydaki öğedir (başlık ve satır).
                val fresh = members.filter { tierOf(it) == null }
                if (fresh.isNotEmpty()) adopt(fresh)
            }
            if (kind.seen.size > SEEN_LIMIT) kind.seen.clear()
            for (i in members) {
                val line = items[i].lineHeight
                val found = tierOf(i)
                val index = found ?: kind.tiers.indices.minByOrNull { off(line, it) }!!
                if (found != null) kind.seen[items[i].source] = index
                val locked = kind.tiers[index]
                val item = result[i]
                result[i] = item.copy(
                    lineHeight = locked.line,
                    look = item.look!!.copy(bold = locked.bold, condensed = locked.condensed),
                    surface = item.surface?.let { palette(it, role) },
                )
            }
            kinds[role] = kind
        }
        return result
    }

    private fun palette(surface: TextSurface, role: String): TextSurface {
        val known = palettes.getOrPut(role) { mutableListOf() }
        known.firstOrNull { near(it.background, surface.background) && near(it.foreground, surface.foreground) }?.let {
            return it.copy(flat = surface.flat)
        }
        known.add(surface)
        if (known.size > PALETTE_LIMIT) known.removeAt(0)
        return surface
    }

    /** Oturum bitti: sonraki öğeler yeniden ölçülür. */
    fun reset() {
        kinds.clear()
        palettes.clear()
    }
}
