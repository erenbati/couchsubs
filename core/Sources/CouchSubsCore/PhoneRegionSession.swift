// SPDX-License-Identifier: AGPL-3.0-only

import CoreGraphics
import Foundation

/// Tek telefon açılışının son karesi, okunmuş balonları ve birebir çevirileri. Ana altyazı ve
/// elle seçilen bölgeler kendi saatlerinde kalır. Telefon kapanınca bu oturum tekrar kullanılmaz.
@MainActor
final class PhoneRegionSession {
    private struct Capture: Sendable {
        let frame: CGImage
        let pose: GamePhoneGeometry.Pose
        /// Karenin geldiği an (ms): çapanın o karedeki yeri bununla bulunur.
        var time = 0
        var region: CropRegion { pose.bounds }

        func isPresent() -> Bool {
            guard let found = GamePhoneGeometry.locate(frame) else { return false }
            return region.isClose(to: found.bounds, tolerance: 0.035)
        }
    }

    private struct Bubble: Sendable {
        var group: ScreenTranslation.Group
        let style: PhoneTextStyle
    }

    private struct Page: Sendable {
        let region: CropRegion
        let signature: [UInt8]
        let pixels: GamePhonePage
        let bubbles: [Bubble]
        /// Telefona yapışık çeviride okuma karesindeki çapa (kuşak ve yer); balon kutuları bu kuşağın başvuru
        /// koordinatındadır. Çapasızsa nil.
        var anchor: AnchorPose? = nil
        /// Balonların koordinatında telefonun bölgesi (çapasızsa `region`).
        var layout: CropRegion? = nil
        var layoutRegion: CropRegion { layout ?? region }
    }

    private let reader: TextReader
    private let translator: TextTranslator
    private let server: RegionSending
    private var latest: Capture?
    private var lastPass: Int?
    private var task: Task<Void, Never>?
    private var page: Page?
    private var rendered: [ScreenTranslation.Item] = []
    private var translations: [String: String] = [:]
    private var keys: [String] = []
    private var nextBubble = 0
    private var anchors: [(prefix: String, x: Double, y: Double)] = []
    private var needsWork = false
    private var emptyOnce = false
    /// Soluk satır kurtarmasının hafızası (`GamePhoneReader.readMessages`).
    private let retry = GamePhoneRetry()
    /// Son tam yayımlanan okuma: tek turluk OCR atlamasını gerçek değişiklikten ayırmak için.
    private var shownPage: Page?
    /// Bir önceki taze okuma (bekletme ya da ıska `page`'i silse de kalır): kaydırmayı ayırt etmek için.
    private var lastRead: Page?
    /// Bu turdaki okuma bir kaydırma (`PhoneSteady.scrolled`): bekletme ve konum sabitleme atlanır, yeni balonların
    /// hepsi tek istekte çevrilir.
    private var scrolling = false
    /// Bu okuma kaç turdur bekletiliyor (en çok `PhoneSteady.holdTurns`); sonra okuma her durumda ilerler.
    private var holds = 0
    /// Telefonun art arda bulunamadığı tur sayısı (`missed`).
    private var absences = 0
    /// Telefonun boyu (bölgenin yüksekliği): gerçek yakınlaşmada balonların görünüşü hemen yenilenir.
    private var scale = 0.0
    /// Kare boyu (piksel): yarım piksellik kutu oynaması yeniden gönderilmez.
    private var frameSize = (width: 1920, height: 1080)

