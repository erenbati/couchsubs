// SPDX-License-Identifier: AGPL-3.0-only

using System.Runtime.InteropServices;
using CouchSubs.Core;

namespace CouchSubs.App.Services;

/// <summary>
/// Bilgisayarın toplam işlemci yükü (bütün süreçler; GetSystemTimes). Kare sıklığı (<see cref="FrameCadence"/>) yük
/// yükselince kendini kısar: oyun (Remote Play, Xbox uygulaması) işlemciyi bizimle paylaşmasın. Saniyede en çok bir kez
/// ölçülür; ölçümün kendisi yük getirmez. Kare iş parçacıklarından çağrılır; kilitlidir.
/// </summary>
internal sealed class SystemCpuLoad
{
    private const long SampleMs = 1000;
    private readonly object gate = new();
    private long sampledAt = long.MinValue;
    private ulong idle, kernel, user;

    /// <summary>Son ölçümden bir saniye geçtiyse yükü ölçüp <paramref name="cadence"/>'e bildirir.</summary>
    public void Report(FrameCadence cadence)
    {
        if (Sample() is { } load) cadence.ReportCpuLoad(load);
    }

    /// <summary>Son ölçümden bu yana yük (0–1); bir saniye geçmediyse ya da ölçülemediyse null.</summary>
    public double? Sample()
    {
        var now = Environment.TickCount64;
        lock (gate)
        {
            if (sampledAt != long.MinValue && now - sampledAt < SampleMs) return null;
            if (!GetSystemTimes(out var idleTime, out var kernelTime, out var userTime)) return null;
            var (i, k, u) = (Ticks(idleTime), Ticks(kernelTime), Ticks(userTime));
            var first = sampledAt == long.MinValue;
            var (di, dk, du) = (i - idle, k - kernel, u - user);
            (idle, kernel, user, sampledAt) = (i, k, u, now);
            if (first) return null;
            // Çekirdek süresi boşta süresini de içerir.
            var total = dk + du;
            return total == 0 ? null : Math.Clamp(1 - (double)di / total, 0, 1);
        }
    }

    private static ulong Ticks(FileTime time) => ((ulong)time.High << 32) | time.Low;

    [StructLayout(LayoutKind.Sequential)]
    private struct FileTime
    {
        public uint Low;
        public uint High;
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GetSystemTimes(out FileTime idleTime, out FileTime kernelTime, out FileTime userTime);
}
