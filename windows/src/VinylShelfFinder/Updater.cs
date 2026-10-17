using System.Diagnostics;
using System.IO.Compression;
using System.Net.Http.Headers;
using System.Reflection;
using System.Text;
using System.Text.Json;
using VinylShelfFinder.Core;

namespace VinylShelfFinder;

/// <summary>
/// "Ny version klar" (som Updater.swift): appen tjekker GitHub én gang om dagen, viser versionen
/// og henter den på brugerens ja. Zip'en pakkes ud i en midlertidig mappe og tjekkes; derefter
/// kopierer et lille PowerShell-script de nye filer over de gamle, når appen er lukket, og åbner
/// appen igen. Data ligger i %LOCALAPPDATA%\VinylShelfFinder og røres ikke.
/// </summary>
public sealed class Updater
{
    public enum Phase { Idle, Checking, UpToDate, Available, Downloading, Installing, Failed }

    public Phase State { get; private set; } = Phase.Idle;
    public UpdateRelease? Release { get; private set; }
    public string? Message { get; private set; }
    public DateTimeOffset? LastChecked { get; private set; }
    public bool Enabled { get; }
    public string CurrentVersion { get; }

    /// Kaldes på UI-tråden, når State ændrer sig.
    public event Action? Changed;

    private readonly string _stateFile;
    private string? _skippedTag;
    private static readonly HttpClient Http = new() { Timeout = TimeSpan.FromMinutes(5) };

