// SPDX-License-Identifier: AGPL-3.0-only

using CouchSubs.Core;

namespace CouchSubs.Core.Tests;

/// <summary>
/// GTA 6 telefonu kapalıyken telefon listesi altyazı yolunda sahne yazısı sayılıp atılınca oturum başına bir kez ipucu
/// (#1202; Mac GamePhoneHintTests ve Android GamePhoneHintTest ile aynı deneme).
/// </summary>
public class GamePhoneHintTests
{
    [Fact]
    public void OffersOncePerSessionOnlyForGta6WithThePhoneOff()
    {
        var hint = new GamePhoneHint();
        Assert.False(hint.Observe("eğik satır (tabela)", readsPhone: true, "GTA 6"));
        Assert.False(hint.Observe("eğik satır (tabela)", readsPhone: false, "Red Dead Redemption 2"));
        Assert.False(hint.Observe("plaka/tabela (kısa büyük harfli satırlar)", readsPhone: false, "GTA 6"));
        Assert.True(hint.Observe("eğik satır (tabela)", readsPhone: false, "GTA 6"));
        Assert.True(hint.Offered);
        Assert.False(hint.Observe(InkTone.Reason, readsPhone: false, "GTA 6"));
        hint.Reset();
        Assert.True(hint.Observe(InkTone.Reason, readsPhone: false, "gta6"));
    }

    [Fact]
    public void PhoneListReasonsAreTiltAndDarkInk()
    {
        Assert.True(GamePhoneHint.IsPhoneList("eğik satır (tabela)"));
        Assert.True(GamePhoneHint.IsPhoneList(InkTone.Reason));
        Assert.False(GamePhoneHint.IsPhoneList("harfsiz sayı"));
        Assert.False(GamePhoneHint.IsPhoneList("karenin ortasında kısa satır"));
    }
}
