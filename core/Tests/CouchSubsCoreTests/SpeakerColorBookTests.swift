// SPDX-License-Identifier: AGPL-3.0-only

import XCTest
@testable import CouchSubsCore

/// Konuşana göre renk v3: dört platformun ortak vektörü (docs/speaker-colors-vectors.json) birebir.
final class SpeakerColorBookTests: XCTestCase {
    private struct Vectors: Decodable {
        struct Step: Decodable { var name: String; var color: String }
        var palette: [String]
        var hues: [Int]
        var minHueGap: Int
        var sequence: [Step]
        var gta6: [Step]
    }

    private func vectors() throws -> Vectors {
        // core/Tests/CouchSubsCoreTests/<dosya> → depo kökü/docs/
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("docs/speaker-colors-vectors.json"))
        return try JSONDecoder().decode(Vectors.self, from: data)
    }

    func testSharedSequenceGivesTheSameColours() throws {
        let vectors = try vectors()
        XCTAssertEqual(SpeakerColors.palette, vectors.palette)
        XCTAssertEqual(SpeakerColors.hues, vectors.hues)
        XCTAssertEqual(SpeakerColorBook.minHueGap, vectors.minHueGap)
        for sequence in [vectors.sequence, vectors.gta6] {
            let book = SpeakerColorBook()
            for step in sequence { XCTAssertEqual(book.color(step.name), step.color, step.name) }
        }
    }

    /// Kullanıcı bildirimi (X): ad renkleri hep pembe/mavi tonlarda çıkıyor, karakterler ayırt edilmiyordu. Eski paletin
    /// on renginden üçü mavi, ikisi pembe/mordu; GTA 6'nın iki baş karakteri Lucia pembe, Jason turkuaz çıkıyordu. Palet
    /// ton çemberine eşit yayılır; bir sahnedeki kişiler birbirinden belirgin ayrı tonlar alır, aynı kişi hep aynı renktir.
    func testColorsSpreadAcrossDistinctHues() {
        let hues = SpeakerColors.hues
        XCTAssertEqual(hues.count, SpeakerColors.palette.count)
        XCTAssertEqual(Set(SpeakerColors.palette).count, SpeakerColors.palette.count)
        for index in hues.indices {
            let next = index + 1 == hues.count ? hues[0] + 360 : hues[index + 1]
            XCTAssertEqual(next - hues[index], 36, "tonlar eşit aralıklı")
        }
        // Koyu zeminde okunaklı.
        for hex in SpeakerColors.palette {
            XCTAssertGreaterThanOrEqual(TextStyleSampler.contrast(hex, SubtitleStyle.defaultBackgroundColor), 6.5, hex)
        }
        let book = SpeakerColorBook()
        let cast = ["Lucia", "Jason", "Cal", "Yolanda", "Brian"]
        let colors = cast.map { book.color($0)! }
        XCTAssertEqual(Set(colors).count, cast.count)
        // Konuşan iki baş karakter birbirine yakın tonda değil; sonrakiler de öncekilerin hiçbirinin tonuna denk düşmez.
        let indices = colors.map { SpeakerColors.palette.firstIndex(of: $0)! }
        XCTAssertGreaterThanOrEqual(SpeakerColorBook.hueGap(indices[1], [indices[0]]), SpeakerColorBook.minHueGap)
        for position in indices.indices.dropFirst() {
            XCTAssertGreaterThanOrEqual(SpeakerColorBook.hueGap(indices[position], Array(indices[..<position])), 36, cast[position])
        }
        // Aynı kişi (büyük harf, yakın okuma) aynı renk; yeni oturumda ilk kişi hep addan hesaplanan rengini alır.
        XCTAssertEqual(book.color("LUCIA"), colors[0])
        XCTAssertEqual(book.color("Jasen"), colors[1])
        book.reset()
        XCTAssertEqual(book.color("Lucia"), SpeakerColors.color(for: "Lucia"))
    }

    func testResetStartsANewSession() {
        let book = SpeakerColorBook()
        XCTAssertEqual(book.color("Mattia"), "#F76AB7")
        XCTAssertEqual(book.color("Boobie"), "#1EE4B2")
        book.reset()
        XCTAssertEqual(book.color("Boobie"), "#F76AB7")
        XCTAssertNil(book.color(" ... "))
    }

    func testTitlesAndTimesAreNotSpeakers() {
        for line in ["Hedef: Arabaya bin.", "Görev: Lucia'yı bul.", "İpucu: Haritayı aç.", "Not: Kaydet.", "Soru: Neden?",
                     "12:30", "3:1 oranla kazandın"] {
            XCTAssertTrue(SpeakerColors.speakers(in: line).isEmpty, line)
        }
    }

    func testServerAndSegmentsUseTheSessionColours() {
        let server = SubtitleServer(port: 0)
        XCTAssertEqual(server.speakerBook.color("Mattia"), "#F76AB7")
        XCTAssertEqual(server.speakerBook.color("Boobie"), "#1EE4B2")
        XCTAssertEqual(SpeakerColors.speakers(in: "Boobie: Gel.", book: server.speakerBook).map(\.color), ["#1EE4B2"])
        XCTAssertEqual(SpeakerColors.segments(in: "Mattla: Gidelim.", book: server.speakerBook).map(\.color), ["#F76AB7", nil])
    }

    /// Altyazı Görünümü › Karakter Adı: "Tek Renk" herkesi aynı renkle, "Karaktere Göre"de seçilen renk otomatik paletin
    /// önüne geçer; seçilmeyenlere palet sırayla verilir. Stil sunucuya gidince defter ayarlanır.
    func testChosenNameColorsWin() {
        let book = SpeakerColorBook()
        book.configure(fixed: nil, overrides: ["Jason": "#4FD1C5"])
        XCTAssertEqual(book.color("JASON"), "#4FD1C5")
        XCTAssertNotNil(book.color("Lucia"))
        XCTAssertNotEqual(book.color("Lucia"), "#4FD1C5")
        book.configure(fixed: "#F5B83D", overrides: [:])
        XCTAssertEqual(book.color("Lucia"), "#F5B83D")
        XCTAssertEqual(book.color("Cal"), "#F5B83D")

        let server = SubtitleServer(port: 0)
        server.sendStyle(SubtitleStyle(nameColorMode: .single, nameHex: "#B794F6"))
        XCTAssertEqual(server.speakerBook.color("Brian"), "#B794F6")
    }

    /// Yeni stil alanları eski kayıtta yoktur; geçersiz renk yok sayılır, TV'ye yalnız geçerli alanlar gider.
    func testStyleColorFieldsDecodeAndEncode() throws {
        let old = try JSONDecoder().decode(SubtitleStyle.self, from: Data(#"{"fontSize":58}"#.utf8))
        XCTAssertEqual(old.backgroundColor, SubtitleStyle.defaultBackgroundColor)
        XCTAssertNil(old.textHex)
        XCTAssertEqual(old.nameColorMode, .speaker)
        XCTAssertFalse(old.nameOnly)
        let bad = try JSONDecoder().decode(SubtitleStyle.self, from: Data(##"{"textHex":"red","backgroundColor":"#0e1a30"}"##.utf8))
        XCTAssertNil(bad.textHex)
        XCTAssertEqual(bad.backgroundColor, "#0E1A30")
        var style = SubtitleStyle()
        style.textHex = "#FFE066"
        style.nameOnly = true
        let json = style.json
        XCTAssertEqual(json["textHex"] as? String, "#FFE066")
        XCTAssertEqual(json["backgroundColor"] as? String, "#101014")
        XCTAssertEqual(json["nameOnly"] as? Bool, true)
        XCTAssertNil(json["hdmiInput"])
        style.hdmiInput = 2
        XCTAssertEqual(style.json["hdmiInput"] as? Int, 2)
        let round = try JSONDecoder().decode(SubtitleStyle.self, from: JSONEncoder().encode(style))
        XCTAssertEqual(round, style)
    }
}
