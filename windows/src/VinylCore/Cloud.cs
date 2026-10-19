using System.Globalization;
using System.Net;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace VinylShelfFinder.Core;

// Port af Sources/VinylCore/Cloud.swift: kontoen i skyen (Supabase), login med e-mail (link eller kode),
// og hentning/afsendelse af poster. Kun den offentlige nøgle ligger i appen; den giver kun adgang
// til egne poster efter login (se supabase/schema.sql). Login gemmes i Legitimationsadministrator.

public static class CloudConfig
{
    public static readonly Uri Url = new("https://vbtxbnwcsipapnfiphlw.supabase.co/");
    /// Offentlig nøgle (publishable). Må ligge i appen; rækkerne er låst til den, der er logget ind.
    public const string PublishableKey = "sb_publishable_q7aX_h3J1W6uyvzQsYEk4Q_85bkkwQm";
    /// Hvor linket i login-mailen sender hen: appen selv. Skal stå under Redirect URLs i Supabase.
    public const string LoginRedirect = "vinylshelf://auth";
    /// Navnet i Legitimationsadministrator (samme som nøgleringen på Mac).
    public const string SecretName = "dk.vinylshelffinder.cloud";
}

/// Et login. Gemmes som JSON i Legitimationsadministrator.
public sealed record CloudSession(string AccessToken, string RefreshToken, double ExpiresAt, string UserId, string Email)
{
    public bool IsExpired => DateTimeOffset.UtcNow.ToUnixTimeSeconds() > ExpiresAt - 60;

    public string ToJson() => new JsonObject
    {
        ["accessToken"] = AccessToken, ["refreshToken"] = RefreshToken, ["expiresAt"] = ExpiresAt,
        ["userID"] = UserId, ["email"] = Email,
    }.ToJsonString();

    public static CloudSession? FromJson(string? json)
    {
        try
        {
            if (json is null || JsonNode.Parse(json) is not JsonObject o) return null;
            return new CloudSession(o["accessToken"]?.GetValue<string>() ?? "", o["refreshToken"]!.GetValue<string>(),
                o["expiresAt"]?.GetValue<double>() ?? 0, o["userID"]!.GetValue<string>(), o["email"]?.GetValue<string>() ?? "");
        }
        catch (Exception e) when (e is JsonException or InvalidOperationException or NullReferenceException) { return null; }
    }
}

public sealed class CloudException : Exception
{
    /// Login er udløbet eller tilbagekaldt: brugeren skal logge ind igen.
    public bool NeedsLogin { get; }
    public CloudException(string message, bool needsLogin = false) : base(message) => NeedsLogin = needsLogin;
}

public sealed class CloudClient
{
    private static readonly HttpClient SharedHttp = new() { Timeout = TimeSpan.FromSeconds(30) };
    private readonly Uri _base;
    private readonly string _key;
    private readonly HttpClient _http;

    public CloudClient(Uri? baseUrl = null, string? key = null, HttpClient? http = null)
    {
        _base = baseUrl ?? CloudConfig.Url;
        _key = key ?? CloudConfig.PublishableKey;
        _http = http ?? SharedHttp;
    }

    // MARK: Login

    /// Sender en login-mail (et link, der åbner appen, og en kode, hvis skabelonen viser den).
    /// Kontoen oprettes, hvis den ikke findes.
    public async Task RequestCodeAsync(string email) =>
        await SendAsync("POST", $"auth/v1/otp?redirect_to={Uri.EscapeDataString(CloudConfig.LoginRedirect)}",
            new JsonObject { ["email"] = email, ["create_user"] = true }, null).ConfigureAwait(false);

    /// Bytter en kode fra mailen for et login.
    public async Task<CloudSession> VerifyAsync(string email, string code)
    {
        var data = await SendAsync("POST", "auth/v1/verify", new JsonObject { ["type"] = "email", ["email"] = email, ["token"] = code }, null).ConfigureAwait(false);
        return SessionFrom(data, email);
    }

