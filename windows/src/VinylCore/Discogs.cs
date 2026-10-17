using System.Net;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace VinylShelfFinder.Core;

// Port af Sources/VinylCore/Discogs.swift: API-klient, danske fejl og samlingen.

public enum DiscogsErrorKind { MissingToken, Unauthorized, Http, RateLimited, Decoding, Offline }

/// Fejl fra Discogs med dansk tekst i Message. Tokenet står aldrig i teksten.
public sealed class DiscogsException : Exception
{
    public DiscogsErrorKind Kind { get; }
    /// HTTP-koden (kun for Kind == Http).
    public int StatusCode { get; }
    /// Hvad der ikke kunne læses (kun for Kind == Decoding).
    public string? Detail { get; }

    private DiscogsException(DiscogsErrorKind kind, int statusCode = 0, string? detail = null)
        : base(Describe(kind, statusCode, detail))
    {
        Kind = kind; StatusCode = statusCode; Detail = detail;
    }

    public static DiscogsException MissingToken() => new(DiscogsErrorKind.MissingToken);
    public static DiscogsException Unauthorized() => new(DiscogsErrorKind.Unauthorized);
    public static DiscogsException Http(int code) => new(DiscogsErrorKind.Http, code);
    public static DiscogsException RateLimited() => new(DiscogsErrorKind.RateLimited);
    public static DiscogsException Decoding(string what) => new(DiscogsErrorKind.Decoding, detail: what);
    /// Ingen forbindelse til Discogs (fx intet internet). Så netværksfejl vises på dansk.
    public static DiscogsException Offline() => new(DiscogsErrorKind.Offline);

    /// 404 beholdes som Http(404), så kaldere kan genkende "findes ikke".
    public bool IsNotFound => Kind == DiscogsErrorKind.Http && StatusCode == 404;

    public static string Describe(DiscogsErrorKind kind, int statusCode = 0, string? detail = null) => kind switch
    {
        DiscogsErrorKind.MissingToken => "Der er ikke gemt noget Discogs-token.",
        DiscogsErrorKind.Unauthorized => "Discogs-tokenet blev afvist. Kontrollér, at det er korrekt.",
        DiscogsErrorKind.Http when statusCode == 404 => "Pladen findes ikke længere på Discogs.",
        DiscogsErrorKind.Http => $"Discogs svarede med en fejl (kode {statusCode}). Prøv igen senere.",
        DiscogsErrorKind.RateLimited => "Discogs begrænser antallet af forespørgsler. Prøv igen om et øjeblik.",
        DiscogsErrorKind.Decoding => $"Svaret fra Discogs kunne ikke læses ({detail}).",
        // Mac: "Tjek, at Mac'en er på internettet" – på Windows står der computeren.
        _ => "Kunne ikke få forbindelse til Discogs. Tjek, at computeren er på internettet, og prøv igen.",
    };
}

/// En forespørgsel til Discogs' API, bygget uden at blive sendt (bruges også af checks).
/// ToString viser aldrig Authorization-headeren.
public sealed class DiscogsRequest
{
    public HttpMethod Method { get; }
    public Uri Url { get; }
    private readonly Dictionary<string, string> _headers;

    internal DiscogsRequest(HttpMethod method, Uri url, Dictionary<string, string> headers)
    {
        Method = method; Url = url; _headers = headers;
    }

    /// Værdien af en header (fx "User-Agent"), eller null.
    public string? Header(string name) =>
        _headers.FirstOrDefault(h => string.Equals(h.Key, name, StringComparison.OrdinalIgnoreCase)).Value;

    /// Navnene på de headere, der sendes (uden værdier).
    public IEnumerable<string> HeaderNames => _headers.Keys;

    /// Laver en ny HttpRequestMessage (en besked kan kun sendes én gang).
    internal HttpRequestMessage ToHttpRequestMessage()
    {
        var msg = new HttpRequestMessage(Method, Url);
        foreach (var (k, v) in _headers) msg.Headers.TryAddWithoutValidation(k, v);
        // Tom krop → Content-Length: 0 ved PUT/POST.
        if (Method != HttpMethod.Get) msg.Content = new ByteArrayContent(Array.Empty<byte>());
        return msg;
    }