    /// "GTA 6 Telefon Mesajları" ayarı: Yanda Panel (mesajlar telefonun yanındaki sohbet panelinde, `ScreenPhoneCard.layout`)
    /// ya da Balonların Üstünde; panelin yazı çarpanı altyazı boyutundan. Her gönderide yeniden okunur.
    var panel: () -> PhonePanelOptions = { PhonePanelOptions() }
    /// Son gönderinin ayarı: ayar değişince aynı mesajlar yeni düzende yeniden gönderilir.
    private var sentOptions: PhonePanelOptions?
    /// Son gönderilen düzen ve Yanda Panel'in dayandığı telefon yeri (`PhoneSteady.steadyPose`, `samePicture`).
    private var sentShown: [ScreenTranslation.Item] = []
    /// Yanda Panel'in kilitli telefon yeri ve yazı boyu (#1152): el titremesiyle değişmez.
    private var steady = PhonePanelSteady()
    /// Boş okumanın art arda kaç turdur sürdüğü: `PhoneSteady.missTurns` tur (~1,35 sn) sürmeden ekran silinmez.
    private var empties = 0
    /// "Telefonu Türkçe çiz" (deneysel, yalnız Mac; `PhoneAnchorSession`, `PhoneTwin`). Verilirse okuma çapayı kurar;
    /// balonlar her zaman kendi yerinde ve çapanın başvuru koordinatında gönderilir, çizim her karede çapanın
    /// dönüşümüyle telefonun üstüne taşınır, OCR yalnız telefonun yazısı değişince çalışır. Çapa kaybolunca sonraki tur
    /// mutlaka okur (çapa yeniden kurulur). nil: eski davranış ("GTA 6 Telefon Mesajları" ayarı).
    var anchor: PhoneAnchorSession?
    /// Gönderilen balonların çapası (kuşak ve başvuru dörtgeni).
    private var sentAnchor: AnchorPose?
    /// Son okumanın çapa kuşağı; değişince ekrandaki düzen baştan kurulur (koordinat değişti).
    private var layoutKey: Int?
    private var bubblesAnchored: Bool { anchor != nil }
    /// Altyazı günlüğü: mesaj çevrilmediğinde ya da bekletildiğinde nedeni (`DropLog`; Windows ve Android ile aynı).
    var onLog: ((String) -> Void)?
    private let drops = DropLog()

    init(reader: TextReader, translator: TextTranslator, server: RegionSending) {
        self.reader = reader
        self.translator = translator
        self.server = server
    }

    func observe(_ frame: CGImage, pose: GamePhoneGeometry.Pose, at time: Int = SubtitleStabilizer.uptimeMs()) {
        latest = Capture(frame: frame, pose: pose, time: time)
    }

    /// Türkçe çizimde balonlar her zaman kendi yerinde (panel yok).
    private var options: PhonePanelOptions {
        var options = panel()
        if anchor != nil { options.enabled = false }
        return options
    }

    /// Sayfanın telefonu bu karede nerede: çapa aynı kuşakta izleniyorsa sayfanın bölgesi çapanın o karedeki yerine
    /// taşınır (telefon kıpırdasa da aynı yazı aynı yerde karşılaştırılır, OCR yalnız yazı değişince çalışır).
    private func followed(_ page: Page, _ capture: Capture) -> CropRegion? {
        guard let anchor, page.layout != nil, let placed = page.anchor, let now = anchor.pose(at: capture.time),
              now.generation == placed.generation else { return nil }
        return now.fromReference(page.layoutRegion)
    }

    /// Çapa varken sayfa eski kuşaktan (ya da çapa kayboldu): yeniden okunmalı ki çapa yeniden kurulsun.
    private func anchorStale(_ page: Page) -> Bool {
        guard let anchor else { return false }
        guard let placed = page.anchor, let now = anchor.pose else { return true }
        return now.generation != placed.generation
    }

    func beginIfDue(_ time: Int) -> Bool {
        guard latest != nil, lastPass.map({ time - $0 >= 450 }) ?? true else { return false }
        lastPass = time
        return true
    }

    func close() {
        latest = nil
        shownPage = nil
        lastRead = nil
        scrolling = false
        absences = 0
        task?.cancel()
        publish([])
        anchor?.reset()
        sentAnchor = nil
        layoutKey = nil
    }

    func visit(packLookup: ((String) -> PackMatch?)?, skipsTurkish: Bool, english: Bool) async {
        guard latest != nil else { return }
        let work = Task {
            await update(packLookup: packLookup, skipsTurkish: skipsTurkish, english: english)
        }
        task = work
        await work.value
        task = nil
    }

