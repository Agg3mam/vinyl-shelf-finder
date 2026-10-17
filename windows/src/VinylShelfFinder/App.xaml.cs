using System.Globalization;
using Microsoft.UI.Xaml;

namespace VinylShelfFinder;

/// <summary>
/// Appens start. Med argumentet <c>--smoke [mappe]</c> åbner appen hovedvinduet, venter ca. 3 s,
/// skriver "OK" i mappe/smoke-ok.txt, gemmer et billede af vinduet i mappe/main-window.png og lukker.
/// Bruges af CI til at bevise, at appen faktisk starter på Windows.
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

        _window = new MainWindow();
        _window.Activate();

        if (_smokeDir is not null)
            _ = RunSmokeAsync(_smokeDir);
    }

    private async Task RunSmokeAsync(string dir)
    {
        try
        {
            Directory.CreateDirectory(dir);
            await Task.Delay(3000); // fortsætter på UI-tråden
            if (_window is null || _window.Content is null)
                throw new InvalidOperationException("Hovedvinduet blev ikke oprettet.");
            File.WriteAllText(Path.Combine(dir, "smoke-ok.txt"), "OK");

            try
            {
                await _window.SaveScreenshotAsync(Path.Combine(dir, "main-window.png"));
            }
            catch (Exception ex)
            {
                TryWrite(Path.Combine(dir, "screenshot-error.txt"), ex.ToString());
            }
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
