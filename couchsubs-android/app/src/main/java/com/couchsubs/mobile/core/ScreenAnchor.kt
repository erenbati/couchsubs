// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.core

import kotlin.math.abs
import kotlin.math.ceil
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt
import kotlin.math.sqrt

/**
 * Çapa takibi (GTA 6 telefonu, görev/harita kartı; Mac/iPhone: ScreenAnchor.swift, Windows: ScreenAnchor.cs; aynı adımlar,
 * aynı eşikler): çevirinin dayandığı dörtgen her karede OCR'sız, alt piksel düzeyinde izlenir. Başvuru karesindeki dörtgenin
 * görüntüsü şablon olur; her yeni karede şablonun izdüşümsel dönüşümü (öteleme + ölçek + dönme + perspektif) ters bileşimli
 * Lucas-Kanade ile piramitte, sağlam ağırlıkla bulunur. Ekranda değişen yazı, önden geçen el ağırlığını yitirir; şablon
 * güncellenmez (kayma birikmez). Uyum çok düşerse çapa kaybolur, sonraki okumada yeniden kurulur. Ortak deneme dosyası
 * fixtures/screen-anchor.json; ölçüm docs/ekran-capasi.md.
 */
object ScreenAnchor {
    const val TRACK_WIDTH = 960
    const val LEVELS = 4
    const val COARSEST_WIDTH = 20.0
    const val SEARCH_RADIUS = 3
    const val MAX_POINTS = 2500
    const val ITERATIONS = 15
    const val HUBER = 8.0
    const val LOST_SHARE = 0.45
    const val INSET = 0.03

    fun levelCount(width: Double): Int {
        var count = 1
        while (count < LEVELS && width / (1 shl count) >= COARSEST_WIDTH) count++
        return count
    }

    /** Gri kare (satır satır, üstten). */
    class Gray(val width: Int, val height: Int, val pixels: ByteArray) {
        init {
            require(width > 1 && height > 1 && pixels.size >= width * height)
        }

        internal fun half(): Gray {
            val w = max(2, width / 2)
            val h = max(2, height / 2)
            val out = ByteArray(w * h)
            for (y in 0 until h) {
                val r0 = min(height - 1, 2 * y) * width
                val r1 = min(height - 1, 2 * y + 1) * width
                for (x in 0 until w) {
                    val x0 = min(width - 1, 2 * x)
                    val x1 = min(width - 1, 2 * x + 1)
                    val sum = at(r0 + x0) + at(r0 + x1) + at(r1 + x0) + at(r1 + x1)
                    out[y * w + x] = ((sum + 2) / 4).toByte()
                }
            }
            return Gray(w, h, out)
        }

        private fun at(i: Int): Int = pixels[i].toInt() and 0xFF

        /** Çift doğrusal örnek; kare dışı NaN. */
        internal fun sample(x: Double, y: Double): Double {
            if (!(x >= 0) || !(y >= 0) || x > width - 1 || y > height - 1) return Double.NaN
            val x0 = min(width - 2, x.toInt())
            val y0 = min(height - 2, y.toInt())
            val fx = x - x0
            val fy = y - y0
            val i = y0 * width + x0
            val p00 = at(i).toDouble()
            val p10 = at(i + 1).toDouble()
            val p01 = at(i + width).toDouble()
            val p11 = at(i + width + 1).toDouble()
            val top = p00 + (p10 - p00) * fx
            val bottom = p01 + (p11 - p01) * fx
            return top + (bottom - top) * fy
        }

