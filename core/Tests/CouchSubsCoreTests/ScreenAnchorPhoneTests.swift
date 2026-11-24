// SPDX-License-Identifier: AGPL-3.0-only

@testable import CouchSubsCore
import Foundation
import XCTest

/// Telefona yapışık çeviri (`PhoneAnchorSession`, `AnchorPose`; önce Mac'te). OCR'sız: yapay kareler
/// (`ScreenAnchorTests.render`) ve dönüşüm hesabı.
final class ScreenAnchorPhoneTests: XCTestCase {
    private let width = 320, height = 180
    private let rect = ScreenAnchor.Rect(x: 110, y: 30, width: 80, height: 120)

    private var region: CropRegion {
        CropRegion(top: rect.y / Double(height), bottom: (rect.y + rect.height) / Double(height),
                   left: rect.x / Double(width), right: (rect.x + rect.width) / Double(width))
    }

    private func frame(_ motion: ScreenAnchor.Motion, k: Int = 0, content: [Double]? = nil) -> ScreenAnchor.Gray {
        ScreenAnchorTests.render(width: width, height: height, rect: rect, motion: motion, frame: k, gain: 1, content: content)
    }

    func testPoseMapsAndUnmapsInFrameUnits() {
        let pose = AnchorPose(generation: 1, reference: CropRegion(top: 0.2, bottom: 0.8, left: 0.55, right: 0.85),
                              motion: ScreenAnchor.Motion(a: 1.05, b: 0.02, c: -0.03, d: 0.98, dx: 0.012, dy: -0.02,
                                                          g: 0.05, h: -0.04))
        for (x, y) in [(0.55, 0.2), (0.7, 0.5), (0.85, 0.8), (0.6, 0.31)] {
            let p = pose.map(x, y)
            let back = pose.unmap(p.x, p.y)!
            XCTAssertEqual(back.x, x, accuracy: 1e-9)
            XCTAssertEqual(back.y, y, accuracy: 1e-9)
            // TV'ye giden 3×3 matris aynı yeri verir.
            let m = pose.matrix
            let w = m[6] * x + m[7] * y + m[8]
            XCTAssertEqual((m[0] * x + m[1] * y + m[2]) / w, p.x, accuracy: 1e-9)
            XCTAssertEqual((m[3] * x + m[4] * y + m[5]) / w, p.y, accuracy: 1e-9)
        }
        // Öteleme ve ölçekte kutu gidip gelince aynı kalır.
        let shift = AnchorPose(generation: 1, reference: pose.reference,
                               motion: ScreenAnchor.Motion(a: 1.1, d: 1.1, dx: 0.03, dy: -0.01))
        let box = TextBox(left: 0.6, top: 0.3, right: 0.75, bottom: 0.36)
        let there = shift.fromReference(box), back = shift.toReference(there)
        XCTAssertEqual(back.left, box.left, accuracy: 1e-9)
        XCTAssertEqual(back.bottom, box.bottom, accuracy: 1e-9)
        XCTAssertEqual(there.right - there.left, (box.right - box.left) * 1.1, accuracy: 1e-9)
    }

    /// İzleme karesinin pikselindeki dönüşüm kareye oranla aynı noktayı taşır (en ve boy farklı ölçekte).
    func testNormalizedMotionMatchesPixelMotion() {
        let px = ScreenAnchor.Motion(a: 1.02, b: 0.04, c: -0.05, d: 0.97, dx: 6, dy: -4, g: 0.0004, h: -0.0003)
        let norm = AnchorPose.normalized(px, width: width, height: height)
        let x = 130.0, y = 70.0
        let p = px.map(x, y, cx: rect.centerX, cy: rect.centerY)
        let q = norm.map(x / Double(width), y / Double(height), cx: rect.centerX / Double(width),
                         cy: rect.centerY / Double(height))
        XCTAssertEqual(q.x * Double(width), p.x, accuracy: 1e-9)
        XCTAssertEqual(q.y * Double(height), p.y, accuracy: 1e-9)
    }

    func testSessionFollowsPhoneAndReportsChanges() {
        let session = PhoneAnchorSession(clock: { 0 })
        var changes: [PhoneAnchorSession.Change] = []
        var lines: [String] = []
        session.onChange = { changes.append($0) }
        session.onLog = { lines.append($0) }
        XCTAssertNil(session.pose(at: 0))

        let first = session.place(gray: frame(.identity), region: region, at: 0)
        XCTAssertEqual(first.generation, 1)
        XCTAssertEqual(first.motion, .identity)
        XCTAssertTrue(session.isActive)
        XCTAssertTrue(lines.contains { $0.hasPrefix("çapa kuruldu (kuşak 1") })

        // Telefon 2,5 piksel sağa, 1,5 piksel yukarı kaydı: çapa izler, çeviri onunla gider.
        session.feed(gray: frame(ScreenAnchor.Motion(dx: 2.5, dy: -1.5), k: 1), at: 33)
        let moved = session.pose(at: 33)!
        XCTAssertEqual(moved.generation, 1)
        XCTAssertEqual(moved.motion.dx * Double(width), 2.5, accuracy: 0.2)
        XCTAssertEqual(moved.motion.dy * Double(height), -1.5, accuracy: 0.2)
        XCTAssertEqual(changes.count, 2)

        // Aynı kuşakta okuma: çapa yeniden kurulmaz, o karenin yeri döner.
        let movedRegion = moved.fromReference(region)
        let again = session.place(gray: frame(ScreenAnchor.Motion(dx: 2.5, dy: -1.5), k: 1), region: movedRegion, at: 33)
        XCTAssertEqual(again, moved)

        // Telefon indirildi (ekran başka sahne): çapa kaybolur, kuşak bildirilir.
        let blank = ScreenAnchor.Gray(width: width, height: height, pixels: [UInt8](repeating: 40, count: width * height))
        session.feed(gray: blank, at: 66)
        XCTAssertFalse(session.isActive)
        XCTAssertNil(session.pose)
        guard case .lost(let generation, _) = changes.last else { return XCTFail("kayıp bildirilmedi") }
        XCTAssertEqual(generation, 1)
        XCTAssertTrue(lines.contains { $0.hasPrefix("çapa kayboldu (kuşak 1") })

        // Sonraki okuma yeni kuşak kurar.
        XCTAssertEqual(session.place(gray: frame(.identity, k: 3), region: region, at: 99).generation, 2)
        session.reset()
        XCTAssertFalse(session.isActive)
    }

