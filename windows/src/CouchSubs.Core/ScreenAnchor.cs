// SPDX-License-Identifier: AGPL-3.0-only

namespace CouchSubs.Core;

/// <summary>
/// Çapa takibi (GTA 6 telefonu, görev/harita kartı; Mac/iPhone: CouchSubsCore/ScreenAnchor.swift, Android: ScreenAnchor.kt;
/// aynı adımlar, aynı eşikler): çevirinin dayandığı dörtgen her karede OCR'sız, alt piksel düzeyinde izlenir. Başvuru
/// karesindeki dörtgenin görüntüsü şablon olur; her yeni karede şablonun izdüşümsel dönüşümü (öteleme + ölçek + dönme +
/// perspektif) ters bileşimli Lucas-Kanade ile piramitte, sağlam ağırlıkla bulunur. Ekranda değişen yazı, önden geçen el
/// ağırlığını yitirir; şablon güncellenmez (kayma birikmez). Uyum çok düşerse çapa kaybolur, sonraki okumada yeniden kurulur.
/// Ortak deneme dosyası core/Tests/CouchSubsCoreTests/Fixtures/screen-anchor.json; ölçüm docs/ekran-capasi.md.
/// </summary>
public static class ScreenAnchor
{
    public const int TrackWidth = 960;
    public const int Levels = 4;
    public const double CoarsestWidth = 20.0;
    public const int SearchRadius = 3;
    public const int MaxPoints = 2500;
    public const int Iterations = 15;
    public const double Huber = 8.0;
    public const double LostShare = 0.45;
    public const double Inset = 0.03;

    public static int LevelCount(double width)
    {
        var count = 1;
        while (count < Levels && width / (1 << count) >= CoarsestWidth) count++;
        return count;
    }

    /// <summary>Gri kare (satır satır, üstten).</summary>
    public sealed class Gray
    {
        public int Width { get; }
        public int Height { get; }
        public byte[] Pixels { get; }

        public Gray(int width, int height, byte[] pixels)
        {
            if (width < 2 || height < 2 || pixels.Length < width * height) throw new ArgumentException("gray frame");
            Width = width;
            Height = height;
            Pixels = pixels;
        }

        /// <summary>RGBA (ya da BGRA) karesinden <paramref name="targetWidth"/> ene (tam sayı katla) küçültülmüş gri kare:
        /// kutu ortalaması, parlaklık (2R + 5G + B) / 8.</summary>
        public static Gray FromRgba(byte[] bytes, int width, int height, bool bgr = false, int targetWidth = TrackWidth)
        {
            var factor = Math.Max(1, (int)Math.Round((double)width / targetWidth, MidpointRounding.AwayFromZero));
            int w = Math.Max(2, width / factor), h = Math.Max(2, height / factor);
            var output = new byte[w * h];
            int r = bgr ? 2 : 0, b = bgr ? 0 : 2;
            var count = factor * factor;
            for (var y = 0; y < h; y++)
            {
                for (var x = 0; x < w; x++)
                {
                    var sum = 0;
                    for (var yy = 0; yy < factor; yy++)
                    {
                        var p = ((Math.Min(height - 1, (y * factor) + yy) * width) + Math.Min(width - 1, x * factor)) * 4;
                        for (var k = 0; k < factor; k++)
                        {
                            sum += (2 * bytes[p + r]) + (5 * bytes[p + 1]) + bytes[p + b];
                            p += 4;
                        }
                    }
                    output[(y * w) + x] = (byte)Math.Min(255, (sum + (4 * count)) / (8 * count));
                }
            }
            return new Gray(w, h, output);
        }

        internal Gray Half()
        {
            int w = Math.Max(2, Width / 2), h = Math.Max(2, Height / 2);
            var output = new byte[w * h];
            for (var y = 0; y < h; y++)
            {
                int r0 = Math.Min(Height - 1, 2 * y) * Width, r1 = Math.Min(Height - 1, (2 * y) + 1) * Width;
                for (var x = 0; x < w; x++)
                {
                    int x0 = Math.Min(Width - 1, 2 * x), x1 = Math.Min(Width - 1, (2 * x) + 1);
                    var sum = Pixels[r0 + x0] + Pixels[r0 + x1] + Pixels[r1 + x0] + Pixels[r1 + x1];
                    output[(y * w) + x] = (byte)((sum + 2) / 4);
                }
            }
            return new Gray(w, h, output);
        }

