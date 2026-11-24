// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// Çapa takibi (GTA 6 telefonu, görev/harita kartı): çevirinin dayandığı dörtgen her karede OCR'sız, alt piksel
/// düzeyinde izlenir. Önceden telefonun yeri yalnız OCR turunda (330 ms'de bir, 400×225'lik kaba ızgarada) bulunuyordu;
/// el titremesiyle ya da karakter yürürken telefon kıpırdadıkça çeviriler yerinde kalıyor, eşik aşılınca birden
/// sıçrıyordu ("titriyor, milim oynamadan telefona yapışık dursun", Sinan Bey). Artık başvuru karesindeki dörtgenin
/// görüntüsü şablon olur; her yeni karede şablonun izdüşümsel dönüşümü (öteleme + ölçek + dönme + elde eğilen telefonun
/// perspektifi) ters bileşimli Lucas-Kanade ile piramitte, sağlam ağırlıkla bulunur. Ekranda değişen yazı (yeni mesaj),
/// önden geçen el ağırlığını yitirir; şablon hiç güncellenmez (kayma birikmez). Uyum çok düşerse (sohbet kaydı, telefon
/// indirildi, sahne değişti) çapa kaybolur ve bir sonraki okumada yeniden kurulur. Çeviri katmanı başvuru karesindeki
/// yerleşimiyle kilitlenir, yalnız bu dönüşümle taşınır: yazı boyu, satır kırılımı değişmez.
///
/// Ölçüm (gerçek kayıt, GTA 6, 23 Kas; docs/ekran-capasi.md): izleme hatası 1920 genişlikte ortanca 0,12–0,15, en kötü
/// 0,7 piksel; önceki yöntemde (yer yalnız OCR turunda) ortanca 1,6–4, en kötü 10–83 piksel.
///
/// Windows (ScreenAnchor.cs) ve Android (ScreenAnchor.kt) aynı adımları, aynı eşikleri kullanır; ortak deneme dosyası
/// Fixtures/screen-anchor.json.
public enum ScreenAnchor {
    /// İzleme karesinin eni (piksel): kare bu ene küçültülür (1920 genişlikte yarısı); ölçüler alt piksel olduğu için
    /// asıl karede de piksel altı kalır.
    public static let trackWidth = 960
    /// En çok piramit katı (1, 1/2, 1/4, 1/8).
    static let levels = 4
    /// En kaba katta dörtgenin eni en az bu kadar piksel kalır (küçük dörtgende daha az kat).
    static let coarsestWidth = 20.0
    /// En kaba katta öteleme taramasının yarıçapı (o katın pikseli; dört katta izleme karesinde ±24 piksel).
    static let searchRadius = 3
    /// Bir katta en çok bu kadar örnek nokta (seyrekleştirilir).
    static let maxPoints = 2500
    /// Kat başına en çok yineleme.
    static let iterations = 15
    /// Sağlam ağırlık eşiği (gri düzey, 0–255): farkı buna kadar olan nokta tam ağırlıklı, `3 × huber`'e kadar
    /// huber / fark, ötesi hiç (ekranda değişen yazı, önden geçen el).
    static let huber = 8.0
    /// Uyumlu (farkı `huber`'den az) nokta oranı bundan azsa çapa kayboldu sayılır.
    static let lostShare = 0.45
    /// Kenardan bu pay içeride örneklenir (telefonun arkasındaki sahne şablona girmesin).
    static let inset = 0.03

    /// Dörtgenin enine göre kat sayısı.
    static func levelCount(width: Double) -> Int {
        var count = 1
        while count < levels, width / Double(1 << count) >= coarsestWidth { count += 1 }
        return count
    }

    /// Gri kare (satır satır, üstten).
    public struct Gray: Sendable {
        public let width: Int
        public let height: Int
        public let pixels: [UInt8]

        public init(width: Int, height: Int, pixels: [UInt8]) {
            precondition(width > 1 && height > 1 && pixels.count >= width * height)
            self.width = width
            self.height = height
            self.pixels = pixels
        }

