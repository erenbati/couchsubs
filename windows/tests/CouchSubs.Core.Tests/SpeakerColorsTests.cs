// SPDX-License-Identifier: AGPL-3.0-only

using CouchSubs.Core;

namespace CouchSubs.Core.Tests;

/// <summary>Mac SpeakerColorsTests, Android SpeakerColorsTest ve TV uygulamasıyla aynı renkler.</summary>
public class SpeakerColorsTests
{
    [Theory]
    [InlineData("Mattia", "#F76AB7")]
    [InlineData("MATTIA", "#F76AB7")]
    [InlineData(" mattia ", "#F76AB7")]
    [InlineData("Lucia", "#2AD5E5")]
    [InlineData("Jason", "#49B5FA")]
    [InlineData("Cal", "#FEA757")]
    public void ColorComesFromTheName(string name, string color) => Assert.Equal(color, SpeakerColors.Color(name));

    [Fact]
    public void PaletteHasTenDistinctColorsWithoutWhite()
    {
        Assert.Equal(10, SpeakerColors.Palette.Distinct().Count());
        Assert.DoesNotContain("#FFFFFF", SpeakerColors.Palette);
    }

    [Fact]
    public void SpeakersAreLineStartNamesInOrderWithoutRepeats()
    {
        Assert.Equal(["Mattia", "Lucia"], SpeakerColors.Speakers("Mattia: Gel.\nLucia: Hayır.\nMattia: Lütfen."));
        Assert.Empty(SpeakerColors.Speakers("Saat 10:30'da buluşalım."));
        Assert.Empty(SpeakerColors.Speakers("Note: Keep going."));
    }

    [Fact]
    public void OnlyTheSpeakerNameIsColored()
    {
        // Sarılmış metin: yalnız "Ad:" konuşanın renginde; cümle ve devam satırı renksiz (kullanıcının Yazı rengi).
        var text = "Mattia: Bunu yarın\nkonuşuruz.\nLucia : Tamam.";
        var segments = SpeakerColors.Segments(text, SpeakerColors.Speakers("Mattia: Bunu yarın konuşuruz.\nLucia : Tamam."));
        Assert.Equal(
            [
                new SpeakerColors.Segment("Mattia:", "#F76AB7"), new SpeakerColors.Segment(" Bunu yarın\nkonuşuruz.\n", null),
                new SpeakerColors.Segment("Lucia :", "#2AD5E5"), new SpeakerColors.Segment(" Tamam.", null),
            ],
            segments);
        Assert.Equal(text, string.Concat(segments.Select(segment => segment.Text)));
    }

    [Fact]
    public void TextBeforeTheFirstNameStaysUncolored()
    {
        var segments = SpeakerColors.Segments("Kapıyı aç.\nJason: Geldim.", ["Jason"]);
        Assert.Equal(
            [new SpeakerColors.Segment("Kapıyı aç.\n", null), new SpeakerColors.Segment("Jason:", "#49B5FA"), new SpeakerColors.Segment(" Geldim.", null)],
            segments);
        Assert.Equal([new SpeakerColors.Segment("Düz metin", null)], SpeakerColors.Segments("Düz metin", []));
    }

    [Fact]
    public void WholeLineColorsTheSentence()
    {
        var segments = SpeakerColors.Segments("Kapıyı aç.\nJason: Geldim\nhemen.", ["Jason"], wholeLine: true);
        Assert.Equal(
            [new SpeakerColors.Segment("Kapıyı aç.\n", null), new SpeakerColors.Segment("Jason: Geldim\nhemen.", "#49B5FA")],
            segments);
    }
}
