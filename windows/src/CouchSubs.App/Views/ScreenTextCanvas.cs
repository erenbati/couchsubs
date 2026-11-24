// SPDX-License-Identifier: AGPL-3.0-only

using System.Globalization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using CouchSubs.Core;

namespace CouchSubs.App.Views;

/// <summary>
/// Ekran yazısı blokları oyun karesindeki kendi yerlerinde (yayın penceresi 16:9 karenin kendisidir), TV ve Mac ile aynı
/// yerleşimle (<see cref="ScreenFit.Layout"/>; Mac StreamWindow ScreenTextBlocks): yazı boyu satır yüksekliğinin 0,95'i ve hiç
/// küçülmez; Türkçe uzunsa önce yalnız yatayda sıkışır, sonra bilgisayarın verdiği alana (<c>Room</c>: simgelere ve komşu yazıya
/// kadar) hizanın tersine genişler; özgün yazı kaç satırsa çeviri o kadar satırdadır. Altyazıyla çakışan kutu yalnız gerektiği
/// kadar yukarı ya da aşağı kayar. Önceden Windows'ta bu çeviriler pencerenin üstünde alt alta, hizalı bir liste olarak
/// çiziliyordu.
/// </summary>
internal sealed class ScreenTextCanvas : Canvas
{
    private static readonly FontFamily Condensed = new("Arial Narrow, Segoe UI");
    private static readonly FontFamily Normal = new("Segoe UI");
    private static readonly CultureInfo Turkish = CultureInfo.GetCultureInfo("tr-TR");

    private IReadOnlyList<ScreenTranslation.Item> items = [];
    private Rect? avoiding;

    public ScreenTextCanvas()
    {
        IsHitTestVisible = false;
        ClipToBounds = true;
        SizeChanged += (_, _) => Layout();
    }

    /// <summary>Kendi yerinde çizilecek öğe: özgün stilli, telefon kartının/panelinin parçası değil.</summary>
    public static bool Draws(ScreenTranslation.Item item) =>
        item.Look is not null && item.Panel is null && !ScreenPhoneCard.IsBackdrop(item) && item.Translation.Length > 0;

    /// <param name="subtitles">Altyazı satırlarının yeri (bu katmanın koordinatında); kutu onunla çakışmaz.</param>
    public void Show(IReadOnlyList<ScreenTranslation.Item> blocks, Rect? subtitles)
    {
        items = blocks;
        avoiding = subtitles;
        Layout();
    }

    /// <summary>Kutunun üst kenarı (Mac ScreenTextBlocks.top ile aynı kural, en az %0,6 ekran yüksekliği boşluk).</summary>
    internal static double Top(Rect rect, Rect? avoiding, double height)
    {
        var gap = height * 0.006;
        if (avoiding is not { } other) return rect.Top;
        var grown = new Rect(other.X, other.Y - gap, other.Width, other.Height + (2 * gap));
        if (!rect.IntersectsWith(grown)) return rect.Top;
        var up = other.Top - gap - rect.Height;
        var down = other.Bottom + gap;
        bool upFits = up >= 0, downFits = down + rect.Height <= height;
        if (upFits && (!downFits || rect.Top - up <= down - rect.Top)) return up;
        if (downFits) return down;
        return Math.Max(0, up);
    }

    private void Layout()
    {
        Children.Clear();
        double width = ActualWidth, height = ActualHeight;
        if (width <= 0 || height <= 0) return;
        var dpi = VisualTreeHelper.GetDpi(this).PixelsPerDip;
        foreach (var item in items.Where(Draws))
        {
            var look = item.Look!;
            var surface = item.Style ?? TextStyleSampler.Neutral;
            var line = Math.Max(1, item.LineHeight * height);
            var fontSize = line * 0.95;
            var pad = line * 0.15;
            var boxHeight = Math.Max(0, item.Box.Bottom - item.Box.Top) * height;
            var family = look.Condensed ? Condensed : Normal;
            var weight = look.Bold ? FontWeights.Bold : FontWeights.SemiBold;
            var typeface = new Typeface(family, FontStyles.Normal, weight, FontStretches.Normal);
            var translation = look.Upper ? item.Translation.ToUpper(Turkish) : item.Translation;
            double Measure(string text) =>
                new FormattedText(text, Turkish, FlowDirection.LeftToRight, typeface, fontSize, Brushes.White, dpi).WidthIncludingTrailingWhitespace;
            var fit = ScreenFit.Layout(translation, item.Box.Left * width, Math.Max(1, item.Box.Right - item.Box.Left) * width,
                                       item.Room is { } room ? (room.Left * width, room.Right * width) : null, item.Rows, look.Align, Measure);
            var pitch = Math.Max(boxHeight / Math.Max(1, fit.Rows.Count), fontSize * 1.05);
            var alignment = look.Align switch { "center" => HorizontalAlignment.Center, "right" => HorizontalAlignment.Right, _ => HorizontalAlignment.Left };
            var origin = look.Align switch { "center" => 0.5, "right" => 1.0, _ => 0.0 };
            var stack = new StackPanel { Width = fit.Width, MinHeight = boxHeight, VerticalAlignment = VerticalAlignment.Center };
            foreach (var text in fit.Rows)
            {
                stack.Children.Add(new TextBlock
                {
                    Text = text,
                    FontFamily = family,
                    FontWeight = weight,
                    FontSize = fontSize,
                    Foreground = new SolidColorBrush(Parse(surface.Foreground, Colors.White)),
                    TextWrapping = TextWrapping.NoWrap,
                    Height = pitch,
                    HorizontalAlignment = alignment,
                    RenderTransformOrigin = new Point(origin, 0.5),
                    RenderTransform = new ScaleTransform(fit.Squeeze, 1),
                });
            }
            var block = new Border
            {
                Background = new SolidColorBrush(Parse(surface.Background, Colors.Black)),
                CornerRadius = new CornerRadius(look.Flat ? 0 : pad),
                Padding = new Thickness(pad),
                Child = stack,
            };
            var rect = new Rect(fit.Left - pad, (item.Box.Top * height) - pad, fit.Width + (2 * pad), boxHeight + (2 * pad));
            SetLeft(block, fit.Left - pad);
            SetTop(block, Top(rect, avoiding, height));
            Children.Add(block);
        }
    }

    private static Color Parse(string? hex, Color fallback) =>
        hex is { Length: 7 } && hex[0] == '#'
        && int.TryParse(hex.AsSpan(1), NumberStyles.HexNumber, null, out var rgb)
            ? Color.FromRgb((byte)(rgb >> 16), (byte)(rgb >> 8), (byte)rgb)
            : fallback;
}