        /// <summary>Çift doğrusal örnek; kare dışı NaN.</summary>
        internal double Sample(double x, double y)
        {
            if (!(x >= 0) || !(y >= 0) || x > Width - 1 || y > Height - 1) return double.NaN;
            int x0 = Math.Min(Width - 2, (int)x), y0 = Math.Min(Height - 2, (int)y);
            double fx = x - x0, fy = y - y0;
            var i = (y0 * Width) + x0;
            double p00 = Pixels[i], p10 = Pixels[i + 1], p01 = Pixels[i + Width], p11 = Pixels[i + Width + 1];
            double top = p00 + ((p10 - p00) * fx), bottom = p01 + ((p11 - p01) * fx);
            return top + ((bottom - top) * fy);
        }
    }

    public readonly record struct Rect(double X, double Y, double Width, double Height)
    {
        public double CenterX => X + (Width / 2);
        public double CenterY => Y + (Height / 2);
    }

    /// <summary>Başvurudan güncel kareye izdüşümsel dönüşüm: u = x − cx, v = y − cy için nokta
    /// (cx + (a u + b v + dx) / w, cy + (c u + d v + dy) / w); w = 1 + g u + h v.</summary>
    public readonly record struct Motion(double A, double B, double C, double D, double Dx, double Dy, double G, double H)
    {
        public static readonly Motion Identity = new(1, 0, 0, 1, 0, 0, 0, 0);

        public double Scale => Math.Sqrt(Math.Abs((A * D) - (B * C)));

        public (double X, double Y) Map(double x, double y, double cx, double cy)
        {
            double u = x - cx, v = y - cy;
            var w = 1 + (G * u) + (H * v);
            return (cx + (((A * u) + (B * v) + Dx) / w), cy + (((C * u) + (D * v) + Dy) / w));
        }

        internal Motion Scaled(double factor) => this with { Dx = Dx / factor, Dy = Dy / factor, G = G * factor, H = H * factor };

        public double Distance(Motion other, Rect rect)
        {
            double cx = rect.CenterX, cy = rect.CenterY, worst = 0;
            foreach (var (x, y) in new[] { (rect.X, rect.Y), (rect.X + rect.Width, rect.Y), (rect.X, rect.Y + rect.Height), (rect.X + rect.Width, rect.Y + rect.Height) })
            {
                var p = Map(x, y, cx, cy);
                var q = other.Map(x, y, cx, cy);
                worst = Math.Max(worst, Math.Sqrt(((p.X - q.X) * (p.X - q.X)) + ((p.Y - q.Y) * (p.Y - q.Y))));
            }
            return worst;
        }
    }

    public readonly record struct Fix(Motion Motion, double Inliers);

    /// <summary>Şablon izleyici: <see cref="Begin"/> başvuru karesinde dörtgeni şablon yapar, <see cref="Track"/> her yeni
    /// karede dönüşümü bulur; çapa kaybolunca null (yeniden Begin gerekir).</summary>
    public sealed class Tracker
    {
        private sealed class Level
        {
            public double Factor;
            public double Offset;
            public readonly List<double> U = new();
            public readonly List<double> V = new();
            public double[] T = Array.Empty<double>();
            public double[] Gx = Array.Empty<double>();
            public double[] Gy = Array.Empty<double>();
        }

        private readonly List<Level> pyramid = new();
        private Motion? previous;

        public Rect? Rect { get; private set; }
        public Motion Motion { get; private set; } = Motion.Identity;
        public bool IsActive => Rect != null;

        public void Begin(Gray frame, Rect rect)
        {
            var inner = new Rect(rect.X + (rect.Width * Inset), rect.Y + (rect.Height * Inset), rect.Width * (1 - (2 * Inset)), rect.Height * (1 - (2 * Inset)));
            Rect = rect;
            Motion = Motion.Identity;
            previous = null;
            pyramid.Clear();
            var count = LevelCount(inner.Width);
            var image = frame;
            for (var index = 0; index < count; index++)
            {
                double factor = 1 << index;
                var level = new Level { Factor = factor, Offset = (factor - 1) / 2 };
                double w = inner.Width / factor, h = inner.Height / factor;
                var step = Math.Max(1, (int)Math.Ceiling(Math.Sqrt(w * h / MaxPoints)));
                int cols = Math.Max(2, (int)w / step), rows = Math.Max(2, (int)h / step);
                for (var row = 0; row < rows; row++)
                {
                    for (var col = 0; col < cols; col++)
                    {
                        level.U.Add(((col + 0.5) * w / cols) - (w / 2));
                        level.V.Add(((row + 0.5) * h / rows) - (h / 2));
                    }
                }
                SampleTemplate(level, image, rect);
                pyramid.Add(level);
                if (index + 1 < count) image = image.Half();
            }
        }