    private func read(_ capture: Capture, signature: [UInt8]) async throws -> Page {
        let reader = self.reader, retry = self.retry, anchor = self.anchor, anchored = bubblesAnchored
        return try await ReadQueue.shared.run(priority: .background, detail: ReadQueue.detail("telefon", capture.frame)) {
            let region = capture.region
            let reading = GamePhoneText.forTranslation(try GamePhoneReader.read(capture.frame, region: region,
                                                                                pose: capture.pose, reader: reader, retry: retry))
            let crop = RegionCropper.crop(capture.frame, to: region)
            let place = TextBox(left: region.left, top: region.top, right: region.right, bottom: region.bottom)
            // Yapışık çeviri: çapa yoksa bu kareyle kurulur (telefonun bu karede bulunan yeriyle; izleyicinin yeri 330 ms
            // geriden gelebilir), varsa bu karenin dönüşümü alınır. Balonlar başvuru koordinatına çevrilir.
            let placement: AnchorPose? = anchor.flatMap { anchor in
                let exact = GamePhoneGeometry.locate(capture.frame).map(\.bounds)
                    .flatMap { $0.isClose(to: region, tolerance: 0.035) ? $0 : nil } ?? region
                return anchor.place(capture.frame, region: exact, at: capture.time)
            }
            let bubbles = ScreenTranslation.withImages(GamePhoneText.groups(reading), from: crop).map { group in
                let style = GamePhonePalette.sample(crop, box: group.box)
                var placed = group
                placed.box = group.box.placed(in: place)
                placed.lineHeight *= region.bottom - region.top
                if anchored, let placement {
                    placed.box = placement.toReference(placed.box)
                    placed.lineHeight /= max(0.25, placement.scale)
                }
                return Bubble(group: placed, style: style)
            }
            return Page(region: region, signature: signature,
                        pixels: GamePhonePage(frame: capture.frame, region: region, reading: reading), bubbles: bubbles,
                        anchor: placement, layout: placement?.toReference(region))
        }
    }

