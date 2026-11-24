// SPDX-License-Identifier: AGPL-3.0-only

import AppKit
import Combine
import CouchSubsCore
import SwiftUI

/// "Ekranı yerinde Türkçe çiz" (deneysel, önce Mac; Sinan Bey kararı 24 Kas): GTA 6 telefonunun Türkçe ikizi
/// (`PhoneTwin`) ve çapanın her karedeki yeri (`PhoneAnchorSession`). Çapa saniyede 30 kez değişebilir; AppModel'in
/// kendisini yayımlamasın diye ayrı tutulur. Çapa kaybolunca ya da kuşak değişince ikiz hemen kalkar: yanlış yerde bir an
/// bile durmaz.
@MainActor
final class PhoneAnchorFeed: ObservableObject {
    @Published private(set) var pose: AnchorPose?
    @Published private(set) var twin: PhoneTwin.Layer?
    /// Bağlı çapa; eski çapanın geç gelen olayı yok sayılır.
    weak var current: PhoneAnchorSession?
    private var token = 0
    private var building = false
    private var pending: (() -> Void)?
    private var loggedBuilds = (minute: Int.min, count: 0)

    func reset() {
        current = nil
        pose = nil
        twin = nil
        token += 1
        pending = nil
    }

    func receive(_ change: PhoneAnchorSession.Change, from anchor: PhoneAnchorSession) {
        guard anchor === current else { return }
        switch change {
        case .moved(let next):
            if pose?.generation != next.generation {
                twin = nil
                token += 1
            }
            pose = next
        case .lost:
            pose = nil
            twin = nil
            token += 1
        }
    }

    /// Yazı değişti: ikiz yeniden kurulur (silme ve çizim yalnız burada). `frame`, çapanın `at` anındaki karesidir.
    func rebuild(items: [ScreenTranslation.Item], frame: CGImage?, at ms: Int, anchor: PhoneAnchorSession?) {
        guard let anchor, anchor === current else { return }
        guard !items.isEmpty, let frame, let pose = anchor.pose(at: ms) else {
            twin = nil
            token += 1
            return
        }
        token += 1
        let mine = token
        let job = { [weak self] in
            guard let self else { return }
            self.building = true
            Task.detached(priority: .userInitiated) {
                let started = SubtitleStabilizer.uptimeMs()
                let layer = PhoneTwin.build(frame: frame, pose: pose, items: items)
                let ms = SubtitleStabilizer.uptimeMs() - started
                await MainActor.run {
                    self.building = false
                    if mine == self.token, self.pose?.generation == pose.generation {
                        self.twin = layer
                        self.log(layer, ms: ms)
                    }
                    if let next = self.pending {
                        self.pending = nil
                        next()
                    }
                }
            }
        }
        // Önceki ikiz hâlâ kuruluyorsa yalnız en son yazı kurulur.
        if building { pending = job } else { job() }
    }

    /// Kutu başına zemin kararı (düz/degrade: silindi; desenli: zemin renginde kutu) altyazı günlüğüne, dakikada sınırlı.
    private func log(_ layer: PhoneTwin.Layer?, ms: Int) {
        let minute = SubtitleStabilizer.uptimeMs() / 60_000
        if loggedBuilds.minute != minute { loggedBuilds = (minute, 0) }
        loggedBuilds.count += 1
        guard loggedBuilds.count <= 6, let layer else { return }
        let shown = layer.notes.prefix(8).joined(separator: "; ")
        SubtitleLog.write("telefon Türkçe çizildi (kuşak \(layer.generation), \(layer.notes.count) yazı, \(ms) ms): \(shown)")
    }
}

/// Türkçe ikizi çapanın dönüşümüyle telefonun üstüne yansıtır. Kap oyun karesinin tamamıdır (oyun penceresi ya da yayın
/// penceresi); ikiz kuşağı çapanınkiyle aynı değilse ya da çapa yoksa hiçbir şey çizilmez.
struct PhoneTwinLayer: View {
    @ObservedObject var feed: PhoneAnchorFeed

