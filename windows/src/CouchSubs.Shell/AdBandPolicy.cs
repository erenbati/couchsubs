// SPDX-License-Identifier: AGPL-3.0-only

namespace CouchSubs.Shell;

/// <summary>
/// Alt reklam şeridi kuralı (design/yeni-arayuz/METINLER.md › Reklam kuralları; Mac, iPhone, Android ile aynı): yalnız uygulama
/// sayfalarında ve gösterilecek reklam varken; çeviri sürerken ve deneme modunda gizli, çeviri durunca geri gelir.
/// </summary>
public static class AdBandPolicy
{
    public static bool Visible(bool appPage, bool hasAds, bool translating, bool demo) => appPage && hasAds && !translating && !demo;
}