        companion object {
            /** RGBA (ya da BGRA) karesinden [targetWidth] ene (tam sayı katla) küçültülmüş gri kare: kutu ortalaması,
             *  parlaklık (2R + 5G + B) / 8. */
            fun fromRgba(bytes: ByteArray, width: Int, height: Int, bgr: Boolean = false, targetWidth: Int = TRACK_WIDTH): Gray {
                val factor = max(1, (width.toDouble() / targetWidth).roundHalfUp())
                val w = max(2, width / factor)
                val h = max(2, height / factor)
                val out = ByteArray(w * h)
                val r = if (bgr) 2 else 0
                val b = if (bgr) 0 else 2
                val count = factor * factor
                for (y in 0 until h) {
                    for (x in 0 until w) {
                        var sum = 0
                        for (yy in 0 until factor) {
                            var p = (min(height - 1, y * factor + yy) * width + min(width - 1, x * factor)) * 4
                            repeat(factor) {
                                sum += 2 * (bytes[p + r].toInt() and 0xFF) + 5 * (bytes[p + 1].toInt() and 0xFF) +
                                    (bytes[p + b].toInt() and 0xFF)
                                p += 4
                            }
                        }
                        out[y * w + x] = min(255, (sum + 4 * count) / (8 * count)).toByte()
                    }
                }
                return Gray(w, h, out)
            }

            private fun Double.roundHalfUp(): Int = if (this >= 0) (this + 0.5).toInt() else this.roundToInt()
        }
    }

    data class Rect(val x: Double, val y: Double, val width: Double, val height: Double) {
        val centerX: Double get() = x + width / 2
        val centerY: Double get() = y + height / 2
    }

    /** Başvurudan güncel kareye izdüşümsel dönüşüm: u = x − cx, v = y − cy için nokta
     *  (cx + (a u + b v + dx) / w, cy + (c u + d v + dy) / w); w = 1 + g u + h v. */
    data class Motion(
        val a: Double = 1.0, val b: Double = 0.0, val c: Double = 0.0, val d: Double = 1.0,
        val dx: Double = 0.0, val dy: Double = 0.0, val g: Double = 0.0, val h: Double = 0.0,
    ) {
        val scale: Double get() = sqrt(abs(a * d - b * c))

        fun map(x: Double, y: Double, cx: Double, cy: Double): Pair<Double, Double> {
            val u = x - cx
            val v = y - cy
            val w = 1 + g * u + h * v
            return Pair(cx + (a * u + b * v + dx) / w, cy + (c * u + d * v + dy) / w)
        }

        internal fun scaled(factor: Double) = copy(dx = dx / factor, dy = dy / factor, g = g * factor, h = h * factor)

        fun distance(other: Motion, rect: Rect): Double {
            val cx = rect.centerX
            val cy = rect.centerY
            var worst = 0.0
            for ((x, y) in listOf(rect.x to rect.y, rect.x + rect.width to rect.y, rect.x to rect.y + rect.height,
                rect.x + rect.width to rect.y + rect.height)) {
                val p = map(x, y, cx, cy)
                val q = other.map(x, y, cx, cy)
                worst = max(worst, sqrt((p.first - q.first) * (p.first - q.first) + (p.second - q.second) * (p.second - q.second)))
            }
            return worst
        }

        companion object {
            val IDENTITY = Motion()
        }
    }

    data class Fix(val motion: Motion, val inliers: Double)

    /** Şablon izleyici: [begin] başvuru karesinde dörtgeni şablon yapar, [track] her yeni karede dönüşümü bulur; çapa
     *  kaybolunca null (yeniden [begin] gerekir). */
    class Tracker {
        private class Level(val factor: Double, val offset: Double) {
            val u = ArrayList<Double>()
            val v = ArrayList<Double>()
            var t = DoubleArray(0)
            var gx = DoubleArray(0)
            var gy = DoubleArray(0)
        }

        private val pyramid = ArrayList<Level>()
        private var previous: Motion? = null
        var rect: Rect? = null
            private set
        var motion: Motion = Motion.IDENTITY
            private set
        val isActive: Boolean get() = rect != null

        fun begin(frame: Gray, rect: Rect) {
            val inner = Rect(rect.x + rect.width * INSET, rect.y + rect.height * INSET, rect.width * (1 - 2 * INSET),
                rect.height * (1 - 2 * INSET))
            this.rect = rect
            motion = Motion.IDENTITY
            previous = null
            pyramid.clear()
            val count = levelCount(inner.width)
            var image = frame
            for (index in 0 until count) {
                val factor = (1 shl index).toDouble()
                val level = Level(factor, (factor - 1) / 2)
                val w = inner.width / factor
                val h = inner.height / factor
                val step = max(1, ceil(sqrt(w * h / MAX_POINTS)).toInt())
                val cols = max(2, w.toInt() / step)
                val rows = max(2, h.toInt() / step)
                for (row in 0 until rows) {
                    for (col in 0 until cols) {
                        level.u.add((col + 0.5) * w / cols - w / 2)
                        level.v.add((row + 0.5) * h / rows - h / 2)
                    }
                }
                sampleTemplate(level, image, rect)
                pyramid.add(level)
                if (index + 1 < count) image = image.half()
            }
        }

