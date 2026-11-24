// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// "Ekranı çevir" ve otomatik ekran yazısında çevirinin görünüşü oturum boyunca kararlı (Sinan Bey: "bir kere ekrana
/// yazıldıysa o boyda kalmalı, ekran değiştikçe stil/boyut değişmesin"). Yazı boyu (satır yüksekliği), kalınlık, dar aile
/// ve renkler her karede yeniden ölçülüyordu: aynı menü satırı bir karede biraz büyük, ötekinde ince, zemini bir ton farklı
/// çiziliyordu. Artık öğe türü başına (`role`: tuş ipucu, çok satırlı bilgi/görev metni, BÜYÜK HARF başlık/sekme, düz etiket)
/// ilk ölçümde kilitlenir:
/// - Aynı türde yazı boyu kilitli boylardan birine `sizeShare` içinde yakınsa o boyla çizilir; kalınlığı ve dar ailesi o
///   boyun ilk ölçümünden gelir. Aynı karede kilitli boya uyan başka öğe varken uymayan öğe ayrı bir boydur (başlık ile
///   satır), hemen kilitlenir.
/// - Türün hiçbir öğesi kilitli boylara uymuyorsa (çözünürlük/pencere değişti, yakınlaşma) değişim ancak kesintisiz
///   `settleMs` sürerse benimsenir; o zamana kadar kilitli boy çizilir, arada uyan tur sayacı sıfırlar
///   (`PhonePanelSteady` ile aynı eşikler: %25, 1 sn).
/// - Renkler: zemin ve yazı rengi kilitli bir renk çiftine `colorSlack` içinde yakınsa o çift çizilir; belirgin farklı çift
///   (seçili menü satırı) ayrı çifttir, hemen kilitlenir.
/// Telefon kartı, balonlar ve sohbet paneli kendi kilidini kullanır (`PhonePanelSteady`); özgün stili olmayan öğeye dokunulmaz.
/// Windows (ScreenStyleLock.cs) ve Android (ScreenStyleLock.kt) aynı kuralı, aynı eşikleri kullanır; ortak deneme dosyası
/// Fixtures/screen-style-lock.json.
public struct ScreenStyleLock: Sendable {
    public static let sizeShare = PhonePanelSteady.sizeShare
    public static let settleMs = PhonePanelSteady.settleMs
    /// Aynı karede bu kadar yakın boylar tek boydur (`ScreenFit.sameLine`).
    public static let sameLine = ScreenFit.sameLine
    /// Renk bileşenlerinin en büyük farkı bu kadarsa aynı renk sayılır.
    public static let colorSlack = 40
    /// Tür başına saklanan en çok renk çifti.
    static let paletteLimit = 32
    /// Tür başına hatırlanan en çok öğe; aşılınca unutulur (boylar kalır).
    static let seenLimit = 256

    struct Tier: Sendable {
        var line: Double
        var bold: Bool
        var condensed: Bool
    }

    struct Kind: Sendable {
        var tiers: [Tier] = []
        var since: Int?
        /// Öğenin (özgün yazısıyla) son çizildiği boy; eş boylar arasında gidip gelmesin.
        var seen: [String: Int] = [:]
    }

    private var kinds: [String: Kind] = [:]
    private var palettes: [String: [PhoneTextStyle]] = [:]

    public init() {}

    /// Öğenin türü; kilide girmeyen öğede nil.
    static func role(_ item: ScreenTranslation.Item) -> String? {
        guard let look = item.look, ScreenFit.takesPart(item), item.panel == nil, item.lineHeight > 0 else { return nil }
        if !(item.icons ?? []).isEmpty { return "hint" }
        if item.rows > 1 || item.paragraphs { return "body" }
        return look.upper ? "caps" : "label"
    }

