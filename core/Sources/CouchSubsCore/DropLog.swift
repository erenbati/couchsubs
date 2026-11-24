// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// Metin hattında bir satırın neden düşürüldüğü, bekletildiği ya da çevrilmediği: altyazı günlüğüne kısa, sınırlı bir
/// satır. Biçim: `düşen satır [Bileşen] neden: "metnin ilk 30 karakteri"`. Kullanıcı bildirimlerinde (GTA 6 telefon
/// mesajı bir kez çevrilip duruyor, görev satırı İngilizce kalıyor, periyodik kopmalar) hangi bileşenin satırı bıraktığı
/// günlükte görünsün diye. Gürültü yapmaz: aynı bileşen + neden + metin `repeatMs` içinde yeniden yazılmaz; bir dakikada
/// en çok `perMinute` satır yazılır, aşan satırlar sayılır ve sonraki yazılan satırın sonunda bildirilir. Yalnız metin
/// yazılır; ekran karesi ya da görüntü yazılmaz. Windows (DropLog.cs) ve Android (DropLog.kt) aynı biçim, aynı sınırlar.
public final class DropLog: @unchecked Sendable {
    /// Alıntının en uzun hâli (karakter).
    public static let excerptLength = 30
    /// Aynı bileşen + neden + metin bu süre içinde yeniden yazılmaz.
    public static let repeatMs = 60_000
    /// Bir dakikada en çok yazılan satır.
    public static let perMinute = 20
    /// Hatırlanan en çok satır anahtarı (bellek sınırı).
    static let memory = 256

    private let lock = NSLock()
    private let now: () -> Int
    private let sink: (String) -> Void
    private var seen: [String: Int] = [:]
    private var windowStart: Int?
    private var written = 0
    private var suppressed = 0

    /// `sink`: varsayılanı altyazı günlüğü (`SubtitleLog`; açılmadıysa, ör. testlerde, hiçbir şey yazılmaz).
    public init(clock: @escaping () -> Int = SubtitleStabilizer.uptimeMs,
                sink: @escaping (String) -> Void = { SubtitleLog.write($0) }) {
        now = clock
        self.sink = sink
    }

    /// Yazılacak günlük satırı; aynı satır yakın zamanda yazıldıysa ya da dakikalık sınır dolduysa nil.
    public func line(_ component: String, _ reason: String, _ text: String) -> String? {
        let excerpt = SubtitleLog.excerpt(text, limit: Self.excerptLength)
        let key = "\(component)|\(reason)|\(excerpt)"
        return lock.withLock {
            let time = now()
            if let last = seen[key], time - last < Self.repeatMs { return nil }
            if let start = windowStart, time - start < 60_000 {
                guard written < Self.perMinute else {
                    suppressed += 1
                    return nil
                }
            } else {
                windowStart = time
                written = 0
            }
            written += 1
            seen[key] = time
            if seen.count > Self.memory {
                seen = seen.filter { time - $0.value < Self.repeatMs }
                if seen.count > Self.memory { seen = [key: time] }
            }
            var line = "düşen satır [\(component)] \(reason): \(excerpt)"
            if suppressed > 0 {
                line += " (+\(suppressed) satır sınır yüzünden yazılmadı)"
                suppressed = 0
            }
            return line
        }
    }

    /// Satırı (yazılacaksa) `log`'a, yoksa kurulurken verilen günlüğe yazar.
    public func note(_ component: String, _ reason: String, _ text: String, log: ((String) -> Void)? = nil) {
        guard let line = line(component, reason, text) else { return }
        (log ?? sink)(line)
    }
}
