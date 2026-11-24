// SPDX-License-Identifier: AGPL-3.0-only

namespace CouchSubs.Core;

/// <summary>
/// Karenin işlemciye kopyalanma sıklığı (uyarlamalı). X'te iki kullanıcı CouchSubs açıkken oyunun takıldığını, kapatınca
/// geçtiğini bildirdi (Windows 11, PS Remote Play penceresi ve Xbox uzaktan oynatma; altyazıyı telefona alınca düzeldi).
/// Pencere yakalaması her karede bütün pencereyi ekran kartından işlemciye kopyalıyordu (1440p'de 14,7 MB; saniyede on
/// kez), Xbox oynatıcısı her 66 ms'de bütün kareyi JPEG'e çevirip gönderiyordu; okuma bu karelerin çoğunu hiç kullanmadan
/// atlıyordu (önceki okuma sürerken). Artık:
/// <list type="bullet">
/// <item>En çok saniyede <see cref="MaxFramesPerSecond"/> kare kopyalanır (<see cref="BaseIntervalMs"/>).</item>
/// <item>Bilgisayarın işlemcisi doluysa seyrekleşir: %75'te <see cref="BusyIntervalMs"/>, %90'da <see cref="FullIntervalMs"/>.</item>
/// <item>Altyazı okuması kare aralığından uzun sürüyorsa aralık okuma süresine çıkar (en çok <see cref="MaxIntervalMs"/>):
/// okuma sürerken kopyalanan kareler atılıyordu.</item>
/// </list>
/// Görüntü değişmiyorsa zaten kare gelmez (Windows.Graphics.Capture ve ScreenCaptureKit yalnız değişen kareyi verir; Xbox
/// oynatıcısı yeni video karesi yoksa göndermez) ve okuma bölge değişmedikçe yazı tanıma yapmaz (<see cref="ReadScheduler"/>).
/// Altyazı tepkisi: en kötü durumda kare en çok <see cref="MaxIntervalMs"/> geç gelir. Mac: FrameCadence.swift (aynı
/// eşikler). Kareler ayrı iş parçacıklarından sorulur; kilitlidir.
/// </summary>
public sealed class FrameCadence
{
    public const int MaxFramesPerSecond = 10;
    public const int BaseIntervalMs = 1000 / MaxFramesPerSecond;
    /// <summary>İşlemci %75 dolu: saniyede 6 kare.</summary>
    public const int BusyIntervalMs = 166;
    /// <summary>İşlemci %90 dolu: saniyede 4 kare.</summary>
    public const int FullIntervalMs = 250;
    /// <summary>Okuma ne kadar yavaş olursa olsun kare en çok bu kadar arayla gelir (altyazı tepkisi).</summary>
    public const int MaxIntervalMs = 333;
    public const double BusyLoad = 0.75, FullLoad = 0.90;
    /// <summary>
    /// Kareler tam aralıkta gelmez (ScreenCaptureKit saniyede 10'u ±birkaç ms ile verir): aralığın bu kadar altı da kabul
    /// edilir, yoksa her ikinci kare atlanıp hız yarıya iniyordu.
    /// </summary>
    public const int JitterMs = 8;

    private readonly object gate = new();
    private long? last;
    private double load;
    private int readMs;

    /// <summary>Şu anki kare aralığı (milisaniye).</summary>
    public int IntervalMs
    {
        get { lock (gate) return Interval(load, readMs); }
    }

    /// <summary>İşlemci yüküne (0–1) ve son altyazı okumasının süresine göre kare aralığı.</summary>
    public static int Interval(double cpuLoad, int lastReadMs)
    {
        var interval = cpuLoad >= FullLoad ? FullIntervalMs : cpuLoad >= BusyLoad ? BusyIntervalMs : BaseIntervalMs;
        return Math.Min(MaxIntervalMs, Math.Max(interval, lastReadMs));
    }

    /// <summary>Bilgisayarın toplam işlemci yükü (0–1); bilinmiyorsa çağrılmaz.</summary>
    public void ReportCpuLoad(double value)
    {
        lock (gate) load = double.IsFinite(value) ? Math.Clamp(value, 0, 1) : 0;
    }

    /// <summary>Son altyazı okumasının (yazı tanıma) süresi.</summary>
    public void ReportReadMs(int? value)
    {
        lock (gate) readMs = Math.Max(0, value ?? 0);
    }

    /// <summary>
    /// Bu kare kopyalanıp okumaya verilsin mi (<paramref name="now"/>: milisaniye saati). Evetse an kaydedilir. Saat geri
    /// gittiyse kare alınır.
    /// </summary>
    public bool Admit(long now)
    {
        lock (gate)
        {
            if (last is { } previous && now >= previous && now - previous < Interval(load, readMs) - JitterMs) return false;
            last = now;
            return true;
        }
    }

    /// <summary>Oturum yenilendi: ilk kare beklemeden alınır.</summary>
    public void Reset()
    {
        lock (gate)
        {
            last = null;
            readMs = 0;
        }
    }
}

/// <summary>
/// Ana ekrandaki canlı önizlemenin (perde) çizim aralığı; hareket kapısıyla aynı kural (Windows MotionGate, Mac
/// DSMotionGate). Önizleme her çizimde bütün kareyi ekran kartına yükler: pencere öndeyken saniyede 4, oyun oynanırken
/// (pencere arka planda ya da simge durumunda) saniyede 1 kez çizilir. Mac: PreviewCadence (FrameCadence.swift).
/// </summary>
public static class PreviewCadence
{
    public const int ActiveIntervalMs = 250;
    public const int BackgroundIntervalMs = 1000;

    /// <param name="windowActive">Uygulamanın penceresi önde ve simge durumunda değil.</param>
    public static int IntervalMs(bool windowActive) => windowActive ? ActiveIntervalMs : BackgroundIntervalMs;
}