        fun reset() {
            rect = null
            motion = Motion.IDENTITY
            previous = null
            pyramid.clear()
        }

        fun track(frame: Gray): Fix? {
            val rect = rect ?: return null
            if (pyramid.isEmpty()) return null
            val images = arrayListOf(frame)
            for (i in 1 until pyramid.size) images.add(images.last().half())
            val coarsest = pyramid.size - 1
            val starts = arrayListOf(motion)
            previous?.let { before ->
                val predicted = motion.copy(dx = motion.dx + (motion.dx - before.dx), dy = motion.dy + (motion.dy - before.dy))
                if (predicted != motion) starts.add(predicted)
            }
            starts.add(search(pyramid[coarsest], images[coarsest], rect, starts.last()))
            var best: Fix? = null
            for (start in starts) {
                val fix = align(pyramid[coarsest], images[coarsest], rect, start) ?: continue
                if (best == null || fix.inliers > best.inliers) best = fix
            }
            var current = best ?: run {
                reset()
                return null
            }
            for (index in coarsest - 1 downTo 0) {
                current = align(pyramid[index], images[index], rect, current.motion) ?: run {
                    reset()
                    return null
                }
            }
            if (current.inliers < LOST_SHARE || !plausible(current.motion, rect)) {
                reset()
                return null
            }
            previous = motion
            motion = current.motion
            return current
        }

        private fun sampleTemplate(level: Level, image: Gray, rect: Rect) {
            val cx = (rect.centerX - level.offset) / level.factor
            val cy = (rect.centerY - level.offset) / level.factor
            val n = level.u.size
            level.t = DoubleArray(n) { Double.NaN }
            level.gx = DoubleArray(n)
            level.gy = DoubleArray(n)
            for (i in 0 until n) {
                val x = cx + level.u[i]
                val y = cy + level.v[i]
                val c = image.sample(x, y)
                val l = image.sample(x - 1, y)
                val r = image.sample(x + 1, y)
                val up = image.sample(x, y - 1)
                val down = image.sample(x, y + 1)
                if (c.isNaN() || l.isNaN() || r.isNaN() || up.isNaN() || down.isNaN()) continue
                level.t[i] = c
                level.gx[i] = (r - l) / 2
                level.gy[i] = (down - up) / 2
            }
        }

        private fun search(level: Level, image: Gray, rect: Rect, start: Motion): Motion {
            val cx = (rect.centerX - level.offset) / level.factor
            val cy = (rect.centerY - level.offset) / level.factor
            val m = start.scaled(level.factor)
            val n = level.u.size
            val stride = max(1, n / 400)
            val px = ArrayList<Double>()
            val py = ArrayList<Double>()
            val pt = ArrayList<Double>()
            var i = 0
            while (i < n) {
                val t = level.t[i]
                val u = level.u[i]
                val v = level.v[i]
                val w = 1 + m.g * u + m.h * v
                if (!t.isNaN() && w > 0.1) {
                    px.add(cx + (m.a * u + m.b * v + m.dx) / w)
                    py.add(cy + (m.c * u + m.d * v + m.dy) / w)
                    pt.add(t)
                }
                i += stride
            }
            var bestCost = Double.POSITIVE_INFINITY
            var bestX = 0
            var bestY = 0
            val values = DoubleArray(px.size)
            for (oy in -SEARCH_RADIUS..SEARCH_RADIUS) {
                for (ox in -SEARCH_RADIUS..SEARCH_RADIUS) {
                    var count = 0.0
                    var shift = 0.0
                    for (k in px.indices) {
                        val value = image.sample(px[k] + ox, py[k] + oy)
                        values[k] = value
                        if (value.isNaN()) continue
                        count += 1
                        shift += pt[k] - value
                    }
                    if (count < 16) continue
                    shift /= count
                    var cost = 0.0
                    for (k in px.indices) if (!values[k].isNaN()) cost += abs(values[k] + shift - pt[k])
                    cost /= count
                    if (cost < bestCost) {
                        bestCost = cost
                        bestX = ox
                        bestY = oy
                    }
                }
            }
            return start.copy(dx = start.dx + bestX * level.factor, dy = start.dy + bestY * level.factor)
        }