    /// Linket fra mailen, kopieret og indsat i appen (https://….supabase.co/auth/v1/verify?token=…&type=…).
    /// Appen bytter det selv for et login, så browseren ikke skal bruges. null, hvis teksten ikke er sådan et link.
    public static (string Token, string Type)? EmailLinkToken(string text)
    {
        if (!Uri.TryCreate(text.Trim(), UriKind.Absolute, out var url) || !url.AbsolutePath.EndsWith("/auth/v1/verify", StringComparison.Ordinal)) return null;
        var q = url.Query.TrimStart('?').Split('&', StringSplitOptions.RemoveEmptyEntries)
                   .Select(p => p.Split('=', 2)).Where(kv => kv.Length == 2)
                   .GroupBy(kv => Uri.UnescapeDataString(kv[0])).ToDictionary(g => g.Key, g => Uri.UnescapeDataString(g.First()[1]));
        if (!q.TryGetValue("token", out var token) || token.Length == 0) return null;
        return (token, q.TryGetValue("type", out var type) ? type : "magiclink");
    }

    public async Task<CloudSession?> VerifyEmailLinkAsync(string text)
    {
        if (EmailLinkToken(text) is not var (token, type)) return null;
        byte[] data;
        try { data = await SendAsync("POST", "auth/v1/verify", new JsonObject { ["type"] = type, ["token_hash"] = token }, null).ConfigureAwait(false); }
        catch (CloudException e) when (e.Message == ExpiredCode) { throw new CloudException(UsedLink); }
        return SessionFrom(data, "");
    }

    internal const string ExpiredCode = "Koden er forkert eller udløbet. Bed om en ny kode.";
    /// Hvert link virker kun én gang – også når man har klikket på det i mailen.
    public const string UsedLink = "Linket er allerede brugt eller er ikke fra den nyeste mail. Hvert link virker kun én gang – også hvis du har klikket på det. Bed om en ny mail, og klik ikke på linket.";

    // MARK: Adgangskode

    /// Mindste længde på en adgangskode (tjekkes i appen, før den sendes).
    public const int MinPasswordLength = 8;

    /// Login med e-mail og adgangskode. Adgangskoden vælges i appen, mens man er logget ind (SetPasswordAsync),
    /// så en ny enhed kan logge ind uden en mail.
    public async Task<CloudSession> SignInAsync(string email, string password)
    {
        var data = await SendAsync("POST", "auth/v1/token?grant_type=password", new JsonObject { ["email"] = email, ["password"] = password }, null).ConfigureAwait(false);
        return SessionFrom(data, email);
    }

    /// Vælger eller skifter kontoens adgangskode. Kræver login.
    public async Task SetPasswordAsync(string password, CloudSession s)
    {
        if (password.Length < MinPasswordLength) throw new CloudException(ShortPassword);
        await SendAsync("PUT", "auth/v1/user", new JsonObject { ["password"] = password }, s.AccessToken).ConfigureAwait(false);
    }

    public const string WrongPassword = "Forkert e-mail eller adgangskode. Har du valgt en adgangskode under Konto i appen på computeren?";
    public const string ShortPassword = "Adgangskoden er for kort. Brug mindst 8 tegn.";

    /// Fornyer et udløbet login.
    public async Task<CloudSession> RefreshAsync(CloudSession s)
    {
        var data = await SendAsync("POST", "auth/v1/token?grant_type=refresh_token", new JsonObject { ["refresh_token"] = s.RefreshToken }, null).ConfigureAwait(false);
        return SessionFrom(data, s.Email);
    }

    internal static CloudSession SessionFrom(byte[] data, string email)
    {
        try
        {
            var o = JsonNode.Parse(data)!.AsObject();
            var user = o["user"]!.AsObject();
            double expiresIn = o["expires_in"]?.GetValue<double>() ?? 3600;
            double expiresAt = o["expires_at"]?.GetValue<double>() ?? DateTimeOffset.UtcNow.ToUnixTimeSeconds() + expiresIn;
            return new CloudSession(o["access_token"]!.GetValue<string>(), o["refresh_token"]!.GetValue<string>(), expiresAt,
                user["id"]!.GetValue<string>(), user["email"]?.GetValue<string>() ?? email);
        }
        catch (Exception e) when (e is JsonException or InvalidOperationException or NullReferenceException)
        {
            throw new CloudException("Svaret fra kontoen kunne ikke læses.");
        }
    }

