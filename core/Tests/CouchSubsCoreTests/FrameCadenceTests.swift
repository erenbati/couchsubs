// SPDX-License-Identifier: AGPL-3.0-only

import XCTest
@testable import CouchSubsCore

/// Kare kopyalama sıklığı (oyun takılması, X'te iki kullanıcı): saniyede kopyalanan kare (kare başı iş) ölçülür.
/// Windows: FrameCadenceTests.cs (aynı eşikler ve beklentiler).
final class FrameCadenceTests: XCTestCase {
    /// Saniyede `arrivals` kare gelirken bir saniyede kopyalanan kare.
    private func copiesInOneSecond(_ cadence: FrameCadence, arrivals: Int, jitterMs: Int = 0) -> Int {
        (0..<arrivals).filter { i in
            cadence.admit(now: 10_000 + i * 1000 / arrivals + (i % 2 == 0 ? 0 : -jitterMs))
        }.count
    }

    func testIntervalFollowsCpuLoadAndReadTime() {
        XCTAssertEqual(FrameCadence.interval(cpuLoad: 0, lastReadMs: 0), FrameCadence.baseIntervalMs)
        XCTAssertEqual(FrameCadence.interval(cpuLoad: 0.74, lastReadMs: 0), FrameCadence.baseIntervalMs)
        XCTAssertEqual(FrameCadence.interval(cpuLoad: 0.75, lastReadMs: 0), FrameCadence.busyIntervalMs)
        XCTAssertEqual(FrameCadence.interval(cpuLoad: 0.9, lastReadMs: 0), FrameCadence.fullIntervalMs)
        XCTAssertEqual(FrameCadence.interval(cpuLoad: 0, lastReadMs: 180), 180)
        XCTAssertEqual(FrameCadence.interval(cpuLoad: 0.95, lastReadMs: 180), FrameCadence.fullIntervalMs)
        XCTAssertEqual(FrameCadence.interval(cpuLoad: 0, lastReadMs: 2000), FrameCadence.maxIntervalMs)
    }

    func testCaptureAt60HzCopiesTenFramesPerSecond() {
        XCTAssertEqual(copiesInOneSecond(FrameCadence(), arrivals: 60), FrameCadence.maxFramesPerSecond)
    }

    func testBusyComputerCopiesFewerFrames() {
        let cadence = FrameCadence()
        cadence.reportCpuLoad(0.95)
        XCTAssertEqual(copiesInOneSecond(cadence, arrivals: 60), 4)
        cadence.reportCpuLoad(0.8)
        cadence.reset()
        XCTAssertEqual(copiesInOneSecond(cadence, arrivals: 60), 6)
    }

    func testSlowReadingDoesNotCopyFramesItWouldDrop() {
        let cadence = FrameCadence()
        cadence.reportReadMs(300)
        XCTAssertEqual(copiesInOneSecond(cadence, arrivals: 60), 4)
        cadence.reset()
        cadence.reportReadMs(5000)
        XCTAssertEqual(copiesInOneSecond(cadence, arrivals: 60), 3)
    }

    func testJitteryTenFramesPerSecondAreAllCopied() {
        // ScreenCaptureKit saniyede 10 kareyi birkaç ms erken/geç verir; her ikinci kare atlanmamalı.
        XCTAssertEqual(copiesInOneSecond(FrameCadence(), arrivals: 10, jitterMs: 4), 10)
    }

    func testResetAdmitsNextFrameAtOnceAndClockGoingBackIsAccepted() {
        let cadence = FrameCadence()
        XCTAssertTrue(cadence.admit(now: 1000))
        XCTAssertFalse(cadence.admit(now: 1010))
        XCTAssertTrue(cadence.admit(now: 500))
        cadence.reset()
        XCTAssertTrue(cadence.admit(now: 510))
    }

    func testPreviewRefreshesOncePerSecondInBackground() {
        XCTAssertTrue(PreviewCadence.due(now: 1100, last: 1000, active: true))
        XCTAssertFalse(PreviewCadence.due(now: 1500, last: 1000, active: false))
        XCTAssertTrue(PreviewCadence.due(now: 2000, last: 1000, active: false))
        XCTAssertTrue(PreviewCadence.due(now: 0, last: nil, active: false))
    }

    func testCpuLoadIsMeasuredOncePerSecond() {
        let load = SystemCpuLoad()
        XCTAssertNil(load.sample(now: 0), "ilk ölçüm karşılaştırma tabanıdır")
        XCTAssertNil(load.sample(now: 500))
        // Bir saniye sonra 0–1 arası bir değer (işlemci sayaçları ilerlemediyse nil olabilir).
        if let value = load.sample(now: 1500) { XCTAssertTrue((0...1).contains(value)) }
    }
}
