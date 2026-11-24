// SPDX-License-Identifier: AGPL-3.0-only

using System.Text.Json;
using CouchSubs.Core;

namespace CouchSubs.Core.Tests;

/// <summary>Konuşana göre renk v3: dört platformun ortak vektörü (docs/speaker-colors-vectors.json) birebir.</summary>
public class SpeakerColorBookTests
{
    private static string Vectors()
    {
        for (var dir = new DirectoryInfo(AppContext.BaseDirectory); dir is not null; dir = dir.Parent)
        {
            var path = Path.Combine(dir.FullName, "docs", "speaker-colors-vectors.json");
            if (File.Exists(path)) return path;
        }
        throw new FileNotFoundException("docs/speaker-colors-vectors.json bulunamadı");
    }

    [Fact]
    public void SharedSequenceGivesTheSameColours()
    {
        using var json = JsonDocument.Parse(File.ReadAllText(Vectors()));
        Assert.Equal(SpeakerColors.Palette, json.RootElement.GetProperty("palette").EnumerateArray().Select(item => item.GetString()!));
        Assert.Equal(SpeakerColors.Hues, json.RootElement.GetProperty("hues").EnumerateArray().Select(item => item.GetInt32()));
        Assert.Equal(SpeakerColorBook.MinHueGap, json.RootElement.GetProperty("minHueGap").GetInt32());
        foreach (var sequence in new[] { "sequence", "gta6" })
        {
            var book = new SpeakerColorBook();
            foreach (var item in json.RootElement.GetProperty(sequence).EnumerateArray())
                Assert.Equal(item.GetProperty("color").GetString(), book.Color(item.GetProperty("name").GetString()!));
        }
    }

    /// <summary>
    /// Kullanıcı bildirimi (X): ad renkleri hep pembe/mavi tonlarda çıkıyor, karakterler ayırt edilmiyordu. Eski paletin on
    /// renginden üçü mavi, ikisi pembe/mordu; GTA 6'nın iki baş karakteri Lucia pembe, Jason turkuaz çıkıyordu. Palet ton
    /// çemberine eşit yayılır; bir sahnedeki kişiler birbirinden belirgin ayrı tonlar alır, aynı kişi hep aynı renktir
    /// (Mac: testColorsSpreadAcrossDistinctHues).
    /// </summary>
    [Fact]
    public void ColorsSpreadAcrossDistinctHues()
    {
        var hues = SpeakerColors.Hues;
        Assert.Equal(SpeakerColors.Palette.Count, hues.Count);
        Assert.Equal(SpeakerColors.Palette.Count, SpeakerColors.Palette.Distinct().Count());
        for (var i = 0; i < hues.Count; i++)
            Assert.Equal(36, (i + 1 == hues.Count ? hues[0] + 360 : hues[i + 1]) - hues[i]);
        var book = new SpeakerColorBook();
        string[] cast = ["Lucia", "Jason", "Cal", "Yolanda", "Brian"];
        var colors = cast.Select(name => book.Color(name)!).ToList();
        Assert.Equal(cast.Length, colors.Distinct().Count());
        var indices = colors.Select(color => SpeakerColors.Palette.ToList().IndexOf(color)).ToList();
        Assert.True(SpeakerColorBook.HueGap(indices[1], [indices[0]]) >= SpeakerColorBook.MinHueGap);
        for (var i = 1; i < indices.Count; i++) Assert.True(SpeakerColorBook.HueGap(indices[i], indices.Take(i).ToList()) >= 36, cast[i]);
        Assert.Equal(colors[0], book.Color("LUCIA"));
        Assert.Equal(colors[1], book.Color("Jasen"));
        book.Reset();
        Assert.Equal(SpeakerColors.Color("Lucia"), book.Color("Lucia"));
    }

    [Fact]
    public void ResetStartsANewSession()
    {
        var book = new SpeakerColorBook();
        Assert.Equal("#F76AB7", book.Color("Mattia"));
        Assert.Equal("#1EE4B2", book.Color("Boobie"));
        book.Reset();
        Assert.Equal("#F76AB7", book.Color("Boobie"));
        Assert.Null(book.Color(" ... "));
    }

    [Theory]
    [InlineData("Hedef: Arabaya bin.")]
    [InlineData("Görev: Lucia'yı bul.")]
    [InlineData("İpucu: Haritayı aç.")]
    [InlineData("Not: Kaydet.")]
    [InlineData("12:30")]
    [InlineData("3:1 oranla kazandın")]
    public void TitlesAndTimesAreNotSpeakers(string line) => Assert.Null(SpeakerPrefix.Parse(line));

    [Fact]
    public void ServerSendsTheSessionColours()
    {
        var server = new SubtitleServer(0) { SpeakerColors = true };
        Assert.Equal("#F76AB7", server.SpeakerBook.Color("Mattia"));
        Assert.Equal("#1EE4B2", server.SpeakerBook.Color("Boobie"));
    }
}
