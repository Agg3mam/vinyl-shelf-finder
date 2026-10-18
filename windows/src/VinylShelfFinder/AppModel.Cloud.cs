using VinylShelfFinder.Core;

namespace VinylShelfFinder;

// Kontoen i skyen (port af AppModel+Cloud.swift): login med e-mail (link eller kode) og automatisk
// synkronisering (ved start, kort efter hver ændring og hvert 5. minut). Slået fra i demo og smoke-test.
public sealed partial class AppModel
{
    private const string CloudDevice = "windows";
    private readonly CloudClient _cloud = new();
    private readonly ISecretStore _cloudSecret = new WindowsCredentialStore(CloudConfig.SecretName);
    private CloudSession? _cloudSession;
    private CancellationTokenSource? _cloudDebounce;
    private bool _cloudTimerRunning;
    private bool _cloudApplying;
    private bool _cloudStarted;

    private bool _cloudLoggedIn;
    /// Logget ind på kontoen?
    public bool CloudLoggedIn { get => _cloudLoggedIn; private set { if (Set(ref _cloudLoggedIn, value)) OnChanged(nameof(NeedsOnboarding)); } }
    private string? _cloudEmail;
    public string? CloudEmail { get => _cloudEmail; private set => Set(ref _cloudEmail, value); }
    private bool _cloudSyncing;
    public bool CloudSyncing { get => _cloudSyncing; private set => Set(ref _cloudSyncing, value); }
    private string? _cloudMessage;
    /// Fejl eller besked til fanen Konto.
    public string? CloudMessage { get => _cloudMessage; private set => Set(ref _cloudMessage, value); }
    private DateTimeOffset? _cloudLastSync;
    public DateTimeOffset? CloudLastSync { get => _cloudLastSync; private set => Set(ref _cloudLastSync, value); }
    private NeedsChoiceException? _cloudChoice;
    /// Første gang: kontoen og denne pc har hver deres reoler.
    public NeedsChoiceException? CloudChoice { get => _cloudChoice; set => Set(ref _cloudChoice, value); }

    public bool CloudEnabled => !IsDemo;

    public void StartCloud()
    {
        if (!CloudEnabled) return;
        _cloudStarted = true;
        CloudLoggedIn = _cloudSecret.Exists;
        CloudEmail = Store.Setting("cloud_email");
        if (double.TryParse(Store.Setting("cloud_last_sync"), System.Globalization.NumberStyles.Float,
                System.Globalization.CultureInfo.InvariantCulture, out var t))
            CloudLastSync = DateTimeOffset.FromUnixTimeMilliseconds((long)(t * 1000));
        if (!CloudLoggedIn) return;
        _ = SyncCloudAsync();
        if (!_cloudTimerRunning) _ = CloudTimerAsync();
    }

    private async Task CloudTimerAsync()
    {
        _cloudTimerRunning = true;
        while (CloudLoggedIn)
        {
            await Task.Delay(TimeSpan.FromMinutes(5));
            await SyncCloudAsync();
        }
        _cloudTimerRunning = false;
    }

    /// Kort efter en ændring (flere ændringer i træk giver én synkronisering).
    public void CloudChanged()
    {
        if (!_cloudStarted || !CloudLoggedIn) return;
        _cloudDebounce?.Cancel();
        var cts = _cloudDebounce = new CancellationTokenSource();
        _ = DebouncedAsync(cts.Token);
    }

    private async Task DebouncedAsync(CancellationToken ct)
    {
        try { await Task.Delay(TimeSpan.FromSeconds(4), ct); } catch (TaskCanceledException) { return; }
        await SyncCloudAsync();
    }

    // MARK: Login

    public async Task<bool> RequestCloudCodeAsync(string email)
    {
        try { await _cloud.RequestCodeAsync(email.Trim().ToLowerInvariant()); CloudMessage = null; return true; }
        catch (Exception ex) { CloudMessage = ex.Message; return false; }
    }

    public async Task<bool> VerifyCloudCodeAsync(string email, string code)
    {
        try
        {
            var s = await _cloud.VerifyAsync(email.Trim().ToLowerInvariant(), new string(code.Where(char.IsDigit).ToArray()));
            LoggedIn(s);
            return true;
        }
        catch (Exception ex) { CloudMessage = ex.Message; return false; }
    }