    public override string ToString() => $"{Method} {Url.AbsoluteUri}";
}

/// Discogs API-klient (personal access token). Tokenet logges eller vises aldrig.
public sealed partial class DiscogsClient
{
    private readonly string _token;
    private readonly HttpClient _http;
    /// Fælles kø for alle klienter i appen (Discogs' grænse gælder hele kontoen).
    private readonly DiscogsRateLimiter _limiter;
    /// Cache til søgninger og udgaver (null = ingen cache).
    private readonly DiscogsResponseCache? _cache;

    public const string UserAgent = "VinylShelfFinder/1.0 +https://github.com/local/vinyl-shelf-finder";
    private const string BaseUrl = "https://api.discogs.com";

    private static readonly HttpClient SharedHttp = new();

    public DiscogsClient(string token, HttpClient? http = null, DiscogsRateLimiter? limiter = null, DiscogsResponseCache? cache = null)
    {
        _token = token ?? "";
        _http = http ?? SharedHttp;
        _limiter = limiter ?? DiscogsRateLimiter.Shared;
        _cache = cache;
    }

    /// Om der overhovedet er et token (uden at afsløre det).
    public bool HasToken => !string.IsNullOrWhiteSpace(_token);

    /// Tokenet må aldrig ende i logs, fejlbeskeder eller udskrifter af klienten.
    public override string ToString() => "DiscogsClient(token: skjult)";

    /// Bygger en forespørgsel til Discogs' API uden at sende den (ren funktion, bruges også af checks).
    /// Tokenet ligger kun i Authorization-headeren – aldrig i URL'en – og må aldrig logges.
    public DiscogsRequest MakeRequest(string method = "GET", string path = "/", IEnumerable<(string Name, string Value)>? query = null)
    {
        var url = new StringBuilder(BaseUrl);
        if (!path.StartsWith('/')) url.Append('/');
        url.Append(path);
        var items = query?.ToList() ?? new();
        if (items.Count > 0)
            url.Append('?').Append(string.Join("&", items.Select(q => $"{Uri.EscapeDataString(q.Name)}={Uri.EscapeDataString(q.Value)}")));
        var headers = new Dictionary<string, string>
        {
            ["Authorization"] = $"Discogs token={_token}",
            ["User-Agent"] = UserAgent,
            ["Accept"] = "application/vnd.discogs.v2.discogs+json",
        };
        return new DiscogsRequest(new HttpMethod(method), new Uri(url.ToString()), headers);
    }

    /// GET. Søgninger og udgaver (IsCacheable) tages fra cachen, hvis klienten har en.
    internal Task<byte[]> GetAsync(string path, IEnumerable<(string, string)>? query = null,
                                   DiscogsPriority priority = DiscogsPriority.Background, CancellationToken ct = default)
    {
        var req = MakeRequest(path: path, query: query);
        if (_cache == null || !IsCacheable(path)) return PerformAsync(req, priority, ct);
        // Et fælles kald i cachen må ikke afbrydes af én kalder.
        return _cache.DataAsync(req.Url.AbsoluteUri, () => PerformAsync(req, priority, CancellationToken.None), ct);
    }

    /// Søgninger og albums udgaver ændrer sig sjældent og må gemmes i cachen.
    /// Priser, samlingen og kontoen hentes altid frisk.
    internal static bool IsCacheable(string path) =>
        path.StartsWith("/database/search", StringComparison.Ordinal) || path.StartsWith("/masters/", StringComparison.Ordinal);

    /// Sender en forespørgsel med en anden metode (fx PUT) med samme rate limit og fejlhåndtering som GET.
    internal Task<byte[]> SendAsync(string method, string path, IEnumerable<(string, string)>? query = null, CancellationToken ct = default) =>
        PerformAsync(MakeRequest(method, path, query), DiscogsPriority.Interactive, ct);

