// SPDX-License-Identifier: AGPL-3.0-only

import CoreGraphics
import CoreText
import Foundation

/// "Sil ve yeniden çiz" (prototip; docs/ekran-yazisi-sil-ciz.md): ekran yazısının yalnız harf noktaları silinir, yerine
/// çevrilmiş yazı aynı boyda, aynı renkte çizilir. Kutu ile örtmenin tersine simge, fotoğraf ve zemin olduğu gibi kalır:
/// maske yalnız yazının kutusundaki, zeminden belirgin ayrılan noktalardır (her oyunda aynı genel yöntem, oyuna özel
/// şablon yok). Zemin düz ya da degradeyse silme satır yönünde doğrusal doldurmadır; dokulu zeminde (3B dünya, video)
/// temiz silinemez, `Patch.clean` false olur ve çizici özgün stilde sıkı kutuya döner.
public enum TextErase {
    /// Görüntünün RGBA kopyası (üst-sol başlangıçlı).
    public struct Image {
        public let width: Int
        public let height: Int
        public var bytes: [UInt8]

        public init(width: Int, height: Int, bytes: [UInt8]) {
            self.width = width
            self.height = height
            self.bytes = bytes
        }

        public init?(_ frame: CGImage) {
            guard let pixels = GamePhonePixels(frame) else { return nil }
            width = pixels.width
            height = pixels.height
            bytes = pixels.bytes
        }

        @inline(__always) func rgb(_ x: Int, _ y: Int) -> (Int, Int, Int) {
            let p = (y * width + x) * 4
            return (Int(bytes[p]), Int(bytes[p + 1]), Int(bytes[p + 2]))
        }

        @inline(__always) mutating func set(_ x: Int, _ y: Int, _ c: (Int, Int, Int)) {
            let p = (y * width + x) * 4
            bytes[p] = UInt8(max(0, min(255, c.0)))
            bytes[p + 1] = UInt8(max(0, min(255, c.1)))
            bytes[p + 2] = UInt8(max(0, min(255, c.2)))
        }

        public func cgImage() -> CGImage? {
            var copy = bytes
            return copy.withUnsafeMutableBytes { buffer in
                CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
            }
        }
    }

    /// Bir yazının silinmesinin sonucu.
    public struct Patch {
        /// Silinen alan (piksel): yazı kutusu, kenar payıyla.
        public var rect: (x0: Int, y0: Int, x1: Int, y1: Int)
        /// Maskedeki (harf) nokta sayısı.
        public var masked: Int
        /// Silmeden sonra yazı kutusunda zeminden hâlâ belirgin ayrılan noktaların, silmeden öncekilere oranı (0 = iz yok).
        public var residual: Double
        /// Zemin düz/degrade: silme temiz. false ise çizici özgün stilde sıkı kutuya döner.
        public var clean: Bool
        /// Harflerin rengi (maskedeki noktaların ortancası).
        public var ink: (Int, Int, Int)
        /// Harflerin dış çizgisinin rengi (harfin içi ile kenarı belirgin farklıysa: GTA 6 tuş etiketleri gibi); yoksa nil.
        public var outline: (Int, Int, Int)?
        /// Silinemediğinde (dokulu zemin) kutunun dolgusu: çevre şeridinin ortalaması.
        public var ground: (Int, Int, Int)
        /// Zeminin dokusu: çevre şeridindeki noktaların zemin kestirimine ortalama uzaklığı.
        public var texture: Double
    }

    /// Zeminden bu kadar (en büyük renk bileşeni farkı) ayrılan nokta harftir.
    public static let inkDistance = 48
    /// Çevre şeridinin dokusu bundan büyükse zemin düz/degrade değildir (temiz silinemez).
    public static let texturedLimit = 14.0

    @inline(__always) static func distance(_ a: (Int, Int, Int), _ b: (Int, Int, Int)) -> Int {
        max(abs(a.0 - b.0), abs(a.1 - b.1), abs(a.2 - b.2))
    }

