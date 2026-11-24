// SPDX-License-Identifier: AGPL-3.0-only

namespace CouchSubs.Core;

/// <summary>
/// Konuşan adını renklendir: "Mattia: …" satırında yalnız ad ("Mattia:") o konuşana özgü renkte görünür, cümle
/// kullanıcının seçtiği yazı renginde kalır; aynı ad hep aynı renktir. Renk addan hesaplanır (büyük/küçük harf fark
/// etmez): FNV-1a (32 bit, UTF-16 birimleri) → 10 renklik palet. Mac/iPhone (SpeakerColors.swift), Android
/// (SpeakerColors.kt) ve TV uygulaması aynı paleti ve aynı hesabı kullanır. TV'ye <c>subtitle</c> olayının
/// <c>speakerNames</c> alanıyla gider (0.9.79'dan eski TV uygulamaları eski <c>speakers</c> alanıyla bütün satırı boyuyordu;
/// yeni alanı tanımaz, tek renk gösterir).
/// </summary>
public static class SpeakerColors
{
    /// <summary>
    /// Koyu altyazı zemininde okunaklı (kontrast en az 6,5:1) on renk, OKLCH ton çemberinde 36 derece arayla: kırmızı,
    /// turuncu, sarı, açık yeşil, yeşil, turkuaz, mavi, lavanta, mor, pembe (beyaz yok: renksiz satır beyazdır).
    /// Kullanıcı bildirimi (X): eski paletin on renginden üçü mavi, ikisi pembe/mordu ve hepsi soluktu; adlar hep
    /// pembe/mavi tonlarda çıkıyor, karakterler ayırt edilmiyordu (ortak vektör: docs/speaker-colors-vectors.json).
    /// </summary>
    public static readonly IReadOnlyList<string> Palette =
    [
        "#FD736D", "#FEA757", "#FEDD3C", "#9BE759", "#1EE4B2", "#2AD5E5", "#49B5FA", "#8F9BFB", "#D482FF", "#F76AB7",
    ];

    /// <summary>
    /// <see cref="Palette"/> renklerinin OKLCH tonu (derece); renkleri ayırırken kullanılır (<see cref="SpeakerColorBook"/>).
    /// Tamsayı tablo: platformlar tonu renkten hesaplamaz, kayan nokta farkı çıkmaz.
    /// </summary>
    public static readonly IReadOnlyList<int> Hues = [25, 61, 97, 133, 169, 205, 241, 277, 313, 349];

    /// <summary>Adın rengi ("#RRGGBB").</summary>
    public static string Color(string name) => Palette[(int)(Hash(name.Trim().ToLowerInvariant()) % (uint)Palette.Count)];

    /// <summary>FNV-1a (32 bit), UTF-16 birimleri üzerinde.</summary>
    public static uint Hash(string key)
    {
        var hash = 2166136261u;
        foreach (var unit in key)
        {
            hash ^= unit;
            hash = unchecked(hash * 16777619u);
        }
        return hash;
    }

    /// <summary>Metnin satır başlarındaki konuşan adları (<see cref="SpeakerPrefix.Parse"/>), ilk görülme sırasıyla, tekrarsız.</summary>
    public static IReadOnlyList<string> Speakers(string text) =>
        [.. text.Split('\n').Select(line => SpeakerPrefix.Parse(line)?.Name).OfType<string>().Distinct()];

    /// <summary>Gösterilecek metnin bir parçası; <see cref="Color"/> null ise öntanımlı renkte.</summary>
    public readonly record struct Segment(string Text, string? Color);

    /// <summary>
    /// Bölünmüş (satırlara sarılmış) metni parçalara ayırır: <paramref name="names"/>'ten biri satır başında "Ad:" ile
    /// başlıyorsa yalnız "Ad:" o adın rengindedir; cümle ve devam satırları renksizdir, kullanıcının seçtiği yazı renginde
    /// kalır (önceden bütün satır renkleniyor, "Yazı rengi" beyazken altyazı renkli görünüyordu). Ad yoksa tek renksiz parça.
    /// </summary>
    /// <param name="colorOf">Adın rengi (oturumun <see cref="SpeakerColorBook"/>'u); verilmezse <see cref="Color"/>.</param>
    /// <param name="wholeLine">Karakter Adı › "Tüm Satır": ad ve cümle, devam satırlarıyla birlikte sonraki konuşanın adına
    /// dek o konuşanın renginde (Mac, Android ve TV uygulamasıyla aynı).</param>
    public static IReadOnlyList<Segment> Segments(string text, IReadOnlyList<string> names, Func<string, string?>? colorOf = null, bool wholeLine = false)
    {
        if (names.Count == 0) return [new Segment(text, null)];
        var result = new List<Segment>();
        var start = 0;
        var lineStart = 0;
        string? running = null;
        while (lineStart <= text.Length)
        {
            var found = names.Where(name => NameEnd(text, lineStart, name) > 0).OrderByDescending(name => name.Length).FirstOrDefault();
            if (found is not null)
            {
                var end = NameEnd(text, lineStart, found);
                var color = colorOf is null ? Color(found) : colorOf(found);
                if (lineStart > start) result.Add(new Segment(text[start..lineStart], running));
                if (wholeLine)
                {
                    running = color;
                    start = lineStart;
                }
                else
                {
                    result.Add(new Segment(text[lineStart..end], color));
                    start = end;
                }
            }
            var next = text.IndexOf('\n', lineStart);
            if (next < 0) break;
            lineStart = next + 1;
        }
        if (start < text.Length) result.Add(new Segment(text[start..], running));
        return result;
    }

    /// <summary>Satır <paramref name="at"/>'te "Ad:" ile başlıyorsa iki noktadan sonraki konum; değilse 0.</summary>
    private static int NameEnd(string text, int at, string name)
    {
        if (string.CompareOrdinal(text, at, name, 0, name.Length) != 0) return 0;
        var rest = at + name.Length;
        if (rest < text.Length && text[rest] == ' ') rest++;
        return rest < text.Length && text[rest] is ':' or '：' ? rest + 1 : 0;
    }
}
