// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// Telefon çevirisi kapalıyken GTA 6'nın telefon listesi altyazı alanına düşüp altyazı yolunda sahne yazısı sayılınca
/// ("eğik satır", "koyu yazı açık zeminde") kullanıcıya oturum başına bir kez "Telefon çevirisi kapalı, açmak ister
/// misiniz?" ipucu gösterilir (#1202, #1197, #1193, #1170: telefon okuyucusu hiç çalışmamıştı, kullanıcı ayarın
/// kapalı olduğunu bilmiyordu). Windows (GamePhoneHint.cs) ve Android (GamePhoneHint.kt) aynı kuralı uygular.
public struct GamePhoneHint: Sendable {
    /// Bu oturumda ipucu gösterildi.
    public private(set) var offered = false

    public init() {}

    /// Sahne yazısı nedeni telefon listesine uyar mı: eğik satır ya da açık zeminde koyu yazı (telefonun beyaz ekranı).
    public static func isPhoneList(_ reason: String) -> Bool {
        reason.hasPrefix("eğik satır") || reason == InkTone.reason
    }

    /// Atılan blok ipucunu gerektiriyor mu. Oturumda yalnız bir kez true döner.
    public mutating func observe(reason: String, readsPhone: Bool, game: String?) -> Bool {
        guard !offered, !readsPhone, let game, GameName.key(game) == "gta 6", Self.isPhoneList(reason) else { return false }
        offered = true
        return true
    }

    /// Yeni oturum: ipucu yeniden gösterilebilir.
    public mutating func reset() { offered = false }
}
