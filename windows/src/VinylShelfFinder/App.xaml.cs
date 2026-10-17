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
        // Demo og CI's smoke-test henter hverken covers eller opdateringer fra nettet.
        Ui.AllowNetworkCovers = !demo && _smokeDir is null;
        var updater = new Updater(enabled: _smokeDir is null && !demo);
        var model = new AppModel(demo);
        var imusic = new IMusicModel(enabled: !demo && _smokeDir is null);
        _window = new MainWindow(updater, model, imusic);
        _window.Activate();

        if (_smokeDir is not null)
            _ = RunSmokeAsync(_smokeDir);
        else
        {
            model.StartBackups();
            imusic.Start();
            _ = _window.CheckForUpdateOnLaunchAsync();
        }
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
                    m.Sidebar = SidebarItem.ForSection(loc.Id);
                    await Shot("04-sektion.png");
                    m.ShowCoverFlow = true;
                    await Shot("04b-cover-flow.png");
                    m.ShowCoverFlow = false;
                }
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