    /// Okumadaki telefon çapanın yerinden uzaksa (izleyici yanlış yere yapıştı ya da telefon başka yerde açıldı) çapa o
    /// okumayla yeniden kurulur.
    func testFarReadingRebasesAnchor() {
        let session = PhoneAnchorSession(clock: { 0 })
        _ = session.place(gray: frame(.identity), region: region, at: 0)
        var far = region
        far.left -= 0.3
        far.right -= 0.3
        let rebased = session.place(gray: frame(.identity), region: far, at: 10)
        XCTAssertEqual(rebased.generation, 2)
        XCTAssertEqual(rebased.reference, far)
    }

    /// Kuruldu/kayboldu satırları dakikada sınırlı; özet 10 sn'de bir.
    func testLogIsBounded() {
        var now = 0
        let session = PhoneAnchorSession(clock: { now })
        var lines: [String] = []
        session.onLog = { lines.append($0) }
        for k in 0..<40 {
            _ = session.place(gray: frame(.identity), region: region, at: k)
            session.reset()
        }
        XCTAssertEqual(lines.count, PhoneAnchorSession.eventLinesPerMinute)
        lines = []
        _ = session.place(gray: frame(.identity), region: region, at: 0)
        for k in 1...4 {
            now = k * 4000
            session.feed(gray: frame(ScreenAnchor.Motion(dx: Double(k) * 0.5), k: k), at: now)
        }
        XCTAssertTrue(lines.contains { $0.hasPrefix("çapa: kuşak") && $0.contains("uyum ort") && $0.contains("kare başı ort") },
                      lines.joined(separator: "\n"))
    }

    func testAnchorEventJson() {
        let pose = AnchorPose(generation: 4, reference: region, motion: ScreenAnchor.Motion(dx: 0.0123456789))
        let moved = SubtitleServer.json(.moved(pose))
        XCTAssertEqual(moved["gen"] as? Int, 4)
        let m = moved["m"] as! [Decimal]
        XCTAssertEqual(m.count, 8)
        XCTAssertEqual(m[4], Decimal(string: "0.012346"))
        let lost = SubtitleServer.json(.lost(generation: 4, reason: "x"))
        XCTAssertEqual(lost["lost"] as? Bool, true)
        XCTAssertEqual(lost["gen"] as? Int, 4)
    }

    /// Türkçe ikiz: düz zeminde yazının harfleri silinip yerine çeviri çizilir; yazı kutusunun dışı saydam kalır (oyunun
    /// görüntüsü, simgeler örtülmez), kutunun içi opak.
    func testTwinErasesOnlyTextBoxes() throws {
        let w = 400, h = 300
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                let o = (y * w + x) * 4
                // Telefon ekranı (x 150–250, y 50–250) açık gri; dışı koyu mavi. Yazı: koyu dikey çizgiler (y 100–112).
                let phone = x >= 150 && x < 250 && y >= 50 && y < 250
                let ink = phone && y >= 100 && y < 112 && x >= 165 && x < 225 && x % 4 < 2
                let c: (UInt8, UInt8, UInt8) = ink ? (20, 20, 20) : phone ? (220, 220, 220) : (10, 30, 90)
                bytes[o] = c.0; bytes[o + 1] = c.1; bytes[o + 2] = c.2; bytes[o + 3] = 255
            }
        }
        let frame = try XCTUnwrap(TextErase.Image(width: w, height: h, bytes: bytes).cgImage())
        let reference = CropRegion(top: 50.0 / 300, bottom: 250.0 / 300, left: 150.0 / 400, right: 250.0 / 400)
        let pose = AnchorPose(generation: 3, reference: reference)
        var item = ScreenTranslation.Item(source: "Hello there", translation: "Merhaba",
                                          box: TextBox(left: 162.0 / 400, top: 98.0 / 300, right: 228.0 / 400, bottom: 114.0 / 300),
                                          lineHeight: 12.0 / 300)
        item.style = PhoneTextStyle(background: "#DCDCDC", foreground: "#141414")
        let layer = try XCTUnwrap(PhoneTwin.build(frame: frame, pose: pose, items: [item]))
        XCTAssertEqual(layer.generation, 3)
        XCTAssertEqual(layer.image.width, 100)
        XCTAssertEqual(layer.notes.count, 1)
        XCTAssertTrue(layer.notes[0].contains("silindi"), layer.notes[0])
        let out = try XCTUnwrap(TextErase.Image(layer.image))
        func alpha(_ x: Int, _ y: Int) -> UInt8 { out.bytes[(y * out.width + x) * 4 + 3] }
        XCTAssertEqual(alpha(5, 5), 0)       // telefonun boş yeri: saydam
        XCTAssertEqual(alpha(50, 150), 0)
        XCTAssertEqual(alpha(40, 56), 255)   // yazının kutusu: opak
        // Çeviri aynı adla gelirse (ad, sayı) dokunulmaz.
        var same = item
        same.translation = same.source
        XCTAssertNil(PhoneTwin.build(frame: frame, pose: pose, items: [same]))
    }
}
