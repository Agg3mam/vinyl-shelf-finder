using System.Globalization;
using Microsoft.UI.Xaml;
using VinylShelfFinder.Core;
using VinylShelfFinder.UI;

namespace VinylShelfFinder;

/// <summary>
/// Appens start. <c>--demo</c> bruger en separat database med eksempeldata (ingen Discogs, intet net).
/// Med <c>--smoke [mappe]</c> (bruges sammen med --demo i CI) går appen selv gennem søg, plade-detalje,
/// Find i reolen og en sektion, gemmer et billede af hver i mappen, skriver "OK" i smoke-ok.txt og lukker.
/// </summary>
public partial class App : Application
{
    private MainWindow? _window;
    private string? _smokeDir;

    public App()
    {
        var da = CultureInfo.GetCultureInfo("da-DK");
        CultureInfo.DefaultThreadCurrentCulture = da;
        CultureInfo.DefaultThreadCurrentUICulture = da;
        CultureInfo.CurrentCulture = da;
        CultureInfo.CurrentUICulture = da;

        InitializeComponent();

        UnhandledException += (_, e) =>
        {
            if (_smokeDir is null) return;
            TryWrite(Path.Combine(_smokeDir, "smoke-error.txt"), e.Exception?.ToString() ?? e.Message);
            Environment.Exit(1);
        };
    }

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        var cmd = Environment.GetCommandLineArgs();
        int i = Array.IndexOf(cmd, "--smoke");
        if (i >= 0)
            _smokeDir = i + 1 < cmd.Length && !cmd[i + 1].StartsWith("--") ? cmd[i + 1] : AppContext.BaseDirectory;

        bool demo = cmd.Contains("--demo");
        // vinylshelf://-adresser (QR-koderne på reolskiltene): kun ét vindue ad gangen. Et nyt eksemplar
        // sender adressen videre til det kørende og lukker. Ikke i demo og smoke-test (rører ikke systemet).
        Microsoft.Windows.AppLifecycle.AppInstance? main = null;
        if (!demo && _smokeDir is null)
        {
            main = SingleInstance(restarting: cmd.Contains("--restart"));
            if (main is null) return;
        }
        // Demo og CI's smoke-test henter hverken covers eller opdateringer fra nettet.
        Ui.AllowNetworkCovers = !demo && _smokeDir is null;
        var updater = new Updater(enabled: _smokeDir is null && !demo);
        var model = new AppModel(demo);
        var imusic = new IMusicModel(enabled: !demo && _smokeDir is null);
        _window = new MainWindow(updater, model, imusic);
        _window.Activate();
        if (main is not null)
        {
            main.Activated += (_, e) => _window.DispatcherQueue.TryEnqueue(() => _window.OpenScanCode(ScanCodeFrom(e)));
            RegisterProtocol();
            _window.OpenScanCode(ScanCodeFrom(Microsoft.Windows.AppLifecycle.AppInstance.GetCurrent().GetActivatedEventArgs()));
        }

