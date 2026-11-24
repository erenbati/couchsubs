// SPDX-License-Identifier: AGPL-3.0-only

using System.Text.Json;
using CouchSubs.Core;
using Xunit;

namespace CouchSubs.Core.Tests;

/// <summary>
/// Çapa takibi (<see cref="ScreenAnchor"/>): telefonun/kartın dörtgeni her karede alt piksel izlenir. Ortak deneme dosyası
/// core/Tests/CouchSubsCoreTests/Fixtures/screen-anchor.json (Mac ScreenAnchorTests.swift ve Android ScreenAnchorTest.kt aynı vakalar).
/// </summary>
public class ScreenAnchorTests
{
    private static ScreenAnchor.Motion Motion(JsonElement values)
    {
        var v = values.EnumerateArray().Select(e => e.GetDouble()).ToArray();
        return new ScreenAnchor.Motion(v[0], v[1], v[2], v[3], v[4], v[5], v[6], v[7]);
    }

    private static ScreenAnchor.Rect Rect(JsonElement values)
    {
        var r = values.EnumerateArray().Select(e => e.GetDouble()).ToArray();
        return new ScreenAnchor.Rect(r[0], r[1], r[2], r[3]);
    }

    /// <summary>Ortak kurala göre yapay kare (bkz. fixture note).</summary>
    internal static ScreenAnchor.Gray Render(int width, int height, ScreenAnchor.Rect rect, ScreenAnchor.Motion m, int frame, double gain, double[]? content)
    {
        double cx = rect.CenterX, cy = rect.CenterY;
        var inverse = ScreenAnchor.Invert3(new[] { m.A, m.B, m.Dx, m.C, m.D, m.Dy, m.G, m.H, 1.0 })!;
        var pixels = new byte[width * height];
        var offsets = new[] { (0.25, 0.25), (0.75, 0.25), (0.25, 0.75), (0.75, 0.75) };
        for (var y = 0; y < height; y++)
        {
            for (var x = 0; x < width; x++)
            {
                double sum = 0;
                foreach (var (sx, sy) in offsets)
                {
                    double fx = x + sx - 0.5, fy = y + sy - 0.5;
                    double px = fx - cx, py = fy - cy;
                    var w = (inverse[6] * px) + (inverse[7] * py) + inverse[8];
                    var u = ((inverse[0] * px) + (inverse[1] * py) + inverse[2]) / w;
                    var v = ((inverse[3] * px) + (inverse[4] * py) + inverse[5]) / w;
                    double value;
                    if (Math.Abs(u) <= rect.Width / 2 && Math.Abs(v) <= rect.Height / 2)
                    {
                        value = content is { } c && u >= c[0] && v >= c[1] && u <= c[2] && v <= c[3]
                            ? 120 + (60 * Math.Sin((0.33 * u) + (0.11 * v)))
                            : 128 + (50 * Math.Sin(0.21 * u) * Math.Cos(0.17 * v)) + (40 * Math.Sin(0.05 * (u + (2 * v))));
                    }
                    else
                    {
                        value = 60 + (30 * Math.Sin((0.13 * fx) + (0.07 * fy) + (0.4 * frame)));
                    }
                    sum += value;
                }
                pixels[(y * width) + x] = (byte)Math.Max(0, Math.Min(255, Math.Round(sum / 4 * gain, MidpointRounding.AwayFromZero)));
            }
        }
        return new ScreenAnchor.Gray(width, height, pixels);
    }

    [Fact]
    public void SharedTrackingVectors()
    {
        using var document = JsonDocument.Parse(File.ReadAllText(PackFixtures.Path("screen-anchor.json")));
        foreach (var vector in document.RootElement.GetProperty("cases").EnumerateArray())
        {
            var name = vector.GetProperty("name").GetString();
            var rect = Rect(vector.GetProperty("rect"));
            int width = vector.GetProperty("width").GetInt32(), height = vector.GetProperty("height").GetInt32();
            var tolerance = vector.GetProperty("tolerance").GetDouble();
            var gains = vector.TryGetProperty("gain", out var g) ? g.EnumerateArray().Select(e => e.GetDouble()).ToArray() : null;
            var content = vector.TryGetProperty("content", out var c) ? c.EnumerateArray().Select(e => e.GetDouble()).ToArray() : null;
            var contentFrom = vector.TryGetProperty("contentFrom", out var cf) ? cf.GetInt32() : int.MaxValue;
            var lostFrom = vector.TryGetProperty("lostFrom", out var lf) ? lf.GetInt32() : int.MaxValue;
            var motions = vector.GetProperty("motions").EnumerateArray().Select(Motion).ToList();
            var tracker = new ScreenAnchor.Tracker();
            for (var k = 0; k < motions.Count; k++)
            {
                var frame = Render(width, height, rect, motions[k], k, gains?[k] ?? 1, k >= contentFrom ? content : null);
                if (k == 0)
                {
                    tracker.Begin(frame, rect);
                    continue;
                }
                var fix = tracker.Track(frame);
                if (k >= lostFrom)
                {
                    Assert.True(fix == null, $"{name} #{k}");
                    break;
                }
                Assert.True(fix != null, $"{name} #{k}: çapa kayboldu");
                var error = fix!.Value.Motion.Distance(motions[k], rect);
                Assert.True(error < tolerance, $"{name} #{k}: {error}");
            }
        }
    }

    [Fact]
    public void SharedSmootherVectors()
    {
        using var document = JsonDocument.Parse(File.ReadAllText(PackFixtures.Path("screen-anchor.json")));
        foreach (var vector in document.RootElement.GetProperty("smoother").EnumerateArray())
        {
            var rect = Rect(vector.GetProperty("rect"));
            var smoother = new ScreenAnchor.Smoother();
            var k = 0;
            foreach (var step in vector.GetProperty("steps").EnumerateArray())
            {
                var got = smoother.Push(Motion(step.GetProperty("raw")), rect);
                Assert.Equal(Motion(step.GetProperty("shown")), got.Motion);
                Assert.True(step.GetProperty("jumped").GetBoolean() == got.Jumped, $"#{k}");
                k++;
            }
        }
    }

    [Fact]
    public void GrayFromRgba()
    {
        var bytes = Enumerable.Repeat((byte)255, 4 * 4 * 4).ToArray();
        bytes[0] = 0; bytes[1] = 0; bytes[2] = 0;
        bytes[^4] = 80; bytes[^3] = 40; bytes[^2] = 0;
        var gray = ScreenAnchor.Gray.FromRgba(bytes, 4, 4, targetWidth: 2);
        Assert.Equal(2, gray.Width);
        Assert.Equal(2, gray.Height);
        Assert.Equal(new byte[] { 191, 255, 255, 203 }, gray.Pixels);
        Assert.Equal(new byte[] { 191, 255, 255, 200 }, ScreenAnchor.Gray.FromRgba(bytes, 4, 4, bgr: true, targetWidth: 2).Pixels);
    }
}