        private fun align(level: Level, image: Gray, rect: Rect, start: Motion): Fix? {
            val cx = (rect.centerX - level.offset) / level.factor
            val cy = (rect.centerY - level.offset) / level.factor
            var m = start.scaled(level.factor)
            val n = level.u.size
            var share = 0.0
            val values = DoubleArray(n)
            val rejected = BooleanArray(n)
            val s = DoubleArray(8)
            val cut = 3 * HUBER
            for (iteration in 0 until ITERATIONS) {
                val hessian = DoubleArray(64)
                val gradient = DoubleArray(8)
                var count = 0.0
                var kept = 0.0
                var sumI = 0.0
                var sumII = 0.0
                var sumT = 0.0
                var sumTT = 0.0
                for (i in 0 until n) {
                    values[i] = Double.NaN
                    val t = level.t[i]
                    if (t.isNaN()) continue
                    val u = level.u[i]
                    val v = level.v[i]
                    val w = 1 + m.g * u + m.h * v
                    if (!(w > 0.1)) continue
                    val value = image.sample(cx + (m.a * u + m.b * v + m.dx) / w, cy + (m.c * u + m.d * v + m.dy) / w)
                    if (value.isNaN()) continue
                    values[i] = value
                    count += 1
                    if (rejected[i]) continue
                    kept += 1
                    sumI += value
                    sumII += value * value
                    sumT += t
                    sumTT += t * t
                }
                if (count < 16 || kept < 16) return null
                val meanI = sumI / kept
                val meanT = sumT / kept
                val spreadI = sqrt(max(0.0, sumII / kept - meanI * meanI))
                val spreadT = sqrt(max(0.0, sumTT / kept - meanT * meanT))
                val gain = if (spreadI > 1e-6) min(4.0, max(0.25, spreadT / spreadI)) else 1.0
                var good = 0.0
                for (i in 0 until n) {
                    val value = values[i]
                    if (value.isNaN()) continue
                    val t = level.t[i]
                    val u = level.u[i]
                    val v = level.v[i]
                    val r = (value - meanI) * gain + meanT - t
                    val size = abs(r)
                    rejected[i] = size > cut
                    if (size <= HUBER) good += 1
                    if (rejected[i]) continue
                    val weight = if (size <= HUBER) 1.0 else HUBER / size
                    val gx = level.gx[i]
                    val gy = level.gy[i]
                    val radial = gx * u + gy * v
                    s[0] = gx * u
                    s[1] = gx * v
                    s[2] = gy * u
                    s[3] = gy * v
                    s[4] = gx
                    s[5] = gy
                    s[6] = -radial * u
                    s[7] = -radial * v
                    for (p in 0 until 8) {
                        val ws = weight * s[p]
                        gradient[p] += ws * r
                        for (q in p until 8) hessian[p * 8 + q] += ws * s[q]
                    }
                }
                share = good / count
                for (p in 0 until 8) for (q in 0 until p) hessian[p * 8 + q] = hessian[q * 8 + p]
                val step = solve(hessian, gradient) ?: return null
                val delta = doubleArrayOf(1 + step[0], step[1], step[4], step[2], 1 + step[3], step[5], step[6], step[7], 1.0)
                val inverse = invert3(delta) ?: return null
                val current = doubleArrayOf(m.a, m.b, m.dx, m.c, m.d, m.dy, m.g, m.h, 1.0)
                val product = DoubleArray(9)
                for (row in 0 until 3) {
                    for (col in 0 until 3) {
                        product[row * 3 + col] = current[row * 3] * inverse[col] + current[row * 3 + 1] * inverse[3 + col] +
                            current[row * 3 + 2] * inverse[6 + col]
                    }
                }
                val k = product[8]
                if (abs(k) <= 1e-12) return null
                m = Motion(product[0] / k, product[1] / k, product[3] / k, product[4] / k, product[2] / k, product[5] / k,
                    product[6] / k, product[7] / k)
                if (abs(step[4]) < 0.005 && abs(step[5]) < 0.005 && abs(step[0]) < 1e-5 && abs(step[1]) < 1e-5 &&
                    abs(step[2]) < 1e-5 && abs(step[3]) < 1e-5 && abs(step[6]) < 1e-7 && abs(step[7]) < 1e-7) break
            }
            return Fix(m.scaled(1 / level.factor), share)
        }
    }