        if (_smokeDir is not null)
            _ = RunSmokeAsync(_smokeDir);
        else
        {
            model.StartBackups();
            model.StartCloud();
            imusic.Start();
            _ = _window.CheckForUpdateOnLaunchAsync();
        }
    }

    /// <summary>
    /// Det kørende eksemplar, eller null, hvis et andet allerede kører (så har det fået aktiveringen).
    /// Efter en genstart (import, nulstilling) venter det nye eksemplar på, at det gamle er lukket.
    /// </summary>
    private static Microsoft.Windows.AppLifecycle.AppInstance? SingleInstance(bool restarting)
    {
        var key = Microsoft.Windows.AppLifecycle.AppInstance.FindOrRegisterForKey("vinylshelffinder");
        for (int i = 0; restarting && !key.IsCurrent && i < 60; i++)
        {
            Thread.Sleep(250);
            key = Microsoft.Windows.AppLifecycle.AppInstance.FindOrRegisterForKey("vinylshelffinder");
        }
        if (key.IsCurrent) return key;
        var args = Microsoft.Windows.AppLifecycle.AppInstance.GetCurrent().GetActivatedEventArgs();
        Task.Run(async () => await key.RedirectActivationToAsync(args)).Wait();
        Environment.Exit(0);
        return null;
    }

    /// <summary>Registrerer vinylshelf:// for denne bruger (ingen administrator), så Windows åbner appen.</summary>
    private static void RegisterProtocol()
    {
        try
        {
            var exe = Environment.ProcessPath!;
            Microsoft.Windows.AppLifecycle.ActivationRegistrationManager.RegisterForProtocolActivation(
                "vinylshelf", exe + ",0", "Vinyl Shelf Finder", exe);
        }
        catch { /* Uden registrering virker alt andet stadig. */ }
    }

    /// <summary>Adressen fra en aktivering: vinylshelf://… som protokol eller som argument.</summary>
    internal static string? ScanCodeFrom(Microsoft.Windows.AppLifecycle.AppActivationArguments e)
    {
        if (e.Data is Windows.ApplicationModel.Activation.IProtocolActivatedEventArgs p) return p.Uri?.AbsoluteUri;
        if (e.Data is Windows.ApplicationModel.Activation.ILaunchActivatedEventArgs l)
            return l.Arguments?.Split(' ', StringSplitOptions.RemoveEmptyEntries).Select(a => a.Trim('"'))
                    .FirstOrDefault(a => a.StartsWith("vinylshelf://", StringComparison.OrdinalIgnoreCase));
        return null;
    }

    private async Task RunSmokeAsync(string dir)
    {
        try
        {
            Directory.CreateDirectory(dir);
            await Task.Delay(3000); // fortsætter på UI-tråden
            if (_window is null || _window.Content is null)
                throw new InvalidOperationException("Hovedvinduet blev ikke oprettet.");
            var m = _window.Model;
            var errors = new List<string>();
            _window.ResizeForSmoke(1280, 820);
            async Task Shot(string name)
            {
                await Task.Delay(700);
                try { await _window.SaveScreenshotAsync(Path.Combine(dir, name)); }
                catch (Exception ex) { errors.Add($"{name}: {ex}"); }
            }

            await Shot("01-start.png");
            if (m.Library.Copies.Count > 0)
            {
                m.Query = "beatles";
                await Shot("02-sog-og-plade.png");
                if (m.Selection is long sel)
                {
                    m.FindModeCopy = sel;
                    await Shot("03-find.png");
                    m.FindModeCopy = null;
                }
                if (m.Library.Locations.FirstOrDefault() is Location loc)
                {
                    m.Sidebar = SidebarItem.Search;
                    _window.OpenScanCode(ShelfLabel.Labels(m.Library)[0].ScanCode);
                    if (m.Sidebar != SidebarItem.ForSection(loc.Id)) throw new InvalidOperationException("vinylshelf://-adressen åbnede ikke sektionen");
                    await Shot("04-sektion.png");
                    m.ShowCoverFlow = true;
                    await Shot("04b-cover-flow.png");
                    m.ShowCoverFlow = false;
                }
                m.Sidebar = new SidebarItem(SidebarKind.SortList);
                if (m.Library.GlobalOrder.Count > 1) { m.SetSortChecked(m.Library.GlobalOrder[0], true); m.SetSortChecked(m.Library.GlobalOrder[1], true); }
                await Shot("04c-sorteringsliste.png");
                m.Medium = Medium.Cd;
                m.Sidebar = new SidebarItem(SidebarKind.SortList);
                await Shot("04d-sorteringsliste-cd.png");
                m.Medium = Medium.Vinyl;
                m.Sidebar = new SidebarItem(SidebarKind.Away);
                await Shot("05-ude-af-reolen.png");
                if (m.AwayItems.FirstOrDefault() is RecordItem away && m.Library.LocationOfCopy.ContainsKey(away.Id))
                {
                    m.ReturnCopy = away.Id;
                    await Shot("06-saet-tilbage.png");
                    m.ReturnCopy = null;
                }
            }
            if (m.Library.Copies.Count > 0)
            {
                m.Sidebar = new SidebarItem(SidebarKind.Listen);
                m.PickRecord();
                await Shot("07-hvad-skal-jeg-hore.png");
                if (m.Selection is long played) m.LogPlay(played);
                m.Sidebar = new SidebarItem(SidebarKind.Plays);
                await Shot("08-lyttelog.png");
                m.Sidebar = new SidebarItem(SidebarKind.FindNew);
                await Shot("12-find-nye-plader.png");
                m.Sidebar = new SidebarItem(SidebarKind.Value);
                await Shot("10-vaerdi.png");
                m.Sidebar = new SidebarItem(SidebarKind.History);
                await Shot("09-historik.png");
                // Lille vindue: plade-detaljen og Find skal kunne bruges ved 800×600.
                _window.ResizeForSmoke(800, 600);
                m.Sidebar = SidebarItem.Search;
                m.Query = "beatles";
                await Shot("13-smal-plade.png");
                if (m.Selection is long small)
                {
                    m.FindModeCopy = small;
                    await Shot("13b-smal-find.png");
                    m.FindModeCopy = null;
                }
                _window.ResizeForSmoke(1280, 820);
                // Udseende: stilene i lys og mørk tilstand (sættes tilbage bagefter).
                if (m.Library.Locations.FirstOrDefault() is Location first)
                {
                    m.Sidebar = SidebarItem.ForSection(first.Id);
                    foreach (var (style, theme) in new[] { (LookStyle.Kasse, LookTheme.Light), (LookStyle.Kasse, LookTheme.Dark), (LookStyle.Fokus, LookTheme.Light), (LookStyle.Cover, LookTheme.Dark) })
                    {
                        m.LookStyle = style;
                        m.LookTheme = theme;
                        await Shot($"14-stil-{style.Id()}-{theme.Id()}.png");
                    }
                    m.LookStyle = LookStyle.Standard;
                    m.LookTheme = LookTheme.Auto;
                }
                _window.OpenSettings();
                await Shot("11-indstillinger.png");
            }
            if (m.ErrorMessage is string err) errors.Add("Fejl i appen: " + err);
            if (errors.Count > 0) TryWrite(Path.Combine(dir, "screenshot-error.txt"), string.Join("\n\n", errors));
            File.WriteAllText(Path.Combine(dir, "smoke-ok.txt"), "OK");
            Environment.Exit(0);
        }
        catch (Exception ex)
        {
            TryWrite(Path.Combine(dir, "smoke-error.txt"), ex.ToString());
            Environment.Exit(1);
        }
    }

    private static void TryWrite(string path, string text)
    {
        try { File.WriteAllText(path, text); } catch { }
    }
}
