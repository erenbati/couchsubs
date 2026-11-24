// SPDX-License-Identifier: AGPL-3.0-only

using System.Collections.Concurrent;
using System.Text.Json;
using CouchSubs.Core;
using CouchSubs.Shell;

namespace CouchSubs.Shell.Tests;

public class GamePhoneReadingTests
{
    [Fact]
    public void PhoneDefaultsToOnAndThePreferenceRoundTrips()
    {
        // GTA 6 telefonu varsayılan açık (#1202): alanı olmayan dosya da açık gelir.
        Assert.True(JsonSerializer.Deserialize<UserSettings>("{}")!.AutoReadGamePhone);
        var json = JsonSerializer.Serialize(new UserSettings { AutoReadGamePhone = false });
        Assert.False(JsonSerializer.Deserialize<UserSettings>(json)!.AutoReadGamePhone);
    }

    [Fact]
    public void MigrationTurnsThePhoneOnOnceForOldSettings()
    {
        // Eski göç otomatik ekran yazısı kapalıyken telefonu kapatmıştı (#1202): bir kez açılır.
        var old = JsonSerializer.Deserialize<UserSettings>(
            """{"AutoScreenText":false,"AutoScreenTextReset":true,"ScreenTextExtrasReset":true,"AutoReadGamePhone":false}""")!;
        Assert.False(old.ReadsGamePhone);
        var migrated = GamePhoneMigration.Apply(old);
        Assert.True(migrated.AutoReadGamePhone);
        Assert.True(migrated.GamePhoneReenabled);
        // Kullanıcı sonra bilerek kapatırsa göç tekrarlanmaz.
        var closed = JsonSerializer.Deserialize<UserSettings>(JsonSerializer.Serialize(migrated))! with { AutoReadGamePhone = false };
        Assert.Equal(closed, GamePhoneMigration.Apply(closed));
        // Yeni kurulum: bütün göçlerden sonra telefon açık.
        var fresh = GamePhoneMigration.Apply(ScreenTextExtrasMigration.Apply(AutoScreenTextMigration.Apply(new UserSettings()).Settings));
        Assert.True(fresh.ReadsGamePhone);
    }

    [Fact]
    public void SessionLogSaysWhetherThePhoneIsRead()
    {
        Assert.Equal("otomatik ekran yazısı: kapalı, telefon: açık", SessionSummary.ScreenText(new UserSettings()));
        Assert.Equal("otomatik ekran yazısı: kapalı, telefon: kapalı",
                     SessionSummary.ScreenText(new UserSettings { AutoReadGamePhone = false }));
        Assert.Equal("otomatik ekran yazısı: açık, telefon: açık",
                     SessionSummary.ScreenText(new UserSettings { AutoReadGamePhone = false, AutoScreenText = true }));
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task NormalSubtitleStillReachesTheDisplayWhenNoPhoneIsBeingRead(bool featureEnabled)
    {
        var services = new FakeServices { ReaderLines = Reading.FromText("Hold the gate") };
        var settings = new MemorySettings();
        // Otomatik ekran yazıları ve hazır alanlar kapalı: telefon dışında ayrı okuyucu açılmasın (bkz. ScreenTextReadingTests).
        settings.Save(new UserSettings { FrameSource = FrameSource.RemotePlayWindow, Output = SubtitleOutput.Computer, AutoReadGamePhone = featureEnabled, AutoScreenText = false, GameAreaPresets = false, ScreenTextExtrasReset = true });
        using var controller = AppControllerTests.Make(services, settings: settings);
        var events = new ConcurrentQueue<SubtitleEvent>();
        controller.StreamEvent += events.Enqueue;
        controller.ChooseGame("GTA 6");
        await controller.StartAsync();
        int readers = services.ReaderLanguages.Count;
        var frame = featureEnabled ? Frame.Blank(400, 225) : PhoneFrame();
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(5));
        while (!events.Any(e => e.Kind == SubtitleEventKind.Subtitle && e.Text == "TR: Hold the gate"))
        {
            services.Streams[0].Emit(frame);
            await Task.Delay(40, timeout.Token);
        }
        Assert.Equal(readers, services.ReaderLanguages.Count);
        Assert.DoesNotContain(events, e => e.Kind == SubtitleEventKind.Region && e.Id == "game-phone");
    }

