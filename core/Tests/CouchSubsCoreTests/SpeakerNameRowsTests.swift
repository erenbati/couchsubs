// SPDX-License-Identifier: AGPL-3.0-only
#if canImport(CoreGraphics)
import CoreGraphics
import XCTest
@testable import CouchSubsCore

private final class FrameReader: TextReader, @unchecked Sendable {
    var frames: [Reading]
    init(_ frames: [Reading]) { self.frames = frames }
    func read(_ image: CGImage) throws -> String { "" }
    func readLines(_ image: CGImage, deep: Bool) throws -> Reading { frames.isEmpty ? .empty : frames.removeFirst() }
}
private final class NameSender: SubtitleSending {
    var sent: [String] = []
    func sendSubtitle(_ text: String, durationMs: Int, box: TextBox?, replaces: Bool) { sent.append(text) }
    func clear() {}
}
private final class NumberingTranslator: TextTranslator {
    var requested: [String] = []
    func translate(_ text: String) async throws -> String {
        requested.append(text)
        return "Çeviri \(requested.count)."
    }
}

/// Kullanıcı bildirimi (X): konuşan adı ("Lucia: …") diyalogların yalnız ~%20'sinde gösteriliyor, kalanında düşüyordu.
/// Yazı tanıma oyunun renkli adını cümleden ayrı satır okuyabiliyor. Ad cümlenin üstünde ayrı satır kalınca, aynı kişi
/// konuşmayı sürdürdükçe değişmeden durduğu için görev/HUD satırı sayılıp atılıyor (ad yalnız konuşan değişince, ilk
/// replikte görünüyordu); aynı satırda ama kutusu kaymış okunan ad ise ayrı blok sayılıp hiç gösterilmiyordu. Android
/// (SpeakerNameRowsTest) ve Windows (SpeakerNameRowsTests) aynı örnekleri kullanır.
@MainActor
final class SpeakerNameRowsTests: XCTestCase {
    private let dialog = [("Lucia", "Could I have another ice water, please?"), ("Lucia", "It is so hot out there today."),
                          ("Lucia", "I think I need to sit down."), ("Jason", "Just be quiet. Donnie's up."),
                          ("Jason", "We gotta go now, come on."), ("Lucia", "Okay, okay.")]

    private var image: CGImage {
        CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
    }

    /// Her replik 17 kare (150 ms arayla ~2,5 sn) ekranda; kutular bütün kareye oranla (gerçek kare gta6-08-jason'ın yerleri).
    private func replay(_ shape: (String, String) -> [TextLine]) async -> [String] {
        var time = 0
        let sender = NameSender()
        let frames = dialog.flatMap { name, body in Array(repeating: Reading(lines: shape(name, body)), count: 17) }
        let pipeline = SubtitlePipeline(reader: FrameReader(frames), translator: NumberingTranslator(), server: sender,
                                        clock: { time })
        for _ in frames.indices {
            await pipeline.process(image, region: CropRegion(top: 0, bottom: 1, left: 0, right: 1))
            await pipeline.waitForTranslations()
            time += 150
        }
        return sender.sent
    }

    private let expected = ["Lucia: Çeviri 1.", "Lucia: Çeviri 2.", "Lucia: Çeviri 3.", "Jason: Çeviri 4.", "Jason: Çeviri 5.",
                            "Lucia: Çeviri 6."]

    func testNameOnItsOwnRowAboveKeepsTheNameOnEveryLine() async {
        let sent = await replay { name, body in
            [TextLine("\(name):", box: TextBox(left: 0.47, top: 0.83, right: 0.53, bottom: 0.865)),
             TextLine(body, box: TextBox(left: 0.33, top: 0.875, right: 0.67, bottom: 0.925))]
        }
        XCTAssertEqual(sent, expected)
    }

    func testNameReadApartOnTheSameRowIsJoined() async {
        let sent = await replay { name, body in
            [TextLine("\(name):", box: TextBox(left: 0.338, top: 0.862, right: 0.397, bottom: 0.905)),
             TextLine(body, box: TextBox(left: 0.47, top: 0.872, right: 0.665, bottom: 0.927))]
        }
        XCTAssertEqual(sent, expected)
    }

