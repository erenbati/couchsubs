// SPDX-License-Identifier: AGPL-3.0-only

namespace CouchSubs.Shell.Tests;

/// <summary>Reklam şeridi: boştaki uygulama sayfalarında görünür; çeviri sürerken, deneme modunda, kurulumda, reklamsız gizli.</summary>
public class AdBandPolicyTests
{
    [Fact]
    public void HiddenWhileTranslating()
    {
        Assert.True(AdBandPolicy.Visible(appPage: true, hasAds: true, translating: false, demo: false));
        Assert.False(AdBandPolicy.Visible(appPage: true, hasAds: true, translating: true, demo: false));
        Assert.False(AdBandPolicy.Visible(appPage: true, hasAds: true, translating: false, demo: true));
        Assert.False(AdBandPolicy.Visible(appPage: false, hasAds: true, translating: false, demo: false));
        Assert.False(AdBandPolicy.Visible(appPage: true, hasAds: false, translating: false, demo: false));
    }
}
