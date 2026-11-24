// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// Konuşana göre renk (v3): oturum boyunca (çeviri başlayınca sıfırlanır) her kişiye bir renk. Yazı tanımanın yakın
/// okuması aynı kişidir ("Mattia", "Mattla", "Mattia." aynı renk). Yeni kişi addan hesaplanan tabanı alır; taban başka
/// birinin rengiyse ya da tonu onlarınkine `minHueGap` dereceden yakınsa, kullanılmayan renklerden tonu kullanılanlara en
/// uzak olan verilir (konuşan iki kişi yan yana karışmasın; ikinci kişi çoğu zaman karşı tonu alır). Kurallar ve ortak
/// test vektörü: scripts/speaker_colors_ref.py, docs/speaker-colors-vectors.json (Windows ve Android aynı sırada aynı
/// rengi verir).
public final class SpeakerColorBook: @unchecked Sendable {
    /// Yeni kişinin tabanı, kullanılan renklerin tonlarına en az bu kadar (derece) uzaksa olduğu gibi alınır.
    public static let minHueGap = 72

    private let lock = NSLock()
    private var people: [(key: String, color: String)] = []

    /// Altyazı Görünümü › Karakter Adı: "Tek Renk"te herkesin rengi (`fixed`), "Karaktere Göre"de kullanıcının seçtiği
    /// kişi renkleri (`overrides`, anahtar küçük harfli ad). Seçilmeyen kişilere sırayla palet rengi verilir.
    private var fixed: String?
    private var overrides: [String: String] = [:]

    public init() {}

    public func configure(fixed: String?, overrides: [String: String]) {
        let normalized = Dictionary(overrides.map { (Self.key($0.key), $0.value) }, uniquingKeysWith: { $1 })
        lock.withLock {
            self.fixed = fixed
            self.overrides = normalized
        }
    }

    /// Bu oturumda rengi verilmiş kişiler (adın anahtarı ve rengi), ilk görülen önce.
    public var known: [(key: String, color: String)] { lock.withLock { people } }

    /// Adın rengi; bilinmeyen kişi eklenir. Ad boşsa nil.
    public func color(_ name: String) -> String? {
        let key = Self.key(name)
        guard !key.isEmpty else { return nil }
        return lock.withLock {
            if let fixed { return fixed }
            if let chosen = overrides[key] ?? overrides.first(where: { Self.samePerson($0.key, key) })?.value {
                if !people.contains(where: { Self.samePerson($0.key, key) }) { people.append((key, chosen)) }
                return chosen
            }
            if let known = people.first(where: { Self.samePerson($0.key, key) }) { return known.color }
            let palette = SpeakerColors.palette
            let pick = palette[Self.pick(base: Int(SpeakerColors.hash(key) % UInt32(palette.count)),
                                         used: people.compactMap { palette.firstIndex(of: $0.color) })]
            people.append((key, pick))
            return pick
        }
    }

    /// Yeni kişinin palet sırası: `base` kullanılmıyor ve kullanılan her tondan en az `minHueGap` uzaksa `base`; değilse
    /// kullanılmayanlardan kullanılanlara en uzak tonlu olan (eşitlikte `base`'den palet sırasıyla ilki); hepsi
    /// kullanılıyorsa `base`. `used`: kullanılan renklerin palet sıraları (kullanıcının seçtiği palet dışı renk sayılmaz).
    static func pick(base: Int, used: [Int]) -> Int {
        guard !used.isEmpty else { return base }
        if !used.contains(base), hueGap(base, used) >= minHueGap { return base }
        let count = SpeakerColors.palette.count
        var best: Int?
        for step in 0..<count {
            let index = (base + step) % count
            guard !used.contains(index) else { continue }
            if best == nil || hueGap(index, used) > hueGap(best!, used) { best = index }
        }
        return best ?? base
    }

    /// `index` renginin tonunun kullanılan renklerin tonlarına en yakın uzaklığı (derece, çember üzerinde).
    static func hueGap(_ index: Int, _ used: [Int]) -> Int {
        let hues = SpeakerColors.hues
        return used.map { other in
            let difference = abs(hues[index] - hues[other])
            return min(difference, 360 - difference)
        }.min() ?? 360
    }

    /// Çeviri yeniden başladı: kişiler unutulur.
    public func reset() {
        lock.withLock { people.removeAll() }
    }

    /// Ad anahtarı: kırpılmış, sondaki noktalaması atılmış, küçük harf.
    static func key(_ name: String) -> String {
        var text = name.trimmingCharacters(in: .whitespaces)
        while let last = text.last, ".,!?;:…".contains(last) { text.removeLast() }
        return text.trimmingCharacters(in: .whitespaces).lowercased()
    }

    private static func samePerson(_ a: String, _ b: String) -> Bool {
        a == b || confusable(a) == confusable(b) || (min(a.utf16.count, b.utf16.count) >= 5 && distance(a, b) <= 1)
    }

    /// Yazı tanımanın karıştırdığı harfler eşitlenir: l/1/| → i, 0 → o, rn → m.
    private static func confusable(_ key: String) -> String {
        String(key.replacingOccurrences(of: "rn", with: "m").map { c -> Character in
            switch c {
            case "l", "1", "|": "i"
            case "0": "o"
            default: c
            }
        })
    }

    private static func distance(_ a: String, _ b: String) -> Int {
        let a = Array(a.utf16), b = Array(b.utf16)
        var row = Array(0...b.count)
        for i in 1...max(1, a.count) where i <= a.count {
            let previous = row
            row[0] = i
            for j in 1...max(1, b.count) where j <= b.count {
                row[j] = min(previous[j] + 1, row[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
        }
        return row[b.count]
    }
}