    private func update(packLookup: ((String) -> PackMatch?)?, skipsTurkish: Bool, english: Bool) async {
        scrolling = false
        guard let start = latest, start.isPresent() else { missed(); return }
        absences = 0
        frameSize = (start.frame.width, start.frame.height)
        let signature = RegionCropper.signature(of: RegionCropper.crop(start.frame, to: start.region))
        let changed = page.map { page in
            // Yapışık çeviride telefonun yeri çapadan gelir: sayfa çapayla taşınıp karşılaştırılır, telefon yalnız
            // kıpırdadı diye yeniden okunmaz.
            if anchorStale(page) { return true }
            if let follow = followed(page, start) {
                let moved = RegionCropper.signature(of: RegionCropper.crop(start.frame, to: follow))
                return ReadScheduler.changed(page.signature, moved, threshold: ReadScheduler.defaultChangeThreshold)
                    || page.pixels.changed(start.frame, region: follow)
            }
            return !page.region.isClose(to: start.region, tolerance: 0.01)
                || ReadScheduler.changed(page.signature, signature, threshold: ReadScheduler.defaultChangeThreshold)
                || page.pixels.changed(start.frame, region: start.region)
        } ?? true
        var fresh = false
        if changed || emptyOnce {
            do { page = try await read(start, signature: signature) }
            catch { page = nil; note("PhoneSession", "okunamadı (\(error.localizedDescription))", ""); return }
            fresh = true
            // Çapa yeniden kuruldu: önceki kuşağın başvuru koordinatındaki düzen ve karşılaştırmalar geçersiz.
            if let read = page, anchor != nil, let generation = read.anchor?.generation, layoutKey != generation {
                layoutKey = generation
                sentAnchor = read.anchor
                rendered = []
                sentShown = []
                shownPage = nil
                lastRead = nil
                steady.reset()
            }
            if let read = page {
                scrolling = lastRead.map { Self.scrolled($0, read) } ?? false
                lastRead = read
                if scrolling { note("PhoneSteady", "kaydırma algılandı, bekletme ve konum sabitleme atlandı", Self.text(read)) }
            }
        } else if !needsWork && !emptyOnce {
            // "GTA 6 Telefon Mesajları" ayarı değişti: aynı sayfa yeni düzende hemen gösterilir.
            if sentOptions != options, let current = page, !rendered.isEmpty {
                publish(items(current, translations: availableTranslations(current.bubbles.map(\.group), packLookup: packLookup,
                                                                          skipsTurkish: skipsTurkish)))
            }
            return
        }
        guard !Task.isCancelled, var current = page, var verified = latest else { return }
        // Okuma sürerken farklı bir sayfa gelmişse eski sayfadan yeni çeviri isteği çıkarma.
        if start.frame !== verified.frame, !matches(current, verified) {
            guard let fresh = await reread(verified) else { missed(); return }
            current = fresh
        }
        guard latest != nil, !Task.isCancelled else { return }
        // Yerinde duran iki komşu arasından düşen balon ya da uzun mesajdaki yan yana birkaç bozuk harf tek okumada
        // ekrandan silinmesin, yeniden çevrilmesin: okuma bir tur bekletilir, sonraki tur mutlaka yeniden okur. Aynı
        // görünen gerçek değişiklik o turda ilerler (Windows ile aynı).
        if fresh, !scrolling, holds < PhoneSteady.holdTurns, let shown = shownPage, !rendered.isEmpty,
           Self.missingInteriorBubble(shown, current)
            || (Self.sameLayout(shown, current, frameSize) && GamePhoneText.hasAdjacentOcrEdits(Self.text(shown), Self.text(current))) {
            if holds == 0 {
                let why = Self.missingInteriorBubble(shown, current) ? "balon düştü" : "harf oynaması"
                note("PhoneSteady", "okuma \(PhoneSteady.holdTurns) tura dek bekletildi (\(why))", Self.text(current))
            }
            holds += 1
            page = nil
            return
        }
        holds = 0
        if current.bubbles.isEmpty {
            // Boş okuma aynı karede bir kez daha okunur: ilk okumada kaçan mesaj gizlenmesin. Ekranda çeviri varsa
            // `PhoneSteady.missTurns` tur boş kalmadan silinmez: telefonun ekranı kısa süre okunamayınca (kare geçişi,
            // bulanıklık) panel kaybolup geri geliyordu (X, 22 Kas).
            empties += 1
            if empties >= (rendered.isEmpty ? 2 : PhoneSteady.missTurns) {
                if !rendered.isEmpty {
                    note("PhoneSteady", "\(PhoneSteady.missTurns) tur boş okundu, çeviri silindi",
                         rendered.map(\.source).joined(separator: " "))
                }
                publish([])
                shownPage = nil
                emptyOnce = false
                empties = 0
            } else { emptyOnce = true }
            needsWork = false
            return
        }
        emptyOnce = false
        empties = 0
        let groups = current.bubbles.map(\.group)
        let paragraphs = groups.flatMap(\.paragraphs)
        var available = availableTranslations(groups, packLookup: packLookup, skipsTurkish: skipsTurkish)
        // Önce yalnız güncel sayfayla eşleşen balonlar kalır. Örneğin yeni WhatUp yanıtı ağdayken
        // önceki yanıtın üstü kendi özgün yazısıyla görünür, bitmiş komşu balonlar okunabilir.
        publish(items(current, translations: available))
        var missing = paragraphs.filter { available[$0] == nil }
        guard !missing.isEmpty else {
            if fresh, let shown = shownPage, Self.text(shown) != Self.text(current) {
                note("PhoneSession", "mesajlar değişti, hepsinin çevirisi hazır sayıldı, motora gitmedi", Self.text(current))
            }
            needsWork = false
            shownPage = current
            return
        }
        // Kaydırmada görünen yeni balonların hepsi tek istekte çevrilir (ücretsiz motorda da): turda tek balon, kaydırılan
        // sohbetin çevirisini turlarca geciktiriyordu (#1170).
        if !translator.translatesTogether, !scrolling {
            followPage(current)
            for offset in groups.indices {
                let index = (nextBubble + offset) % groups.count
                let lead = groups[index].paragraphs.filter { available[$0] == nil }
                if lead.contains(where: GamePhoneText.isMessagePreview) {
                    missing = lead
                    nextBubble = (index + 1) % groups.count
                    break
                }
            }
        }
        var unique: Set<String> = []
        missing = missing.filter { unique.insert($0).inserted }
        let inputs = missing.map {
            let text = IconText.protect($0).text
            return english ? GamePhoneText.englishModelInput(text) : text
        }
        do {
            let result = try await translator.translateAll(inputs)
            guard !Task.isCancelled, latest != nil else { return }
            guard result.count == inputs.count else {
                needsWork = true
                note("PhoneSession", "çevrilemedi (motor \(result.count)/\(inputs.count) yanıt)", missing.joined(separator: " "))
                return
            }
            for (source, translated) in zip(missing, result) {
                guard !translated.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    note("PhoneSession", "motor boş çeviri döndü, gösterilmedi", source)
                    continue
                }
                remember(source, translated)
                available[source] = translated
            }
        } catch {
            needsWork = true
            note("PhoneSession", "çevrilemedi (\(error.localizedDescription))", missing.joined(separator: " "))
            return
        }

