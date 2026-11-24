// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.core

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sin

/**
 * Çapa takibi ([ScreenAnchor]): telefonun/kartın dörtgeni her karede alt piksel izlenir. Ortak deneme dosyası
 * fixtures/screen-anchor.json (Mac ScreenAnchorTests.swift ve Windows ScreenAnchorTests.cs aynı vakalar).
 */
class ScreenAnchorTest {
    private fun doubles(array: JSONArray) = DoubleArray(array.length()) { array.getDouble(it) }

    private fun motion(array: JSONArray): ScreenAnchor.Motion {
        val v = doubles(array)
        return ScreenAnchor.Motion(v[0], v[1], v[2], v[3], v[4], v[5], v[6], v[7])
    }

    private fun rect(array: JSONArray): ScreenAnchor.Rect {
        val r = doubles(array)
        return ScreenAnchor.Rect(r[0], r[1], r[2], r[3])
    }

    /** Ortak kurala göre yapay kare (bkz. fixture note). */
    private fun render(width: Int, height: Int, rect: ScreenAnchor.Rect, m: ScreenAnchor.Motion, frame: Int, gain: Double,
                       content: DoubleArray?): ScreenAnchor.Gray {
        val cx = rect.centerX
        val cy = rect.centerY
        val inverse = ScreenAnchor.invert3(doubleArrayOf(m.a, m.b, m.dx, m.c, m.d, m.dy, m.g, m.h, 1.0))!!
        val pixels = ByteArray(width * height)
        val offsets = listOf(0.25 to 0.25, 0.75 to 0.25, 0.25 to 0.75, 0.75 to 0.75)
        for (y in 0 until height) {
            for (x in 0 until width) {
                var sum = 0.0
                for ((sx, sy) in offsets) {
                    val fx = x + sx - 0.5
                    val fy = y + sy - 0.5
                    val px = fx - cx
                    val py = fy - cy
                    val w = inverse[6] * px + inverse[7] * py + inverse[8]
                    val u = (inverse[0] * px + inverse[1] * py + inverse[2]) / w
                    val v = (inverse[3] * px + inverse[4] * py + inverse[5]) / w
                    sum += if (abs(u) <= rect.width / 2 && abs(v) <= rect.height / 2) {
                        if (content != null && u >= content[0] && v >= content[1] && u <= content[2] && v <= content[3]) {
                            120 + 60 * sin(0.33 * u + 0.11 * v)
                        } else {
                            128 + 50 * sin(0.21 * u) * cos(0.17 * v) + 40 * sin(0.05 * (u + 2 * v))
                        }
                    } else {
                        60 + 30 * sin(0.13 * fx + 0.07 * fy + 0.4 * frame)
                    }
                }
                val value = sum / 4 * gain
                pixels[y * width + x] = max(0.0, min(255.0, Math.floor(value + 0.5))).toInt().toByte()
            }
        }
        return ScreenAnchor.Gray(width, height, pixels)
    }

    @Test
    fun sharedTrackingVectors() {
        val cases = JSONObject(Fixtures.text("screen-anchor.json")).getJSONArray("cases")
        for (c in 0 until cases.length()) {
            val vector = cases.getJSONObject(c)
            val name = vector.getString("name")
            val rect = rect(vector.getJSONArray("rect"))
            val width = vector.getInt("width")
            val height = vector.getInt("height")
            val tolerance = vector.getDouble("tolerance")
            val gains = vector.optJSONArray("gain")?.let(::doubles)
            val content = vector.optJSONArray("content")?.let(::doubles)
            val contentFrom = vector.optInt("contentFrom", Int.MAX_VALUE)
            val lostFrom = vector.optInt("lostFrom", Int.MAX_VALUE)
            val motionsArray = vector.getJSONArray("motions")
            val motions = (0 until motionsArray.length()).map { motion(motionsArray.getJSONArray(it)) }
            val tracker = ScreenAnchor.Tracker()
            for ((k, truth) in motions.withIndex()) {
                val frame = render(width, height, rect, truth, k, gains?.get(k) ?: 1.0, if (k >= contentFrom) content else null)
                if (k == 0) {
                    tracker.begin(frame, rect)
                    continue
                }
                val fix = tracker.track(frame)
                if (k >= lostFrom) {
                    assertNull("$name #$k", fix)
                    break
                }
                assertNotNull("$name #$k: çapa kayboldu", fix)
                val error = fix!!.motion.distance(truth, rect)
                assertTrue("$name #$k: $error", error < tolerance)
            }
        }
    }

    @Test
    fun sharedSmootherVectors() {
        val vectors = JSONObject(Fixtures.text("screen-anchor.json")).getJSONArray("smoother")
        for (c in 0 until vectors.length()) {
            val vector = vectors.getJSONObject(c)
            val rect = rect(vector.getJSONArray("rect"))
            val smoother = ScreenAnchor.Smoother()
            val steps = vector.getJSONArray("steps")
            for (k in 0 until steps.length()) {
                val step = steps.getJSONObject(k)
                val got = smoother.push(motion(step.getJSONArray("raw")), rect)
                assertEquals("#$k", motion(step.getJSONArray("shown")), got.first)
                assertEquals("#$k", step.getBoolean("jumped"), got.second)
            }
        }
    }

    @Test
    fun grayFromRgba() {
        val bytes = ByteArray(4 * 4 * 4) { 255.toByte() }
        bytes[0] = 0; bytes[1] = 0; bytes[2] = 0
        bytes[bytes.size - 4] = 80; bytes[bytes.size - 3] = 40; bytes[bytes.size - 2] = 0
        val gray = ScreenAnchor.Gray.fromRgba(bytes, 4, 4, targetWidth = 2)
        assertEquals(2, gray.width)
        assertEquals(2, gray.height)
        assertArrayEquals(byteArrayOf(191.toByte(), 255.toByte(), 255.toByte(), 203.toByte()), gray.pixels)
        assertArrayEquals(byteArrayOf(191.toByte(), 255.toByte(), 255.toByte(), 200.toByte()),
            ScreenAnchor.Gray.fromRgba(bytes, 4, 4, bgr = true, targetWidth = 2).pixels)
    }
}