        /// RGBA (ya da BGRA) karesinden `targetWidth` ene (tam sayı katla) küçültülmüş gri kare: kutu ortalaması,
        /// parlaklık (2R + 5G + B) / 8. `bgr`: bayt sırası mavi önce. Küçültme katı da döner (izleme karesi → asıl kare).
        public static func fromRGBA(_ bytes: [UInt8], width: Int, height: Int, bgr: Bool = false,
                                    targetWidth: Int = ScreenAnchor.trackWidth) -> Gray {
            let factor = max(1, Int((Double(width) / Double(targetWidth)).rounded()))
            let w = max(2, width / factor), h = max(2, height / factor)
            var out = [UInt8](repeating: 0, count: w * h)
            let r = bgr ? 2 : 0, b = bgr ? 0 : 2
            let count = factor * factor
            for y in 0..<h {
                for x in 0..<w {
                    var sum = 0
                    for yy in 0..<factor {
                        var p = ((min(height - 1, y * factor + yy)) * width + min(width - 1, x * factor)) * 4
                        for _ in 0..<factor {
                            sum += 2 * Int(bytes[p + r]) + 5 * Int(bytes[p + 1]) + Int(bytes[p + b])
                            p += 4
                        }
                    }
                    out[y * w + x] = UInt8(min(255, (sum + 4 * count) / (8 * count)))
                }
            }
            return Gray(width: w, height: h, pixels: out)
        }

        /// Yarı boyutlu kare (2×2 kutu ortalaması).
        func half() -> Gray {
            let w = max(2, width / 2), h = max(2, height / 2)
            var out = [UInt8](repeating: 0, count: w * h)
            for y in 0..<h {
                let r0 = min(height - 1, 2 * y) * width, r1 = min(height - 1, 2 * y + 1) * width
                for x in 0..<w {
                    let x0 = min(width - 1, 2 * x), x1 = min(width - 1, 2 * x + 1)
                    let sum = Int(pixels[r0 + x0]) + Int(pixels[r0 + x1]) + Int(pixels[r1 + x0]) + Int(pixels[r1 + x1])
                    out[y * w + x] = UInt8((sum + 2) / 4)
                }
            }
            return Gray(width: w, height: h, pixels: out)
        }

        /// Çift doğrusal örnek; kare dışı nil.
        @inline(__always) func sample(_ x: Double, _ y: Double) -> Double? {
            guard x >= 0, y >= 0, x <= Double(width - 1), y <= Double(height - 1) else { return nil }
            let x0 = min(width - 2, Int(x)), y0 = min(height - 2, Int(y))
            let fx = x - Double(x0), fy = y - Double(y0)
            let i = y0 * width + x0
            let p00 = Double(pixels[i]), p10 = Double(pixels[i + 1])
            let p01 = Double(pixels[i + width]), p11 = Double(pixels[i + width + 1])
            let top = p00 + (p10 - p00) * fx, bottom = p01 + (p11 - p01) * fx
            return top + (bottom - top) * fy
        }
    }

    /// Dikdörtgen (izleme karesinin pikselleri, sol üst köşe ve boyut).
    public struct Rect: Equatable, Sendable {
        public var x: Double, y: Double, width: Double, height: Double
        public init(x: Double, y: Double, width: Double, height: Double) {
            self.x = x
            self.y = y
            self.width = width
            self.height = height
        }
        public var centerX: Double { x + width / 2 }
        public var centerY: Double { y + height / 2 }
    }

    /// Başvuru karesinden güncel kareye izdüşümsel dönüşüm. Başvuru dörtgeninin ortasına (cx, cy) göre u = x − cx,
    /// v = y − cy olmak üzere nokta (cx + (a u + b v + dx) / w, cy + (c u + d v + dy) / w)'ye gider; w = 1 + g u + h v.
    /// Ekranda CSS `matrix3d` ile aynıdır (g = h = 0 iken `matrix(a, c, b, d, dx, dy)`).
    public struct Motion: Equatable, Sendable {
        public var a: Double, b: Double, c: Double, d: Double, dx: Double, dy: Double, g: Double, h: Double
        public init(a: Double = 1, b: Double = 0, c: Double = 0, d: Double = 1, dx: Double = 0, dy: Double = 0,
                    g: Double = 0, h: Double = 0) {
            self.a = a
            self.b = b
            self.c = c
            self.d = d
            self.dx = dx
            self.dy = dy
            self.g = g
            self.h = h
        }
        public static let identity = Motion()
        /// Ortalama ölçek (ortadaki alan büyümesinin karekökü).
        public var scale: Double { abs(a * d - b * c).squareRoot() }

        /// Başvurudaki noktanın güncel karedeki yeri (`cx`, `cy`: başvuru dörtgeninin ortası).
        public func map(_ x: Double, _ y: Double, cx: Double, cy: Double) -> (x: Double, y: Double) {
            let u = x - cx, v = y - cy
            let w = 1 + g * u + h * v
            return (cx + (a * u + b * v + dx) / w, cy + (c * u + d * v + dy) / w)
        }

