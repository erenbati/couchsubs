// SPDX-License-Identifier: AGPL-3.0-only

namespace CouchSubs.Core.Tests;

/// <summary>
/// Kare kopyalama sıklığı (oyun takılması, X'te iki kullanıcı): saniyede kopyalanan kare (kare başı iş) eski ve yeni
/// kurala göre ölçülür. Mac: FrameCadenceTests.swift (aynı eşikler ve beklentiler).
/// </summary>
public class FrameCadenceTests
{
    /// <summary>Saniyede <paramref name="arrivalsPerSecond"/> kare gelirken bir saniyede kopyalanan kare.</summary>
    private static int CopiesInOneSecond(FrameCadence cadence, int arrivalsPerSecond, int jitterMs = 0)
    {
        var copies = 0;
        for (var i = 0; i < arrivalsPerSecond; i++)
        {
            var now = 10_000 + i * 1000 / arrivalsPerSecond + (i % 2 == 0 ? 0 : -jitterMs);
            if (cadence.Admit(now)) copies++;
        }
        return copies;
    }

    [Theory]
    [InlineData(0.0, 0, FrameCadence.BaseIntervalMs)]
    [InlineData(0.74, 0, FrameCadence.BaseIntervalMs)]
    [InlineData(0.75, 0, FrameCadence.BusyIntervalMs)]
    [InlineData(0.90, 0, FrameCadence.FullIntervalMs)]
    [InlineData(0.0, 180, 180)]
    [InlineData(0.95, 180, FrameCadence.FullIntervalMs)]
    [InlineData(0.0, 2000, FrameCadence.MaxIntervalMs)]
    public void IntervalFollowsCpuLoadAndReadTime(double load, int readMs, int expected) =>
        Assert.Equal(expected, FrameCadence.Interval(load, readMs));

    [Fact]
    public void WindowCaptureAt60HzCopiesTenFramesPerSecond()
    {
        // Windows.Graphics.Capture oyun penceresinden saniyede 60 kare verir.
        var cadence = new FrameCadence();
        Assert.Equal(FrameCadence.MaxFramesPerSecond, CopiesInOneSecond(cadence, 60));
    }

    [Fact]
    public void BusyComputerCopiesFewerFrames()
    {
        var cadence = new FrameCadence();
        cadence.ReportCpuLoad(0.95);
        Assert.Equal(4, CopiesInOneSecond(cadence, 60));
        cadence.ReportCpuLoad(0.8);
        cadence.Reset();
        Assert.Equal(6, CopiesInOneSecond(cadence, 60));
    }

    [Fact]
    public void SlowReadingDoesNotCopyFramesItWouldDrop()
    {
        // Yazı tanıma 300 ms sürüyorsa saniyede ancak ~3 kare okunur; eskiden 10 kare kopyalanıp 7'si atılıyordu.
        var cadence = new FrameCadence();
        cadence.ReportReadMs(300);
        Assert.Equal(4, CopiesInOneSecond(cadence, 60));
        // Okuma çok yavaşsa bile kare en çok MaxIntervalMs arayla gelir (altyazı tepkisi).
        cadence.Reset();
        cadence.ReportReadMs(5000);
        Assert.Equal(3, CopiesInOneSecond(cadence, 60));
    }

    [Fact]
    public void XboxPlayerSendsTenInsteadOfFifteenFrames()
    {
        // Xbox oynatıcısı eskiden her 66 ms'de bir kareyi JPEG'e çevirip gönderiyordu (saniyede 15).
        var cadence = new FrameCadence();
        Assert.Equal(10, CopiesInOneSecond(cadence, 60));
        Assert.True(cadence.IntervalMs >= 100);
    }

    [Fact]
    public void JitteryTenFramesPerSecondAreAllCopied()
    {
        // ScreenCaptureKit saniyede 10 kareyi birkaç ms erken/geç verir; her ikinci kare atlanmamalı.
        var cadence = new FrameCadence();
        Assert.Equal(10, CopiesInOneSecond(cadence, 10, jitterMs: 4));
    }

    [Fact]
    public void ResetAdmitsNextFrameAtOnceAndClockGoingBackIsAccepted()
    {
        var cadence = new FrameCadence();
        Assert.True(cadence.Admit(1000));
        Assert.False(cadence.Admit(1010));
        Assert.True(cadence.Admit(500));
        cadence.Reset();
        Assert.True(cadence.Admit(510));
    }

    [Fact]
    public void PreviewDrawsOncePerSecondWhileGameIsInFront()
    {
        Assert.Equal(250, PreviewCadence.IntervalMs(windowActive: true));
        Assert.Equal(1000, PreviewCadence.IntervalMs(windowActive: false));
    }
}