    /// Fælles afsendelse: fælles kø (rate limit), genforsøg ved 429 og danske fejl.
    internal async Task<byte[]> PerformAsync(DiscogsRequest req, DiscogsPriority priority = DiscogsPriority.Interactive, CancellationToken ct = default)
    {
        for (int attempt = 0; attempt < 5; attempt++)
        {
            await _limiter.AcquireAsync(priority, ct).ConfigureAwait(false);
            HttpStatusCode status;
            byte[] data;
            int? remaining = null;
            try
            {
                using var msg = req.ToHttpRequestMessage();
                using var resp = await _http.SendAsync(msg, ct).ConfigureAwait(false);
                status = resp.StatusCode;
                data = await resp.Content.ReadAsByteArrayAsync(ct).ConfigureAwait(false);
                if (resp.Headers.TryGetValues("X-Discogs-Ratelimit-Remaining", out var values)
                    && int.TryParse(values.FirstOrDefault(), out var r)) remaining = r;
            }
            catch (OperationCanceledException) when (ct.IsCancellationRequested) { throw; }
            // Timeout, intet net, afbrudt forbindelse. Den indre fejl gemmes ikke (kun dansk tekst).
            catch (OperationCanceledException) { throw DiscogsException.Offline(); }
            catch (HttpRequestException) { throw DiscogsException.Offline(); }
            catch (IOException) { throw DiscogsException.Offline(); }

            int code = (int)status;
            if (code >= 200 && code < 300)
            {
                // Næsten ingen kald tilbage i minuttet → kort pause for alle kald i appen.
                _limiter.Observe(remaining);
                return data;
            }
            if (code == 401 || code == 403) throw DiscogsException.Unauthorized();
            if (code == 429)
            {
                // Køen holder pause; næste forsøg venter i AcquireAsync.
                _limiter.BackOff(5 + attempt * 5);
                continue;
            }
            throw DiscogsException.Http(code);
        }
        throw DiscogsException.RateLimited();
    }

    internal static string EscapePath(string s) => Uri.EscapeDataString(s);

    /// Returnerer brugernavnet for tokenet.
    public async Task<string> IdentityAsync(CancellationToken ct = default)
    {
        var data = await GetAsync("/oauth/identity", priority: DiscogsPriority.Interactive, ct: ct).ConfigureAwait(false);
        try
        {
            using var doc = JsonDocument.Parse(data);
            if (Json.Str(Json.Prop(doc.RootElement, "username")) is string name) return name;
        }
        catch (JsonException) { }
        throw DiscogsException.Decoding("dine kontooplysninger");
    }

    /// Henter hele Collection (mappe 0 = "All"). progress får (hentet indtil nu, i alt).
    public async Task<List<DiscogsCollectionItem>> FetchCollectionAsync(string username, Action<int, int>? progress = null, CancellationToken ct = default)
    {
        int page = 1, pages;
        var all = new List<DiscogsCollectionItem>();
        var user = EscapePath(username);
        do
        {
            var data = await GetAsync($"/users/{user}/collection/folders/0/releases", new[]
            {
                ("per_page", "100"), ("page", page.ToString()), ("sort", "artist"), ("sort_order", "asc"),
            }, ct: ct).ConfigureAwait(false);
            DiscogsCollectionPage decoded;
            try { decoded = ParseCollectionPage(data); }
            catch (DiscogsException) { throw DiscogsException.Decoding($"samlingen, side {page}"); }
            pages = decoded.Pages;
            all.AddRange(decoded.Items);
            progress?.Invoke(all.Count, decoded.Total);
            page++;
        } while (page <= pages);
        return all;
    }

    // MARK: JSON

    /// Én side af samlingen. Mangler de nødvendige felter, kastes DiscogsException (Decoding).
    public static DiscogsCollectionPage ParseCollectionPage(byte[] data)
    {
        try
        {
            using var doc = JsonDocument.Parse(data);
            var root = doc.RootElement;
            var pag = Json.Prop(root, "pagination") ?? throw new FormatException();
            var pages = Json.Int(Json.Prop(pag, "pages")) ?? throw new FormatException();
            var total = Json.Int(Json.Prop(pag, "items")) ?? throw new FormatException();
            var releases = Json.Prop(root, "releases");
            if (releases is not { ValueKind: JsonValueKind.Array } list) throw new FormatException();
            var items = new List<DiscogsCollectionItem>();
            foreach (var it in list.EnumerateArray()) items.Add(ConvertCollectionItem(it));
            return new DiscogsCollectionPage(items, pages, total);
        }
        catch (Exception e) when (e is JsonException or FormatException or InvalidOperationException)
        {
            throw DiscogsException.Decoding("samlingen");
        }
    }

