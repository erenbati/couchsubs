// SPDX-License-Identifier: AGPL-3.0-only

@testable import CouchSubsCore
import Foundation
import XCTest

/// Çapa takibi (`ScreenAnchor`): telefonun/kartın dörtgeni her karede alt piksel izlenir. Ortak deneme dosyası
/// Fixtures/screen-anchor.json (Windows ScreenAnchorTests.cs ve Android ScreenAnchorTest.kt aynı vakalar).
final class ScreenAnchorTests: XCTestCase {
    private static func motion(_ values: [Double]) -> ScreenAnchor.Motion {
        ScreenAnchor.Motion(a: values[0], b: values[1], c: values[2], d: values[3], dx: values[4], dy: values[5],
                            g: values[6], h: values[7])
    }

    /// Ortak kurala göre yapay kare (bkz. fixture `note`).
    static func render(width: Int, height: Int, rect: ScreenAnchor.Rect, motion m: ScreenAnchor.Motion, frame k: Int,
                       gain: Double, content: [Double]?) -> ScreenAnchor.Gray {
        let cx = rect.centerX, cy = rect.centerY
        let inverse = ScreenAnchor.invert3([m.a, m.b, m.dx, m.c, m.d, m.dy, m.g, m.h, 1])!
        var pixels = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                var sum = 0.0
                for (sx, sy) in [(0.25, 0.25), (0.75, 0.25), (0.25, 0.75), (0.75, 0.75)] {
                    let fx = Double(x) + sx - 0.5, fy = Double(y) + sy - 0.5
                    let px = fx - cx, py = fy - cy
                    let w = inverse[6] * px + inverse[7] * py + inverse[8]
                    let u = (inverse[0] * px + inverse[1] * py + inverse[2]) / w
                    let v = (inverse[3] * px + inverse[4] * py + inverse[5]) / w
                    var value: Double
                    if abs(u) <= rect.width / 2, abs(v) <= rect.height / 2 {
                        if let c = content, u >= c[0], v >= c[1], u <= c[2], v <= c[3] {
                            value = 120 + 60 * sin(0.33 * u + 0.11 * v)
                        } else {
                            value = 128 + 50 * sin(0.21 * u) * cos(0.17 * v) + 40 * sin(0.05 * (u + 2 * v))
                        }
                    } else {
                        value = 60 + 30 * sin(0.13 * fx + 0.07 * fy + 0.4 * Double(k))
                    }
                    sum += value
                }
                pixels[y * width + x] = UInt8(max(0, min(255, (sum / 4 * gain).rounded())))
            }
        }
        return ScreenAnchor.Gray(width: width, height: height, pixels: pixels)
    }

    private func fixture() throws -> [String: Any] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/screen-anchor.json")
        return try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
    }

    func testSharedTrackingVectors() throws {
        for vector in try fixture()["cases"] as! [[String: Any]] {
            let name = vector["name"] as! String
            let r = vector["rect"] as! [Double]
            let rect = ScreenAnchor.Rect(x: r[0], y: r[1], width: r[2], height: r[3])
            let width = vector["width"] as! Int, height = vector["height"] as! Int
            let tolerance = vector["tolerance"] as! Double
            let gains = vector["gain"] as? [Double]
            let content = vector["content"] as? [Double]
            let contentFrom = vector["contentFrom"] as? Int ?? Int.max
            let lostFrom = vector["lostFrom"] as? Int ?? Int.max
            let motions = (vector["motions"] as! [[Double]]).map(Self.motion)
            let tracker = ScreenAnchor.Tracker()
            for (k, truth) in motions.enumerated() {
                let frame = Self.render(width: width, height: height, rect: rect, motion: truth, frame: k,
                                        gain: gains?[k] ?? 1, content: k >= contentFrom ? content : nil)
                if k == 0 {
                    tracker.begin(frame, rect: rect)
                    continue
                }
                let fix = tracker.track(frame)
                if k >= lostFrom {
                    XCTAssertNil(fix, "\(name) #\(k)")
                    break
                }
                guard let fix else { XCTFail("\(name) #\(k): çapa kayboldu"); break }
                let error = fix.motion.distance(to: truth, rect: rect)
                XCTAssertLessThan(error, tolerance, "\(name) #\(k)")
            }
        }
    }

    func testSharedSmootherVectors() throws {
        for vector in try fixture()["smoother"] as! [[String: Any]] {
            let r = vector["rect"] as! [Double]
            let rect = ScreenAnchor.Rect(x: r[0], y: r[1], width: r[2], height: r[3])
            var smoother = ScreenAnchor.Smoother()
            for (k, step) in (vector["steps"] as! [[String: Any]]).enumerated() {
                let got = smoother.push(Self.motion(step["raw"] as! [Double]), rect: rect)
                XCTAssertEqual(got.motion, Self.motion(step["shown"] as! [Double]), "\(vector["name"]!) #\(k)")
                XCTAssertEqual(got.jumped, step["jumped"] as! Bool, "\(vector["name"]!) #\(k)")
            }
        }
    }

    /// RGBA karesi izleme enine kutu ortalamasıyla küçülür (parlaklık (2R + 5G + B) / 8).
    func testGrayFromRGBA() {
        var bytes = [UInt8](repeating: 255, count: 4 * 4 * 4)
        bytes[0] = 0; bytes[1] = 0; bytes[2] = 0
        bytes[4 * 4 * 4 - 4] = 80; bytes[4 * 4 * 4 - 3] = 40; bytes[4 * 4 * 4 - 2] = 0
        let gray = ScreenAnchor.Gray.fromRGBA(bytes, width: 4, height: 4, targetWidth: 2)
        XCTAssertEqual(gray.width, 2)
        XCTAssertEqual(gray.height, 2)
        XCTAssertEqual(gray.pixels, [191, 255, 255, 203])
        XCTAssertEqual(ScreenAnchor.Gray.fromRGBA(bytes, width: 4, height: 4, bgr: true, targetWidth: 2).pixels, [191, 255, 255, 200])
    }
}
