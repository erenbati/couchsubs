// SPDX-License-Identifier: AGPL-3.0-only

using System.Text.Json;
using CouchSubs.Core;
using Xunit;

namespace CouchSubs.Core.Tests;

/// <summary>
/// Ekran yazısı çevirisinin oturum boyunca kararlı görünüşü (<see cref="ScreenStyleLock"/>). Ortak deneme dosyası
/// core/Tests/CouchSubsCoreTests/Fixtures/screen-style-lock.json (Mac ScreenStyleLockTests.swift ve Android
/// ScreenStyleLockTest.kt aynı vakalar).
/// </summary>
public class ScreenStyleLockTests
{
    private static ScreenTranslation.Item Item(JsonElement entry)
    {
        var source = entry.GetProperty("source").GetString()!;
        var icons = entry.GetProperty("icons").GetInt32();
        var hasLook = !entry.TryGetProperty("look", out var look) || look.GetBoolean();
        return new ScreenTranslation.Item(source, "TR " + source, new TextBox(0.1, 0.1, 0.3, 0.14), entry.GetProperty("line").GetDouble(),
                                          icons > 0 ? [.. Enumerable.Range(0, icons).Select(i => new IconPlacement(i, "data:image/png;base64,"))] : null)
        {
            Rows = entry.GetProperty("rows").GetInt32(),
            Bubble = entry.TryGetProperty("bubble", out var bubble) && bubble.GetBoolean(),
            Style = new PhoneTextStyle(entry.GetProperty("bg").GetString()!, entry.GetProperty("fg").GetString()!),
            Look = hasLook ? new TextLook(entry.GetProperty("bold").GetBoolean(), entry.GetProperty("condensed").GetBoolean(), "left",
                                          entry.GetProperty("upper").GetBoolean(), true) : null,
        };
    }

    [Fact]
    public void SharedStyleLockVectors()
    {
        using var document = JsonDocument.Parse(File.ReadAllText(PackFixtures.Path("screen-style-lock.json")));
        foreach (var vector in document.RootElement.GetProperty("cases").EnumerateArray())
        {
            var name = vector.GetProperty("name").GetString();
            var lockState = new ScreenStyleLock();
            var s = 0;
            foreach (var step in vector.GetProperty("steps").EnumerateArray())
            {
                var items = step.GetProperty("items").EnumerateArray().Select(Item).ToList();
                var got = lockState.Steady(items, step.GetProperty("now").GetInt64());
                var expect = step.GetProperty("expect").EnumerateArray().ToList();
                Assert.Equal(expect.Count, got.Count);
                for (var k = 0; k < expect.Count; k++)
                {
                    var label = $"{name} #{s}.{k}";
                    Assert.True(Math.Abs(expect[k].GetProperty("line").GetDouble() - got[k].LineHeight) < 1e-9, label);
                    Assert.True(expect[k].GetProperty("fg").GetString() == got[k].Style?.Foreground, label);
                    Assert.True(expect[k].GetProperty("bg").GetString() == got[k].Style?.Background, label);
                    if (got[k].Look is { } l)
                    {
                        Assert.True(expect[k].GetProperty("bold").GetBoolean() == l.Bold, label);
                        Assert.True(expect[k].GetProperty("condensed").GetBoolean() == l.Condensed, label);
                    }
                }
                s++;
            }
        }
    }

    /// <summary>Ölçüt: ±%10 titreyen menüde aynı öğenin boyu/stili kareler arasında hiç değişmez.</summary>
    [Fact]
    public void JitteringMenuNeverChangesLook()
    {
        var lockState = new ScreenStyleLock();
        var random = new Random(7);
        var first = new Dictionary<string, (double, bool, string, string)>();
        for (var frame = 0; frame < 120; frame++)
        {
            var rows = new[] { "MAP", "BRIEF", "PROGRESS", "SETTINGS" }.Select(name =>
                new ScreenTranslation.Item(name, name, new TextBox(0.1, 0.1, 0.2, 0.13), 0.03 * (0.9 + (0.2 * random.NextDouble())))
                {
                    Style = new PhoneTextStyle($"#{random.Next(0, 31):X2}1010", "#FFFFFF"),
                    Look = new TextLook(random.Next(2) == 0, false, "left", true, true),
                }).ToList();
            foreach (var item in lockState.Steady(rows, frame * 500L))
            {
                var look = (item.LineHeight, item.Look!.Bold, item.Style!.Background, item.Style.Foreground);
                if (first.TryGetValue(item.Source, out var seen)) Assert.Equal(seen, look);
                else first[item.Source] = look;
            }
        }
    }
}