    /// Yazı kutusunu (kareye oranla) siler. Kutunun yalnız harf noktaları değişir.
    @discardableResult
    public static func erase(_ image: inout Image, box: TextBox) -> Patch? {
        let w = image.width, h = image.height
        let bx0 = Int((box.left * Double(w)).rounded(.down)), bx1 = Int((box.right * Double(w)).rounded(.up))
        let by0 = Int((box.top * Double(h)).rounded(.down)), by1 = Int((box.bottom * Double(h)).rounded(.up))
        let lineHeight = max(4, by1 - by0)
        let pad = max(2, lineHeight / 8)
        // Yatayda kutunun dışına çıkılmaz: yazının hemen yanındaki simge ve fotoğraf hiç değişmez (kutu ScreenFit'te yalnız
        // yazıyı kapsayacak biçimde daraltılmıştır). Dikeyde harflerin yumuşak kenarı için kenar payı.
        let x0 = max(1, bx0), x1 = min(w - 2, bx1 - 1), y0 = max(1, by0 - pad), y1 = min(h - 2, by1 + pad)
        guard x1 > x0 + 2, y1 > y0 + 2 else { return nil }
        let ring = max(2, lineHeight / 5)
        // Zemin kestirimi: her satırda kutunun solundaki ve sağındaki şeridin ortalaması, aralarında doğrusal (yatay
        // degrade); üst ve alt şeritlerle karşılaştırılarak dokusu ölçülür.
        func mean(_ xs: ClosedRange<Int>, _ y: Int) -> (Int, Int, Int) {
            var s = (0, 0, 0), n = 0
            for x in xs where x >= 0 && x < w { let c = image.rgb(x, y); s = (s.0 + c.0, s.1 + c.1, s.2 + c.2); n += 1 }
            return n == 0 ? (0, 0, 0) : (s.0 / n, s.1 / n, s.2 / n)
        }
        let leftEdge = max(0, x0 - ring)...max(0, x0 - 1), rightEdge = min(w - 1, x1 + 1)...min(w - 1, x1 + ring)
        var lefts: [(Int, Int, Int)] = [], rights: [(Int, Int, Int)] = []
        for y in y0...y1 { lefts.append(mean(leftEdge, y)); rights.append(mean(rightEdge, y)) }
        func ground(_ x: Int, _ y: Int) -> (Int, Int, Int) {
            let t = Double(x - x0) / Double(max(1, x1 - x0))
            let l = lefts[y - y0], r = rights[y - y0]
            return (Int(Double(l.0) * (1 - t) + Double(r.0) * t), Int(Double(l.1) * (1 - t) + Double(r.1) * t),
                    Int(Double(l.2) * (1 - t) + Double(r.2) * t))
        }
        // Doku: üst ve alt şeridin noktaları kestirime ne kadar uzak (düz/degrade zeminde birkaç birim).
        var texture = 0.0, samples = 0
        for y in [max(0, y0 - 1), min(h - 1, y1 + 1)] {
            for x in stride(from: x0, through: x1, by: 2) {
                texture += Double(distance(image.rgb(x, y), ground(x, min(max(y, y0), y1)))); samples += 1
            }
        }
        texture /= Double(max(1, samples))
        // Maske: zeminden belirgin ayrılan noktalar, harfin yumuşak kenarı ve dış çizgisi için bir nokta genişletilmiş.
        let mw = x1 - x0 + 1, mh = y1 - y0 + 1
        var core = [Bool](repeating: false, count: mw * mh)
        for y in y0...y1 {
            for x in x0...x1 {
                let c = image.rgb(x, y)
                if distance(c, ground(x, y)) > inkDistance { core[(y - y0) * mw + (x - x0)] = true }
            }
        }
        let grow = max(1, lineHeight / 16)
        var mask = core
        for y in 0..<mh {
            for x in 0..<mw where core[y * mw + x] {
                for dy in -grow...grow { for dx in -grow...grow {
                    let yy = y + dy, xx = x + dx
                    if yy >= 0, yy < mh, xx >= 0, xx < mw { mask[yy * mw + xx] = true }
                } }
            }
        }
        let before = core.filter { $0 }.count
        guard before > 0 else { return nil }
        // Harfin içi (dört komşusu da harf) ve kenarı ayrı renklenir: içi yazı rengi, kenarı belirgin farklıysa dış çizgi.
        var inside: [(Int, Int, Int)] = [], edge: [(Int, Int, Int)] = []
        for y in 0..<mh {
            for x in 0..<mw where core[y * mw + x] {
                let c = image.rgb(x0 + x, y0 + y)
                let interior = x > 0 && x < mw - 1 && y > 0 && y < mh - 1 && core[y * mw + x - 1] && core[y * mw + x + 1]
                    && core[(y - 1) * mw + x] && core[(y + 1) * mw + x]
                if interior { inside.append(c) } else { edge.append(c) }
            }
        }
        func median(_ list: [(Int, Int, Int)]) -> (Int, Int, Int)? {
            guard !list.isEmpty else { return nil }
            let order = list.indices.sorted { list[$0].0 * 299 + list[$0].1 * 587 + list[$0].2 * 114 < list[$1].0 * 299 + list[$1].1 * 587 + list[$1].2 * 114 }
            return list[order[order.count / 2]]
        }
        let solid = !inside.isEmpty && inside.count >= before / 10
        let fill = median(solid ? inside : edge + inside)!
        let rim = solid ? median(edge) : nil
        let outline = rim.flatMap { distance($0, fill) > 90 ? $0 : nil }
        let around = mean(leftEdge, (y0 + y1) / 2)
        // Silme: her satırda maskeli aralık, iki yanındaki maskesiz noktalar arasında doğrusal doldurulur.
        for y in 0..<mh {
            var x = 0
            while x < mw {
                guard mask[y * mw + x] else { x += 1; continue }
                var end = x
                while end + 1 < mw, mask[y * mw + end + 1] { end += 1 }
                let ax = x0 + x - 1, bx = x0 + end + 1, yy = y0 + y
                let a = image.rgb(max(0, ax), yy), b = image.rgb(min(w - 1, bx), yy)
                let span = Double(bx - ax)
                for k in x...end {
                    let t = Double(x0 + k - ax) / span
                    image.set(x0 + k, yy, (Int(Double(a.0) * (1 - t) + Double(b.0) * t), Int(Double(a.1) * (1 - t) + Double(b.1) * t),
                                           Int(Double(a.2) * (1 - t) + Double(b.2) * t)))
                }
                x = end + 1
            }
        }
        var after = 0
        for y in by0...min(by1, h - 1) {
            for x in max(0, bx0)...min(bx1, w - 1) where distance(image.rgb(x, y), ground(min(max(x, x0), x1), min(max(y, y0), y1))) > inkDistance {
                after += 1
            }
        }
        return Patch(rect: (x0, y0, x1, y1), masked: before, residual: Double(after) / Double(before),
                     clean: texture <= texturedLimit, ink: fill, outline: outline, ground: around, texture: texture)
    }