    [Fact]
    public async Task OpensOnlyInTheSelectedGameAndClearsOnlyThePhoneWhenDisabled()
    {
        var services = new FakeServices { ReaderLines = Reading.FromText("Call me tomorrow.") };
        var settings = new MemorySettings();
        // Telefon kapalı başlar (kullanıcı kapatmış; göç yapılmış).
        settings.Save(new UserSettings { FrameSource = FrameSource.RemotePlayWindow, Output = SubtitleOutput.Computer, AutoScreenText = false, GameAreaPresets = false, AutoReadGamePhone = false, GamePhoneReenabled = true });
        var controller = AppControllerTests.Make(services, settings: settings);
        var events = new ConcurrentQueue<SubtitleEvent>();
        controller.StreamEvent += events.Enqueue;
        var frame = PhoneFrame();
        try
        {
            await controller.StartAsync();
            var stream = Assert.Single(services.Streams);
            var mainReaders = services.ReaderLanguages.Count;
            controller.ChooseGame("Grand Theft Auto VI");
            stream.Emit(frame);
            await Task.Delay(360);
            stream.Emit(frame);
            Assert.Equal(mainReaders, services.ReaderLanguages.Count);

            controller.ChooseGame("Far Cry 3");
            controller.Settings = controller.Settings with { AutoReadGamePhone = true };
            stream.Emit(frame);
            await Task.Delay(360);
            stream.Emit(frame);
            Assert.Equal(mainReaders, services.ReaderLanguages.Count);

            controller.ChooseGame("GTA 6");
            stream.Emit(Frame.Blank(frame.Width, frame.Height));
            await Task.Delay(360);
            stream.Emit(frame);
            Assert.Equal(mainReaders, services.ReaderLanguages.Count);

            using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(7));
            while (!events.Any(e => e.Kind == SubtitleEventKind.Region && e.Id == "game-phone" && e.Text?.Length > 0))
            {
                await Task.Delay(120, timeout.Token);
                stream.Emit(frame);
            }
            Assert.Equal(mainReaders + 1, services.ReaderLanguages.Count);
            events.Clear();
            controller.Settings = controller.Settings with { AutoReadGamePhone = false };
            Assert.Contains(events, e => e.Kind == SubtitleEventKind.Region && e.Id == "game-phone" && e.Text == "");
            Assert.DoesNotContain(events, e => e.Kind == SubtitleEventKind.RegionClear);
        }
        finally { controller.Stop(); }
    }

    /// <summary>
    /// Xbox çalışan oyunu bildirmez (X'te iki kullanıcı: GTA 6 telefonu Xbox'ta otomatik çevrilmiyordu). Xbox için daha önce
    /// seçilen oyun kendiliğinden kullanılır ve telefon açılır; hiç seçim yoksa Oyun karosu vurgulanır, çeviri sürerken oyun
    /// seçilince telefon izleyicisi yeniden başlatmadan kurulur ve seçim Xbox'a özel saklanır (Mac, iPhone, Android ile aynı).
    /// </summary>
    [Theory]
    [InlineData(true)]
    [InlineData(false)]
    public async Task XboxUsesTheLastChosenGameOrOpensThePhoneAsSoonAsTheGameIsChosen(bool remembered)
    {
        var store = new MemoryStore();
        store.Save(StoreKeys.ConsoleKind, GameConsoleKind.Xbox);
        store.Save(StoreKeys.XboxToken, "{}");
        store.Save(StoreKeys.XboxConsole, new XboxConsole("F4", "Salon Xbox", "XboxSeriesX", true));
        // PS5'in kaydı Xbox'ta kullanılmaz.
        store.Save(StoreKeys.LastGames, remembered
            ? new Dictionary<string, string> { [GameSense.XboxConsole] = "Grand Theft Auto VI", ["PS5"] = "Elden Ring" }
            : new Dictionary<string, string> { ["PS5"] = "Grand Theft Auto VI" });
        var settings = new MemorySettings();
        settings.Save(new UserSettings { Output = SubtitleOutput.Computer, AutoReadGamePhone = true, AutoScreenText = false, GameAreaPresets = false, ScreenTextExtrasReset = true });
        var xbox = new FakeXbox([]);
        var services = new FakeServices { Xbox = xbox, ReaderLines = Reading.FromText("Call me tomorrow.") };
        var controller = AppControllerTests.Make(services, store, settings);
        var events = new ConcurrentQueue<SubtitleEvent>();
        controller.StreamEvent += events.Enqueue;
        var frame = PhoneFrame();
        try
        {
            await controller.StartAsync();
            var stream = Assert.Single(xbox.Streams).Stream;
            if (remembered)
            {
                Assert.Equal("Grand Theft Auto VI", controller.PlayedGame);
                Assert.False(controller.XboxNeedsGame);
            }
            else
            {
                Assert.Null(controller.PlayedGame);
                Assert.True(controller.XboxNeedsGame);
                var mainReaders = services.ReaderLanguages.Count;
                stream.Emit(frame);
                await Task.Delay(360);
                stream.Emit(frame);
                Assert.Equal(mainReaders, services.ReaderLanguages.Count);
                controller.ChooseGame("GTA 6");
                Assert.False(controller.XboxNeedsGame);
                Assert.Equal("GTA 6", store.Load<Dictionary<string, string>>(StoreKeys.LastGames)?[GameSense.XboxConsole]);
            }
            using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(7));
            while (!events.Any(e => e.Kind == SubtitleEventKind.Region && e.Id == "game-phone" && e.Text?.Length > 0))
            {
                stream.Emit(frame);
                await Task.Delay(120, timeout.Token);
            }
            // Telefon için çeviri yeniden başlatılmadı.
            Assert.Single(xbox.Streams);
        }
        finally { controller.Dispose(); }
        Assert.False(controller.XboxNeedsGame);
    }

    // Kayıt gerektirmeden kasa kenarları, iki hoparlör yarığı ve ön kamerayla gerçek algılayıcıyı çalıştırır.
    private static Frame PhoneFrame()
    {
        var frame = Frame.Blank(400, 225);
        void Fill(int x, int y, int width, int height, byte value)
        {
            for (var row = y; row < y + height; row++)
                Array.Fill(frame.Pixels, value, row * frame.Stride + x * 4, width * 4);
        }
        Fill(158, 42, 84, 157, 180);
        Fill(164, 52, 73, 138, 80);
        Fill(194, 47, 12, 2, 20);
        Fill(210, 47, 2, 2, 20);
        Fill(196, 192, 8, 2, 20);
        return frame;
    }
}
