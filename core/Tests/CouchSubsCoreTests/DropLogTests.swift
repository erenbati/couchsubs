// SPDX-License-Identifier: AGPL-3.0-only

import XCTest
@testable import CouchSubsCore

/// Düşen satır günlüğü: biçim, tekrar ve dakikalık sınır (Windows DropLogTests, Android DropLogTest aynı).
final class DropLogTests: XCTestCase {
    func testFormatsComponentReasonAndShortExcerpt() {
        var time = 0
        let drops = DropLog(clock: { time }, sink: { _ in })
        XCTAssertEqual(drops.line("MissionLine", "3 sn dolmadan kalktı", "Go to the marked location on the map"),
                       "düşen satır [MissionLine] 3 sn dolmadan kalktı: \"Go to the marked location on …\"")
        time += 1
        XCTAssertNil(drops.line("MissionLine", "3 sn dolmadan kalktı", "Go to the marked location on the map"))
        XCTAssertNotNil(drops.line("MissionLine", "başka neden", "Go to the marked location on the map"))
        time += DropLog.repeatMs
        XCTAssertNotNil(drops.line("MissionLine", "3 sn dolmadan kalktı", "Go to the marked location on the map"))
    }

    func testCapsLinesPerMinuteAndReportsSuppressed() {
        var time = 0
        var lines: [String] = []
        let drops = DropLog(clock: { time }, sink: { lines.append($0) })
        for index in 0..<(DropLog.perMinute + 5) { drops.note("SettledText", "neden", "satır \(index)") }
        XCTAssertEqual(lines.count, DropLog.perMinute)
        time = 60_000
        drops.note("SettledText", "neden", "yeni satır")
        XCTAssertEqual(lines.last, "düşen satır [SettledText] neden: \"yeni satır\" (+5 satır sınır yüzünden yazılmadı)")
    }

    func testScreenIssue() {
        XCTAssertNil(AIRequest.screenIssue(source: "Open map", translation: "Haritayı aç", limit: 12))
        XCTAssertEqual(AIRequest.screenIssue(source: "Open map", translation: " ", limit: 10), "motor boş çeviri döndü")
        XCTAssertEqual(AIRequest.screenIssue(source: "Open map", translation: "open map", limit: 10),
                       "çeviri aslıyla aynı döndü, İngilizce kaldı")
        XCTAssertNil(AIRequest.screenIssue(source: "42", translation: "42", limit: 4))
        XCTAssertEqual(AIRequest.screenIssue(source: "Open map", translation: "Haritayı şimdi aç", limit: 10),
                       "%115 sınırını aştı (17/10)")
    }
}