    /// Login fra linket i mailen: vinylshelf://auth#access_token=…&refresh_token=…&expires_at=…
    /// Virker også med en indsat adresse fra browseren (http://localhost:3000/#access_token=…).
    /// null, hvis adressen ikke er et login.
    public static CloudSession? SessionFromLink(string link)
    {
        if (!Uri.TryCreate(link.Trim(), UriKind.Absolute, out var url)) return null;
        var fragment = url.Fragment.TrimStart('#');
        bool isAppLink = url.Scheme == "vinylshelf" && url.Host == "auth";
        bool isPasted = (url.Scheme == "http" || url.Scheme == "https") && (fragment.Contains("access_token=") || fragment.Contains("error="));
        if (!isAppLink && !isPasted) return null;
        var raw = fragment.Length > 0 ? fragment : url.Query.TrimStart('?');
        var p = new Dictionary<string, string>();
        foreach (var pair in raw.Split('&', StringSplitOptions.RemoveEmptyEntries))
        {
            var kv = pair.Split('=', 2);
            if (kv.Length == 2) p[Uri.UnescapeDataString(kv[0])] = Uri.UnescapeDataString(kv[1].Replace('+', ' '));
        }
        if (p.TryGetValue("error_description", out var desc) || p.TryGetValue("error", out desc))
            throw new CloudException(desc.Contains("expired") || desc.Contains("invalid")
                ? "Linket er brugt eller udløbet. Bed om en ny mail."
                : $"Login mislykkedes: {desc}");
        if (!p.TryGetValue("access_token", out var access) || !p.TryGetValue("refresh_token", out var refresh)
            || JwtClaims(access) is not JsonObject claims || claims["sub"]?.GetValue<string>() is not string id)
            throw new CloudException("Linket kunne ikke læses. Bed om en ny mail.");
        double expiresAt = p.TryGetValue("expires_at", out var ea) && double.TryParse(ea, NumberStyles.Float, CultureInfo.InvariantCulture, out var e1) ? e1
            : claims["exp"]?.GetValue<double>() ?? DateTimeOffset.UtcNow.ToUnixTimeSeconds() + 3600;
        return new CloudSession(access, refresh, expiresAt, id, claims["email"]?.GetValue<string>() ?? "");
    }

    internal static JsonObject? JwtClaims(string jwt)
    {
        var parts = jwt.Split('.');
        if (parts.Length < 2) return null;
        var b = parts[1].Replace('-', '+').Replace('_', '/');
        while (b.Length % 4 != 0) b += "=";
        try { return JsonNode.Parse(Convert.FromBase64String(b)) as JsonObject; }
        catch (Exception e) when (e is FormatException or JsonException) { return null; }
    }

    // MARK: Poster

    /// Poster ændret siden `since` (serverens tid), og det nye `since`. Henter i sider á 1000.
    public async Task<(List<SyncDoc> Docs, string? Cursor)> FetchAsync(string? since, CloudSession s)
    {
        var docs = new List<SyncDoc>();
        var cursor = since;
        int offset = 0;
        // Lidt overlap, så en ændring, der blev gemt samtidig med den forrige hentning, ikke tabes.
        string? from = since is not null && ParseDate(since) is DateTimeOffset d ? IsoString(d.AddSeconds(-5)) : null;
        while (true)
        {
            var path = $"rest/v1/sync_records?select=kind,key,data,deleted,updated_at&order=updated_at.asc,kind.asc,key.asc&limit=1000&offset={offset}";
            if (from is not null) path += $"&updated_at=gte.{Uri.EscapeDataString(from)}";
            var data = await SendAsync("GET", path, null, s.AccessToken).ConfigureAwait(false);
            JsonArray rows;
            try { rows = JsonNode.Parse(data)!.AsArray(); }
            catch (Exception e) when (e is JsonException or InvalidOperationException or NullReferenceException) { throw new CloudException("Svaret fra kontoen kunne ikke læses."); }
            foreach (var r in rows.OfType<JsonObject>())
            {
                if (SyncKindExtensions.FromRaw(r["kind"]?.GetValue<string>()) is not SyncKind k || r["key"]?.GetValue<string>() is not string key) continue;
                bool deleted = r["deleted"]?.GetValue<bool>() == true;
                var payload = !deleted && r["data"] is JsonObject o ? (JsonObject)JsonNode.Parse(o.ToJsonString())! : null;
                docs.Add(new SyncDoc(k, key, payload));
                if (r["updated_at"]?.GetValue<string>() is string u) cursor = u;
            }
            if (rows.Count < 1000) break;
            offset += rows.Count;
        }
        return (docs, cursor);
    }

