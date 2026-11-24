// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// Konuşan adını renklendir: "Mattia: …" satırında yalnız ad ("Mattia:") o konuşanın sabit renginde görünür, cümle
/// kullanıcının seçtiği yazı renginde kalır. Renk addan hesaplanır (büyük/küçük harf fark etmez), aynı konuşan her
/// cihazda ve her oturumda aynı renktir. TV'ye `subtitle` olayının `speakerNames` alanıyla gider (0.9.79'dan eski TV
/// uygulamaları eski `speakers` alanıyla bütün satırı boyuyordu). Windows (SpeakerColors.cs), Android (SpeakerColors.kt)
/// ve TV uygulaması aynı paleti ve aynı hesabı kullanır.
public enum SpeakerColors {
    /// Koyu altyazı zemininde okunaklı (kontrast en az 6,5:1) on renk, OKLCH ton çemberinde 36 derece arayla: kırmızı,
    /// turuncu, sarı, açık yeşil, yeşil, turkuaz, mavi, lavanta, mor, pembe. Kullanıcı bildirimi (X): eski paletin on
    /// renginden üçü mavi, ikisi pembe/mordu ve hepsi soluktu; adlar hep pembe/mavi tonlarda çıkıyor, karakterler ayırt
    /// edilmiyordu (ortak vektör: docs/speaker-colors-vectors.json).
    public static let palette = ["#FD736D", "#FEA757", "#FEDD3C", "#9BE759", "#1EE4B2",
                                 "#2AD5E5", "#49B5FA", "#8F9BFB", "#D482FF", "#F76AB7"]
    /// `palette` renklerinin OKLCH tonu (derece); renkleri ayırırken kullanılır (`SpeakerColorBook`). Tamsayı tablo:
    /// platformlar tonu renkten hesaplamaz, kayan nokta farkı çıkmaz.
    public static let hues = [25, 61, 97, 133, 169, 205, 241, 277, 313, 349]

    /// Konuşanın rengi ("#RRGGBB"): küçük harfli adın UTF-16 birimleri üzerinde FNV-1a (32 bit).
    public static func color(for name: String) -> String {
        palette[Int(hash(name.trimmingCharacters(in: .whitespaces).lowercased()) % UInt32(palette.count))]
    }

    /// FNV-1a (32 bit), UTF-16 birimleri üzerinde.
    static func hash(_ key: String) -> UInt32 {
        var hash: UInt32 = 2_166_136_261
        for unit in key.utf16 {
            hash ^= UInt32(unit)
            hash = hash &* 16_777_619
        }
        return hash
    }

    /// "#RRGGBB" → 0–1 arası bileşenler; geçersizse nil.
    public static func rgb(_ hex: String) -> (red: Double, green: Double, blue: Double)? {
        guard hex.count == 7, hex.hasPrefix("#"), let value = UInt32(hex.dropFirst(), radix: 16) else { return nil }
        return (Double(value >> 16 & 0xFF) / 255, Double(value >> 8 & 0xFF) / 255, Double(value & 0xFF) / 255)
    }

    public struct Speaker: Equatable, Sendable {
        public var name: String
        public var color: String
    }

    /// Satır başlarındaki konuşan adları (tekrarsız, ilk görünüş sırasıyla) ve renkleri. `book`: oturumun renk defteri
    /// (v2); verilmezse addan hesaplanan renk.
    public static func speakers(in text: String, book: SpeakerColorBook? = nil) -> [Speaker] {
        var seen = Set<String>()
        return text.components(separatedBy: "\n").compactMap { line in
            guard let name = speaker(line), seen.insert(name).inserted else { return nil }
            return Speaker(name: name, color: book?.color(name) ?? color(for: name))
        }
    }

    /// Çeviride ad gibi görünen Türkçe başlıklar ("Hedef: Arabaya bin."); konuşan sayılmaz, renklenmez (Android ile aynı).
    static let turkishHeadings: Set<String> = [
        "hedef", "görev", "not", "ipucu", "uyarı", "ödül", "ödüller", "konum", "bölüm", "güncelleme", "bilgi", "durum",
        "soru", "cevap",
    ]

    /// Satırın baştaki konuşan adı; Türkçe başlıksa nil.
    static func speaker(_ line: String) -> String? {
        guard let name = SpeakerPrefix.split(line)?.name,
              !turkishHeadings.contains(name.lowercased(with: Locale(identifier: "tr"))) else { return nil }
        return name
    }

    public struct Segment: Equatable, Sendable {
        public var text: String
        /// nil: adsız (varsayılan renkte) parça.
        public var color: String?
    }

    /// Metnin parçaları. Yalnız satır başındaki konuşan adı ve iki noktası ("Mattia:") o konuşanın renginde; cümle ve
    /// bölünmüş devam satırları renksizdir, kullanıcının seçtiği yazı renginde kalır (önceden bütün satır renkleniyor,
    /// "Yazı rengi" beyazken altyazı renkli görünüyordu). Parçalar birleşince metnin kendisi çıkar.
    ///
    /// `wholeLine` (Karakter Adı › "Tüm Satır"): ad ve cümle, bölünmüş devam satırlarıyla birlikte sonraki konuşanın
    /// adına dek o konuşanın renginde (Windows, Android ve TV uygulamasıyla aynı).
    public static func segments(in text: String, book: SpeakerColorBook? = nil, wholeLine: Bool = false) -> [Segment] {
        var result: [Segment] = []
        func add(_ piece: String, _ color: String?) {
            guard !piece.isEmpty else { return }
            if let last = result.last, last.color == color {
                result[result.count - 1].text += piece
            } else {
                result.append(Segment(text: piece, color: color))
            }
        }
        var running: String?
        for (index, line) in text.components(separatedBy: "\n").enumerated() {
            if index > 0 { add("\n", running) }
            guard let name = speaker(line), let range = nameRange(name, in: line) else {
                add(line, running)
                continue
            }
            let color = book?.color(name) ?? color(for: name)
            add(String(line[..<range.lowerBound]), running)
            add(String(line[range]), color)
            if wholeLine { running = color }
            add(String(line[range.upperBound...]), running)
        }
        return result
    }

    /// Satırdaki "Ad:" bölümü (baştaki boşluk hariç, ad ile iki nokta arasındaki boşluk dahil); yoksa nil.
    static func nameRange(_ name: String, in line: String) -> Range<String.Index>? {
        guard let start = line.firstIndex(where: { !$0.isWhitespace }), line[start...].hasPrefix(name) else { return nil }
        var index = line.index(start, offsetBy: name.count)
        while index < line.endIndex, line[index] == " " { index = line.index(after: index) }
        guard index < line.endIndex, line[index] == ":" || line[index] == "：" else { return nil }
        return start..<line.index(after: index)
    }
}