        /// Katta (koordinatlar `factor`'e bölünmüş) aynı dönüşüm.
        func scaled(_ factor: Double) -> Motion {
            Motion(a: a, b: b, c: c, d: d, dx: dx / factor, dy: dy / factor, g: g * factor, h: h * factor)
        }

        /// Dörtgenin köşelerinin bu iki dönüşümle gittiği yerler arasındaki en büyük uzaklık (piksel).
        public func distance(to other: Motion, rect: Rect) -> Double {
            let cx = rect.centerX, cy = rect.centerY
            var worst = 0.0
            for (x, y) in [(rect.x, rect.y), (rect.x + rect.width, rect.y), (rect.x, rect.y + rect.height),
                           (rect.x + rect.width, rect.y + rect.height)] {
                let p = map(x, y, cx: cx, cy: cy), q = other.map(x, y, cx: cx, cy: cy)
                worst = max(worst, ((p.x - q.x) * (p.x - q.x) + (p.y - q.y) * (p.y - q.y)).squareRoot())
            }
            return worst
        }
    }

    /// Bir karenin izleme sonucu: dönüşüm ve uyumlu nokta oranı (0–1).
    public struct Fix: Equatable, Sendable {
        public let motion: Motion
        public let inliers: Double
    }

    /// Şablon izleyici. `begin` başvuru karesinde dörtgeni şablon yapar; `track` her yeni karede dönüşümü bulur,
    /// çapa kaybolunca nil döner (yeniden `begin` gerekir).
    public final class Tracker {
        private struct Level {
            let factor: Double
            let offset: Double
            var u: [Double] = [], v: [Double] = []
            var t: [Double] = [], gx: [Double] = [], gy: [Double] = []
        }

        public private(set) var rect: Rect?
        public private(set) var motion = Motion.identity
        private var previous: Motion?
        private var pyramid: [Level] = []

        public init() {}

        public var isActive: Bool { rect != nil }

        public func begin(_ frame: Gray, rect: Rect) {
            let inner = Rect(x: rect.x + rect.width * ScreenAnchor.inset, y: rect.y + rect.height * ScreenAnchor.inset,
                             width: rect.width * (1 - 2 * ScreenAnchor.inset),
                             height: rect.height * (1 - 2 * ScreenAnchor.inset))
            self.rect = rect
            motion = .identity
            previous = nil
            pyramid = []
            let count = ScreenAnchor.levelCount(width: inner.width)
            var image = frame
            for index in 0..<count {
                let factor = Double(1 << index)
                var level = Level(factor: factor, offset: (factor - 1) / 2)
                let w = inner.width / factor, h = inner.height / factor
                let step = max(1, Int((w * h / Double(ScreenAnchor.maxPoints)).squareRoot().rounded(.up)))
                let cols = max(2, Int(w) / step), rows = max(2, Int(h) / step)
                for row in 0..<rows {
                    for col in 0..<cols {
                        level.u.append((Double(col) + 0.5) * w / Double(cols) - w / 2)
                        level.v.append((Double(row) + 0.5) * h / Double(rows) - h / 2)
                    }
                }
                sampleTemplate(&level, image, rect: rect)
                pyramid.append(level)
                if index + 1 < count { image = image.half() }
            }
        }

        public func reset() {
            rect = nil
            motion = .identity
            previous = nil
            pyramid = []
        }

        /// Güncel karede dönüşüm. En kaba katta üç başlangıç denenir: önceki dönüşüm, sabit hızla öngörülen ve onun
        /// çevresinde tam piksel öteleme taramasının en iyisi (telefon hızla kalkarken/arabada sarsılırken karede 15–20
        /// piksel gidebiliyor); uyumu yüksek olan ince katlara geçer. Çapa kaybolursa nil (izleyici sıfırlanır).
        public func track(_ frame: Gray) -> Fix? {
            guard let rect, !pyramid.isEmpty else { return nil }
            var images = [frame]
            for _ in 1..<pyramid.count { images.append(images[images.count - 1].half()) }
            let coarsest = pyramid.count - 1
            var starts = [motion]
            if let previous {
                var predicted = motion
                predicted.dx += motion.dx - previous.dx
                predicted.dy += motion.dy - previous.dy
                if predicted != motion { starts.append(predicted) }
            }
            starts.append(search(pyramid[coarsest], images[coarsest], rect: rect, around: starts[starts.count - 1]))
            var best: Fix?
            for start in starts {
                guard let fix = align(pyramid[coarsest], images[coarsest], rect: rect, start: start) else { continue }
                if best.map({ fix.inliers > $0.inliers }) ?? true { best = fix }
            }
            guard var current = best else {
                reset()
                return nil
            }
            for index in stride(from: coarsest - 1, through: 0, by: -1) {
                guard let fix = align(pyramid[index], images[index], rect: rect, start: current.motion) else {
                    reset()
                    return nil
                }
                current = fix
            }
            guard current.inliers >= ScreenAnchor.lostShare, ScreenAnchor.plausible(current.motion, rect: rect) else {
                reset()
                return nil
            }
            previous = motion
            motion = current.motion
            return current
        }