    /// Sender poster (i bunker á 500). Den nyeste ændring på serveren vinder.
    public async Task UpsertAsync(IReadOnlyList<SyncDoc> docs, CloudSession s, string device)
    {
        for (int start = 0; start < docs.Count; start += 500)
        {
            var rows = new JsonArray();
            foreach (var d in docs.Skip(start).Take(500))
                rows.Add(new JsonObject
                {
                    ["user_id"] = s.UserId, ["kind"] = d.Kind.RawValue(), ["key"] = d.Key, ["deleted"] = d.Data is null,
                    ["device"] = device, ["data"] = d.Data is null ? null : JsonNode.Parse(d.Data.ToJsonString()),
                });
            await SendAsync("POST", "rest/v1/sync_records?on_conflict=user_id,kind,key", rows, s.AccessToken,
                ("Prefer", "resolution=merge-duplicates,return=minimal")).ConfigureAwait(false);
        }
    }

    // MARK: HTTP

    private async Task<byte[]> SendAsync(string method, string path, JsonNode? body, string? token, params (string, string)[] headers)
    {
        using var msg = new HttpRequestMessage(new HttpMethod(method), new Uri(_base, path));
        msg.Headers.TryAddWithoutValidation("apikey", _key);
        msg.Headers.TryAddWithoutValidation("Authorization", $"Bearer {token ?? _key}");
        foreach (var (k, v) in headers) msg.Headers.TryAddWithoutValidation(k, v);
        if (body is not null) msg.Content = new StringContent(body.ToJsonString(), Encoding.UTF8, "application/json");
        HttpResponseMessage resp;
        try { resp = await _http.SendAsync(msg).ConfigureAwait(false); }
        catch (Exception e) when (e is HttpRequestException or TaskCanceledException)
        {
            throw new CloudException("Kontoen kunne ikke nås. Tjek internetforbindelsen, og prøv igen.");
        }
        using (resp)
        {
            var data = await resp.Content.ReadAsByteArrayAsync().ConfigureAwait(false);
            if (!resp.IsSuccessStatusCode) throw ErrorFrom((int)resp.StatusCode, data);
            return data;
        }
    }

    internal static CloudException ErrorFrom(int status, byte[] data)
    {
        string code = "";
        try
        {
            if (JsonNode.Parse(data) is JsonObject o)
                code = (o["error_code"] ?? o["code"] ?? o["error"]) is JsonValue v ? v.ToString() : "";
        }
        catch (JsonException) { }
        switch (code)
        {
            case "otp_expired": return new CloudException(ExpiredCode);
            case "invalid_credentials": return new CloudException(WrongPassword);
            case "weak_password": return new CloudException(ShortPassword);
            case "same_password": return new CloudException("Det er allerede din adgangskode.");
            case "over_email_send_rate_limit":
            case "over_request_rate_limit": return new CloudException("Der er sendt for mange koder for nylig. Vent lidt, og prøv igen.");
            case "email_address_invalid":
            case "validation_failed": return new CloudException("E-mailadressen ser forkert ud.");
            case "invalid_grant":
            case "refresh_token_not_found":
            case "refresh_token_already_used":
            case "session_not_found":
            case "bad_jwt": return new CloudException("Du skal logge ind igen.", needsLogin: true);
        }
        if (status == 401) return new CloudException("Du skal logge ind igen.", needsLogin: true);
        if (status == 429) return new CloudException("Der er sendt for mange forespørgsler. Vent lidt, og prøv igen.");
        return new CloudException($"Kontoen svarede med en fejl ({status}). Prøv igen senere.");
    }