    func testInlineNameStillWorks() async {
        let sent = await replay { name, body in [TextLine("\(name): \(body)", box: TextBox(left: 0.335, top: 0.87, right: 0.665, bottom: 0.927))] }
        XCTAssertEqual(sent, expected)
    }

    func testNameOnlyLines() {
        XCTAssertEqual(SpeakerPrefix.nameOnly("Lucia:"), "Lucia")
        XCTAssertEqual(SpeakerPrefix.nameOnly(" JASON : "), "JASON")
        XCTAssertEqual(SpeakerPrefix.nameOnly("CO Wilson："), "CO Wilson")
        XCTAssertEqual(SpeakerPrefix.nameOnly("Dre'Quan:"), "Dre'Quan")
        for line in ["Note:", "Objective:", "Lucia: Wait.", "lucia:", "10:", "Lucia", "Very Long Name Of Four:", ""] {
            XCTAssertNil(SpeakerPrefix.nameOnly(line), line)
        }
        // Büyük harfli ad ve iki noktadan sonra boşluksuz okuma da ad sayılır.
        XCTAssertEqual(SpeakerPrefix.split("LUCIA: COULD I HAVE ANOTHER?"), .init(name: "LUCIA", body: "COULD I HAVE ANOTHER?"))
        XCTAssertEqual(SpeakerPrefix.split("Lucia:Could I have another?"), .init(name: "Lucia", body: "Could I have another?"))
    }

    func testJoiningRowsAttachesTheNameToItsSentence() {
        let above = Reading(lines: [TextLine("Lucia:", box: TextBox(left: 0.45, top: 0.60, right: 0.55, bottom: 0.70)),
                                    TextLine("We don't have a car,", box: TextBox(left: 0.20, top: 0.72, right: 0.80, bottom: 0.82)),
                                    TextLine("food or clothes.", box: TextBox(left: 0.30, top: 0.84, right: 0.70, bottom: 0.94))])
        let joined = above.joiningRows()
        XCTAssertEqual(joined.lines.map(\.text), ["Lucia: We don't have a car,", "food or clothes."])
        // Kutu cümlenin satırıdır (yatayda adı da kapsar).
        XCTAssertEqual(joined.lines[0].box, TextBox(left: 0.20, top: 0.72, right: 0.80, bottom: 0.82))

        // Yerleri bilinmeyen okuma: ad alttaki satıra katılır.
        XCTAssertEqual(Reading(text: "JASON:\nWhat the hell was that?").joiningRows().text, "JASON: What the hell was that?")

        // Ad değil ("Note:"), altında cümle yok, cümle çok uzakta, yatayda başka yerde ya da alttaki zaten adlı: dokunulmaz.
        let untouched = [
            Reading(lines: [TextLine("Note:", box: TextBox(left: 0.45, top: 0.60, right: 0.55, bottom: 0.70)),
                            TextLine("The gate is shut.", box: TextBox(left: 0.30, top: 0.72, right: 0.70, bottom: 0.82))]),
            Reading(lines: [TextLine("Lucia:", box: TextBox(left: 0.45, top: 0.60, right: 0.55, bottom: 0.70)),
                            TextLine("42", box: TextBox(left: 0.45, top: 0.72, right: 0.55, bottom: 0.82))]),
            Reading(lines: [TextLine("Lucia:", box: TextBox(left: 0.45, top: 0.20, right: 0.55, bottom: 0.30)),
                            TextLine("Could I have another?", box: TextBox(left: 0.30, top: 0.72, right: 0.70, bottom: 0.82))]),
            Reading(lines: [TextLine("Lucia:", box: TextBox(left: 0.05, top: 0.60, right: 0.12, bottom: 0.70)),
                            TextLine("Could I have another?", box: TextBox(left: 0.30, top: 0.72, right: 0.70, bottom: 0.82))]),
            Reading(lines: [TextLine("Lucia:", box: TextBox(left: 0.45, top: 0.60, right: 0.55, bottom: 0.70)),
                            TextLine("Jason: Not now.", box: TextBox(left: 0.30, top: 0.72, right: 0.70, bottom: 0.82))]),
        ]
        for reading in untouched { XCTAssertEqual(reading.joiningRows().lines.map(\.text), reading.lines.map(\.text)) }
    }
}
#endif
