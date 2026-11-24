// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// Karenin kendi belleğimize kopyalanma sıklığı (uyarlamalı). X'te iki kullanıcı CouchSubs açıkken oyunun takıldığını,
/// kapatınca geçtiğini bildirdi (Windows'ta Remote Play penceresi ve Xbox uzaktan oynatma). Pencere yakalaması her karede
/// bütün pencereyi kopyalıyor (#928'den beri Mac'te de), okuma bu karelerin çoğunu hiç kullanmadan atlıyordu (önceki
/// okuma sürerken). Artık:
/// - En çok saniyede `maxFramesPerSecond` kare kopyalanır (`baseIntervalMs`).
/// - Bilgisayarın işlemcisi doluysa seyrekleşir: %75'te `busyIntervalMs`, %90'da `fullIntervalMs`.
/// - Altyazı okuması kare aralığından uzun sürüyorsa aralık okuma süresine çıkar (en çok `maxIntervalMs`).
/// Görüntü değişmiyorsa zaten kare gelmez (ScreenCaptureKit yalnız değişen kareyi tam verir) ve okuma bölge değişmedikçe
/// yazı tanıma yapmaz (`ReadScheduler`). Sınıra takılan son kare tutulur, sınır dolunca okunur (#1019: görüntü durunca
/// yeni kare gelmez). Windows: FrameCadence.cs (aynı eşikler). İş parçacığı güvenlidir.
public final class FrameCadence: @unchecked Sendable {
    public static let maxFramesPerSecond = 10
    public static let baseIntervalMs = 1000 / maxFramesPerSecond
    /// İşlemci %75 dolu: saniyede 6 kare.
    public static let busyIntervalMs = 166
    /// İşlemci %90 dolu: saniyede 4 kare.
    public static let fullIntervalMs = 250
    /// Okuma ne kadar yavaş olursa olsun kare en çok bu kadar arayla gelir (altyazı tepkisi).
    public static let maxIntervalMs = 333
    public static let busyLoad = 0.75
    public static let fullLoad = 0.90
    /// Kareler tam aralıkta gelmez (ScreenCaptureKit saniyede 10'u ±birkaç ms ile verir): aralığın bu kadar altı da kabul
    /// edilir, yoksa her ikinci kare atlanıp hız yarıya iniyordu.
    public static let jitterMs = 8

    private let lock = NSLock()
    private var last: Int?
    private var load = 0.0
    private var readMs = 0

    public init() {}

    /// Şu anki kare aralığı (milisaniye).
    public var intervalMs: Int { lock.withLock { Self.interval(cpuLoad: load, lastReadMs: readMs) } }

    /// İşlemci yüküne (0–1) ve son altyazı okumasının süresine göre kare aralığı.
    public static func interval(cpuLoad: Double, lastReadMs: Int) -> Int {
        let interval = cpuLoad >= fullLoad ? fullIntervalMs : cpuLoad >= busyLoad ? busyIntervalMs : baseIntervalMs
        return min(maxIntervalMs, max(interval, lastReadMs))
    }

    /// Bilgisayarın toplam işlemci yükü (0–1).
    public func reportCpuLoad(_ value: Double) {
        lock.withLock { load = value.isFinite ? min(max(value, 0), 1) : 0 }
    }

    /// Son altyazı okumasının (yazı tanıma) süresi.
    public func reportReadMs(_ value: Int?) {
        lock.withLock { readMs = max(0, value ?? 0) }
    }

    /// Bu kare kopyalanıp okumaya verilsin mi (`now`: milisaniye saati). Evetse an kaydedilir; saat geri gittiyse alınır.
    public func admit(now: Int) -> Bool {
        lock.withLock {
            if let last, now >= last, now - last < Self.interval(cpuLoad: load, lastReadMs: readMs) - Self.jitterMs { return false }
            last = now
            return true
        }
    }

    /// Oturum yenilendi: ilk kare beklemeden alınır.
    public func reset() {
        lock.withLock {
            last = nil
            readMs = 0
        }
    }
}

/// Ana ekrandaki canlı önizlemenin (perde) yenilenme aralığı; hareket kapısıyla aynı kural (DSMotionGate, Windows
/// MotionGate). Pencere öndeyken saniyede 2 (HomeTicker), oyun oynanırken (uygulama arka planda) saniyede 1 kez.
/// Windows: PreviewCadence (FrameCadence.cs; orada önde saniyede 4).
public enum PreviewCadence {
    public static let backgroundIntervalMs = 1000

    /// Önizleme bu yenilemede güncellensin mi (`last`: son güncellemenin anı; `active`: uygulama önde).
    public static func due(now: Int, last: Int?, active: Bool) -> Bool {
        guard !active, let last, now >= last else { return true }
        return now - last >= backgroundIntervalMs
    }
}

/// Bilgisayarın toplam işlemci yükü (host_statistics, bütün süreçler); saniyede en çok bir kez ölçülür. Kare sıklığı
/// (`FrameCadence`) yük yükselince kendini kısar. Windows: SystemCpuLoad.cs (GetSystemTimes).
public final class SystemCpuLoad: @unchecked Sendable {
    private let lock = NSLock()
    private var sampledAt: Int?
    private var ticks: (busy: UInt64, total: UInt64)?

    public init() {}

    /// Son ölçümden bir saniye geçtiyse yükü ölçüp `cadence`'e bildirir.
    public func report(to cadence: FrameCadence, now: Int) {
        if let load = sample(now: now) { cadence.reportCpuLoad(load) }
    }

    /// Son ölçümden bu yana yük (0–1); bir saniye geçmediyse ya da ölçülemediyse nil.
    public func sample(now: Int) -> Double? {
        lock.withLock {
            if let sampledAt, now >= sampledAt, now - sampledAt < 1000 { return nil }
            guard let current = Self.read() else { return nil }
            defer { ticks = current; sampledAt = now }
            guard let previous = ticks, current.total > previous.total, current.busy >= previous.busy else { return nil }
            return min(max(Double(current.busy - previous.busy) / Double(current.total - previous.total), 0), 1)
        }
    }

    private static func read() -> (busy: UInt64, total: UInt64)? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let user = UInt64(info.cpu_ticks.0), system = UInt64(info.cpu_ticks.1)
        let idle = UInt64(info.cpu_ticks.2), nice = UInt64(info.cpu_ticks.3)
        return (user + system + nice, user + system + idle + nice)
    }
}
