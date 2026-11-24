// SPDX-License-Identifier: AGPL-3.0-only

@testable import CouchSubsCore
import CoreGraphics
import Foundation
import XCTest

/// Ekran yazısı çevirisinin takibi (`ScreenPresence`): özgün yazı kalkınca çeviri aynı karede kalkar, titreme yok. Ortak
/// deneme dosyası Fixtures/screen-presence.json (Windows ScreenPresenceTests.cs ve Android ScreenPresenceTest.kt aynı vakalar).
final class ScreenPresenceTests: XCTestCase {
    static func item(_ source: String, tracked: Bool, left: Double = 0.1) -> ScreenTranslation.Item {
        var item = ScreenTranslation.Item(source: source, translation: "TR " + source,
                                          box: TextBox(left: left, top: 0.1, right: left + 0.2, bottom: 0.15), lineHeight: 0.04)
        item.style = PhoneTextStyle(background: "#1E1E1E", foreground: "#E6E6E6")
        item.look = TextLook(bold: false, condensed: false, align: .left, upper: true, flat: true)
        item.bubble = !tracked
        return item
    }

    func testSharedPresenceVectors() throws {
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/screen-presence.json")
        let fixture = try JSONSerialization.jsonObject(with: Data(contentsOf: source)) as! [String: Any]
        for vector in fixture["cases"] as! [[String: Any]] {
            let name = vector["name"] as! String
            let items = (vector["items"] as! [[String: Any]]).enumerated().map { i, entry in
                Self.item(entry["source"] as! String, tracked: entry["tracked"] as! Bool, left: 0.1 + 0.25 * Double(i))
            }
            var presence = ScreenPresence()
            for (f, frame) in (vector["frames"] as! [[String: Any]]).enumerated() {
                let patches = frame["patches"] as! [Any]
                let got = presence.visible(items) { box in
                    let index = items.firstIndex { $0.box == box }!
                    return patches[index] as? [Int]
                }
                XCTAssertEqual(got, frame["expect"] as! [Bool], "\(name) #\(f)")
            }
        }
    }

    /// Sunucu: özgün yazısı kalkan öğe TV'ye giden `screen` olayından aynı karede düşer, geri gelince döner.
    func testServerDropsTranslationWhoseTextLeft() {
        let server = SubtitleServer(port: 0)
        var events: [[ScreenTranslation.Item]] = []
        server.onEvent = { event in if case let .screen(_, _, items) = event { events.append(items) } }
        let items = [Self.item("MAP", tracked: true), Self.item("BRIEF", tracked: true, left: 0.4)]
        server.sendScreen(items, durationMs: 10_000)
        let text = (0..<(ScreenPresence.cols * ScreenPresence.rows)).map { $0 % 5 == 0 ? 230 : 30 }
        let flat = [Int](repeating: 30, count: text.count)
        server.observe { _ in text }
        XCTAssertEqual(events.count, 1)
        server.observe { box in box.left < 0.3 ? flat : text }
        XCTAssertEqual(events.last?.map(\.source), ["BRIEF"])
        // Aynı çeviriler yeniden gönderilse de (süre uzatma) kalkan öğe dönmez.
        server.sendScreen(items, durationMs: 10_000)
        XCTAssertEqual(events.last?.map(\.source), ["BRIEF"])
        server.observe { _ in text }
        server.observe { _ in text }
        XCTAssertEqual(events.last?.map(\.source), ["MAP", "BRIEF"])
    }
}