    /// Linket i login-mailen (vinylshelf://auth#…) eller en indsat adresse fra browseren.
    /// Returnerer true, hvis adressen var et login.
    public bool CompleteCloudLink(string link)
    {
        try
        {
            if (CloudClient.SessionFromLink(link) is not CloudSession s) return false;
            if (CloudEnabled) LoggedIn(s);
        }
        catch (CloudException ex) { CloudMessage = ex.Message; }
        return true;
    }

    /// Feltet i fanen Konto: koden fra mailen eller det kopierede link.
    public async Task<bool> CompleteCloudInputAsync(string email, string text)
    {
        var t = text.Trim();
        if (t.Contains('/') || t.Contains(':')) return await CompleteCloudPasteAsync(t);
        return await VerifyCloudCodeAsync(email, t);
    }

    /// Indsat tekst i fanen Konto: linket fra mailen, eller adressen fra en browserside.
    public async Task<bool> CompleteCloudPasteAsync(string text)
    {
        try
        {
            if (await _cloud.VerifyEmailLinkAsync(text) is CloudSession s) { LoggedIn(s); return true; }
        }
        catch (Exception ex) { CloudMessage = ex.Message; return false; }
        if (CompleteCloudLink(text)) return CloudLoggedIn;
        CloudMessage = "Det indsatte er ikke et login-link. Kopiér linket fra mailen (højreklik › Kopiér link).";
        return false;
    }

    private void LoggedIn(CloudSession s)
    {
        SaveCloudSession(s);
        var email = s.Email.Length > 0 ? s.Email : CloudEmail ?? "";
        CloudEmail = email;
        Store.SetSetting("cloud_email", email);
        CloudMessage = null;
        StartCloud();
    }

    public void LogOutCloud()
    {
        _cloudDebounce?.Cancel();
        _cloudSecret.Delete();
        _cloudSession = null;
        CloudLoggedIn = false;
        CloudMessage = null;
        // Data på denne pc bliver, hvor de er. Næste login sammenligner forfra.
        Store.SetSetting("cloud_cursor", null);
        Store.SetSetting("cloud_user", null);
    }

    private void SaveCloudSession(CloudSession s)
    {
        // Legitimationsadministrator rummer højst 2.560 byte; adgangsnøglen kan altid fornyes.
        try { _cloudSecret.Save(s.ToJson()); }
        catch (InvalidOperationException) { _cloudSecret.Save((s with { AccessToken = "", ExpiresAt = 0 }).ToJson()); }
        _cloudSession = s;
    }

    private async Task<CloudSession> ValidCloudSessionAsync()
    {
        _cloudSession ??= CloudSession.FromJson(_cloudSecret.Load());
        if (_cloudSession is not CloudSession s) throw new CloudException("Du skal logge ind igen.", needsLogin: true);
        if (s.IsExpired || s.AccessToken.Length == 0)
        {
            s = await _cloud.RefreshAsync(s);
            SaveCloudSession(s);
        }
        return s;
    }

    // MARK: Synkronisering

    public async Task SyncCloudAsync(FirstSync? firstSync = null)
    {
        if (!CloudEnabled || !CloudLoggedIn || CloudSyncing) return;
        CloudSyncing = true;
        try
        {
            var s = await ValidCloudSessionAsync();
            var report = await CloudSync.RunAsync(Store, _cloud, s, CloudDevice, firstSync);
            if (report.Received > 0)
            {
                _cloudApplying = true;
                try { ReloadSettingsFromStore(); Reload(); }
                finally { _cloudApplying = false; }
            }
            CloudLastSync = DateTimeOffset.Now;
            Store.SetSetting("cloud_last_sync", (DateTimeOffset.Now.ToUnixTimeMilliseconds() / 1000.0).ToString("R", System.Globalization.CultureInfo.InvariantCulture));
            CloudMessage = null;
        }
        catch (NeedsChoiceException choice) { CloudChoice = choice; }
        catch (CloudException ex) when (ex.NeedsLogin)
        {
            LogOutCloud();
            CloudMessage = "Du er logget ud af kontoen. Log ind igen for at synkronisere.";
        }
        catch (Exception ex) { CloudMessage = ex is CloudException ? ex.Message : Describe(ex); }
        finally { CloudSyncing = false; }
    }

    public void ResolveCloudChoice(FirstSync choice)
    {
        CloudChoice = null;
        _ = SyncCloudAsync(choice);
    }
}