    var body: some View {
        GeometryReader { proxy in
            if let pose = feed.pose, let twin = feed.twin, twin.generation == pose.generation {
                let w = proxy.size.width, h = proxy.size.height
                let r = twin.reference
                Image(decorative: twin.image, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: (r.right - r.left) * w, height: (r.bottom - r.top) * h)
                    .position(x: (r.left + r.right) / 2 * w, y: (r.top + r.bottom) / 2 * h)
                    .frame(width: w, height: h)
                    .projectionEffect(Self.projection(pose, width: w, height: h))
            }
        }
        .allowsHitTesting(false)
    }

    /// Başvurudan güncel kareye dönüşüm (`AnchorPose.matrix`, kareye oranlı) kabın noktalarında. SwiftUI satır vektörü
    /// kullanır: [x y 1] · T.
    static func projection(_ pose: AnchorPose, width w: CGFloat, height h: CGFloat) -> ProjectionTransform {
        let m = pose.matrix.map { CGFloat($0) }
        guard w > 0, h > 0 else { return ProjectionTransform() }
        var t = ProjectionTransform()
        t.m11 = m[0]
        t.m21 = m[1] * w / h
        t.m31 = m[2] * w
        t.m12 = m[3] * h / w
        t.m22 = m[4]
        t.m32 = m[5] * h
        t.m13 = m[6] / w
        t.m23 = m[7] / h
        t.m33 = m[8]
        return t
    }
}

/// Oyun penceresinin (PS Remote Play, chiaki-ng ya da seçilen OBS/oyun penceresi) tam üstünde, kenarsız, tıklamaları
/// geçiren saydam panel: telefonun Türkçe ikizi orada, telefonun üstünde çizilir. Yakalama yalnız oyun penceresini aldığı
/// için bu panel okunmaz.
@MainActor
final class PhoneTwinOverlayController {
    private weak var model: AppModel?
    private var panel: NSPanel?
    private var timer: Timer?
    private var changes: AnyCancellable?

    func attach(_ model: AppModel) {
        guard self.model == nil else { return }
        self.model = model
        // Pencerenin yeri saniyede 4 kez yoklanır (kullanıcı oyun penceresini taşıyabilir); çapa değişince de.
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }
        changes = model.phoneAnchorFeed.$pose.map { $0 != nil }.removeDuplicates().sink { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.update() } }
        }
    }

    private func update() {
        guard let model, model.phoneAnchor != nil, model.phoneAnchorFeed.pose != nil,
              let id = model.capturedWindow?.windowID, let frame = Self.screenFrame(of: id) else {
            panel?.orderOut(nil)
            return
        }
        let panel = self.panel ?? makePanel(model)
        if panel.frame != frame { panel.setFrame(frame, display: true) }
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    private func makePanel(_ model: AppModel) -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 640, height: 360),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.ignoresMouseEvents = true
        let host = NSHostingView(rootView: PhoneTwinLayer(feed: model.phoneAnchorFeed))
        host.sizingOptions = []
        panel.contentView = host
        self.panel = panel
        return panel
    }

    /// Pencerenin ekrandaki çerçevesi (AppKit koordinatı, sol alt başlangıç); pencere ekranda değilse nil.
    static func screenFrame(of id: CGWindowID) -> NSRect? {
        guard let info = (CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]])?.first,
              (info[kCGWindowIsOnscreen as String] as? Bool) == true,
              let bounds = info[kCGWindowBounds as String] as? NSDictionary,
              let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary),
              let primary = NSScreen.screens.first else { return nil }
        // Core Graphics: ana ekranın sol üstü başlangıç, aşağı doğru artar.
        return NSRect(x: rect.minX, y: primary.frame.maxY - rect.maxY, width: rect.width, height: rect.height)
    }
}
