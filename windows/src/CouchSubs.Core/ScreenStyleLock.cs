// SPDX-License-Identifier: AGPL-3.0-only

namespace CouchSubs.Core;

/// <summary>
/// "Ekranı çevir" ve otomatik ekran yazısında çevirinin görünüşü oturum boyunca kararlı (Mac: CouchSubsCore/ScreenStyleLock.swift,
/// Android: ScreenStyleLock.kt; aynı kural, aynı eşikler). Öğe türü başına (tuş ipucu, çok satırlı metin, BÜYÜK HARF başlık/sekme,
/// düz etiket) yazı boyu, kalınlık, dar aile ve renkler ilk ölçümde kilitlenir. Kilitli boya <see cref="SizeShare"/> içinde yakın
/// ölçüm kilitli boyla çizilir; aynı karede kilitli boya uyan öğe varken uymayan öğe ayrı boydur, hemen kilitlenir. Türün hiçbir
/// öğesi uymuyorsa değişim ancak kesintisiz <see cref="SettleMs"/> sürerse benimsenir. Renk çifti kilitli bir çifte
/// <see cref="ColorSlack"/> içinde yakınsa o çift çizilir. Telefon kartı, balonlar, sohbet paneli ve özgün stili olmayan öğe kilide
/// girmez. Ortak deneme dosyası core/Tests/CouchSubsCoreTests/Fixtures/screen-style-lock.json.
/// </summary>
public sealed class ScreenStyleLock
{
    public const double SizeShare = PhonePanelSteady.SizeShare;
    public const long SettleMs = PhonePanelSteady.SettleMs;
    public const double SameLine = ScreenFit.SameLine;
    public const int ColorSlack = 40;
    internal const int PaletteLimit = 32;
    internal const int SeenLimit = 256;

    private sealed record Tier(double Line, bool Bold, bool Condensed);

    private sealed class Kind
    {
        internal List<Tier> Tiers = [];
        internal long? Since;
        /// <summary>Öğenin (özgün yazısıyla) son çizildiği boy.</summary>
        internal Dictionary<string, int> Seen = [];
    }

    private readonly Dictionary<string, Kind> kinds = [];
    private readonly Dictionary<string, List<PhoneTextStyle>> palettes = [];

    internal static string? Role(ScreenTranslation.Item item)
    {
        if (item.Look is not { } look || !ScreenFit.TakesPart(item) || item.Panel is not null || item.LineHeight <= 0) return null;
        if (item.Icons is { Count: > 0 }) return "hint";
        if (item.Rows > 1 || item.Paragraphs) return "body";
        return look.Upper ? "caps" : "label";
    }

