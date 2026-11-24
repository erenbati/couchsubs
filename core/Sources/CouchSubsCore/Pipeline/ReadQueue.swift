// SPDX-License-Identifier: AGPL-3.0-only

import CoreGraphics
import Foundation

public enum ReadQueueError: Error, Equatable {
    /// Okuma `ms` milisaniyede bitmedi (ya da o kadar sıra bekledi); kare atlandı.
    case timedOut(ms: Int)
    /// Asıl okuyucu takılı ve bağımsız yedek okuyucu yok (ya da o da takıldı); yeni okuma verilmedi (#507, #679).
    case stuck
}

/// Okumanın önceliği: altyazı her zaman öndedir; ek alanlar, ekran yazısı, telefon ve "Ekranı çevir" arkadan gelir.
public enum ReadPriority: Int, Sendable {
    case subtitle = 0
    case background = 1
}

/// Asıl okuyucu (bu süreçteki Vision) takılınca okumayı **bağımsız bir bağlamda** sürdüren yedek (#679).
///
/// Vision'ın metin tanıması süreç genelinde tek kilitle çalışır: bir istek dönmezken (macOS 27'de modelin ANE için
/// derlenmesi 30–90 sn sürer) başka iş parçacığında, yeni `VNRecognizeTextRequest`/`VNImageRequestHandler` ile,
/// hatta "hızlı" düzeyde verilen istek de o bitene kadar bekler. Bu yüzden süreç içinde yeni kuyruk kurmak kurtarmaz;
/// gerçek yedek ayrı bir süreçtir (Mac: `OcrHelperRescuer`).
public protocol ReadRescuer: AnyObject, Sendable {
    /// Yedek bağlamda okur; yedek kuyruğun iş parçacığında, senkron çağrılır.
    func recognize(_ image: CGImage, language: String) throws -> Reading
    /// Yedekteki okuma da süresinde dönmedi: bağlam bırakılır (süreç öldürülür), sonraki okumada yenisi kurulur.
    func abandon()
    /// Asıl okuyucu düzeldi; yedek kapatılabilir.
    func standDown()
}