        /// Şablon: katın noktalarındaki parlaklık ve eğimi (başvuru karesi, kat koordinatında; izleme karesinin x'i katta
        /// (x − offset) / factor, kutu ortalamasının piksel ortası).
        private func sampleTemplate(_ level: inout Level, _ image: Gray, rect: Rect) {
            let cx = (rect.centerX - level.offset) / level.factor, cy = (rect.centerY - level.offset) / level.factor
            let n = level.u.count
            level.t = [Double](repeating: .nan, count: n)
            level.gx = [Double](repeating: 0, count: n)
            level.gy = [Double](repeating: 0, count: n)
            for i in 0..<n {
                let x = cx + level.u[i], y = cy + level.v[i]
                guard let c = image.sample(x, y), let l = image.sample(x - 1, y), let r = image.sample(x + 1, y),
                      let up = image.sample(x, y - 1), let down = image.sample(x, y + 1) else { continue }
                level.t[i] = c
                level.gx[i] = (r - l) / 2
                level.gy[i] = (down - up) / 2
            }
        }

        /// En kaba katta öteleme taraması: `start`'ın çevresinde ±`searchRadius` piksel, her tam konumda (en çok ~400
        /// noktayla) ortalaması eşitlenmiş mutlak farkın ortalaması en küçük olan.
        private func search(_ level: Level, _ image: Gray, rect: Rect, around start: Motion) -> Motion {
            let cx = (rect.centerX - level.offset) / level.factor, cy = (rect.centerY - level.offset) / level.factor
            let m = start.scaled(level.factor)
            let n = level.u.count
            let stride = max(1, n / 400)
            var points: [(x: Double, y: Double, t: Double)] = []
            var i = 0
            while i < n {
                let t = level.t[i], u = level.u[i], v = level.v[i]
                let w = 1 + m.g * u + m.h * v
                if !t.isNaN, w > 0.1 {
                    points.append((cx + (m.a * u + m.b * v + m.dx) / w, cy + (m.c * u + m.d * v + m.dy) / w, t))
                }
                i += stride
            }
            var bestCost = Double.infinity, bestX = 0, bestY = 0
            let radius = ScreenAnchor.searchRadius
            var values = [Double](repeating: 0, count: points.count)
            for oy in -radius...radius {
                for ox in -radius...radius {
                    var count = 0.0, shift = 0.0
                    for (k, p) in points.enumerated() {
                        guard let value = image.sample(p.x + Double(ox), p.y + Double(oy)) else {
                            values[k] = .nan
                            continue
                        }
                        values[k] = value
                        count += 1
                        shift += p.t - value
                    }
                    guard count >= 16 else { continue }
                    shift /= count
                    var cost = 0.0
                    for (k, p) in points.enumerated() where !values[k].isNaN { cost += abs(values[k] + shift - p.t) }
                    cost /= count
                    if cost < bestCost {
                        bestCost = cost
                        bestX = ox
                        bestY = oy
                    }
                }
            }
            var found = start
            found.dx += Double(bestX) * level.factor
            found.dy += Double(bestY) * level.factor
            return found
        }