    /// Çeviriyi silinen yazının yerine çizer: yazı boyu satır yüksekliğinden (küçültme yok), rengi harflerin rengi, dış
    /// çizgisi varsa o da; özgün yazı kaç satırsa (`rows`) çeviri o kadar satıra sözcük sözcük bölünür, sığmayan satır yalnız
    /// yatayda sıkıştırılır (en çok %30). Temiz silinemeyen yazıda önce kutu zemin rengiyle doldurulur (güvenli dönüş).
    public static func draw(_ text: String, in image: inout Image, box: TextBox, lineHeight: Double, rows: Int = 1,
                            patch: Patch, bold: Bool, align: TextLook.Align) {
        guard let cg = image.cgImage() else { return }
        let w = image.width, h = image.height
        var bytes = image.bytes
        bytes.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return }
            context.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            func color(_ c: (Int, Int, Int)) -> CGColor {
                CGColor(srgbRed: CGFloat(c.0) / 255, green: CGFloat(c.1) / 255, blue: CGFloat(c.2) / 255, alpha: 1)
            }
            if !patch.clean {
                let r = patch.rect
                context.setFillColor(color(patch.ground))
                context.fill(CGRect(x: r.x0, y: h - r.y1 - 1, width: r.x1 - r.x0 + 1, height: r.y1 - r.y0 + 1))
            }
            let size = CGFloat(lineHeight * Double(h)) * 0.95
            let font = CTFontCreateWithName((bold ? "Helvetica-Bold" : "Helvetica") as CFString, size, nil)
            var attributes: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): color(patch.ink),
            ]
            if let outline = patch.outline {
                attributes[NSAttributedString.Key(kCTStrokeColorAttributeName as String)] = color(outline)
                attributes[NSAttributedString.Key(kCTStrokeWidthAttributeName as String)] = -8.0
            }
            func width(_ string: String) -> CGFloat {
                CGFloat(CTLineGetTypographicBounds(CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: attributes)), nil, nil, nil))
            }
            let room = CGFloat((box.right - box.left) * Double(w))
            // Sözcükler satırlara: her satır en çok kutunun genişliğinin 1/0,7 katı (sıkıştırmayla sığar).
            var lines: [String] = []
            let words = text.split(separator: " ").map(String.init)
            if rows <= 1 { lines = [text] } else {
                let target = width(text) / CGFloat(rows)
                var current = ""
                for word in words {
                    let next = current.isEmpty ? word : current + " " + word
                    if !current.isEmpty, width(next) > max(target * 1.08, room) , lines.count < rows - 1 { lines.append(current); current = word }
                    else { current = next }
                }
                lines.append(current)
            }
            let pitch = CGFloat((box.bottom - box.top) * Double(h)) / CGFloat(max(1, lines.count))
            let left = CGFloat(box.left * Double(w))
            for (k, string) in lines.enumerated() {
                let line = CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: attributes))
                let natural = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
                let squeeze = natural > room ? max(0.7, room / natural) : 1
                let drawn = natural * squeeze
                let x: CGFloat = switch align {
                case .left: left
                case .right: left + room - drawn
                case .center: left + (room - drawn) / 2
                }
                // Taban çizgisi: satırın altından yazı boyunun ~%20'si yukarıda (Core Graphics alttan başlar).
                let bottom = CGFloat(box.top * Double(h)) + pitch * CGFloat(k + 1)
                let baseline = CGFloat(h) - bottom + min(size, pitch) * 0.2
                context.saveGState()
                context.translateBy(x: x, y: baseline)
                context.scaleBy(x: squeeze, y: 1)
                context.textPosition = .zero
                CTLineDraw(line, context)
                context.restoreGState()
            }
        }
        image.bytes = bytes
    }
}