/// Yazı tanıma (Vision) çağrılarının tek sırası (#385, #507, #679).
///
/// - **Tek okuma**: süreç genelinde aynı anda tek Vision isteği verilir. Aynı anda verilen istekler Vision'ı
///   kilitleyebiliyordu (#385); takılan isteğin yanına yenisini vermek de işe yaramaz, o da aynı kilidi bekler.
/// - **Swift havuzu tutulmaz**: okuma kendi `DispatchQueue`'sunda çalışır, çağıran `await` ile bekler.
/// - **Öncelik**: sırada altyazı okuması varsa önce o verilir; arka plan okumaları (ek alan, ekran yazısı) altyazıyı
///   geciktiriyorsa kendilerini kısar (`backgroundSlowdown`).
/// - **Takılma**: `timeoutMs` içinde dönmeyen okuma `timedOut` ile bırakılır ve asıl okuyucu "takılı" sayılır. Takılıyken
///   yeni Vision isteği verilmez. Yedek (`rescuer`) varsa okumalar ona gider, altyazı sürer; yoksa okuma hemen
///   `stuck` ile döner. Takılan okuma bitince asıl okuyucuya kendiliğinden dönülür, yedek kapatılır. Yedek varken
///   altyazı okuması için sınır `subtitleTimeoutMs`'tir (#822); cihazın son altyazı okumalarının ortanca süresine göre
///   uzar (ortanca × 3, en çok `subtitleTimeoutCapMs`), ısınıp yavaşlayan Mac'te yanlış alarm çıkmasın (#1210).
/// - **Altyazıyı bekleten arka plan okuması takılma değildir** (#1210): altyazı, asıl okuyucuda süren bir arka plan
///   okumasının (telefon, ek alan, ekran yazısı, "Ekranı çevir") arkasında sınır kadar beklerse sıradaki arka plan
///   okumaları düşürülür, altyazı yalnız o tur için yedekten okunur (yedek yoksa sırada öne geçer). Asıl okuyucu takılı
///   sayılmaz, uyarı çıkmaz; arka plan okuması kendi süresinde (`timeoutMs`) bitmezse o zaman takılmadır.
/// - **Hızlı düzey süreli** (#1210): takılma yinelenince (`degradeAfterStalls`) okumalar `fastLevelHoldMs` boyunca hızlı
///   düzeyde verilir, sonra isabetli düzey yeniden denenir. Eskiden oturum boyunca kalıcıydı; çeviriler bozuk geliyor,
///   ancak uygulamayı yeniden açmak düzeltiyordu.
/// - **Yedek de takılırsa** bağlamı bırakılıp yenisi kurulur; art arda `maxRescueFailures` kez olursa yedek, asıl
///   okuyucu düzelene kadar kullanılmaz.
public final class ReadQueue: @unchecked Sendable {
    public static let shared = ReadQueue(degradeAfterStalls: 2, subtitleTimeoutMs: ReadQueue.defaultSubtitleTimeoutMs)
    /// Bütün karenin derin okuması (üç Vision isteği) yavaş Mac'te birkaç saniye sürer; `FrameGate`'in 15 saniyesinden
    /// önce dönmeli ki hat yeniden kurulmadan sonraki kare okunsun.
    public static let defaultTimeoutMs = 10_000
    /// Altyazı okuması (ya da önünde beklediği okuma) bundan uzun sürerse asıl okuyucu takılı sayılır, altyazı yedekten
    /// okunur (GitHub #822). Eskiden altyazı da `defaultTimeoutMs` bekliyordu: asıl okuyucu yavaşladığında her takılmada
    /// 10 sn hiç satır okunmuyordu. Mac'te Sony Remote Play penceresinden okuyan kullanıcının altyazı geçmişinde
    /// çeviriler beta.52'deki 1–4 sn yerine 8–11 sn (ve 19–20 sn) arayla geliyordu: "5-6 cümlede bir çeviri" ve ekranda
    /// uzun kalan çeviri. Altyazı okuması normalde 0,1–0,5 sn sürer (derin okuma 1 sn'yi bulmaz).
    public static let defaultSubtitleTimeoutMs = 3_000
    public static let defaultMaxRescueFailures = 3
    /// Takılma yinelenince okumaların hızlı düzeyde verildiği süre; sonra isabetli düzeye dönülür (#1210).
    public static let defaultFastLevelHoldMs = 120_000
    /// Uyarlanan altyazı sınırı için tutulan son altyazı okuması sayısı ve gereken en az okuma.
    static let subtitleSampleCount = 15
    static let subtitleMinSamples = 5
    /// Uyarlanan altyazı sınırı: son altyazı okumalarının ortanca süresinin bu katı.
    static let subtitleLimitFactor = 3
    /// Altyazı okuması sırada bundan uzun beklediyse arka plan okumaları seyrekleşir.
    public static let subtitleWaitLimitMs = 150

    /// Günlüğe yazılacak olaylar (tanı).
    public enum Event: Sendable, Equatable {
        /// Asıl okuyucudaki okuma dönmedi. `rescued`: okumalar yedeğe geçti.
        case stalled(Stall, rescued: Bool)
        /// Takılan okuma `ms` sonra bitti; asıl okuyucuya dönüldü.
        case recovered(ms: Int)
        /// Yedekteki okuma da dönmedi; yedek bağlam yeniden kurulacak (`failures`: art arda kaçıncı).
        case rescueFailed(Stall, failures: Int)
        /// Okuyucu `stalls` kez takıldı: bir süre (`fastLevelHoldMs`) hızlı düzeyde okunur (Neural Engine yolu bırakıldı).
        case degraded(stalls: Int)
        /// Hızlı düzeyin süresi doldu (`afterMs` sonra): okumalar yeniden isabetli düzeyde verilir.
        case restored(afterMs: Int)
        /// Altyazı, asıl okuyucuda süren arka plan okumasının arkasında sınır kadar bekledi. Takılma sayılmadı:
        /// sıradaki `dropped` arka plan okuması düşürüldü; `rescued`: altyazı bu tur yedekten okundu.
        case backgroundYielded(Stall, dropped: Int, rescued: Bool)
        /// Bırakılan (iPhone) takılı okuma sonunda bitti; `stillStuck`: hâlâ bitmemiş bırakılan okuma sayısı.
        case abandonedFinished(stillStuck: Int)
    }

    /// Dönmeyen okumanın ayrıntısı.
    public struct Stall: Sendable, Equatable {
        /// Okumanın ne olduğu ve karenin boyutu ("altyazı 1728x324 derin").
        public var detail: String
        public var ms: Int
        /// `ProcessInfo.thermalState` ("nominal", "fair", "serious", "critical").
        public var thermal: String
        /// Sürecin bellek ayak izi (MB); ölçülemezse nil.
        public var memoryMB: Int?
        /// Sırada bekleyen okuma sayısı.
        public var pending: Int
        /// O anda süren okuma sayısı (asıl ve yedek).
        public var running: Int
    }

