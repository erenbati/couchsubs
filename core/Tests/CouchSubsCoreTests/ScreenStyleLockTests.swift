// SPDX-License-Identifier: AGPL-3.0-only

@testable import CouchSubsCore
import Foundation
import XCTest

/// Ekran yazısı çevirisinin oturum boyunca kararlı görünüşü (`ScreenStyleLock`). Ortak deneme dosyası
/// Fixtures/screen-style-lock.json (Windows ScreenStyleLockTests.cs ve Android ScreenStyleLockTest.kt aynı vakalar).
final class ScreenStyleLockTests: XCTestCase {
    static func item(_ entry: [String: Any]) -> ScreenTranslation.Item {
        let source = entry["source"] as! String
        var item = ScreenTranslation.Item(source: source, translation: "TR " + source,
                                          box: TextBox(left: 0.1, top: 0.1, right: 0.3, bottom: 0.14), lineHeight: entry["line"] as! Double)
        let icons = entry["icons"] as! Int
        if icons > 0 { item.icons = (0..<icons).map { IconPlacement(at: $0, image: "data:image/png;base64,") } }
        item.rows = entry["rows"] as! Int
        item.bubble = entry["bubble"] as? Bool ?? false
        item.style = PhoneTextStyle(background: entry["bg"] as! String, foreground: entry["fg"] as! String)
        if entry["look"] as? Bool ?? true {
            item.look = TextLook(bold: entry["bold"] as! Bool, condensed: entry["condensed"] as! Bool, align: .left,
                                 upper: entry["upper"] as! Bool, flat: true)
        }
        return item
    }

    func testSharedStyleLockVectors() throws {
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/screen-style-lock.json")
        let fixture = try JSONSerialization.jsonObject(with: Data(contentsOf: source)) as! [String: Any]
        for vector in fixture["cases"] as! [[String: Any]] {
            let name = vector["name"] as! String
            var lock = ScreenStyleLock()
            for (s, step) in (vector["steps"] as! [[String: Any]]).enumerated() {
                let items = (step["items"] as! [[String: Any]]).map(Self.item)
                let got = lock.steady(items, now: step["now"] as! Int)
                let expect = step["expect"] as! [[String: Any]]
                XCTAssertEqual(got.count, expect.count, "\(name) #\(s)")
                for (k, (item, want)) in zip(got, expect).enumerated() {
                    let label = "\(name) #\(s).\(k)"
                    XCTAssertEqual(item.lineHeight, want["line"] as! Double, accuracy: 1e-9, label)
                    XCTAssertEqual(item.style?.foreground, want["fg"] as? String, label)
                    XCTAssertEqual(item.style?.background, want["bg"] as? String, label)
                    if let look = item.look {
                        XCTAssertEqual(look.bold, want["bold"] as! Bool, label)
                        XCTAssertEqual(look.condensed, want["condensed"] as! Bool, label)
                    }
                }
            }
        }
    }

    /// Ölçüt: aynı öğe türünde kareler arası boy/stil değişimi 0. Satır yükseklikleri ±%10 titreyen, kalınlığı ve
    /// renkleri oynayan 120 karelik menü dizisinde her öğe hep ilk çizildiği gibi görünür.
    private struct Seeded: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state
        }
    }

    func testJitteringMenuNeverChangesLook() {
        var lock = ScreenStyleLock()
        var generator = Seeded(state: 7)
        var first: [String: (Double, Bool, String, String)] = [:]
        for frame in 0..<120 {
            let rows = ["MAP", "BRIEF", "PROGRESS", "SETTINGS"].map { name -> ScreenTranslation.Item in
                var item = ScreenTranslation.Item(source: name, translation: name, box: TextBox(left: 0.1, top: 0.1, right: 0.2, bottom: 0.13),
                                                  lineHeight: 0.03 * Double.random(in: 0.9...1.1, using: &generator))
                let shade = String(format: "#%02X%02X%02X", Int.random(in: 0...30, using: &generator), 16, 16)
                item.style = PhoneTextStyle(background: shade, foreground: "#FFFFFF")
                item.look = TextLook(bold: Bool.random(using: &generator), condensed: false, align: .left, upper: true, flat: true)
                return item
            }
            for item in lock.steady(rows, now: frame * 500) {
                let look = (item.lineHeight, item.look!.bold, item.style!.background, item.style!.foreground)
                if let seen = first[item.source] {
                    XCTAssertEqual(seen.0, look.0)
                    XCTAssertEqual(seen.1, look.1)
                    XCTAssertEqual(seen.2, look.2)
                    XCTAssertEqual(seen.3, look.3)
                } else { first[item.source] = look }
            }
        }
    }
}
