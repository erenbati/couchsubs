// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.core

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Test
import kotlin.random.Random

/**
 * Ekran yazısı çevirisinin oturum boyunca kararlı görünüşü ([ScreenStyleLock]). Ortak deneme dosyası
 * fixtures/screen-style-lock.json (Mac ScreenStyleLockTests.swift ve Windows ScreenStyleLockTests.cs aynı vakalar).
 */
class ScreenStyleLockTest {
    private fun item(entry: JSONObject): ScreenTranslation.Item {
        val source = entry.getString("source")
        val icons = entry.getInt("icons")
        return ScreenTranslation.Item(
            source = source, translation = "TR $source", box = TextBox(0.1, 0.1, 0.3, 0.14), lineHeight = entry.getDouble("line"),
            icons = if (icons > 0) (0 until icons).map { IconPlacement(it, "data:image/png;base64,") } else null,
            surface = TextSurface(entry.getString("bg"), entry.getString("fg")),
            look = if (entry.optBoolean("look", true)) {
                TextLook(entry.getBoolean("bold"), entry.getBoolean("condensed"), "left", entry.getBoolean("upper"))
            } else null,
            bubble = entry.optBoolean("bubble", false),
            rows = entry.getInt("rows"),
        )
    }

    @Test
    fun sharedStyleLockVectors() {
        val cases = JSONObject(Fixtures.text("screen-style-lock.json")).getJSONArray("cases")
        for (c in 0 until cases.length()) {
            val vector = cases.getJSONObject(c)
            val name = vector.getString("name")
            val lock = ScreenStyleLock()
            val steps = vector.getJSONArray("steps")
            for (s in 0 until steps.length()) {
                val step = steps.getJSONObject(s)
                val raw = step.getJSONArray("items")
                val got = lock.steady((0 until raw.length()).map { item(raw.getJSONObject(it)) }, step.getLong("now"))
                val expect = step.getJSONArray("expect")
                assertEquals("$name #$s", expect.length(), got.size)
                for (k in got.indices) {
                    val want = expect.getJSONObject(k)
                    val label = "$name #$s.$k"
                    assertEquals(label, want.getDouble("line"), got[k].lineHeight, 1e-9)
                    assertEquals(label, want.getString("fg"), got[k].surface?.foreground)
                    assertEquals(label, want.getString("bg"), got[k].surface?.background)
                    got[k].look?.let {
                        assertEquals(label, want.getBoolean("bold"), it.bold)
                        assertEquals(label, want.getBoolean("condensed"), it.condensed)
                    }
                }
            }
        }
    }

    /** Ölçüt: ±%10 titreyen menüde aynı öğenin boyu/stili kareler arasında hiç değişmez. */
    @Test
    fun jitteringMenuNeverChangesLook() {
        val lock = ScreenStyleLock()
        val random = Random(7)
        val first = mutableMapOf<String, List<Any>>()
        for (frame in 0 until 120) {
            val rows = listOf("MAP", "BRIEF", "PROGRESS", "SETTINGS").map { name ->
                ScreenTranslation.Item(
                    source = name, translation = name, box = TextBox(0.1, 0.1, 0.2, 0.13),
                    lineHeight = 0.03 * (0.9 + 0.2 * random.nextDouble()),
                    surface = TextSurface("#%02X1010".format(random.nextInt(0, 31)), "#FFFFFF"),
                    look = TextLook(random.nextBoolean(), false, "left", true),
                )
            }
            for (item in lock.steady(rows, frame * 500L)) {
                val look = listOf(item.lineHeight, item.look!!.bold, item.surface!!.background, item.surface!!.foreground)
                val seen = first[item.source]
                if (seen != null) assertEquals(item.source, seen, look) else first[item.source] = look
            }
        }
    }
}
