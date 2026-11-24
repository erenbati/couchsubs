// SPDX-License-Identifier: AGPL-3.0-only

using System.Text.Json;
using CouchSubs.Core;
using Xunit;

namespace CouchSubs.Core.Tests;

/// <summary>
/// Ekran yazısı çevirisinin takibi (<see cref="ScreenPresence"/>): özgün yazı kalkınca çeviri aynı karede kalkar, titreme yok.
/// Ortak deneme dosyası core/Tests/CouchSubsCoreTests/Fixtures/screen-presence.json (Mac ScreenPresenceTests.swift ve Android
/// ScreenPresenceTest.kt aynı vakalar).
/// </summary>
public class ScreenPresenceTests
{
    private static ScreenTranslation.Item Item(string source, bool tracked, double left = 0.1) =>
        new(source, "TR " + source, new TextBox(left, 0.1, left + 0.2, 0.15), 0.04)
        {
            Style = new PhoneTextStyle("#1E1E1E", "#E6E6E6"),
            Look = new TextLook(false, false, "left", true, true),
            Bubble = !tracked,
        };

    [Fact]
    public void SharedPresenceVectors()
    {
        using var document = JsonDocument.Parse(File.ReadAllText(PackFixtures.Path("screen-presence.json")));
        foreach (var vector in document.RootElement.GetProperty("cases").EnumerateArray())
        {
            var name = vector.GetProperty("name").GetString();
            var items = vector.GetProperty("items").EnumerateArray()
                .Select((entry, i) => Item(entry.GetProperty("source").GetString()!, entry.GetProperty("tracked").GetBoolean(), 0.1 + (0.25 * i)))
                .ToList();
            var presence = new ScreenPresence();
            var f = 0;
            foreach (var frame in vector.GetProperty("frames").EnumerateArray())
            {
                var patches = frame.GetProperty("patches").EnumerateArray().ToList();
                var got = presence.Visible(items, box =>
                {
                    var patch = patches[items.FindIndex(item => item.Box == box)];
                    return patch.ValueKind == JsonValueKind.Null ? null : [.. patch.EnumerateArray().Select(v => v.GetInt32())];
                });
                var expect = frame.GetProperty("expect").EnumerateArray().Select(v => v.GetBoolean()).ToList();
                Assert.True(expect.SequenceEqual(got), $"{name} #{f}");
                f++;
            }
        }
    }

    /// <summary>Sunucu: özgün yazısı kalkan öğe TV'ye giden <c>screen</c> olayından aynı karede düşer, geri gelince döner.</summary>
    [Fact]
    public void ServerDropsTranslationWhoseTextLeft()
    {
        using var server = new SubtitleServer(0);
        var events = new List<IReadOnlyList<ScreenTranslation.Item>>();
        server.EventSent += e => { if (e.Kind == SubtitleEventKind.Screen && e.Blocks is { } items) events.Add(items); };
        ScreenTranslation.Item[] items = [Item("MAP", true), Item("BRIEF", true, 0.4)];
        server.SendScreen(items, 10_000);
        var text = Enumerable.Range(0, ScreenPresence.Cols * ScreenPresence.Rows).Select(i => i % 5 == 0 ? 230 : 30).ToArray();
        var flat = Enumerable.Repeat(30, text.Length).ToArray();
        server.Observe(_ => text);
        Assert.Single(events);
        server.Observe(box => box.Left < 0.3 ? flat : text);
        Assert.Equal(["BRIEF"], events[^1].Select(i => i.Source));
        server.SendScreen(items, 10_000);
        Assert.Equal(["BRIEF"], events[^1].Select(i => i.Source));
        server.Observe(_ => text);
        server.Observe(_ => text);
        Assert.Equal(["MAP", "BRIEF"], events[^1].Select(i => i.Source));
    }

    /// <summary>
    /// #1182: çeviri kaldırıldı, takip o sırada değişikliği hesaplamıştı. Kaldırılan çeviri takipten TV'ye yeniden
    /// gönderilmez (Android ScreenPresenceTest ile aynı vaka).
    /// </summary>
    [Fact]
    public void ClearedTranslationIsNotRedrawnByPresence()
    {
        using var server = new SubtitleServer(0);
        var kinds = new List<SubtitleEventKind>();
        server.EventSent += e => kinds.Add(e.Kind);
        ScreenTranslation.Item[] items = [Item("MAP", true), Item("BRIEF", true, 0.4)];
        server.SendScreen(items, 10_000);
        var text = Enumerable.Range(0, ScreenPresence.Cols * ScreenPresence.Rows).Select(i => i % 5 == 0 ? 230 : 30).ToArray();
        var flat = Enumerable.Repeat(30, text.Length).ToArray();
        server.Observe(_ => text);
        // Takip bu karede MAP'in kalktığını görürken çeviri kaldırılıyor.
        server.Observe(box =>
        {
            if (box.Left >= 0.3) return text;
            server.ClearScreen();
            return flat;
        });
        Assert.Equal(SubtitleEventKind.ScreenClear, kinds[^1]);
        server.Observe(_ => text);
        server.Observe(_ => text);
        Assert.Equal(SubtitleEventKind.ScreenClear, kinds[^1]);
    }
}