        public void Reset()
        {
            Rect = null;
            Motion = Motion.Identity;
            previous = null;
            pyramid.Clear();
        }

        public Fix? Track(Gray frame)
        {
            if (Rect is not { } rect || pyramid.Count == 0) return null;
            var images = new List<Gray> { frame };
            for (var i = 1; i < pyramid.Count; i++) images.Add(images[^1].Half());
            var coarsest = pyramid.Count - 1;
            var starts = new List<Motion> { Motion };
            if (previous is { } before)
            {
                var predicted = Motion with { Dx = Motion.Dx + (Motion.Dx - before.Dx), Dy = Motion.Dy + (Motion.Dy - before.Dy) };
                if (predicted != Motion) starts.Add(predicted);
            }
            starts.Add(Search(pyramid[coarsest], images[coarsest], rect, starts[^1]));
            Fix? best = null;
            foreach (var start in starts)
            {
                if (Align(pyramid[coarsest], images[coarsest], rect, start) is not { } fix) continue;
                if (best is not { } b || fix.Inliers > b.Inliers) best = fix;
            }
            if (best is not { } current)
            {
                Reset();
                return null;
            }
            for (var index = coarsest - 1; index >= 0; index--)
            {
                if (Align(pyramid[index], images[index], rect, current.Motion) is not { } fix)
                {
                    Reset();
                    return null;
                }
                current = fix;
            }
            if (current.Inliers < LostShare || !Plausible(current.Motion, rect))
            {
                Reset();
                return null;
            }
            previous = Motion;
            Motion = current.Motion;
            return current;
        }

        private static void SampleTemplate(Level level, Gray image, Rect rect)
        {
            double cx = (rect.CenterX - level.Offset) / level.Factor, cy = (rect.CenterY - level.Offset) / level.Factor;
            var n = level.U.Count;
            level.T = new double[n];
            level.Gx = new double[n];
            level.Gy = new double[n];
            for (var i = 0; i < n; i++)
            {
                level.T[i] = double.NaN;
                double x = cx + level.U[i], y = cy + level.V[i];
                double c = image.Sample(x, y), l = image.Sample(x - 1, y), r = image.Sample(x + 1, y), up = image.Sample(x, y - 1), down = image.Sample(x, y + 1);
                if (double.IsNaN(c) || double.IsNaN(l) || double.IsNaN(r) || double.IsNaN(up) || double.IsNaN(down)) continue;
                level.T[i] = c;
                level.Gx[i] = (r - l) / 2;
                level.Gy[i] = (down - up) / 2;
            }
        }

        private static Motion Search(Level level, Gray image, Rect rect, Motion start)
        {
            double cx = (rect.CenterX - level.Offset) / level.Factor, cy = (rect.CenterY - level.Offset) / level.Factor;
            var m = start.Scaled(level.Factor);
            var n = level.U.Count;
            var stride = Math.Max(1, n / 400);
            var points = new List<(double X, double Y, double T)>();
            for (var i = 0; i < n; i += stride)
            {
                double t = level.T[i], u = level.U[i], v = level.V[i];
                var w = 1 + (m.G * u) + (m.H * v);
                if (!double.IsNaN(t) && w > 0.1) points.Add((cx + (((m.A * u) + (m.B * v) + m.Dx) / w), cy + (((m.C * u) + (m.D * v) + m.Dy) / w), t));
            }
            double bestCost = double.PositiveInfinity;
            int bestX = 0, bestY = 0;
            var values = new double[points.Count];
            for (var oy = -SearchRadius; oy <= SearchRadius; oy++)
            {
                for (var ox = -SearchRadius; ox <= SearchRadius; ox++)
                {
                    double count = 0, shift = 0;
                    for (var k = 0; k < points.Count; k++)
                    {
                        var value = image.Sample(points[k].X + ox, points[k].Y + oy);
                        values[k] = value;
                        if (double.IsNaN(value)) continue;
                        count++;
                        shift += points[k].T - value;
                    }
                    if (count < 16) continue;
                    shift /= count;
                    double cost = 0;
                    for (var k = 0; k < points.Count; k++) if (!double.IsNaN(values[k])) cost += Math.Abs(values[k] + shift - points[k].T);
                    cost /= count;
                    if (cost < bestCost)
                    {
                        bestCost = cost;
                        bestX = ox;
                        bestY = oy;
                    }
                }
            }
            return start with { Dx = start.Dx + (bestX * level.Factor), Dy = start.Dy + (bestY * level.Factor) };
        }