        guard let latest else { return }
        if latest.frame !== verified.frame, !matches(current, latest) {
            verified = latest
            guard let fresh = await reread(verified) else { missed(); return }
            current = fresh
            available = availableTranslations(current.bubbles.map(\.group), packLookup: packLookup, skipsTurkish: skipsTurkish)
        }
        guard !Task.isCancelled, self.latest != nil else { return }
        publish(items(current, translations: available))
        needsWork = current.bubbles.contains { $0.group.paragraphs.contains { available[$0] == nil } }
        shownPage = needsWork ? nil : current
    }

    /// Mesajın düşürülme ya da bekletilme nedeni (`DropLog`: aynı neden + metin yinelenmez, dakikada sınırlı).
    private func note(_ component: String, _ reason: String, _ text: String) {
        drops.note(component, reason, IconText.plain(text), log: onLog)
    }

    /// İki okuma arasında sohbet kaydırıldı mı (`PhoneSteady.scrolled`; üstler telefon bölgesine oranlı).
    private static func scrolled(_ previous: Page, _ current: Page) -> Bool {
        func tops(_ page: Page) -> [(text: String, top: Double)] {
            let height = max(1e-6, page.region.bottom - page.region.top)
            return page.bubbles.map { ($0.group.paragraphs.joined(separator: "\n"), ($0.group.box.top - page.region.top) / height) }
        }
        let heights = current.bubbles.map(\.group.lineHeight).sorted()
        guard !heights.isEmpty else { return false }
        let line = heights[heights.count / 2] / max(1e-6, current.region.bottom - current.region.top)
        return PhoneSteady.scrolled(previous: tops(previous), current: tops(current), lineHeight: line)
    }

    private static func text(_ page: Page) -> String {
        page.bubbles.flatMap(\.group.paragraphs).joined(separator: "\n")
    }

    /// Yalnız tek iç balon eksilmiş: kalanların yazısı ve kutuları aynı sırada, aynı yerde. Kaydırma, yeni yazı ya da
    /// sayfanın kapanması bu denetime takılmaz.
    nonisolated static func missingInteriorBubble(_ shownBubbles: [(paragraphs: [String], box: TextBox)],
                                                  _ current: [(paragraphs: [String], box: TextBox)]) -> Bool {
        guard current.count >= 2, shownBubbles.count == current.count + 1 else { return false }
        var missing = false
        for (index, bubble) in current.enumerated() {
            var prior = shownBubbles[missing ? index + 1 : index]
            if prior.paragraphs != bubble.paragraphs {
                guard !missing, index > 0 else { return false }
                missing = true
                prior = shownBubbles[index + 1]
                guard prior.paragraphs == bubble.paragraphs else { return false }
            }
            let a = prior.box, b = bubble.box
            if abs(a.left - b.left) > 0.012 || abs(a.right - b.right) > 0.012 || abs(a.top - b.top) > 0.012
                || abs(a.bottom - b.bottom) > 0.012 { return false }
        }
        // Kalanlar yerinde, yalnız en alttaki balon düştü: yeni mesaj eklenir, silinmez; bu da bir OCR atlamasıdır.
        return true
    }

    private static func missingInteriorBubble(_ shown: Page, _ current: Page) -> Bool {
        missingInteriorBubble(shown.bubbles.map { ($0.group.paragraphs, $0.group.box) },
                              current.bubbles.map { ($0.group.paragraphs, $0.group.box) })
    }

    /// İki okumanın balonları aynı yerde (iki piksel içinde) ve aynı yüzeyde: telefon kıpırdamadı.
    private static func sameLayout(_ a: Page, _ b: Page, _ size: (width: Int, height: Int)) -> Bool {
        guard a.bubbles.count == b.bubbles.count else { return false }
        let dx = 2.0 / Double(size.width), dy = 2.0 / Double(size.height)
        return zip(a.bubbles, b.bubbles).allSatisfy { x, y in
            x.group.paragraphs.count == y.group.paragraphs.count && near(x.group.box, y.group.box, dx, dy)
                && abs(x.group.lineHeight - y.group.lineHeight) <= dy
                && nearColor(x.style.background, y.style.background) && nearColor(x.style.foreground, y.style.foreground)
        }
    }

    nonisolated static func near(_ a: TextBox, _ b: TextBox, _ dx: Double, _ dy: Double) -> Bool {
        abs(a.left - b.left) <= dx && abs(a.right - b.right) <= dx && abs(a.top - b.top) <= dy && abs(a.bottom - b.bottom) <= dy
    }

    /// İki renk her kanalda en çok `tolerance` farklı (palet kanalları sekizli basamaklara yuvarlar; bir basamak fark
    /// sıkıştırma titreşimidir).
    nonisolated static func nearColor(_ a: String, _ b: String, _ tolerance: Int = 8) -> Bool {
        if a == b { return true }
        func channels(_ hex: String) -> [Int]? {
            guard hex.count == 7, hex.hasPrefix("#"), let value = Int(hex.dropFirst(), radix: 16) else { return nil }
            return [(value >> 16) & 0xFF, (value >> 8) & 0xFF, value & 0xFF]
        }
        guard let x = channels(a), let y = channels(b) else { return false }
        return zip(x, y).allSatisfy { abs($0 - $1) <= tolerance }
    }

    /// Aynı balon hareket ederken yeri her gönderide izlenir; küçük OCR kutu farkları yazı boyunu ve satır kırılımını,
    /// renk örneklemesi zemini sürekli değiştirmesin. Esas alınan, son çizilendir (Windows ile aynı). Aynı balon
    /// (`PhoneSteady.match`: aynı çeviri, OCR'la biraz farklı okunsa da aynı mesaj) ilk okunuşunu korur: yazının bir harfi
    /// oynadı diye gönderi yenilenmez.
    nonisolated static func stableBlocks(_ items: [ScreenTranslation.Item], previous: [ScreenTranslation.Item]) -> [ScreenTranslation.Item] {
        items.map { item in
            guard let match = PhoneSteady.match(item, in: previous) else { return item }
            var stable = item
            stable.source = match.source
            // Balonun tarafı (gelen/giden/not) da kimliğiyle kalır: hiza ya da renk okuması bir piksel oynadı diye balon
            // panelde sola sağa atlamaz.
            if let role = match.phone?.role, stable.phone != nil { stable.phone?.role = role }
            let width = item.box.right - item.box.left, height = item.box.bottom - item.box.top
            let oldWidth = match.box.right - match.box.left, oldHeight = match.box.bottom - match.box.top
            if oldWidth > 0, abs(width - oldWidth) <= oldWidth * 0.05 { stable.box.right = min(1, item.box.left + oldWidth) }
            if oldHeight > 0, abs(height - oldHeight) <= oldHeight * 0.10 { stable.box.bottom = min(1, item.box.top + oldHeight) }
            if abs(item.lineHeight - match.lineHeight) <= match.lineHeight * 0.15 { stable.lineHeight = match.lineHeight }
            if let style = item.style, let before = match.style {
                // Ön ve arka renk ayrı ayrı: seçimin gerçek yazı/zemin rengi değişimi korunur.
                // Yazı rengi zeminin aynı yanında kaldıysa (ikisi de zeminden koyu ya da ikisi de açık) eskisi kalır: yazı
                // örneği balonun kenar pikselinden bir koyu, bir gri okunuyor, TV'de yazı rengi titriyordu. Seçimde yazı
                // zeminin öbür yanına geçer (siyahtan beyaza): o değişim izlenir.
                let ink = nearColor(style.foreground, before.foreground, 16)
                    || PhoneSteady.sameInk(style.foreground, before.foreground, on: style.background)
                var kept = PhoneTextStyle(background: nearColor(style.background, before.background, 16) ? before.background : style.background,
                                          foreground: ink ? before.foreground : style.foreground)
                // İki okunabilir paletin karışımı kontrastı düşürebilir: o durumda güncel çift kullanılır.
                if kept != before, kept != style, TextStyleSampler.contrast(kept.background, kept.foreground) < 4.5 { kept = style }
                stable.style = kept
            }
            return stable
        }
    }

    private func matches(_ page: Page, _ capture: Capture) -> Bool {
        if anchor != nil, let follow = followed(page, capture) {
            return capture.isPresent() && !page.pixels.changed(capture.frame, region: follow)
        }
        return capture.isPresent() && page.region.isClose(to: capture.region, tolerance: 0.01)
            && !page.pixels.changed(capture.frame, region: capture.region)
    }

    private func reread(_ capture: Capture) async -> Page? {
        guard capture.isPresent(), !Task.isCancelled else { return nil }
        let signature = RegionCropper.signature(of: RegionCropper.crop(capture.frame, to: capture.region))
        guard let fresh = try? await read(capture, signature: signature), let last = latest, !Task.isCancelled,
              last.frame === capture.frame || matches(fresh, last) else { return nil }
        page = fresh
        return fresh
    }

    /// Telefon bu turda bulunamadı ya da okuma doğrulanamadı. Çeviriler hemen silinmez: tek karelik ıska çevirileri
    /// kaldırıp geri getiriyor, ekranda gidip geliyordu. Art arda `PhoneSteady.missTurns` turdan sonra silinir
    /// (telefon gerçekten kapanınca izleyici oturumu zaten kapatır).
    ///
    /// Ekran kalsa da okunan sayfa bırakılır: sonraki tur mutlaka yeniden okur. Eskiden sayfa kalıyordu; çeviri bu turda
    /// geldiyse ve telefon aynı görünüşe döndüyse sayfa "değişmedi" sayılıyor, hazır çeviri hiç gösterilmiyordu (GitHub
    /// #822, X: "çeviri ya hiç gelmiyor ya da geç geliyor"; Windows `Signature = null` ile zaten yeniden okuyordu).
    private func missed() {
        absences += 1
        if absences >= PhoneSteady.missTurns { clearMissing() } else { page = nil }
    }

    private func clearMissing() {
        absences = 0
        page = nil
        shownPage = nil
        emptyOnce = false
        empties = 0
        needsWork = false
        publish([])
    }

    private func remember(_ source: String, _ translation: String) {
        if translations[source] == nil {
            if keys.count >= 2 * ScreenTranslation.maxGroups { translations[keys.removeFirst()] = nil }
            keys.append(source)
        }
        translations[source] = translation
    }

    /// Paketten, hafızadan ya da zaten Türkçe olduğu için hazır çeviriler. Kişinin adı (sohbet başlığı) çevrilmez: "Rose"
    /// "Gül" olmasın; panelin başlığında aslıyla görünür.
    private func availableTranslations(_ groups: [ScreenTranslation.Group], packLookup: ((String) -> PackMatch?)?,
                                       skipsTurkish: Bool) -> [String: String] {
        var result: [String: String] = [:]
        for group in groups {
            for text in group.paragraphs {
                if group.phone?.role.keepsText == true {
                    result[text] = text
                    continue
                }
                let known = packLookup?(IconText.plain(text))?.text ?? PhoneSteady.translation(of: text, in: translations)
                result[text] = known ?? ((skipsTurkish && TurkishText.isSure(text)) ? text : nil)
            }
        }
        return result
    }

    /// Çevirisi hazır balonlar. Panelde çevirisi aslıyla aynı mesajlar ("ok", ad) da görünür (sohbet eksik kalmasın);
    /// balonların üstünde ise atılır, özgün yazı görünür kalır.
    private func items(_ page: Page, translations: [String: String]) -> [ScreenTranslation.Item] {
        let keepUnchanged = options.enabled
        return page.bubbles.compactMap { bubble in
            let group = bubble.group
            let result = group.paragraphs.compactMap { GamePhoneText.keepIdentifiers($0, translation: translations[$0]) }
            guard result.count == group.paragraphs.count,
                  var item = ScreenTranslation.item(group, group.paragraphs.map(IconText.protect), result,
                                                    keepUnchanged: keepUnchanged) else { return nil }
            item.style = bubble.style
            return item
        }
    }

    private func publish(_ fresh: [ScreenTranslation.Item]) {
        var items = fresh
        let now = lastPass ?? 0
        if let region = latest?.region {
            let height = region.bottom - region.top
            // Telefon gerçekten yakınlaşıp uzaklaşınca balonların yerindeki görünüşü hemen yenilenir (Balonların Üstünde).
            // Yapışık çeviride balonlar başvuru koordinatındadır; yakınlaşmayı çapanın dönüşümü taşır.
            if sentAnchor == nil, abs(height - scale) > scale * 0.03 {
                scale = height
            } else if !rendered.isEmpty, scrolling {
                // Kaydırmada balonlar gerçekten yer değiştirdi: eski yerlerinde tutulmaz (`steadyPositions` atlanır);
                // aynı balonun boyu, satır yüksekliği ve rengi korunur (Windows ve Android ile aynı).
                items = Self.stableBlocks(items, previous: rendered)
            } else if !rendered.isEmpty {
                items = PhoneSteady.steadyPositions(Self.stableBlocks(items, previous: rendered), previous: rendered,
                                                    aspect: Double(frameSize.width) / Double(max(1, frameSize.height)))
            }
        }
        // Yanda Panel'in dayandığı telefon yeri ve yazı boyu ise el titremesiyle değişmez (`PhonePanelSteady`): yalnız
        // belirgin ve kalıcı yakınlaşma/kaymada yenilenir. Ekran silinince (telefon kayboldu) sonraki gönderi baştan ölçer.
        if fresh.isEmpty { steady.reset() }
        let placed = fresh.isEmpty ? nil : latest.map { steady.steadyPose($0.pose, now: now) }
        let options = self.options
        let sameOptions = sentOptions == options
        guard rendered != items || (!sameOptions && !items.isEmpty) else { return }
        // Aynı yazı bir iki piksel oynadıysa (OCR kutusu, yüzey örneği) yeniden gönderilmez; gerçek hareket birikince gider.
        let dx = 2.0 / Double(frameSize.width), dy = 2.0 / Double(frameSize.height)
        if sameOptions, rendered.count == items.count, !items.isEmpty, zip(rendered, items).allSatisfy({ a, b in
            a.source == b.source && a.translation == b.translation && Self.near(a.box, b.box, dx, dy)
                && abs(a.lineHeight - b.lineHeight) <= dy && Self.sameSurface(a.style, b.style)
        }) { return }
        rendered = items
        sentOptions = options
        // Panel telefonun el titremesiyle kaymaz, yazı boyu değişmez (`PhonePanelSteady`); TV'de aynı görünen gönderi
        // yinelenmez.
        let line = steady.steadyLine(ScreenPhoneCard.measuredLine(items), now: now)
        let shown = Self.arranged(items, pose: placed?.pose, frameSize: frameSize, options: options, line: line)
        if sameOptions, PhoneSteady.samePicture(shown, sentShown) {
            // Çeviriler aynı ama özgün mesajlar değişti: yeni mesaj TV'ye gitmedi (yalnız bu durum günlüğe).
            let sources = shown.map(\.source)
            if sources != sentShown.map(\.source) {
                note("PhoneSteady", "samePicture: görüntü aynı sayıldı, gönderilmedi", sources.joined(separator: " "))
            }
            return
        }
        sentShown = shown
        let boxes = shown.map(\.box)
        let box = boxes.dropFirst().reduce(boxes.first) { $0?.union($1) }
        let heights = shown.map(\.lineHeight).sorted()
        server.sendRegion(id: "game-phone", text: shown.filter { !ScreenPhoneCard.isBackdrop($0) }.map(\.translation)
                            .joined(separator: "\n"), box: box,
                          lineHeight: heights.isEmpty ? nil : heights[heights.count / 2], icons: nil,
                          blocks: shown.isEmpty ? nil : shown, anchor: shown.isEmpty ? nil : sentAnchor)
    }

    /// Gönderilecek düzen: Yanda Panel'de telefonun mesajları yanındaki sohbet panelinde (`ScreenPhoneCard.layout`; ana
    /// ekran yazıları yerinde kalır), Balonların Üstünde'de her çeviri kendi balonunun yerinde (çevirisi aslıyla aynı
    /// olanlar atılır). Telefonun yeri bilinmiyorsa balonlar yerinde kalır.
    nonisolated static func arranged(_ items: [ScreenTranslation.Item], pose: GamePhoneGeometry.Pose?,
                                     frameSize: (width: Int, height: Int), options: PhonePanelOptions,
                                     line: Double? = nil) -> [ScreenTranslation.Item] {
        guard options.enabled, let pose, !items.isEmpty else { return items.filter { !$0.unchanged } }
        let handset = ScreenPhoneCard.Handset(pose: pose, aspect: Double(frameSize.width) / Double(max(1, frameSize.height)))
        return ScreenPhoneCard.layout(items, handset: handset, textScale: options.textScale, line: line).filter { !$0.unchanged }
    }

    private static func sameSurface(_ a: PhoneTextStyle?, _ b: PhoneTextStyle?) -> Bool {
        guard let a, let b else { return a == b }
        return nearColor(a.background, b.background) && nearColor(a.foreground, b.foreground)
    }

    private func followPage(_ page: Page) {
        let w = page.region.right - page.region.left, h = page.region.bottom - page.region.top
        let current: [(prefix: String, x: Double, y: Double)] = page.bubbles.compactMap { bubble in
            guard let first = bubble.group.paragraphs.first, GamePhoneText.isMessagePreview(first) else { return nil }
            return (TextMatch.normalize(first).split(separator: " ").prefix(3).joined(separator: " "),
                    (bubble.group.box.left - page.region.left) / w, (bubble.group.box.top - page.region.top) / h)
        }
        if !current.isEmpty {
            if !current.contains(where: { b in anchors.contains { a in
                a.prefix == b.prefix && abs(a.x - b.x) <= 0.10 && abs(a.y - b.y) <= 0.08
            } }) { nextBubble = 0 }
            anchors = current
        }
    }
}
