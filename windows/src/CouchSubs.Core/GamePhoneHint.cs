// SPDX-License-Identifier: AGPL-3.0-only

namespace CouchSubs.Core;

/// <summary>
/// GTA 6 telefonu kapalıyken telefonun mesaj listesi altyazı alanına düşünce altyazı yolu onu sahne yazısı sayıp atıyor
/// ("eğik satır", "koyu yazı açık zeminde"); kullanıcı telefonun neden çevrilmediğini bilmiyordu (GitHub #1202, #1197,
/// #1193, #1170). Bu durumda oturum başına bir kez "Telefon çevirisi kapalı, açmak ister misiniz?" ipucu gösterilir.
/// Mac/iPhone (GamePhoneHint.swift) ve Android (GamePhoneHint.kt) aynı kuralı uygular.
/// </summary>
public sealed class GamePhoneHint
{
    /// <summary>Bu oturumda ipucu önerildi.</summary>
    public bool Offered { get; private set; }

    /// <summary>Atılma nedeni telefon listesine uyuyor mu: eğik satır ya da açık zeminde koyu yazı.</summary>
    public static bool IsPhoneList(string reason) =>
        reason.StartsWith("eğik satır", StringComparison.Ordinal) || reason == InkTone.Reason;

    /// <summary>
    /// Altyazı yolu bir bloğu sahne yazısı sayıp attı. Telefon okunmuyorsa, oyun GTA 6 ise ve neden telefon listesine
    /// uyuyorsa ipucu oturumda bir kez önerilir (true).
    /// </summary>
    public bool Observe(string reason, bool readsPhone, string? game)
    {
        if (Offered || readsPhone || GameName.Key(game) != "gta 6" || !IsPhoneList(reason)) return false;
        Offered = true;
        return true;
    }

    /// <summary>Yeni oturum: ipucu yeniden önerilebilir.</summary>
    public void Reset() => Offered = false;
}