    private static DiscogsCollectionItem ConvertCollectionItem(JsonElement it)
    {
        var instanceId = Json.Int(Json.Prop(it, "instance_id")) ?? throw new FormatException();
        _ = Json.Int(Json.Prop(it, "id")) ?? throw new FormatException();
        var b = Json.Prop(it, "basic_information") ?? throw new FormatException();
        var id = Json.Int(Json.Prop(b, "id")) ?? throw new FormatException();
        var title = Json.Str(Json.Prop(b, "title")) ?? throw new FormatException();
        var year = Json.Int(Json.Prop(b, "year"));

        var label = Json.Array(Json.Prop(b, "labels")).FirstOrDefault();
        string? labelName = label.ValueKind == JsonValueKind.Object ? Json.Str(Json.Prop(label, "name")) : null;
        string? catno = label.ValueKind == JsonValueKind.Object ? Json.Str(Json.Prop(label, "catno")) : null;

        string? fmt = null;
        var f = Json.Array(Json.Prop(b, "formats")).FirstOrDefault();
        if (f.ValueKind == JsonValueKind.Object)
        {
            var parts = new List<string>();
            var name = Json.Str(Json.Prop(f, "name"));
            var qty = Json.Str(Json.Prop(f, "qty"));
            if (qty != null && int.TryParse(qty, System.Globalization.NumberStyles.AllowLeadingSign,
                    System.Globalization.CultureInfo.InvariantCulture, out var n) && n > 1) parts.Add($"{n}×{name ?? ""}");
            else if (name != null) parts.Add(name);
            parts.AddRange(Json.StrArray(Json.Prop(f, "descriptions")) ?? new List<string>());
            fmt = string.Join(", ", parts);
        }

        static string? NonEmpty(string? s) => string.IsNullOrEmpty(s) || s.Contains("spacer.gif") ? null : s;

        var artists = Json.Array(Json.Prop(b, "artists"))
            .Where(a => a.ValueKind == JsonValueKind.Object && Json.Str(Json.Prop(a, "name")) != null)
            .Select(a => (Name: Json.Str(Json.Prop(a, "name"))!, Anv: Json.Str(Json.Prop(a, "anv")), Join: Json.Str(Json.Prop(a, "join"))))
            .ToList();
        var genres = Json.StrArray(Json.Prop(b, "genres"));

        var release = new Release(
            id,
            ArtistName(artists),
            title,
            year > 0 ? year : null,
            labelName == null ? null : CleanDiscogsName(labelName),
            catno == null || catno.ToLowerInvariant() == "none" ? null : catno,
            fmt,
            NonEmpty(Json.Str(Json.Prop(b, "cover_image"))),
            NonEmpty(Json.Str(Json.Prop(b, "thumb"))),
            genres == null ? null : string.Join(", ", genres));
        return new DiscogsCollectionItem(instanceId, Json.Str(Json.Prop(it, "date_added")), release);
    }

    /// Samler kunstnernavne som Discogs viser dem: "Simon & Garfunkel", "Nirvana (2)" → "Nirvana".
    internal static string ArtistName(IReadOnlyList<(string Name, string? Anv, string? Join)> artists)
    {
        if (artists.Count == 0) return "Ukendt kunstner";
        var sb = new StringBuilder();
        for (int i = 0; i < artists.Count; i++)
        {
            var a = artists[i];
            var name = !string.IsNullOrEmpty(a.Anv) ? a.Anv! : a.Name;
            sb.Append(CleanDiscogsName(name));
            if (i < artists.Count - 1)
            {
                var j = (a.Join ?? "").Trim();
                sb.Append(j.Length == 0 ? ", " : (j == "," ? ", " : $" {j} "));
            }
        }
        return sb.ToString();
    }

    private static readonly Regex DisambiguationSuffix = new(@"\s\(\d+\)$", RegexOptions.CultureInvariant);

    /// Fjerner Discogs' disambiguerings-suffiks " (2)".
    public static string CleanDiscogsName(string s) => DisambiguationSuffix.Replace(s, "");
}

/// Én side af samlingen: posterne, antal sider og antal poster i alt.
public sealed record DiscogsCollectionPage(IReadOnlyList<DiscogsCollectionItem> Items, int Pages, int Total);
