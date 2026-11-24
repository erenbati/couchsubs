// SPDX-License-Identifier: AGPL-3.0-only

import XCTest
@testable import CouchSubsCore

/// GTA 6 telefonu: kaydırma algısı ve telefon çevirisi kapalıyken gösterilen ipucu (#1202, #1197, #1193, #1170).
final class GamePhoneScrollTests: XCTestCase {
    private let line = 0.04

    /// Sohbet yukarı kaydırıldı: aynı mesajların hepsi aynı yöne, satır yüksekliğinin yarısından fazla kaydı.
    func testAllBubblesMovingTheSameWayIsAScroll() {
        let before = [("Where are you going tonight?", 0.30), ("Meet me at the marina", 0.45), ("Ok", 0.60)]
        let after = [("Meet me at the marina", 0.30), ("Ok", 0.45), ("Bring the car around", 0.60)]
        XCTAssertTrue(PhoneSteady.scrolled(previous: before.map { (text: $0.0, top: $0.1) },
                                           current: after.map { (text: $0.0, top: $0.1) }, lineHeight: line))
        // Aşağı kaydırma da kaydırmadır.
        XCTAssertTrue(PhoneSteady.scrolled(previous: after.map { (text: $0.0, top: $0.1) },
                                           current: before.map { (text: $0.0, top: $0.1) }, lineHeight: line))
    }

    /// OCR kutusunun bir iki piksellik oynaması, yeni mesajın eklenmesi ya da tek balonun ters yöne gitmesi kaydırma değildir.
    func testJitterNewMessagesAndMixedMovesAreNotAScroll() {
        let before = [(text: "Where are you going tonight?", top: 0.30), (text: "Meet me at the marina", top: 0.45)]
        let jitter = [(text: "Where are you going tonight?", top: 0.305), (text: "Meet me at the marina", top: 0.447)]
        XCTAssertFalse(PhoneSteady.scrolled(previous: before, current: jitter, lineHeight: line))
        let appended = before + [(text: "Bring the car around", top: 0.60)]
        XCTAssertFalse(PhoneSteady.scrolled(previous: before, current: appended, lineHeight: line))
        let mixed = [(text: "Where are you going tonight?", top: 0.20), (text: "Meet me at the marina", top: 0.55)]
        XCTAssertFalse(PhoneSteady.scrolled(previous: before, current: mixed, lineHeight: line))
        let unrelated = [(text: "Bring the car around", top: 0.10)]
        XCTAssertFalse(PhoneSteady.scrolled(previous: before, current: unrelated, lineHeight: line))
        XCTAssertFalse(PhoneSteady.scrolled(previous: before, current: before.map { (text: $0.text, top: $0.top - 0.2) }, lineHeight: 0))
    }

    /// OCR'la biraz farklı okunan aynı mesaj da eşleşir; aynı yazılı iki balon birer kez eşlenir.
    func testSlightlyDifferentReadingsAndRepeatedMessagesArePaired() {
        let before = [(text: "Did you hear back from the guy at the marina?", top: 0.30), (text: "Ok", top: 0.50), (text: "Ok", top: 0.60)]
        let after = [(text: "Did you hear back frorn the guy at the rnarina?", top: 0.10), (text: "Ok", top: 0.30), (text: "Ok", top: 0.40)]
        XCTAssertTrue(PhoneSteady.scrolled(previous: before, current: after, lineHeight: line))
    }

    /// Telefon çevirisi kapalıyken GTA 6'da telefon listesine uyan atma (eğik satır, açık zeminde koyu yazı) oturumda bir
    /// kez ipucu verir; telefon açıkken, başka oyunda ya da başka nedenle verilmez.
    func testPhoneHintIsOfferedOncePerSessionOnlyWhenThePhoneIsOff() {
        var hint = GamePhoneHint()
        XCTAssertFalse(hint.observe(reason: "eğik satır (tabela)", readsPhone: true, game: "GTA 6"))
        XCTAssertFalse(hint.observe(reason: "eğik satır (tabela)", readsPhone: false, game: "Red Dead Redemption 2"))
        XCTAssertFalse(hint.observe(reason: "eğik satır (tabela)", readsPhone: false, game: nil))
        XCTAssertFalse(hint.observe(reason: "harfsiz sayı", readsPhone: false, game: "GTA 6"))
        XCTAssertTrue(hint.observe(reason: InkTone.reason, readsPhone: false, game: "Grand Theft Auto VI"))
        XCTAssertFalse(hint.observe(reason: "eğik satır (tabela)", readsPhone: false, game: "GTA 6"))
        hint.reset()
        XCTAssertTrue(hint.observe(reason: "eğik satır (tabela)", readsPhone: false, game: "gta6"))
    }
}
