// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

/// LG: kurulumdan (ya da kapat-aç ile yeniden başlatmadan) sonra TV'de ÇALIŞAN uygulamanın sürümü kurulan sürüm mü?
/// beta.89 (Mac, LG): TV'ye 0.9.84 kurulmuştu (appinfo.json 0.9.84), açık uygulama ise 0.9.81'di; Mac "TV uygulaması hazır
/// (sürüm 0.9.84)" diyordu. TV uygulaması altyazı akışına bağlanırken sürümünü bildirir (`/events?v=`); bu bildirim kurulan
/// sürümden eskiyse uygulama bir kez daha kapatılıp açılır, yine eskiyse kullanıcıya "TV'de CouchSubs'ı kapatıp yeniden
/// açın" denir. Windows (TvAppRunningCheck.cs) ve Android (TvAppRunningCheck.kt) ile aynı kurallar.
public struct TVAppRunningCheck: Equatable, Sendable {
    public enum Verdict: Equatable, Sendable {
        /// Çalışan uygulama kurulan sürümde (ya da daha yeni): denetim biter.
        case running
        /// Çalışan uygulama eski: bir kez daha kapatılıp açılmalı.
        case restartAgain
        /// Kapatıp açtıktan sonra da eski: kullanıcıya söylenir.
        case stale
    }

    public let expected: String
    public private(set) var restarted = false

    public init(expected: String) { self.expected = expected }

    /// TV uygulaması sürümünü bildirdi (boş: sürüm bildirmeyen eski uygulama).
    public mutating func report(_ version: String) -> Verdict {
        if !Self.isStale(running: version, installed: expected) { return .running }
        if !restarted {
            restarted = true
            return .restartAgain
        }
        return .stale
    }

    /// Çalışan uygulamanın bildirdiği sürüm (boş: sürüm bildirmeyen eski uygulama) kurulu paketten eski mi?
    public static func isStale(running: String, installed: String) -> Bool {
        guard !installed.isEmpty else { return false }
        return running.isEmpty || DevModeInstaller.isNewer(installed, than: running)
    }
}