    public Updater(bool enabled)
    {
        Enabled = enabled;
        var v = Assembly.GetExecutingAssembly().GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion ?? "0";
        CurrentVersion = AppVersion.Parse(v)?.ToString() ?? v;
        var dir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "VinylShelfFinder");
        _stateFile = Path.Combine(dir, "update.json");
        LoadState();
    }

    /// Ved start: tjek, hvis der er gået et døgn. Giver true, hvis brugeren skal spørges.
    public async Task<bool> CheckOnLaunchAsync()
    {
        if (!Enabled || !AppUpdate.IsCheckDue(LastChecked, DateTimeOffset.Now)) return false;
        await CheckAsync();
        return State == Phase.Available && Release is not null && Release.Tag != _skippedTag;
    }

    public async Task CheckAsync()
    {
        if (!Enabled) return;
        Set(Phase.Checking);
        try
        {
            using var req = new HttpRequestMessage(HttpMethod.Get, AppUpdate.LatestUrl);
            req.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("application/vnd.github+json"));
            req.Headers.UserAgent.ParseAdd($"VinylShelfFinder/{CurrentVersion}");
            using var resp = await Http.SendAsync(req);
            LastChecked = DateTimeOffset.Now;
            SaveState();
            // 404: der er endnu ingen udgivelse.
            if ((int)resp.StatusCode == 404) { Release = null; Set(Phase.UpToDate); return; }
            if (!resp.IsSuccessStatusCode)
            {
                Set(Phase.Failed, $"GitHub svarede ikke som ventet ({(int)resp.StatusCode}). Prøv igen senere.");
                return;
            }
            var r = AppUpdate.ParseLatest(await resp.Content.ReadAsStringAsync());
            Release = r is not null && AppUpdate.IsNewer(r, CurrentVersion) ? r : null;
            Set(Release is null ? Phase.UpToDate : Phase.Available);
        }
        catch (Exception)
        {
            Set(Phase.Failed, "Kunne ikke tjekke for en ny version. Tjek internetforbindelsen, og prøv igen.");
        }
    }

    /// "Senere": spørg ikke igen ved start om netop denne version.
    public void Postpone(UpdateRelease release)
    {
        _skippedTag = release.Tag;
        SaveState();
    }

    /// "Opdatér nu": henter, tjekker og starter udskiftningen. Lukker appen, hvis alt gik godt.
    public async Task InstallAsync(UpdateRelease release)
    {
        Set(Phase.Downloading);
        var work = Path.Combine(Path.GetTempPath(), "vsf-update-" + Guid.NewGuid().ToString("N"));
        try
        {
            var target = AppContext.BaseDirectory.TrimEnd(Path.DirectorySeparatorChar);
            if (!CanWrite(target))
                throw new UpdateError($"Appen ligger et sted, hvor den ikke kan skrive ({target}). Pak den ud i din egen mappe, og prøv igen.");

            Directory.CreateDirectory(work);
            var zip = Path.Combine(work, "app.zip");
            await DownloadAsync(release, zip);

            Set(Phase.Installing);
            var unpacked = Path.Combine(work, "ny");
            ZipFile.ExtractToDirectory(zip, unpacked);
            // Zip'en fra windows.yml indeholder mappen VinylShelfFinder med exe'en.
            var newDir = Path.Combine(unpacked, "VinylShelfFinder");
            if (!File.Exists(Path.Combine(newDir, "VinylShelfFinder.exe")))
                throw new UpdateError("Den hentede fil er ikke Vinyl Shelf Finder. Intet er ændret.");

            StartReplaceScript(newDir, target, work);
            Environment.Exit(0);
        }
        catch (Exception e)
        {
            try { Directory.Delete(work, true); } catch { }
            Set(Phase.Failed, (e as UpdateError)?.Message ?? "Opdateringen mislykkedes. Den gamle version er uændret.");
        }
    }

    private async Task DownloadAsync(UpdateRelease release, string path)
    {
        using var req = new HttpRequestMessage(HttpMethod.Get, release.DownloadUrl);
        req.Headers.UserAgent.ParseAdd($"VinylShelfFinder/{CurrentVersion}");
        using var resp = await Http.SendAsync(req, HttpCompletionOption.ResponseHeadersRead);
        var final = resp.RequestMessage?.RequestUri;
        if (!resp.IsSuccessStatusCode || final is null || final.Scheme != "https" || !AppUpdate.IsTrustedHost(final.Host))
            throw new UpdateError("Kunne ikke hente den nye version fra GitHub.");
        await using (var file = File.Create(path))
            await resp.Content.CopyToAsync(file);
        if (release.Size is long size && new FileInfo(path).Length != size)
            throw new UpdateError("Den hentede fil er ufuldstændig. Prøv igen.");
    }

    /// Venter på, at appen lukker, kopierer de nye filer ind (gamle filer overskrives) og åbner appen igen.
    private static void StartReplaceScript(string newDir, string target, string work)
    {
        static string Q(string s) => "'" + s.Replace("'", "''") + "'";
        var exe = Path.Combine(target, "VinylShelfFinder.exe");
        var script = $$"""
            $ErrorActionPreference = 'Stop'
            Wait-Process -Id {{Environment.ProcessId}} -Timeout 60 -ErrorAction SilentlyContinue
            for ($i = 0; $i -lt 10; $i++) {
              try { Copy-Item -Path (Join-Path {{Q(newDir)}} '*') -Destination {{Q(target)}} -Recurse -Force; break }
              catch { Start-Sleep -Seconds 1 }
            }
            Start-Process -FilePath {{Q(exe)}}
            Start-Sleep -Seconds 2
            Remove-Item -LiteralPath {{Q(work)}} -Recurse -Force -ErrorAction SilentlyContinue
            """;
        var encoded = Convert.ToBase64String(Encoding.Unicode.GetBytes(script));
        Process.Start(new ProcessStartInfo("powershell.exe",
            $"-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -EncodedCommand {encoded}")
        {
            UseShellExecute = false,
            CreateNoWindow = true,
        });
    }

    private static bool CanWrite(string dir)
    {
        try
        {
            var probe = Path.Combine(dir, ".vsf-skrivetest");
            File.WriteAllText(probe, "");
            File.Delete(probe);
            return true;
        }
        catch { return false; }
    }

    private void Set(Phase phase, string? message = null)
    {
        State = phase;
        Message = message;
        Changed?.Invoke();
    }

    private sealed record StateFile(DateTimeOffset? LastChecked, string? SkippedTag);

    private void LoadState()
    {
        try
        {
            var s = JsonSerializer.Deserialize<StateFile>(File.ReadAllText(_stateFile));
            LastChecked = s?.LastChecked;
            _skippedTag = s?.SkippedTag;
        }
        catch { }
    }

    private void SaveState()
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(_stateFile)!);
            File.WriteAllText(_stateFile, JsonSerializer.Serialize(new StateFile(LastChecked, _skippedTag)));
        }
        catch { }
    }

    private sealed class UpdateError(string message) : Exception(message);
}