        private static Fix? Align(Level level, Gray image, Rect rect, Motion start)
        {
            double cx = (rect.CenterX - level.Offset) / level.Factor, cy = (rect.CenterY - level.Offset) / level.Factor;
            var m = start.Scaled(level.Factor);
            var n = level.U.Count;
            double share = 0;
            var values = new double[n];
            var rejected = new bool[n];
            var s = new double[8];
            var cut = 3 * Huber;
            for (var iteration = 0; iteration < Iterations; iteration++)
            {
                var hessian = new double[64];
                var gradient = new double[8];
                double count = 0, kept = 0, sumI = 0, sumII = 0, sumT = 0, sumTT = 0;
                for (var i = 0; i < n; i++)
                {
                    values[i] = double.NaN;
                    var t = level.T[i];
                    if (double.IsNaN(t)) continue;
                    double u = level.U[i], v = level.V[i];
                    var w = 1 + (m.G * u) + (m.H * v);
                    if (!(w > 0.1)) continue;
                    var value = image.Sample(cx + (((m.A * u) + (m.B * v) + m.Dx) / w), cy + (((m.C * u) + (m.D * v) + m.Dy) / w));
                    if (double.IsNaN(value)) continue;
                    values[i] = value;
                    count++;
                    if (rejected[i]) continue;
                    kept++;
                    sumI += value;
                    sumII += value * value;
                    sumT += t;
                    sumTT += t * t;
                }
                if (count < 16 || kept < 16) return null;
                double meanI = sumI / kept, meanT = sumT / kept;
                var spreadI = Math.Sqrt(Math.Max(0, (sumII / kept) - (meanI * meanI)));
                var spreadT = Math.Sqrt(Math.Max(0, (sumTT / kept) - (meanT * meanT)));
                var gain = spreadI > 1e-6 ? Math.Min(4, Math.Max(0.25, spreadT / spreadI)) : 1;
                double good = 0;
                for (var i = 0; i < n; i++)
                {
                    var value = values[i];
                    if (double.IsNaN(value)) continue;
                    double t = level.T[i], u = level.U[i], v = level.V[i];
                    var r = ((value - meanI) * gain) + meanT - t;
                    var size = Math.Abs(r);
                    rejected[i] = size > cut;
                    if (size <= Huber) good++;
                    if (rejected[i]) continue;
                    var weight = size <= Huber ? 1 : Huber / size;
                    double gx = level.Gx[i], gy = level.Gy[i];
                    var radial = (gx * u) + (gy * v);
                    s[0] = gx * u;
                    s[1] = gx * v;
                    s[2] = gy * u;
                    s[3] = gy * v;
                    s[4] = gx;
                    s[5] = gy;
                    s[6] = -radial * u;
                    s[7] = -radial * v;
                    for (var p = 0; p < 8; p++)
                    {
                        var ws = weight * s[p];
                        gradient[p] += ws * r;
                        for (var q = p; q < 8; q++) hessian[(p * 8) + q] += ws * s[q];
                    }
                }
                share = good / count;
                for (var p = 0; p < 8; p++) for (var q = 0; q < p; q++) hessian[(p * 8) + q] = hessian[(q * 8) + p];
                if (Solve(hessian, gradient) is not { } step) return null;
                var delta = new[] { 1 + step[0], step[1], step[4], step[2], 1 + step[3], step[5], step[6], step[7], 1.0 };
                if (Invert3(delta) is not { } inverse) return null;
                var current = new[] { m.A, m.B, m.Dx, m.C, m.D, m.Dy, m.G, m.H, 1.0 };
                var product = new double[9];
                for (var row = 0; row < 3; row++)
                {
                    for (var col = 0; col < 3; col++)
                    {
                        product[(row * 3) + col] = (current[row * 3] * inverse[col]) + (current[(row * 3) + 1] * inverse[3 + col]) + (current[(row * 3) + 2] * inverse[6 + col]);
                    }
                }
                var k8 = product[8];
                if (Math.Abs(k8) <= 1e-12) return null;
                m = new Motion(product[0] / k8, product[1] / k8, product[3] / k8, product[4] / k8, product[2] / k8, product[5] / k8, product[6] / k8, product[7] / k8);
                if (Math.Abs(step[4]) < 0.005 && Math.Abs(step[5]) < 0.005 && Math.Abs(step[0]) < 1e-5 && Math.Abs(step[1]) < 1e-5
                    && Math.Abs(step[2]) < 1e-5 && Math.Abs(step[3]) < 1e-5 && Math.Abs(step[6]) < 1e-7 && Math.Abs(step[7]) < 1e-7) break;
            }
            return new Fix(m.Scaled(1 / level.Factor), share);
        }
    }