    /// Bir okuma: sonucu ya da süre aşımı, hangisi önce gelirse bir kez teslim edilir.
    private final class Item: @unchecked Sendable {
        let priority: ReadPriority
        let detail: String
        /// Altyazıyı bekletince düşürülebilir (dönemsel arka plan okuması); kullanıcının istediği okuma düşürülmez.
        let droppable: Bool
        /// Altyazıyı bekletti, altyazı yanından geçirildi (takılma sayılmadı).
        var yielded = false
        let submitted = ReadQueue.uptimeMs()
        var started: Int?
        /// Başladığında verilen süre sınırı (ms).
        var limitMs: Int?
        /// Süresi doldu, çağırana haber verildi; iş hâlâ sürüyor olabilir.
        var expired = false
        let work: @Sendable () -> Void
        let fail: @Sendable (Error) -> Void
        init(priority: ReadPriority, detail: String, droppable: Bool,
             work: @escaping @Sendable () -> Void, fail: @escaping @Sendable (Error) -> Void) {
            self.priority = priority
            self.detail = detail
            self.droppable = droppable
            self.work = work
            self.fail = fail
        }
    }

    private final class Lane {
        let queue: DispatchQueue
        var pending: [Item] = []
        var running: Item?
        /// Süren okumanın süresi doldu; bitene kadar bu kuyruğa yeni okuma verilmez.
        var stalledSince: Int?
        /// Takılı okumasıyla bırakıldı (`abandonStall`); okuma bitince sayaçtan düşülür.
        var abandoned = false
        /// Takılı sayılan okumanın başladığı an (takılmanın süresi bundan ölçülür).
        var stallStarted: Int?
        init(label: String) { queue = DispatchQueue(label: label, qos: .userInitiated) }
    }

    private let lock = NSLock()
    private var primary: Lane
    private var primaryGeneration = 0
    private var abandonedStalls = 0
    private var rescue: Lane
    private let label: String
    private var rescueGeneration = 0
    private var rescueFailures = 0
    private let timeoutMs: Int
    /// Altyazı okumasının ve önünde beklediği okumanın takılı sayılma süresi (`defaultSubtitleTimeoutMs`); uyarlanan
    /// sınırın alt ucu.
    private let subtitleTimeoutMs: Int
    /// Uyarlanan altyazı sınırının üst ucu.
    private let subtitleTimeoutCapMs: Int
    /// Asıl okuyucudaki son altyazı okumalarının süreleri (ms).
    private var subtitleSamples: [Int] = []
    /// Okumaların hızlı düzeye geçirildiği an (bu sıra geçirdiyse).
    private var fastLevelSince: Int?
    /// Hızlı düzeyin süresi (ms).
    public let fastLevelHoldMs: Int
    /// Altyazı, arka plan okumasının yanından yedeğe geçirildi; arka plan okuması bitince yedek kapatılır.
    private var rescueBorrowed = false
    private let maxRescueFailures: Int
    /// Asıl okuyucu bu kadar kez takılırsa okuma yolu değiştirilir (`VisionReader.useFastLevel`); nil: değiştirilmez.
    private let degradeAfterStalls: Int?
    private var stalls = 0
    private var lastSubtitleWaitMs = 0
    private var _rescuer: ReadRescuer?
    private var _onEvent: (@Sendable (Event) -> Void)?

    public init(label: String = "com.couchsubs.ocr", timeoutMs: Int = ReadQueue.defaultTimeoutMs,
                maxRescueFailures: Int = ReadQueue.defaultMaxRescueFailures, degradeAfterStalls: Int? = nil,
                subtitleTimeoutMs: Int? = nil, subtitleTimeoutCapMs: Int? = nil,
                fastLevelHoldMs: Int = ReadQueue.defaultFastLevelHoldMs) {
        self.degradeAfterStalls = degradeAfterStalls
        self.label = label
        self.timeoutMs = timeoutMs
        self.subtitleTimeoutMs = min(subtitleTimeoutMs ?? timeoutMs, timeoutMs)
        self.subtitleTimeoutCapMs = max(self.subtitleTimeoutMs, min(subtitleTimeoutCapMs ?? timeoutMs, timeoutMs))
        self.fastLevelHoldMs = fastLevelHoldMs
        self.maxRescueFailures = maxRescueFailures
        primary = Lane(label: label)
        rescue = Lane(label: "\(label).yedek.0")
    }