    /// <summary>Öğeler kilitli görünüşle. <paramref name="now"/>: milisaniye (tekdüze saat).</summary>
    public IReadOnlyList<ScreenTranslation.Item> Steady(IReadOnlyList<ScreenTranslation.Item> items, long now)
    {
        var result = items.ToList();
        var roles = items.Select(Role).ToList();
        foreach (var role in roles.OfType<string>().Distinct().OrderBy(r => r, StringComparer.Ordinal))
        {
            var members = Enumerable.Range(0, items.Count).Where(i => roles[i] == role).ToList();
            if (!kinds.TryGetValue(role, out var kind)) kind = new Kind();
            double Off(double line, int t) => Math.Abs(line / kind.Tiers[t].Line - 1);
            // Öğenin boyu: önceki karede çizildiği boy hâlâ uyuyorsa o (eş boylar arasında gidip gelmesin), yoksa en yakın uyan boy.
            int? TierOf(int i)
            {
                var line = items[i].LineHeight;
                if (kind.Seen.TryGetValue(items[i].Source, out var seen) && seen < kind.Tiers.Count && Off(line, seen) <= SizeShare) return seen;
                int? best = null;
                for (var t = 0; t < kind.Tiers.Count; t++)
                    if (Off(line, t) <= SizeShare && (best is null || Off(line, t) < Off(line, best.Value))) best = t;
                return best;
            }
            void Adopt(List<int> fresh)
            {
                foreach (var (tier, group) in Tiers([.. fresh.Select(i => items[i])]))
                {
                    foreach (var k in group) kind.Seen[items[fresh[k]].Source] = kind.Tiers.Count;
                    kind.Tiers.Add(tier);
                }
            }
            var matched = members.Where(i => TierOf(i) is not null).ToList();
            if (kind.Tiers.Count == 0) Adopt(members);
            else if (matched.Count == 0)
            {
                // Türün hiçbir öğesi kilitli boya uymuyor: ölçek değişimi adayı.
                if (kind.Since is { } since && now - since >= SettleMs)
                {
                    kind = new Kind();
                    Adopt(members);
                }
                else kind.Since ??= now;
            }
            else
            {
                kind.Since = null;
                // Uyan öğe varken uymayan öğe aynı ekranda başka boydaki öğedir (başlık ve satır).
                var fresh = members.Where(i => TierOf(i) is null).ToList();
                if (fresh.Count > 0) Adopt(fresh);
            }
            if (kind.Seen.Count > SeenLimit) kind.Seen.Clear();
            foreach (var i in members)
            {
                var line = items[i].LineHeight;
                var found = TierOf(i);
                var index = found ?? Enumerable.Range(0, kind.Tiers.Count).OrderBy(t => Off(line, t)).First();
                if (found is not null) kind.Seen[items[i].Source] = index;
                var locked = kind.Tiers[index];
                var item = result[i];
                result[i] = item with
                {
                    LineHeight = locked.Line,
                    Look = item.Look! with { Bold = locked.Bold, Condensed = locked.Condensed },
                    Style = item.Style is { } style ? Palette(style, role) : null,
                };
            }
            kinds[role] = kind;
        }
        return result;
    }

    /// <summary>
    /// Bir karedeki öğelerin boyları: yakın boylar (<see cref="SameLine"/>) tek boyda, değeri ortanca öğeninki; her boyun
    /// öğeleri (verilen listedeki sıraları).
    /// </summary>
    private static List<(Tier Tier, List<int> Group)> Tiers(List<ScreenTranslation.Item> items)
    {
        var groups = new List<List<int>>();
        foreach (var i in Enumerable.Range(0, items.Count).OrderBy(i => items[i].LineHeight))
        {
            if (groups.Count > 0 && items[i].LineHeight <= items[groups[^1][0]].LineHeight * (1 + SameLine)) groups[^1].Add(i);
            else groups.Add([i]);
        }
        return [.. groups.Select(group =>
        {
            var middle = items[group[(group.Count - 1) / 2]];
            return (new Tier(middle.LineHeight, middle.Look?.Bold ?? false, middle.Look?.Condensed ?? false), group);
        })];
    }

    private PhoneTextStyle Palette(PhoneTextStyle style, string role)
    {
        if (!palettes.TryGetValue(role, out var known)) palettes[role] = known = [];
        var found = known.FirstOrDefault(p => Near(p.Background, style.Background) && Near(p.Foreground, style.Foreground));
        if (found is not null) return found;
        known.Add(style);
        if (known.Count > PaletteLimit) known.RemoveAt(0);
        return style;
    }

    internal static bool Near(string a, string b)
    {
        if (Rgb(a) is not { } x || Rgb(b) is not { } y) return a == b;
        return Math.Abs(x.R - y.R) <= ColorSlack && Math.Abs(x.G - y.G) <= ColorSlack && Math.Abs(x.B - y.B) <= ColorSlack;
    }

    private static (int R, int G, int B)? Rgb(string hex)
    {
        if (hex.Length != 7 || hex[0] != '#'
            || !int.TryParse(hex.AsSpan(1), System.Globalization.NumberStyles.HexNumber, null, out var value)) return null;
        return ((value >> 16) & 0xFF, (value >> 8) & 0xFF, value & 0xFF);
    }

    /// <summary>Oturum bitti: sonraki öğeler yeniden ölçülür.</summary>
    public void Reset()
    {
        kinds.Clear();
        palettes.Clear();
    }
}
