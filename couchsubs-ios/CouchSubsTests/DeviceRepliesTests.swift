// SPDX-License-Identifier: AGPL-3.0-only

import XCTest
@testable import CouchSubs

/// TV yanıtları CRLF, LF ya da CR ile gelebilir; Swift'te "\r\n" tek Character olduğundan ayrıca denenir.
final class DeviceRepliesTests: XCTestCase {
    /// #1158: sessiz sürüm denetimi "TV'de CouchSubs yok"u "liste okunamadı"dan ayırır (Android ile aynı kural).
    func testInstalledPresenceSeparatesMissingFromUnknown() {
        XCTAssertEqual(SamsungInstaller.presence(version: "0.9.80", listRead: true, foreign: false), .version("0.9.80"))
        XCTAssertEqual(SamsungInstaller.presence(version: nil, listRead: true, foreign: false), .missing)
        XCTAssertEqual(SamsungInstaller.presence(version: nil, listRead: false, foreign: false), .unknown)
        XCTAssertEqual(SamsungInstaller.presence(version: "1.0", listRead: true, foreign: true), .unknown)
    }

    /// "IP hatası" (#1158): metin menüyü, iki ayarı ve bu cihazın adresini söyler.
    func testHostPcStepsShowThisDevicesAddress() {
        let text = TVText.hostPcSteps("192.168.1.34")
        XCTAssertTrue(text.contains("192.168.1.34"))
        XCTAssertTrue(text.contains("1 2 3 4 5"))
        XCTAssertTrue(text.contains("Host PC IP"))
    }

    func testDuidIsReadFromCrlfLfAndCrReplies() {
        XCTAssertEqual(SamsungInstaller.duid(fromGetduid: "XTCK7KNUEHTUM\r\nXTCK7KNUEHTUM"), "XTCK7KNUEHTUM")
        XCTAssertEqual(SamsungInstaller.duid(fromGetduid: "XTCK7KNUEHTUM\nXTCK7KNUEHTUM\n"), "XTCK7KNUEHTUM")
        XCTAssertEqual(SamsungInstaller.duid(fromGetduid: "XTCK7KNUEHTUM\rXTCK7KNUEHTUM\r"), "XTCK7KNUEHTUM")
        XCTAssertEqual(SamsungInstaller.duid(fromGetduid: "\r\nXTCK7KNUEHTUM\r\n"), "XTCK7KNUEHTUM")
        XCTAssertNil(SamsungInstaller.duid(fromGetduid: ""))
        XCTAssertNil(SamsungInstaller.duid(fromGetduid: "error: closed\r\n"))
    }

    func testPlayStoreIsFoundInCrlfPackageList() {
        XCTAssertTrue(AndroidTvInstaller.hasPlayStore("package:com.google.android.tvlauncher\r\npackage:com.android.vending\r\n"))
        XCTAssertTrue(AndroidTvInstaller.hasPlayStore("package:com.android.vending\n"))
        XCTAssertFalse(AndroidTvInstaller.hasPlayStore("package:com.google.android.tvlauncher\r\n"))
    }

    func testCapabilityAndSummaryReadCrlf() {
        let capability = SdbConnection.parseCapability([0, 0] + Array("secure_protocol:enabled\r\nsdbd_rootperm:disabled\r\n".utf8))
        XCTAssertEqual(capability["secure_protocol"], "enabled")
        XCTAssertEqual(capability["sdbd_rootperm"], "disabled")
        XCTAssertEqual(SamsungDiagnostics.summary("ok\r\ninstall failed\r\nreason: space\r\n"), "install failed | reason: space")
    }
}
