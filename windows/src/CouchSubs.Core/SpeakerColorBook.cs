// SPDX-License-Identifier: AGPL-3.0-only

namespace CouchSubs.Core;

/// <summary>
/// Konuşana göre renk (v3): oturum boyunca (çeviri başlayınca sıfırlanır) her kişiye bir renk. Yazı tanımanın yakın
/// okuması aynı kişidir ("Mattia", "Mattla", "Mattia." aynı renk). Yeni kişi addan hesaplanan tabanı alır; taban başka
/// birinin rengiyse ya da tonu onlarınkine <see cref="MinHueGap"/> dereceden yakınsa, kullanılmayan renklerden tonu
/// kullanılanlara en uzak olan verilir (konuşan iki kişi yan yana karışmasın; ikinci kişi çoğu zaman karşı tonu alır).
/// Kurallar ve ortak test vektörü: scripts/speaker_colors_ref.py, docs/speaker-colors-vectors.json (Mac/iPhone ve Android
/// aynı sırada aynı rengi verir).
/// </summary>
public sealed class SpeakerColorBook
{
    /// <summary>Yeni kişinin tabanı, kullanılan renklerin tonlarına en az bu kadar (derece) uzaksa olduğu gibi alınır.</summary>
    public const int MinHueGap = 72;

    private readonly object gate = new();
    private readonly List<(string Key, string Color)> people = [];
    /// <summary>"Tek Renk"te herkesin rengi; "Karaktere Göre"de kullanıcının seçtiği kişi renkleri (anahtar küçük harfli ad).</summary>
    private string? fixedColor;
    private Dictionary<string, string> overrides = [];

    /// <summary>Altyazı Görünümü › Karakter Adı (Mac SpeakerColorBook.configure ile aynı).</summary>
    public void Configure(string? fixedColor, IReadOnlyDictionary<string, string> chosen)
    {
        var normalized = new Dictionary<string, string>();
        foreach (var (name, color) in chosen) normalized[Key(name)] = color;
        lock (gate)
        {
            this.fixedColor = fixedColor;
            overrides = normalized;
        }
    }

    /// <summary>Bu oturumda rengi verilmiş kişiler (adın anahtarı ve rengi), ilk görülen önce (Mac SpeakerColorBook.known).</summary>
    public IReadOnlyList<(string Key, string Color)> Known
    {
        get { lock (gate) return [.. people]; }
    }

    /// <summary>Adın rengi; bilinmeyen kişi eklenir. Ad boşsa null.</summary>
    public string? Color(string name)
    {
        var key = Key(name);
        if (key.Length == 0) return null;
        lock (gate)
        {
            if (fixedColor is not null) return fixedColor;
            var chosen = overrides.TryGetValue(key, out var exact) ? exact
                : overrides.FirstOrDefault(entry => SamePerson(entry.Key, key)).Value;
            if (chosen is not null)
            {
                if (!people.Any(person => SamePerson(person.Key, key))) people.Add((key, chosen));
                return chosen;
            }
            foreach (var (known, color) in people)
                if (SamePerson(known, key)) return color;
            var palette = SpeakerColors.Palette;
            var used = people.Select(person => IndexOf(palette, person.Color)).Where(index => index >= 0).ToList();
            var pick = palette[Pick((int)(SpeakerColors.Hash(key) % (uint)palette.Count), used)];
            people.Add((key, pick));
            return pick;
        }
    }

    /// <summary>
    /// Yeni kişinin palet sırası: <paramref name="base0"/> kullanılmıyor ve kullanılan her tondan en az
    /// <see cref="MinHueGap"/> uzaksa o; değilse kullanılmayanlardan kullanılanlara en uzak tonlu olan (eşitlikte tabandan
    /// palet sırasıyla ilki); hepsi kullanılıyorsa taban. <paramref name="used"/>: kullanılan renklerin palet sıraları
    /// (kullanıcının seçtiği palet dışı renk sayılmaz). Mac (SpeakerColorBook.pick) ve Android ile aynı.
    /// </summary>
    internal static int Pick(int base0, IReadOnlyList<int> used)
    {
        if (used.Count == 0) return base0;
        if (!used.Contains(base0) && HueGap(base0, used) >= MinHueGap) return base0;
        var count = SpeakerColors.Palette.Count;
        int? best = null;
        for (var step = 0; step < count; step++)
        {
            var index = (base0 + step) % count;
            if (used.Contains(index)) continue;
            if (best is null || HueGap(index, used) > HueGap(best.Value, used)) best = index;
        }
        return best ?? base0;
    }

    /// <summary><paramref name="index"/> renginin tonunun kullanılan renklerin tonlarına en yakın uzaklığı (derece, çember üzerinde).</summary>
    internal static int HueGap(int index, IReadOnlyList<int> used)
    {
        var hues = SpeakerColors.Hues;
        var gap = 360;
        foreach (var other in used)
        {
            var difference = Math.Abs(hues[index] - hues[other]);
            gap = Math.Min(gap, Math.Min(difference, 360 - difference));
        }
        return gap;
    }

    private static int IndexOf(IReadOnlyList<string> palette, string color)
    {
        for (var i = 0; i < palette.Count; i++)
            if (palette[i] == color) return i;
        return -1;
    }

    /// <summary>Çeviri yeniden başladı: kişiler unutulur.</summary>
    public void Reset()
    {
        lock (gate) people.Clear();
    }

    /// <summary>Ad anahtarı: kırpılmış, sondaki noktalaması atılmış, küçük harf.</summary>
    public static string Key(string name) => name.Trim().TrimEnd('.', ',', '!', '?', ';', ':', '…').Trim().ToLowerInvariant();

    private static bool SamePerson(string a, string b) =>
        a == b || Confusable(a) == Confusable(b) || (Math.Min(a.Length, b.Length) >= 5 && Distance(a, b) <= 1);

    /// <summary>Yazı tanımanın karıştırdığı harfler eşitlenir: l/1/| → i, 0 → o, rn → m.</summary>
    private static string Confusable(string key) => string.Concat(key.Replace("rn", "m").Select(c => c switch
    {
        'l' or '1' or '|' => 'i',
        '0' => 'o',
        _ => c,
    }));

    private static int Distance(string a, string b)
    {
        var row = Enumerable.Range(0, b.Length + 1).ToArray();
        for (var i = 1; i <= a.Length; i++)
        {
            var previous = (int[])row.Clone();
            row[0] = i;
            for (var j = 1; j <= b.Length; j++)
                row[j] = Math.Min(Math.Min(previous[j] + 1, row[j - 1] + 1), previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1));
        }
        return row[b.Length];
    }
}