        /// Ters bileşimli Lucas-Kanade (izdüşümsel dönüşüm, 8 değişken), sağlam ağırlıkla. Parlaklık ve karşıtlık
        /// (pozlama değişimi, ekran kararması) önceki yinelemede atılmayan noktalardan eşitlenir.
        private func align(_ level: Level, _ image: Gray, rect: Rect, start: Motion) -> Fix? {
            let cx = (rect.centerX - level.offset) / level.factor, cy = (rect.centerY - level.offset) / level.factor
            var m = start.scaled(level.factor)
            let n = level.u.count
            var share = 0.0
            var values = [Double](repeating: .nan, count: n)
            var rejected = [Bool](repeating: false, count: n)
            var s = [Double](repeating: 0, count: 8)
            let cut = 3 * ScreenAnchor.huber
            for _ in 0..<ScreenAnchor.iterations {
                var hessian = [Double](repeating: 0, count: 64), gradient = [Double](repeating: 0, count: 8)
                var count = 0.0, kept = 0.0, sumI = 0.0, sumII = 0.0, sumT = 0.0, sumTT = 0.0
                for i in 0..<n {
                    values[i] = .nan
                    let t = level.t[i]
                    guard !t.isNaN else { continue }
                    let u = level.u[i], v = level.v[i]
                    let w = 1 + m.g * u + m.h * v
                    guard w > 0.1, let value = image.sample(cx + (m.a * u + m.b * v + m.dx) / w,
                                                            cy + (m.c * u + m.d * v + m.dy) / w) else { continue }
                    values[i] = value
                    count += 1
                    guard !rejected[i] else { continue }
                    kept += 1
                    sumI += value
                    sumII += value * value
                    sumT += t
                    sumTT += t * t
                }
                guard count >= 16, kept >= 16 else { return nil }
                let meanI = sumI / kept, meanT = sumT / kept
                let spreadI = max(0, sumII / kept - meanI * meanI).squareRoot()
                let spreadT = max(0, sumTT / kept - meanT * meanT).squareRoot()
                let gain = spreadI > 1e-6 ? min(4, max(0.25, spreadT / spreadI)) : 1
                var good = 0.0
                for i in 0..<n {
                    let value = values[i]
                    guard !value.isNaN else { continue }
                    let t = level.t[i], u = level.u[i], v = level.v[i]
                    let r = (value - meanI) * gain + meanT - t
                    let size = abs(r)
                    rejected[i] = size > cut
                    if size <= ScreenAnchor.huber { good += 1 }
                    guard !rejected[i] else { continue }
                    let weight = size <= ScreenAnchor.huber ? 1 : ScreenAnchor.huber / size
                    let gx = level.gx[i], gy = level.gy[i]
                    let radial = gx * u + gy * v
                    s[0] = gx * u
                    s[1] = gx * v
                    s[2] = gy * u
                    s[3] = gy * v
                    s[4] = gx
                    s[5] = gy
                    s[6] = -radial * u
                    s[7] = -radial * v
                    for p in 0..<8 {
                        let ws = weight * s[p]
                        gradient[p] += ws * r
                        for q in p..<8 { hessian[p * 8 + q] += ws * s[q] }
                    }
                }
                share = good / count
                for p in 0..<8 { for q in 0..<p { hessian[p * 8 + q] = hessian[q * 8 + p] } }
                guard let step = ScreenAnchor.solve(hessian, gradient) else { return nil }
                // Ters bileşim: H ← H · H(Δ)⁻¹ (3×3, sağ alt 1'e bölünür).
                let delta = [1 + step[0], step[1], step[4], step[2], 1 + step[3], step[5], step[6], step[7], 1.0]
                guard let inverse = ScreenAnchor.invert3(delta) else { return nil }
                let current = [m.a, m.b, m.dx, m.c, m.d, m.dy, m.g, m.h, 1.0]
                var product = [Double](repeating: 0, count: 9)
                for row in 0..<3 {
                    for col in 0..<3 {
                        product[row * 3 + col] = current[row * 3] * inverse[col] + current[row * 3 + 1] * inverse[3 + col]
                            + current[row * 3 + 2] * inverse[6 + col]
                    }
                }
                let k = product[8]
                guard abs(k) > 1e-12 else { return nil }
                m = Motion(a: product[0] / k, b: product[1] / k, c: product[3] / k, d: product[4] / k,
                           dx: product[2] / k, dy: product[5] / k, g: product[6] / k, h: product[7] / k)
                if abs(step[4]) < 0.005, abs(step[5]) < 0.005, abs(step[0]) < 1e-5, abs(step[1]) < 1e-5,
                   abs(step[2]) < 1e-5, abs(step[3]) < 1e-5, abs(step[6]) < 1e-7, abs(step[7]) < 1e-7 { break }
            }
            return Fix(motion: m.scaled(1 / level.factor), inliers: share)
        }
    }

