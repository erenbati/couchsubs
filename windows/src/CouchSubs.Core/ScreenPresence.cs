// SPDX-License-Identifier: AGPL-3.0-only

namespace CouchSubs.Core;

/// <summary>
/// Ekran yazısı çevirisinin takibi (Mac: CouchSubsCore/ScreenPresence.swift, Android: ScreenPresence.kt; aynı kural, aynı
/// eşikler): her karede, çevirisi gösterilen her öğenin kutusunun küçük gri izi (<see cref="Cols"/> x <see cref="Rows"/>) ilk
/// görüldüğü izle karşılaştırılır (Pearson ilintisinin büyüklüğü; seçim gezince ters dönen renk aynı yazıdır). İz düzleşti
/// ya da ilinti <see cref="InstantCorrelation"/>'ın altında: çeviri aynı karede kalkar. <see cref="GoneCorrelation"/>'ın altında
/// <see cref="SettleFrames"/> kare kalırsa da kalkar; <see cref="BackCorrelation"/>'a <see cref="SettleFrames"/> kare çıkarsa geri
/// gelir. İlk izi düz öğe hemen yok sayılır. Telefon kartı, balonlar, sohbet paneli ve özgün stili olmayan öğe izlenmez.
/// Ortak deneme dosyası core/Tests/CouchSubsCoreTests/Fixtures/screen-presence.json.
/// </summary>
public sealed class ScreenPresence
{
    public const int Cols = 24;
    public const int Rows = 6;
    public const double GoneCorrelation = 0.5;
    public const double InstantCorrelation = 0.3;
    public const double BackCorrelation = 0.8;
    public const int SettleFrames = 2;
    public const double FlatDeviation = 6.0;

    private sealed class Entry(int[] reference, bool visible)
    {
        internal int[] Reference { get; } = reference;
        internal bool Visible { get; set; } = visible;
        internal int Streak { get; set; }
    }

    private Dictionary<string, Entry> entries = [];

    public static bool Tracks(ScreenTranslation.Item item) => item.Look is not null && ScreenFit.TakesPart(item) && item.Panel is null;

    private static string Key(ScreenTranslation.Item item)
    {
        static long R(double v) => (long)Math.Round(v * 1000, MidpointRounding.AwayFromZero);
        return $"{item.Source}|{R(item.Box.Left)},{R(item.Box.Top)},{R(item.Box.Right)},{R(item.Box.Bottom)}";
    }

    /// <summary>İki izin ilintisinin büyüklüğü (0…1); biri düzse null.</summary>
    internal static double? Correlation(IReadOnlyList<int> a, IReadOnlyList<int> b)
    {
        if (a.Count != b.Count || a.Count == 0) return null;
        double n = a.Count, ma = a.Sum() / n, mb = b.Sum() / n, sab = 0, saa = 0, sbb = 0;
        for (var i = 0; i < a.Count; i++)
        {
            double x = a[i] - ma, y = b[i] - mb;
            sab += x * y;
            saa += x * x;
            sbb += y * y;
        }
        if (Math.Sqrt(saa / n) < FlatDeviation || Math.Sqrt(sbb / n) < FlatDeviation) return null;
        return Math.Abs(sab / Math.Sqrt(saa * sbb));
    }

    private static bool Flat(IReadOnlyList<int> a)
    {
        if (a.Count == 0) return true;
        double n = a.Count, m = a.Sum() / n;
        return Math.Sqrt(a.Sum(v => (v - m) * (v - m)) / n) < FlatDeviation;
    }

    /// <summary>
    /// Bu karede görünür olan öğeler. <paramref name="patch"/>: öğenin kutusunun bu karedeki izi (null: kutu karenin dışında,
    /// öğe görünür kalır). Listede olmayan öğeler unutulur.
    /// </summary>
    public IReadOnlyList<bool> Visible(IReadOnlyList<ScreenTranslation.Item> items, Func<TextBox, IReadOnlyList<int>?> patch)
    {
        var kept = new Dictionary<string, Entry>();
        var result = new List<bool>(items.Count);
        foreach (var item in items)
        {
            if (!Tracks(item)) { result.Add(true); continue; }
            var key = Key(item);
            var now = patch(item.Box);
            if (now is null)
            {
                if (entries.TryGetValue(key, out var old)) kept[key] = old;
                result.Add(old?.Visible ?? true);
                continue;
            }
            if (!kept.TryGetValue(key, out var entry) && !entries.TryGetValue(key, out entry))
            {
                entry = new Entry([.. now], !Flat(now));
                kept[key] = entry;
                result.Add(entry.Visible);
                continue;
            }
            var score = Correlation(entry.Reference, now) ?? 0;
            var flips = entry.Visible ? score < GoneCorrelation : score >= BackCorrelation;
            entry.Streak = flips ? entry.Streak + 1 : 0;
            // Yazı silindi (iz düz) ya da yerinde bambaşka yazı var: beklemeden, bu karede kalkar.
            var instant = entry.Visible && score < InstantCorrelation;
            if (instant || entry.Streak >= SettleFrames)
            {
                entry.Visible = !entry.Visible;
                entry.Streak = 0;
            }
            kept[key] = entry;
            result.Add(entry.Visible);
        }
        entries = kept;
        return result;
    }

    /// <summary>Öğenin özgün yazısı kalktı mı (son karede yok sayıldı).</summary>
    public bool Hidden(ScreenTranslation.Item item) => Tracks(item) && entries.TryGetValue(Key(item), out var entry) && !entry.Visible;

    /// <summary>Kutunun izi: kutu <see cref="Cols"/> x <see cref="Rows"/> ızgaraya bölünür, her hücrenin ortasının parlaklığı.</summary>
    public static IReadOnlyList<int>? Patch(Frame frame, TextBox box)
    {
        if (!frame.IsConsistent || frame.Width == 0 || frame.Height == 0) return null;
        double x0 = box.Left * frame.Width, y0 = box.Top * frame.Height;
        double w = (box.Right - box.Left) * frame.Width, h = (box.Bottom - box.Top) * frame.Height;
        if (w < 2 || h < 2) return null;
        var values = new int[Cols * Rows];
        for (var r = 0; r < Rows; r++)
            for (var c = 0; c < Cols; c++)
            {
                var x = Math.Clamp((int)(x0 + ((c + 0.5) * w / Cols)), 0, frame.Width - 1);
                var y = Math.Clamp((int)(y0 + ((r + 0.5) * h / Rows)), 0, frame.Height - 1);
                var p = (y * frame.Stride) + (x * 4);
                values[(r * Cols) + c] = ((frame.Pixels[p + 2] * 299) + (frame.Pixels[p + 1] * 587) + (frame.Pixels[p] * 114)) / 1000;
            }
        return values;
    }

    public void Reset() => entries = [];
}
