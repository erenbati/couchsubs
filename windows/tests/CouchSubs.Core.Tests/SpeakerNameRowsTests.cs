// SPDX-License-Identifier: AGPL-3.0-only
namespace CouchSubs.Core.Tests;

/// <summary>
/// Kullanıcı bildirimi (X): konuşan adı ("Lucia: …") diyalogların yalnız ~%20'sinde gösteriliyor, kalanında düşüyordu.
/// Yazı tanıma oyunun renkli adını cümleden ayrı satır okuyabiliyor. Ad cümlenin üstünde ayrı satır kalınca, aynı kişi
/// konuşmayı sürdürdükçe değişmeden durduğu için görev/HUD satırı sayılıp atılıyor (ad yalnız konuşan değişince, ilk
/// replikte görünüyordu); aynı satırda ama kutusu kaymış okunan ad ise ayrı blok sayılıp hiç gösterilmiyordu
/// (Mac/iPhone: SpeakerNameRowsTests.swift, Android: SpeakerNameRowsTest.kt).
/// </summary>
public class SpeakerNameRowsTests
{
    private sealed class Translator : ITextTranslator
    {
        public List<string> Requested { get; } = [];
        public Task<string> TranslateAsync(string text, CancellationToken cancellationToken = default)
        {
            lock (Requested)
            {
                Requested.Add(text);
                return Task.FromResult($"Çeviri {Requested.Count}.");
            }
        }
    }

    private static readonly (string Name, string Body)[] Dialog =
    [
        ("Lucia", "Could I have another ice water, please?"), ("Lucia", "It is so hot out there today."),
        ("Lucia", "I think I need to sit down."), ("Jason", "Just be quiet. Donnie's up."),
        ("Jason", "We gotta go now, come on."), ("Lucia", "Okay, okay."),
    ];

    private static readonly string[] Expected =
        ["Lucia: Çeviri 1.", "Lucia: Çeviri 2.", "Lucia: Çeviri 3.", "Jason: Çeviri 4.", "Jason: Çeviri 5.", "Lucia: Çeviri 6."];

    /// <summary>Her replik 17 kare (150 ms arayla ~2,5 sn) ekranda; kutular bütün kareye oranla (gerçek kare gta6-08-jason'ın yerleri).</summary>
    private static async Task<List<string>> Replay(Func<string, string, TextLine[]> shape)
    {
        long clock = 0;
        var frames = Dialog.SelectMany(line => Enumerable.Repeat(new Reading(shape(line.Name, line.Body)), 17)).ToList();
        var sender = new FakeSender();
        var pipeline = new SubtitlePipeline(new SequenceReader(frames), new Translator(), sender, clock: () => clock);
        for (var i = 0; i < frames.Count; i++)
        {
            await pipeline.ProcessAsync(Frame.Blank(64, 64), new CropRegion(0, 1, 0, 1));
            await pipeline.WaitForTranslationsAsync();
            clock += 150;
        }
        return sender.Sent;
    }

    [Fact]
    public async Task NameOnItsOwnRowAboveKeepsTheNameOnEveryLine()
    {
        var sent = await Replay((name, body) =>
        [
            new TextLine($"{name}:", new TextBox(0.47, 0.83, 0.53, 0.865)),
            new TextLine(body, new TextBox(0.33, 0.875, 0.67, 0.925)),
        ]);
        Assert.Equal(Expected, sent);
    }

    [Fact]
    public async Task NameReadApartOnTheSameRowIsJoined()
    {
        var sent = await Replay((name, body) =>
        [
            new TextLine($"{name}:", new TextBox(0.338, 0.862, 0.397, 0.905)),
            new TextLine(body, new TextBox(0.47, 0.872, 0.665, 0.927)),
        ]);
        Assert.Equal(Expected, sent);
    }

    [Fact]
    public async Task InlineNameStillWorks()
    {
        var sent = await Replay((name, body) => [new TextLine($"{name}: {body}", new TextBox(0.335, 0.87, 0.665, 0.927))]);
        Assert.Equal(Expected, sent);
    }

    [Fact]
    public void NameOnlyLines()
    {
        Assert.Equal("Lucia", SpeakerPrefix.NameOnly("Lucia:"));
        Assert.Equal("JASON", SpeakerPrefix.NameOnly(" JASON : "));
        Assert.Equal("CO Wilson", SpeakerPrefix.NameOnly("CO Wilson："));
        Assert.Equal("Dre'Quan", SpeakerPrefix.NameOnly("Dre'Quan:"));
        foreach (var line in new[] { "Note:", "Objective:", "Lucia: Wait.", "lucia:", "10:", "Lucia", "Very Long Name Of Four:", "" })
            Assert.Null(SpeakerPrefix.NameOnly(line));
        // Büyük harfli ad ve iki noktadan sonra boşluksuz okuma da ad sayılır.
        Assert.Equal(new SpeakerPrefix.Split("LUCIA", "COULD I HAVE ANOTHER?"), SpeakerPrefix.Parse("LUCIA: COULD I HAVE ANOTHER?"));
        Assert.Equal(new SpeakerPrefix.Split("Lucia", "Could I have another?"), SpeakerPrefix.Parse("Lucia:Could I have another?"));
    }

    [Fact]
    public void JoiningRowsAttachesTheNameToItsSentence()
    {
        var above = new Reading(
        [
            new TextLine("Lucia:", new TextBox(0.45, 0.60, 0.55, 0.70)),
            new TextLine("We don't have a car,", new TextBox(0.20, 0.72, 0.80, 0.82)),
            new TextLine("food or clothes.", new TextBox(0.30, 0.84, 0.70, 0.94)),
        ]);
        var joined = above.JoiningRows();
        Assert.Equal(new[] { "Lucia: We don't have a car,", "food or clothes." }, joined.Lines.Select(line => line.Text));
        // Kutu cümlenin satırıdır (yatayda adı da kapsar).
        Assert.Equal(new TextBox(0.20, 0.72, 0.80, 0.82), joined.Lines[0].Box);

        // Yerleri bilinmeyen okuma: ad alttaki satıra katılır.
        Assert.Equal("JASON: What the hell was that?", Reading.FromText("JASON:\nWhat the hell was that?").JoiningRows().Text);

        // Ad değil ("Note:"), altında cümle yok, cümle çok uzakta, yatayda başka yerde ya da alttaki zaten adlı: dokunulmaz.
        Reading[] untouched =
        [
            new([new TextLine("Note:", new TextBox(0.45, 0.60, 0.55, 0.70)), new TextLine("The gate is shut.", new TextBox(0.30, 0.72, 0.70, 0.82))]),
            new([new TextLine("Lucia:", new TextBox(0.45, 0.60, 0.55, 0.70)), new TextLine("42", new TextBox(0.45, 0.72, 0.55, 0.82))]),
            new([new TextLine("Lucia:", new TextBox(0.45, 0.20, 0.55, 0.30)), new TextLine("Could I have another?", new TextBox(0.30, 0.72, 0.70, 0.82))]),
            new([new TextLine("Lucia:", new TextBox(0.05, 0.60, 0.12, 0.70)), new TextLine("Could I have another?", new TextBox(0.30, 0.72, 0.70, 0.82))]),
            new([new TextLine("Lucia:", new TextBox(0.45, 0.60, 0.55, 0.70)), new TextLine("Jason: Not now.", new TextBox(0.30, 0.72, 0.70, 0.82))]),
        ];
        foreach (var reading in untouched)
            Assert.Equal(reading.Lines.Select(line => line.Text), reading.JoiningRows().Lines.Select(line => line.Text));
    }
}