    /// Bağımsız yedek okuyucu (yoksa takılınca okuma `stuck` ile döner).
    public var rescuer: ReadRescuer? {
        get { lock.withLock { _rescuer } }
        set { lock.withLock { _rescuer = newValue } }
    }

    public var onEvent: (@Sendable (Event) -> Void)? {
        get { lock.withLock { _onEvent } }
        set { lock.withLock { _onEvent = newValue } }
    }

    /// Altyazı okumasının şu anki takılı sayılma süresi (ms): son okumaların ortanca süresi × 3, `subtitleTimeoutMs` ile
    /// `subtitleTimeoutCapMs` arasında. Yeterli okuma yoksa `subtitleTimeoutMs`.
    public var currentSubtitleTimeoutMs: Int { lock.withLock { subtitleLimit } }

    /// Kilit altında okunur.
    private var subtitleLimit: Int {
        guard subtitleSamples.count >= Self.subtitleMinSamples else { return subtitleTimeoutMs }
        let median = subtitleSamples.sorted()[subtitleSamples.count / 2]
        return min(max(median * Self.subtitleLimitFactor, subtitleTimeoutMs), subtitleTimeoutCapMs)
    }

    /// Kilit altında çağrılır: okumalar `fastLevelHoldMs` boyunca hızlı düzeyde verilir.
    private func useFastLevelForAWhile(now: Int) {
        VisionReader.useFastLevel = true
        fastLevelSince = now
    }

    /// Asıl okuyucu takılı mı ve kaç milisaniyedir.
    public var stalledMs: Int? { lock.withLock { primary.stalledSince.map { Self.uptimeMs() - $0 } } }

    /// Bağımsız yedeği olmayan yerde (iPhone; ayrı süreç açılamaz) takılan okuma bırakılır: asıl okuyucuya yeni kuyruk
    /// kurulur ve okumalar bundan sonra hızlı düzeyde (Neural Engine'siz) verilir. Eskiden iPhone'da takılan tek okuma
    /// bitmezse altyazı bir daha gelmiyordu; "Durdur / Başlat" düzeltmiyor, yalnız uygulamayı kapatıp açmak
    /// düzeltiyordu (Android'de takılan tanıyıcı zaten bırakılıp yenisi kuruluyor). Bırakılan okuma arka planda kalır
    /// (iş parçacığı durdurulamaz); bu yüzden süreç başına en çok `maxAbandons` kez yapılır.
    ///
    /// `olderThanMs`: takılma en az bu kadar sürmüş olmalı (takılan okuma çoğu zaman kendiliğinden biter). Bırakıldıysa
    /// takılmanın süresi (ms), bırakılmadıysa nil.
    @discardableResult
    public func abandonStall(olderThanMs: Int, maxAbandons: Int = ReadQueue.defaultMaxAbandons) -> Int? {
        let abandoned: Int? = lock.withLock {
            guard let since = primary.stalledSince, abandonedStalls < maxAbandons else { return nil }
            let ms = Self.uptimeMs() - (primary.stallStarted ?? since - timeoutMs)
            guard ms >= olderThanMs else { return nil }
            abandonedStalls += 1
            primary.abandoned = true
            primaryGeneration += 1
            // Eski kuyruğun bekleyenleri yoktur (takılınca yedeğe taşındı ya da hata aldı); takılan iş orada kalır.
            primary = Lane(label: "\(label).\(primaryGeneration)")
            // Hızlı düzey süreli: bırakılan okumalar bitip süre dolunca isabetli düzeye dönülür.
            useFastLevelForAWhile(now: Self.uptimeMs())
            return ms
        }
        guard abandoned != nil else { return nil }
        let current = lock.withLock { primary }
        pump(current)
        return abandoned
    }

    /// iPhone'da süreç başına bırakılabilecek takılı okuma sayısı (her biri bir iş parçacığını tutar).
    public static let defaultMaxAbandons = 3

    /// Takılıyken okumalar yedekten mi geliyor.
    public var isRescuing: Bool { lock.withLock { primary.stalledSince != nil && rescueUsable } }