    /// Dönüşüm elde tutulan bir telefona/ekrandaki bir karta uyar mı: ölçek 0,5–2, iki eksenin ölçek oranı 0,75–1,33,
    /// köşelerde perspektif payı %15'ten az. Telefon indirilirken izleyici bulanık kareye yapışıp telefonu "uzatabiliyordu"
    /// (gerçek kayıt, araba sahnesi); öyle bir sonuç çapa kaybı sayılır.
    static func plausible(_ m: Motion, rect: Rect) -> Bool {
        let scale = m.scale
        guard scale > 0.5, scale < 2 else { return false }
        let x = (m.a * m.a + m.c * m.c).squareRoot(), y = (m.b * m.b + m.d * m.d).squareRoot()
        guard y > 0, x / y > 0.75, x / y < 1.0 / 0.75 else { return false }
        return abs(m.g) * rect.width / 2 + abs(m.h) * rect.height / 2 < 0.15
    }

    /// 3×3 matrisin tersi (satır satır); tekil ise nil.
    static func invert3(_ m: [Double]) -> [Double]? {
        let c00 = m[4] * m[8] - m[5] * m[7], c01 = m[5] * m[6] - m[3] * m[8], c02 = m[3] * m[7] - m[4] * m[6]
        let det = m[0] * c00 + m[1] * c01 + m[2] * c02
        guard abs(det) > 1e-12 else { return nil }
        return [c00 / det, (m[2] * m[7] - m[1] * m[8]) / det, (m[1] * m[5] - m[2] * m[4]) / det,
                c01 / det, (m[0] * m[8] - m[2] * m[6]) / det, (m[2] * m[3] - m[0] * m[5]) / det,
                c02 / det, (m[1] * m[6] - m[0] * m[7]) / det, (m[0] * m[4] - m[1] * m[3]) / det]
    }

    /// Doğrusal denklem (kısmi pivotlu Gauss); tekil ise nil.
    static func solve(_ matrix: [Double], _ vector: [Double]) -> [Double]? {
        var m = matrix, x = vector
        let n = vector.count
        for col in 0..<n {
            var pivot = col
            for row in col + 1..<n where abs(m[row * n + col]) > abs(m[pivot * n + col]) { pivot = row }
            guard abs(m[pivot * n + col]) > 1e-9 else { return nil }
            if pivot != col {
                for k in 0..<n { m.swapAt(col * n + k, pivot * n + k) }
                x.swapAt(col, pivot)
            }
            for row in col + 1..<n {
                let f = m[row * n + col] / m[col * n + col]
                guard f != 0 else { continue }
                for k in col..<n { m[row * n + k] -= f * m[col * n + k] }
                x[row] -= f * x[col]
            }
        }
        for row in stride(from: n - 1, through: 0, by: -1) {
            var sum = x[row]
            for k in row + 1..<n { sum -= m[row * n + k] * x[k] }
            x[row] = sum / m[row * n + row]
        }
        return x
    }

    /// Dönüşümün kararlılığı. Gerçek kayıtta (GTA 6, 23 Kas) üç karelik doğru uydurma (gecikmesiz kestirim) izlemeyi
    /// bozdu: arabada sarsılan telefonda ivme yüzünden taşıyor, izleme hatasının en kötüsü 0,4 pikselden 6 piksele
    /// çıkıyordu; ham ölçüm zaten piksel altı kararlıydı. Bu yüzden yumuşatma yalnız ölü bölgedir: dörtgenin hiçbir köşesi
    /// son gösterilenden `deadband` pikselden fazla oynamadıysa son gösterilen kalır (duran telefonda çeviri piksel
    /// piksel sabit); oynadıysa ham ölçüm gecikmesiz gösterilir. Ani sıçramada (sahne değişimi, telefon başka yere)
    /// `jumped`: çapa yeniden kurulmalı.
    public struct Smoother: Sendable {
        /// Ardışık iki ölçüm arasında dörtgenin bir köşesi bundan (dörtgen yüksekliğine oranla) fazla kaydıysa sıçramadır.
        public static let jumpShare = 0.12
        /// Ölü bölge (izleme karesinin pikseli).
        public static let deadband = 0.15
        private var last: Motion?
        private var shown: Motion?

        public init() {}

        public mutating func reset() {
            last = nil
            shown = nil
        }

        /// Gösterilecek dönüşüm ve sıçrama olup olmadığı.
        public mutating func push(_ raw: Motion, rect: Rect) -> (motion: Motion, jumped: Bool) {
            defer { last = raw }
            if let last, raw.distance(to: last, rect: rect) > Self.jumpShare * rect.height {
                shown = raw
                return (raw, true)
            }
            if let shown, raw.distance(to: shown, rect: rect) <= Self.deadband { return (shown, false) }
            shown = raw
            return (raw, false)
        }
    }
}