    /// Öğeler kilitli görünüşle. `now`: milisaniye (tekdüze saat).
    public mutating func steady(_ items: [ScreenTranslation.Item], now: Int) -> [ScreenTranslation.Item] {
        var result = items
        let roles = items.map(Self.role)
        for role in Set(roles.compactMap { $0 }).sorted() {
            let members = items.indices.filter { roles[$0] == role }
            var kind = kinds[role] ?? Kind()
            func off(_ line: Double, _ tier: Int) -> Double { abs(line / kind.tiers[tier].line - 1) }
            /// Öğenin boyu: önceki karede çizildiği boy hâlâ uyuyorsa o (eş boylar arasında gidip gelmesin), yoksa en yakın
            /// uyan boy.
            func tier(_ i: Int) -> Int? {
                let line = items[i].lineHeight
                if let seen = kind.seen[items[i].source], seen < kind.tiers.count, off(line, seen) <= Self.sizeShare { return seen }
                let near = kind.tiers.indices.filter { off(line, $0) <= Self.sizeShare }
                return near.min { off(line, $0) < off(line, $1) }
            }
            func adopt(_ fresh: [Int]) {
                for (tier, group) in Self.tiers(fresh.map { items[$0] }) {
                    for k in group { kind.seen[items[fresh[k]].source] = kind.tiers.count }
                    kind.tiers.append(tier)
                }
            }
            let matched = members.filter { tier($0) != nil }
            if kind.tiers.isEmpty {
                adopt(members)
            } else if matched.isEmpty {
                // Türün hiçbir öğesi kilitli boya uymuyor: ölçek değişimi adayı.
                if let since = kind.since, now - since >= Self.settleMs {
                    kind = Kind()
                    adopt(members)
                } else if kind.since == nil {
                    kind.since = now
                }
            } else {
                kind.since = nil
                // Uyan öğe varken uymayan öğe aynı ekranda başka boydaki öğedir (başlık ve satır).
                let fresh = members.filter { tier($0) == nil }
                if !fresh.isEmpty { adopt(fresh) }
            }
            if kind.seen.count > Self.seenLimit { kind.seen = [:] }
            for i in members {
                let line = items[i].lineHeight
                let index = tier(i) ?? kind.tiers.indices.min { off(line, $0) < off(line, $1) }!
                if tier(i) != nil { kind.seen[items[i].source] = index }
                let locked = kind.tiers[index]
                result[i].lineHeight = locked.line
                result[i].look?.bold = locked.bold
                result[i].look?.condensed = locked.condensed
                if let style = items[i].style { result[i].style = palette(style, role: role) }
            }
            kinds[role] = kind
        }
        return result
    }

    /// Bir karedeki öğelerin boyları: yakın boylar (`sameLine`) tek boyda, değeri ortanca öğeninki; her boyun öğeleri
    /// (verilen dizideki sıraları).
    static func tiers(_ items: [ScreenTranslation.Item]) -> [(Tier, [Int])] {
        let order = items.indices.sorted { items[$0].lineHeight < items[$1].lineHeight }
        var groups: [[Int]] = []
        for i in order {
            if let first = groups.last?.first, items[i].lineHeight <= items[first].lineHeight * (1 + sameLine) {
                groups[groups.count - 1].append(i)
            } else {
                groups.append([i])
            }
        }
        return groups.map { group in
            let middle = items[group[(group.count - 1) / 2]]
            return (Tier(line: middle.lineHeight, bold: middle.look?.bold ?? false, condensed: middle.look?.condensed ?? false), group)
        }
    }

    private mutating func palette(_ style: PhoneTextStyle, role: String) -> PhoneTextStyle {
        var known = palettes[role] ?? []
        if let found = known.first(where: { Self.near($0.background, style.background) && Self.near($0.foreground, style.foreground) }) {
            return found
        }
        known.append(style)
        palettes[role] = Array(known.suffix(Self.paletteLimit))
        return style
    }

    static func near(_ a: String, _ b: String) -> Bool {
        guard let x = rgb(a), let y = rgb(b) else { return a == b }
        return abs(x.0 - y.0) <= colorSlack && abs(x.1 - y.1) <= colorSlack && abs(x.2 - y.2) <= colorSlack
    }

    private static func rgb(_ hex: String) -> (Int, Int, Int)? {
        guard hex.count == 7, hex.hasPrefix("#"), let value = Int(hex.dropFirst(), radix: 16) else { return nil }
        return ((value >> 16) & 0xFF, (value >> 8) & 0xFF, value & 0xFF)
    }

    /// Oturum bitti (ya da çözünürlük değişti): sonraki öğeler yeniden ölçülür.
    public mutating func reset() {
        self = ScreenStyleLock()
    }
}