    /// Arka plan okumalarının aralığı bununla çarpılır: altyazı okuması sırada beklediyse 2, çok beklediyse 4; asıl
    /// okuyucu takılıyken 4 (yedek yalnız altyazıya yetsin).
    public var backgroundSlowdown: Int {
        lock.withLock {
            if primary.stalledSince != nil { return 4 }
            if lastSubtitleWaitMs > Self.subtitleWaitLimitMs * 4 { return 4 }
            return lastSubtitleWaitMs > Self.subtitleWaitLimitMs ? 2 : 1
        }
    }

    /// Yedek bağlamdaki okumada bu iş parçacığının yedeği (`VisionReader` bakar); asıl okumada nil.
    public static var activeRescuer: ReadRescuer? {
        (Thread.current.threadDictionary[rescuerKey] as? RescuerBox)?.rescuer
    }

    private static let rescuerKey = "com.couchsubs.ocr.rescuer"
    private final class RescuerBox { let rescuer: ReadRescuer; init(_ rescuer: ReadRescuer) { self.rescuer = rescuer } }

    private var rescueUsable: Bool { _rescuer != nil && rescueFailures < maxRescueFailures }

    /// `work`'ü okuma sırasında çalıştırır. Çağıranın thread'i (Swift havuzu) beklerken bloklanmaz.
    /// `detail`: takılırsa günlüğe yazılacak ad ve kare boyutu.
    /// `droppable`: arka plan okuması altyazıyı bekletince düşürülebilir (dönemsel okumalar); kullanıcının istediği
    /// okuma ("Ekranı çevir", "Alanı çevir") false verir.
    public func run<T: Sendable>(priority: ReadPriority = .subtitle, detail: @autoclosure () -> String = "",
                                 droppable: Bool = true,
                                 _ work: @escaping @Sendable () throws -> T) async throws -> T {
        let detail = detail()
        let result: Result<T, Error> = await withCheckedContinuation { continuation in
            let once = Once(continuation)
            let item = Item(priority: priority, detail: detail, droppable: droppable,
                            work: { once.resume(Result { try work() }) },
                            fail: { once.resume(.failure($0)) })
            submit(item)
        }
        return try result.get()
    }