    /** Dönüşüm elde tutulan telefona/karta uyar mı: ölçek 0,5–2, eksen oranı 0,75–1,33, köşelerde perspektif %15'ten az. */
    fun plausible(m: Motion, rect: Rect): Boolean {
        val scale = m.scale
        if (!(scale > 0.5) || !(scale < 2)) return false
        val x = sqrt(m.a * m.a + m.c * m.c)
        val y = sqrt(m.b * m.b + m.d * m.d)
        if (!(y > 0) || !(x / y > 0.75) || !(x / y < 1.0 / 0.75)) return false
        return abs(m.g) * rect.width / 2 + abs(m.h) * rect.height / 2 < 0.15
    }

    fun invert3(m: DoubleArray): DoubleArray? {
        val c00 = m[4] * m[8] - m[5] * m[7]
        val c01 = m[5] * m[6] - m[3] * m[8]
        val c02 = m[3] * m[7] - m[4] * m[6]
        val det = m[0] * c00 + m[1] * c01 + m[2] * c02
        if (abs(det) <= 1e-12) return null
        return doubleArrayOf(
            c00 / det, (m[2] * m[7] - m[1] * m[8]) / det, (m[1] * m[5] - m[2] * m[4]) / det,
            c01 / det, (m[0] * m[8] - m[2] * m[6]) / det, (m[2] * m[3] - m[0] * m[5]) / det,
            c02 / det, (m[1] * m[6] - m[0] * m[7]) / det, (m[0] * m[4] - m[1] * m[3]) / det,
        )
    }

    internal fun solve(matrix: DoubleArray, vector: DoubleArray): DoubleArray? {
        val m = matrix.copyOf()
        val x = vector.copyOf()
        val n = vector.size
        for (col in 0 until n) {
            var pivot = col
            for (row in col + 1 until n) if (abs(m[row * n + col]) > abs(m[pivot * n + col])) pivot = row
            if (abs(m[pivot * n + col]) <= 1e-9) return null
            if (pivot != col) {
                for (k in 0 until n) {
                    val tmp = m[col * n + k]
                    m[col * n + k] = m[pivot * n + k]
                    m[pivot * n + k] = tmp
                }
                val tmp = x[col]
                x[col] = x[pivot]
                x[pivot] = tmp
            }
            for (row in col + 1 until n) {
                val f = m[row * n + col] / m[col * n + col]
                if (f == 0.0) continue
                for (k in col until n) m[row * n + k] -= f * m[col * n + k]
                x[row] -= f * x[col]
            }
        }
        for (row in n - 1 downTo 0) {
            var sum = x[row]
            for (k in row + 1 until n) sum -= m[row * n + k] * x[k]
            x[row] = sum / m[row * n + row]
        }
        return x
    }

    /** Dönüşümün kararlılığı: ölü bölge ([DEADBAND] pikselden az oynama gösterilmez), sıçramada ([JUMP_SHARE]) çapa
     *  yeniden kurulmalı. */
    class Smoother {
        companion object {
            const val JUMP_SHARE = 0.12
            const val DEADBAND = 0.15
        }

        private var last: Motion? = null
        private var shown: Motion? = null

        fun reset() {
            last = null
            shown = null
        }

        fun push(raw: Motion, rect: Rect): Pair<Motion, Boolean> {
            try {
                val previous = last
                if (previous != null && raw.distance(previous, rect) > JUMP_SHARE * rect.height) {
                    shown = raw
                    return Pair(raw, true)
                }
                val current = shown
                if (current != null && raw.distance(current, rect) <= DEADBAND) return Pair(current, false)
                shown = raw
                return Pair(raw, false)
            } finally {
                last = raw
            }
        }
    }
}
