// SPDX-License-Identifier: AGPL-3.0-only

namespace CouchSubs.Core.LgTv;

public enum TvAppRunningVerdict
{
    /// <summary>Çalışan uygulama kurulan sürümde (ya da daha yeni): denetim biter.</summary>
    Running,
    /// <summary>Çalışan uygulama eski: bir kez daha kapatılıp açılmalı.</summary>
    RestartAgain,
    /// <summary>Kapatıp açtıktan sonra da eski: kullanıcıya söylenir.</summary>
    Stale,
}

/// <summary>
/// LG: kurulumdan (ya da kapat-aç ile yeniden başlatmadan) sonra TV'de ÇALIŞAN uygulamanın sürümü kurulan sürüm mü?
/// beta.89 (Mac, LG): TV'ye 0.9.84 kurulmuştu, açık uygulama ise 0.9.81'di. TV uygulaması altyazı akışına bağlanırken
/// sürümünü bildirir (<c>/events?v=</c>); kurulan sürümden eskiyse uygulama bir kez daha kapatılıp açılır, yine eskiyse
/// kullanıcıya "TV'de CouchSubs'ı kapatıp yeniden açın" denir. Mac/iPhone (TVAppRunningCheck.swift) ve Android ile aynı.
/// </summary>
public sealed class TvAppRunningCheck(string expected)
{
    public string Expected { get; } = expected;
    public bool Restarted { get; private set; }

    /// <summary>TV uygulaması sürümünü bildirdi (boş: sürüm bildirmeyen eski uygulama).</summary>
    public TvAppRunningVerdict Report(string version)
    {
        if (!IsStale(version, Expected)) return TvAppRunningVerdict.Running;
        if (Restarted) return TvAppRunningVerdict.Stale;
        Restarted = true;
        return TvAppRunningVerdict.RestartAgain;
    }

    /// <summary>Çalışan uygulamanın bildirdiği sürüm (boş: eski uygulama) kurulu paketten eski mi?</summary>
    public static bool IsStale(string running, string installed) =>
        installed.Length > 0 && (running.Length == 0 || DevModeInstaller.IsNewer(installed, running));
}