    private func submit(_ item: Item) {
        let (lane, limitMs): (Lane?, Int) = lock.withLock {
            var lane: Lane?
            if primary.stalledSince == nil {
                // Asıl okuyucu altyazıyı bekleten bir arka plan okumasıyla meşgulse yeni altyazı doğrudan yedeğe gider.
                if item.priority == .subtitle, primary.running?.yielded == true, rescueUsable, rescue.stalledSince == nil {
                    rescueBorrowed = true
                    lane = rescue
                } else {
                    lane = primary
                }
            } else if rescueUsable, rescue.stalledSince == nil {
                lane = rescue
            }
            guard let lane else { return (nil, 0) }
            Self.enqueue(item, in: lane)
            return (lane, subtitleLimit)
        }
        guard let lane else { return item.fail(ReadQueueError.stuck) }
        let timeoutMs = self.timeoutMs
        if item.priority == .subtitle, limitMs < timeoutMs {
            // Altyazı, asıl okuyucudaki uzun bir okumanın arkasında sınırdan fazla beklemez. Önündeki arka plan
            // okumasıysa takılma sayılmaz, yanından geçilir (`yieldToSubtitle`). Altyazı okumasıysa ve yedek varsa o okuma
            // takılı sayılır, altyazı (ve öbür bekleyenler) yedeğe geçer.
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + .milliseconds(limitMs)) { [self, weak item] in
                guard let item else { return }
                let blocker: (item: Item, lane: Lane)? = lock.withLock {
                    guard primary.pending.contains(where: { $0 === item }), let running = primary.running, !running.expired,
                          !running.yielded else { return nil }
                    if running.priority == .background { return (running, primary) }
                    guard rescueUsable, let started = running.started,
                          Self.uptimeMs() - started >= (running.limitMs ?? limitMs) else { return nil }
                    return (running, primary)
                }
                guard let blocker else { return }
                if blocker.item.priority == .background { yieldToSubtitle(blocker.item) } else { overdue(blocker.item, on: blocker.lane) }
            }
        }
        // Sırada `timeoutMs` bekleyen okuma artık bayattır; kare atlanır.
        // Zamanlayıcılar okumayı zayıf tutar (`weak item`): biten okumanın karesi (ve kırpığın bağlı olduğu bütün kare)
        // hemen bırakılır. Eskiden her okuma karesini 10 sn tutuyordu; Mac'te pencere yakalamanın (ScreenCaptureKit) üç
        // karelik havuzu tutulan karelerle dolunca yeni kare gelmiyor, altyazı ~10,6 sn arayla okunuyordu (GitHub #822).
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .milliseconds(timeoutMs)) { [self, weak item] in
            guard let item else { return }
            // Asıl okuyucu bu arada takıldıysa okuma yedeğin sırasına taşınmıştır.
            let waiting = lock.withLock {
                for lane in [primary, rescue] {
                    if let index = lane.pending.firstIndex(where: { $0 === item }) {
                        lane.pending.remove(at: index)
                        return true
                    }
                }
                return false
            }
            if waiting { item.fail(ReadQueueError.timedOut(ms: timeoutMs)) }
        }
        pump(lane)
    }

    /// Altyazı okuması bekleyen arka plan okumalarının önüne geçer; aynı öncelikte geliş sırası korunur.
    private static func enqueue(_ item: Item, in lane: Lane) {
        let index = lane.pending.firstIndex { $0.priority.rawValue > item.priority.rawValue } ?? lane.pending.count
        lane.pending.insert(item, at: index)
    }

    /// Altyazı, asıl okuyucuda süren arka plan okumasının arkasında sınır kadar bekledi (#1210). Bu takılma sayılmaz (asıl
    /// okuyucu çalışıyor, yalnız meşgul): uyarı çıkmaz, okumalar yedeğe taşınmaz, hızlı düzeye geçilmez. Sıradaki
    /// düşürülebilir arka plan okumaları düşürülür, arka plan turları kısılır; yedek varsa bekleyen altyazılar bu tur
    /// yedekten okunur. Süren arka plan okuması sürer (Vision isteği yarıda kesilemez) ve sonucunu teslim eder;
    /// `timeoutMs`'te bitmezse o zaman takılmadır.
    private func yieldToSubtitle(_ running: Item) {
        var dropped: [Item] = []
        var rescued = false
        let event: Event? = lock.withLock {
            guard primary.running === running, !running.expired, !running.yielded, primary.stalledSince == nil else { return nil }
            running.yielded = true
            let now = Self.uptimeMs()
            let waited = primary.pending.first { $0.priority == .subtitle }.map { now - $0.submitted } ?? 0
            // Arka plan turları en çok kısılır (×4); beklemeden okunan sonraki altyazı kısmayı kaldırır.
            lastSubtitleWaitMs = max(waited, Self.subtitleWaitLimitMs * 4 + 1)
            dropped = primary.pending.filter { $0.priority == .background && $0.droppable }
            primary.pending.removeAll { $0.priority == .background && $0.droppable }
            if rescueUsable, rescue.stalledSince == nil {
                let subtitles = primary.pending.filter { $0.priority == .subtitle }
                primary.pending.removeAll { $0.priority == .subtitle }
                subtitles.forEach { Self.enqueue($0, in: rescue) }
                rescued = !subtitles.isEmpty
                if rescued { rescueBorrowed = true }
            }
            let stall = Stall(detail: running.detail, ms: now - (running.started ?? running.submitted),
                              thermal: Self.thermalName(), memoryMB: Self.memoryMB(),
                              pending: primary.pending.count + rescue.pending.count,
                              running: (primary.running == nil ? 0 : 1) + (rescue.running == nil ? 0 : 1))
            return .backgroundYielded(stall, dropped: dropped.count, rescued: rescued)
        }
        guard let event else { return }
        dropped.forEach { $0.fail(ReadQueueError.timedOut(ms: timeoutMs)) }
        onEvent?(event)
        if rescued { pump(lock.withLock { rescue }) }
    }

    /// Kilit altında çağrılır: yedek yalnız arka plan okumasının yanından geçirilen altyazılar için açıldıysa ve artık
    /// gerekmiyorsa kapatılacak yedeği döndürür.
    private func endBorrowedRescue() -> ReadRescuer? {
        guard rescueBorrowed, primary.stalledSince == nil, primary.running?.yielded != true,
              rescue.running == nil, rescue.pending.isEmpty else { return nil }
        rescueBorrowed = false
        return _rescuer
    }

    /// Kuyruk boşsa sıradaki okumayı başlatır.
    private func pump(_ lane: Lane) {
        var restored: Event?
        let next: (item: Item, rescuer: ReadRescuer?, limitMs: Int)? = lock.withLock {
            guard lane.running == nil, lane.stalledSince == nil, !lane.pending.isEmpty else { return nil }
            let item = lane.pending.removeFirst()
            let now = Self.uptimeMs()
            item.started = now
            lane.running = item
            if lane === primary {
                if item.priority == .subtitle { lastSubtitleWaitMs = now - item.submitted }
                // Hızlı düzeyin süresi dolduysa isabetli düzeye dönülür (bırakılmış, bitmemiş okuma yoksa: iPhone'da
                // o okumalar Vision'ı hâlâ tutuyor olabilir). Yeniden takılırsa bir takılmada yine hızlı düzeye geçilir.
                if let since = fastLevelSince, now - since >= fastLevelHoldMs, abandonedStalls == 0 {
                    fastLevelSince = nil
                    VisionReader.useFastLevel = false
                    stalls = max(0, (degradeAfterStalls ?? 1) - 1)
                    restored = .restored(afterMs: now - since)
                }
            }
            // Asıl okuyucudaki altyazı okuması, yedek varsa (Mac) uyarlanan sınırda (`subtitleLimit`) takılı sayılır;
            // yedeksiz (iPhone) beklemenin bir yararı olmadığından eski süre geçerlidir.
            let limitMs = lane === primary && item.priority == .subtitle && rescueUsable ? subtitleLimit : timeoutMs
            item.limitMs = limitMs
            return (item, lane === primary ? nil : _rescuer, limitMs)
        }
        if let restored { onEvent?(restored) }
        guard let next else { return }
        let item = next.item
        let limitMs = next.limitMs
        lane.queue.async { [self] in
            if let rescuer = next.rescuer { Thread.current.threadDictionary[Self.rescuerKey] = RescuerBox(rescuer) }
            item.work()
            Thread.current.threadDictionary.removeObject(forKey: Self.rescuerKey)
            finished(item, on: lane)
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .milliseconds(limitMs)) { [self, weak item, weak lane] in
            guard let item, let lane else { return }
            overdue(item, on: lane)
        }
    }

    private func finished(_ item: Item, on lane: Lane) {
        var events: [Event] = []
        var standDown: ReadRescuer?
        lock.withLock {
            guard lane.running === item else { return }
            lane.running = nil
            let now = Self.uptimeMs()
            // Asıl okuyucudaki altyazı okumasının süresi uyarlanan sınıra (`subtitleLimit`) katılır; takılı sayılıp sonra
            // biten okumanınki de (yavaşlayan cihazın gerçek süresi).
            if lane === primary, !lane.abandoned, item.priority == .subtitle, let started = item.started {
                subtitleSamples.append(now - started)
                if subtitleSamples.count > Self.subtitleSampleCount { subtitleSamples.removeFirst() }
            }
            if lane.abandoned {
                // Bırakılan okuma sonunda bitti: iş parçacığı serbest, sınırdan düşülür. Eskiden sayaç süreç boyunca
                // yalnız artıyordu; uzun oyunda (TestFlight, X: "2 saat sonra altyazı gitti, uygulamayı kapatıp açınca
                // düzeldi") dördüncü takılma bırakılamıyor, altyazı uygulama kapatılana dek bir daha gelmiyordu.
                lane.abandoned = false
                abandonedStalls = max(0, abandonedStalls - 1)
                events.append(.abandonedFinished(stillStuck: abandonedStalls))
            } else if lane === primary {
                if let since = lane.stalledSince {
                    // Takılan okuma sonunda bitti: asıl okuyucu yeniden kullanılır.
                    let ran = now - (lane.stallStarted ?? since - timeoutMs)
                    lane.stalledSince = nil
                    lane.stallStarted = nil
                    rescueFailures = 0
                    rescueBorrowed = false
                    standDown = _rescuer
                    events.append(.recovered(ms: ran))
                    // Takılma yineleniyorsa isabetli düzey (Neural Engine) bir süre (`fastLevelHoldMs`) bırakılır: hızlı
                    // düzey o yolu hiç kullanmaz. Süre dolunca isabetli düzey yeniden denenir (#1210). Takılıyken
                    // değiştirmek işe yaramaz (istek aynı kilidi bekler); düzelince değişir.
                    // Yalnız `timeoutMs`'i aşan okuma sayılır: altyazıyı bekletmemek için erken takılı sayılan, birkaç
                    // saniyede biten okuma (ör. "Ekranı çevir"in bütün kare okuması) isabetli düzeyi bıraktırmaz.
                    if ran >= timeoutMs { stalls += 1 }
                    if ran >= timeoutMs, let degradeAfterStalls, stalls >= degradeAfterStalls, fastLevelSince == nil {
                        useFastLevelForAWhile(now: now)
                        events.append(.degraded(stalls: stalls))
                    }
                } else {
                    standDown = endBorrowedRescue()
                }
            } else {
                if !item.expired { rescueFailures = 0 }
                standDown = endBorrowedRescue()
            }
        }
        standDown?.standDown()
        events.forEach { onEvent?($0) }
        pump(lane)
    }

    /// Okuma `timeoutMs`'dir sürüyor: çağırana süre aşımı döner, kuyruk takılı sayılır.
    private func overdue(_ item: Item, on lane: Lane) {
        var event: Event?
        var abandon: ReadRescuer?
        var stranded: [Item] = []
        let stuck: Bool = lock.withLock {
            guard lane.running === item, !item.expired else { return false }
            item.expired = true
            let stall = Stall(detail: item.detail, ms: Self.uptimeMs() - (item.started ?? item.submitted),
                              thermal: Self.thermalName(), memoryMB: Self.memoryMB(),
                              pending: primary.pending.count + rescue.pending.count,
                              running: (primary.running == nil ? 0 : 1) + (rescue.running == nil ? 0 : 1))
            if lane === primary {
                lane.stalledSince = Self.uptimeMs()
                lane.stallStarted = item.started ?? item.submitted
                // Bekleyenler yedeğe taşınır; yedek yoksa beklemeden hata alırlar.
                let waiting = lane.pending
                lane.pending = []
                if rescueUsable, rescue.stalledSince == nil { rescue.pending.append(contentsOf: waiting) } else { stranded = waiting }
                event = .stalled(stall, rescued: rescueUsable)
            } else {
                // Yedek bağlam da takıldı: bırakılır, sonraki okuma yeni bağlamda (yeni kuyruk, yeni süreç) yapılır.
                rescueFailures += 1
                abandon = _rescuer
                stranded = lane.pending
                rescueGeneration += 1
                rescue = Lane(label: "\(label).yedek.\(rescueGeneration)")
                event = .rescueFailed(stall, failures: rescueFailures)
            }
            return true
        }
        guard stuck else { return }
        abandon?.abandon()
        if let event { onEvent?(event) }
        // `resume` bir kez teslim eder: iş sonradan bitse de çağıran süre aşımını almış olur.
        item.fail(ReadQueueError.timedOut(ms: item.limitMs ?? timeoutMs))
        stranded.forEach { $0.fail(ReadQueueError.stuck) }
        let next = lock.withLock { rescue }
        pump(next)
    }

    /// Sonucu yalnız bir kez teslim eden sarmalayıcı.
    private final class Once<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Result<T, Error>, Never>?
        init(_ continuation: CheckedContinuation<Result<T, Error>, Never>) { self.continuation = continuation }
        func resume(_ result: Result<T, Error>) {
            let pending: CheckedContinuation<Result<T, Error>, Never>? = lock.withLock {
                defer { continuation = nil }
                return continuation
            }
            pending?.resume(returning: result)
        }
    }

    // MARK: - Tanı

    static func uptimeMs() -> Int { Int(DispatchTime.now().uptimeNanoseconds / 1_000_000) }

    public static func thermalName(_ state: ProcessInfo.ThermalState = ProcessInfo.processInfo.thermalState) -> String {
        switch state {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "bilinmiyor"
        }
    }

    /// Sürecin bellek ayak izi (MB).
    public static func memoryMB() -> Int? {
        #if canImport(Darwin)
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Int(info.phys_footprint / 1_048_576) : nil
        #else
        return nil
        #endif
    }
}

extension ReadQueue.Stall {
    /// Günlük satırı: "altyazı 1728x324 derin, 10004 ms; ısı: nominal, bellek 412 MB, sırada 1, süren 1".
    public var logText: String {
        let memory = memoryMB.map { "\($0) MB" } ?? "?"
        return "\(detail.isEmpty ? "okuma" : detail), \(ms) ms; ısı: \(thermal), bellek \(memory), sırada \(pending), süren \(running)"
    }
}

extension ReadQueue {
    /// Günlükte karenin boyutu: "altyazı 1728x324 derin".
    public static func detail(_ name: String, _ image: CGImage, deep: Bool = false) -> String {
        "\(name) \(image.width)x\(image.height)\(deep ? " derin" : "")"
    }
}