    /// Serverens tidsstempler, fx "2026-10-18T15:01:02.123456+00:00".
    public static DateTimeOffset? ParseDate(string s) =>
        DateTimeOffset.TryParse(s, CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal, out var d) ? d : null;

    internal static string IsoString(DateTimeOffset d) => d.UtcDateTime.ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'", CultureInfo.InvariantCulture);
}

// MARK: Én synkronisering

/// Første gang på en konto, når både kontoen og denne enhed har reoler: hvilke skal bruges?
public enum FirstSync { UseCloud, UseThisDevice }

public sealed class NeedsChoiceException : Exception
{
    public int CloudSections { get; }
    public int LocalSections { get; }
    public NeedsChoiceException(int cloud, int local) : base("Kontoen og enheden har hver deres reoler.")
    {
        CloudSections = cloud;
        LocalSections = local;
    }
}

public sealed record CloudSyncReport(int Received, int Sent);

public static class CloudSync
{
    /// Henter nyt fra skyen, lægger det ind, og sender egne ændringer op.
    /// Kaster NeedsChoiceException, hvis kontoen og enheden begge har reoler første gang.
    /// <paramref name="safetyCopy"/> kaldes, før reoler på denne enhed slettes (fx en sikkerhedskopi). Fejler den, ændres intet.
    public static async Task<CloudSyncReport> RunAsync(ShelfStore store, CloudClient client, CloudSession session, string device,
                                                       FirstSync? firstSync = null, Action? safetyCopy = null)
    {
        // En anden konto end sidst: start forfra med sammenligningen.
        if (store.Setting("cloud_user") != session.UserId)
        {
            store.Db.Run("DELETE FROM sync_state");
            store.SetSetting("cloud_cursor", null);
        }
        var since = store.Setting("cloud_cursor");
        var (remote, cursor) = await client.FetchAsync(since, session);
        int sent = 0;
        bool copied = false;

        if (since is null)
        {
            var remoteLocations = remote.Where(d => d.Kind == SyncKind.Location && d.Data is not null).Select(d => d.Key).ToHashSet();
            store.EnsureSyncIds();
            var localLocations = store.Db.Query("SELECT uid FROM locations").Select(r => r.Text("uid")).OfType<string>().ToHashSet();
            if (remoteLocations.Count > 0 && localLocations.Count > 0 && !remoteLocations.Overlaps(localLocations))
            {
                switch (firstSync)
                {
                    case null:
                        throw new NeedsChoiceException(remoteLocations.Count, localLocations.Count);
                    case FirstSync.UseCloud:
                        safetyCopy?.Invoke();
                        copied = true;
                        store.Db.Transaction(() =>
                        {
                            store.Db.Run("DELETE FROM placements");
                            store.Db.Run("DELETE FROM locations");
                        });
                        break;
                    case FirstSync.UseThisDevice:
                        // Kontoens reoler slettes; resten (plader, afspilninger, indstillinger) flettes.
                        var deletions = remote.Where(d => d.Kind is SyncKind.Location or SyncKind.Section)
                                              .Select(d => new SyncDoc(d.Kind, d.Key, null)).ToList();
                        remote = remote.Where(d => d.Kind is not (SyncKind.Location or SyncKind.Section)).ToList();
                        await client.UpsertAsync(deletions, session, device);
                        sent += deletions.Count;
                        break;
                }
            }
        }

        // En anden enhed har slettet reoler, som findes her.
        if (!copied && remote.Any(d => d.Kind == SyncKind.Location && d.Data is null && store.HasLocation(d.Key)))
            safetyCopy?.Invoke();

        int received = store.ApplySyncDocs(remote);
        store.SetSetting("cloud_user", session.UserId);
        var pending = store.PendingSyncDocs();
        if (pending.Count > 0)
        {
            await client.UpsertAsync(pending, session, device);
            store.MarkSynced(pending);
            sent += pending.Count;
        }
        if (cursor is not null) store.SetSetting("cloud_cursor", cursor);
        return new CloudSyncReport(received, sent);
    }
}
