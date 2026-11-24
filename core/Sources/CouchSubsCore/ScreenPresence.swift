// SPDX-License-Identifier: AGPL-3.0-only

import CoreGraphics
import Foundation

/// Ekran yazısı çevirisinin takibi: özgün yazı ekrandan kalkınca çevirisi de aynı anda kalkar, menü değişince eski çeviri
/// kalmaz. Çeviri yazı tanımanın sonraki turunu (yarım saniye ile birkaç saniye) bekliyordu; menüden çıkınca eski menünün
/// Türkçesi oyunun üstünde asılı kalıyordu. Her karede, çevirisi gösterilen her öğenin kutusunun küçük gri izi (`cols` x
/// `rows`) ilk görüldüğü izle karşılaştırılır (Pearson ilintisinin büyüklüğü; seçim gezince ters dönen renk aynı yazıdır):
/// - İz düzleşti ya da ilinti `instantCorrelation`'ın altında (yerinde başka yazı): çeviri aynı karede kalkar.
/// - İlinti `goneCorrelation`'ın altına düşüp `settleFrames` kare öyle kalırsa (belirsiz sapma) yazı yok sayılır.
/// - Kalkan yazının izi yeniden `backCorrelation`'a çıkıp `settleFrames` kare öyle kalırsa (geçiş efekti bitti) geri gelir.
///   İki eşik arası değişmez: titreme olmaz.
/// - İlk izi düz (yazısız) olan öğe hemen yok sayılır: yazı okunduğu karede vardı, bu karede yok.
/// Telefon kartı, balonlar, sohbet paneli ve özgün stili olmayan öğe izlenmez (yerleri özgün yazının yeri değil).
/// Windows (ScreenPresence.cs) ve Android (ScreenPresence.kt) aynı kuralı, aynı eşikleri kullanır; ortak deneme dosyası
/// Fixtures/screen-presence.json.
public struct ScreenPresence: Sendable {
    public static let cols = 24
    public static let rows = 6
    public static let goneCorrelation = 0.5
    /// İlinti bundan da düşükse (iz düz ya da yerinde başka yazı) çeviri beklemeden, aynı karede kalkar.
    public static let instantCorrelation = 0.3
    public static let backCorrelation = 0.8
    public static let settleFrames = 2
    /// İzin parlaklık sapması bundan küçükse düzdür (yazı yok).
    public static let flatDeviation = 6.0

    struct Entry: Sendable {
        var reference: [Int]
        var visible: Bool
        var streak = 0
    }

    private var entries: [String: Entry] = [:]

    public init() {}

    /// İzlenen öğe mi.
    public static func tracks(_ item: ScreenTranslation.Item) -> Bool {
        item.look != nil && ScreenFit.takesPart(item) && item.panel == nil
    }

    static func key(_ item: ScreenTranslation.Item) -> String {
        func r(_ v: Double) -> Int { Int((v * 1000).rounded()) }
        return "\(item.source)|\(r(item.box.left)),\(r(item.box.top)),\(r(item.box.right)),\(r(item.box.bottom))"
    }

    /// İki izin ilintisinin büyüklüğü (0…1); biri düzse nil.
    static func correlation(_ a: [Int], _ b: [Int]) -> Double? {
        guard a.count == b.count, !a.isEmpty else { return nil }
        let n = Double(a.count)
        let ma = Double(a.reduce(0, +)) / n, mb = Double(b.reduce(0, +)) / n
        var sab = 0.0, saa = 0.0, sbb = 0.0
        for i in a.indices {
            let x = Double(a[i]) - ma, y = Double(b[i]) - mb
            sab += x * y
            saa += x * x
            sbb += y * y
        }
        guard (saa / n).squareRoot() >= flatDeviation, (sbb / n).squareRoot() >= flatDeviation else { return nil }
        return abs(sab / (saa * sbb).squareRoot())
    }

    static func flat(_ a: [Int]) -> Bool {
        guard !a.isEmpty else { return true }
        let n = Double(a.count), m = Double(a.reduce(0, +)) / n
        return (a.reduce(0.0) { $0 + (Double($1) - m) * (Double($1) - m) } / n).squareRoot() < flatDeviation
    }

    /// Bu karede görünür olan öğeler. `patch`: öğenin kutusunun bu karedeki izi (`cols` x `rows` parlaklık, satır satır);
    /// kutu karenin dışındaysa nil (öğe görünür kalır). Önceki karelerde izlenip artık listede olmayan öğeler unutulur.
    public mutating func visible(_ items: [ScreenTranslation.Item], patch: (TextBox) -> [Int]?) -> [Bool] {
        var kept: [String: Entry] = [:]
        let result = items.map { item -> Bool in
            guard Self.tracks(item) else { return true }
            let key = Self.key(item)
            guard let now = patch(item.box) else {
                if let entry = entries[key] { kept[key] = entry }
                return entries[key]?.visible ?? true
            }
            guard var entry = kept[key] ?? entries[key] else {
                let entry = Entry(reference: now, visible: !Self.flat(now))
                kept[key] = entry
                return entry.visible
            }
            let score = Self.correlation(entry.reference, now) ?? 0
            let flips = entry.visible ? score < Self.goneCorrelation : score >= Self.backCorrelation
            entry.streak = flips ? entry.streak + 1 : 0
            // Yazı silindi (iz düz) ya da yerinde bambaşka yazı var: beklemeden, bu karede kalkar.
            let instant = entry.visible && score < Self.instantCorrelation
            if instant || entry.streak >= Self.settleFrames {
                entry.visible.toggle()
                entry.streak = 0
            }
            kept[key] = entry
            return entry.visible
        }
        entries = kept
        return result
    }

    /// Kutunun izi: kutu `cols` x `rows` ızgaraya küçültülür, her hücrenin parlaklığı (0-255).
    public static func patch(_ frame: CGImage, box: TextBox) -> [Int]? {
        let w = Double(frame.width), h = Double(frame.height)
        let rect = CGRect(x: box.left * w, y: box.top * h, width: (box.right - box.left) * w, height: (box.bottom - box.top) * h)
        guard rect.width >= 2, rect.height >= 2, let pixels = GamePhonePixels(frame, in: rect, width: cols, height: rows) else { return nil }
        return (0..<(cols * rows)).map { i in
            let p = i * 4
            return (Int(pixels.bytes[p]) * 299 + Int(pixels.bytes[p + 1]) * 587 + Int(pixels.bytes[p + 2]) * 114) / 1000
        }
    }

    /// Öğenin özgün yazısı kalktı mı (son karede yok sayıldı).
    public func hidden(_ item: ScreenTranslation.Item) -> Bool {
        Self.tracks(item) && entries[Self.key(item)]?.visible == false
    }

    public mutating func reset() {
        entries = [:]
    }
}