    /// <summary>Dönüşüm elde tutulan telefona/karta uyar mı: ölçek 0,5–2, eksen oranı 0,75–1,33, köşelerde perspektif %15'ten az.</summary>
    public static bool Plausible(Motion m, Rect rect)
    {
        var scale = m.Scale;
        if (!(scale > 0.5) || !(scale < 2)) return false;
        double x = Math.Sqrt((m.A * m.A) + (m.C * m.C)), y = Math.Sqrt((m.B * m.B) + (m.D * m.D));
        if (!(y > 0) || !(x / y > 0.75) || !(x / y < 1.0 / 0.75)) return false;
        return (Math.Abs(m.G) * rect.Width / 2) + (Math.Abs(m.H) * rect.Height / 2) < 0.15;
    }

    public static double[]? Invert3(double[] m)
    {
        double c00 = (m[4] * m[8]) - (m[5] * m[7]), c01 = (m[5] * m[6]) - (m[3] * m[8]), c02 = (m[3] * m[7]) - (m[4] * m[6]);
        var det = (m[0] * c00) + (m[1] * c01) + (m[2] * c02);
        if (Math.Abs(det) <= 1e-12) return null;
        return new[]
        {
            c00 / det, ((m[2] * m[7]) - (m[1] * m[8])) / det, ((m[1] * m[5]) - (m[2] * m[4])) / det,
            c01 / det, ((m[0] * m[8]) - (m[2] * m[6])) / det, ((m[2] * m[3]) - (m[0] * m[5])) / det,
            c02 / det, ((m[1] * m[6]) - (m[0] * m[7])) / det, ((m[0] * m[4]) - (m[1] * m[3])) / det,
        };
    }

    internal static double[]? Solve(double[] matrix, double[] vector)
    {
        var m = (double[])matrix.Clone();
        var x = (double[])vector.Clone();
        var n = vector.Length;
        for (var col = 0; col < n; col++)
        {
            var pivot = col;
            for (var row = col + 1; row < n; row++) if (Math.Abs(m[(row * n) + col]) > Math.Abs(m[(pivot * n) + col])) pivot = row;
            if (Math.Abs(m[(pivot * n) + col]) <= 1e-9) return null;
            if (pivot != col)
            {
                for (var k = 0; k < n; k++) (m[(col * n) + k], m[(pivot * n) + k]) = (m[(pivot * n) + k], m[(col * n) + k]);
                (x[col], x[pivot]) = (x[pivot], x[col]);
            }
            for (var row = col + 1; row < n; row++)
            {
                var f = m[(row * n) + col] / m[(col * n) + col];
                if (f == 0) continue;
                for (var k = col; k < n; k++) m[(row * n) + k] -= f * m[(col * n) + k];
                x[row] -= f * x[col];
            }
        }
        for (var row = n - 1; row >= 0; row--)
        {
            var sum = x[row];
            for (var k = row + 1; k < n; k++) sum -= m[(row * n) + k] * x[k];
            x[row] = sum / m[(row * n) + row];
        }
        return x;
    }

    /// <summary>Dönüşümün kararlılığı: ölü bölge (<see cref="Deadband"/> pikselden az oynama gösterilmez), sıçramada
    /// (<see cref="JumpShare"/>) çapa yeniden kurulmalı.</summary>
    public sealed class Smoother
    {
        public const double JumpShare = 0.12;
        public const double Deadband = 0.15;
        private Motion? last;
        private Motion? shown;

        public void Reset()
        {
            last = null;
            shown = null;
        }

        public (Motion Motion, bool Jumped) Push(Motion raw, Rect rect)
        {
            try
            {
                if (last is { } previous && raw.Distance(previous, rect) > JumpShare * rect.Height)
                {
                    shown = raw;
                    return (raw, true);
                }
                if (shown is { } current && raw.Distance(current, rect) <= Deadband) return (current, false);
                shown = raw;
                return (raw, false);
            }
            finally
            {
                last = raw;
            }
        }
    }
}
