using System.ComponentModel;
using System.Runtime.CompilerServices;
using VinylShelfFinder.Core;

namespace VinylShelfFinder;

/// <summary>Hvilket format der ledes efter. Huskes mellem gange.</summary>
public enum FormatFilter { All, Vinyl, Cd, Cassette }

public static class FormatFilterExtensions
{
    public static readonly FormatFilter[] All = { FormatFilter.All, FormatFilter.Vinyl, FormatFilter.Cd, FormatFilter.Cassette };

    public static string Label(this FormatFilter f) => f switch
    {
        FormatFilter.All => "Alle",
        FormatFilter.Vinyl => "Vinyl",
        FormatFilter.Cd => "CD",
        _ => "Kassette",
    };

    /// <summary>Discogs' eget navn til format-filteret (null = alle formater).</summary>
    public static string? Discogs(this FormatFilter f) => f switch
    {
        FormatFilter.Vinyl => "Vinyl",
        FormatFilter.Cd => "CD",
        FormatFilter.Cassette => "Cassette",
        _ => null,
    };
}

public static class DiscogsAlbumExtensions
{
    /// <summary>Et album identificeres af id og art: et master-id og et release-id kan have samme tal.</summary>
    public static (int Id, bool IsMaster) Key(this DiscogsAlbum a) => (a.Id, a.IsMaster);

    /// <summary>"1959 · Vinyl, LP, CD"</summary>
    public static string DetailLine(this DiscogsAlbum a)
    {
        var parts = new List<string>();
        if (a.Year is int y) parts.Add(y.ToString());
        var f = a.Formats.Distinct().ToList();
        if (f.Count > 0) parts.Add(string.Join(", ", f));
        return string.Join(" · ", parts);
    }

    /// <summary>Til covers. Masters får et negativt id, så de aldrig forveksles med en release.</summary>
    public static Release AsRelease(this DiscogsAlbum a) => new(
        a.IsMaster ? -a.Id : a.Id, a.Artist, a.Title, a.Year, null, null, string.Join(", ", a.Formats),
        (a.CoverUrl ?? a.ThumbUrl)?.ToString(), (a.ThumbUrl ?? a.CoverUrl)?.ToString(), null);

    /// <summary>"1959 · US"</summary>
    public static string YearCountry(this DiscogsVersion v) =>
        string.Join(" · ", new[] { v.Year?.ToString(), v.Country.Length == 0 ? null : v.Country }.OfType<string>());

    /// <summary>"Columbia CL 1355"</summary>
    public static string LabelLine(this DiscogsVersion v)
    {
        var cat = v.Catno.Equals("none", StringComparison.OrdinalIgnoreCase) ? "" : v.Catno;
        return string.Join(" ", new[] { v.Label, cat }.Where(s => s.Length > 0));
    }

    /// <summary>"Columbia CL 1355 · Vinyl, LP, Album, Mono"</summary>
    public static string DetailLine(this DiscogsVersion v) => string.Join(" · ", new[] { v.LabelLine(), v.Format }.Where(s => s.Length > 0));

    /// <summary>"1959 · US · Columbia CL 1355 · Vinyl, LP, Album, Mono"</summary>
    public static string Summary(this DiscogsVersion v) => string.Join(" · ", new[] { v.YearCountry(), v.DetailLine() }.Where(s => s.Length > 0));

    public static Release AsRelease(this DiscogsVersion v, string artist) =>
        new(v.Id, artist, v.Title, v.Year, v.Label, v.Catno, v.Format, null, v.ThumbUrl?.ToString(), null);
}

public enum LoadPhase { Idle, Loading, Loaded, Failed }

/// <summary>Pris for én udgave: henter, hentet eller fejlet.</summary>
public sealed record PriceState(LoadPhase Phase, MarketInfo? Market = null, string? Error = null);

public sealed record WantState(LoadPhase Phase, string? Error = null);

/// <summary>
/// Tilstanden bag "Find nye plader" (FindNewModel.swift): søgning i Discogs' katalog, valgt album,
/// udgaver med pris (de mest udbredte hentes med det samme), billigste køb og ønskeliste.
/// Købet sker hos Discogs (i Discogs-vinduet).
/// </summary>
public sealed class FindNewModel : INotifyPropertyChanged
{
    public event PropertyChangedEventHandler? PropertyChanged;
    private readonly AppModel _app;

    public const int MinimumQueryLength = 2;
    public static readonly TimeSpan SearchDelay = TimeSpan.FromMilliseconds(400);
    public static readonly TimeSpan VersionsDelay = TimeSpan.FromMilliseconds(350);
    /// Så mange af de mest udbredte udgaver får hentet pris med det samme.
    public const int PricedCount = 12;
    public const int VersionPagesToRank = 3;
    public const int PriceConcurrency = 3;
    public static readonly TimeSpan PriceMaxAge = TimeSpan.FromMinutes(15);

    public FindNewModel(AppModel app)
    {
        _app = app;
        _format = Enum.TryParse<FormatFilter>(app.Store.Setting("findnew_format"), out var f) ? f : FormatFilter.All;
    }

    // MARK: Søgning

    private string _query = "";
    public string Query
    {
        get => _query;
        set
        {
            if (_query == value) return;
            var old = _query.Trim();
            _query = value;
            OnChanged();
            if (value.Trim() != old) ScheduleSearch();
        }
    }

    private FormatFilter _format;
    public FormatFilter Format
    {
        get => _format;
        set
        {
            if (_format == value) return;
            _format = value;
            _app.Store.SetSetting("findnew_format", value.ToString());
            OnChanged();
            ScheduleSearch();
            if (SelectedAlbum is not null) { ShowAllVersions = false; RetryVersions(); }
        }
    }

    public IReadOnlyList<DiscogsAlbum> Albums { get; private set; } = Array.Empty<DiscogsAlbum>();
    public bool HasMore { get; private set; }
    public LoadPhase SearchPhase { get; private set; }
    public string? SearchError { get; private set; }
    public bool LoadingMore { get; private set; }
    public string ResultQuery { get; private set; } = "";
    private int _page = 1;
    private CancellationTokenSource? _searchCts;

    // MARK: Valgt album og udgaver

    private (int Id, bool IsMaster)? _selectedKey;
    public (int Id, bool IsMaster)? SelectedKey
    {
        get => _selectedKey;
        set
        {
            if (_selectedKey == value) return;
            _selectedKey = value;
            OnChanged();
            AlbumChanged();
        }
    }

    public DiscogsAlbum? SelectedAlbum { get; private set; }
    public IReadOnlyList<DiscogsVersion> Versions { get; private set; } = Array.Empty<DiscogsVersion>();
    public bool VersionsHasMore { get; private set; }
    public int VersionsTotal { get; private set; }
    public LoadPhase VersionsPhase { get; private set; }
    public string? VersionsError { get; private set; }
    public bool LoadingMoreVersions { get; private set; }
    private bool _showAll;
    public bool ShowAllVersions { get => _showAll; set { _showAll = value; OnChanged(); } }
    private int _versionsPage = 1;
    private CancellationTokenSource? _versionsCts;
    private CancellationTokenSource? _pricesCts;

    // MARK: Priser og ønskeliste

    private readonly Dictionary<string, PriceState> _prices = new();
    private readonly Dictionary<int, WantState> _wants = new();
    private DiscogsClient? _client;
    private DiscogsResponseCache _cache = new();

    /// <summary>Kræver forbindelse til Discogs (token) og er slået fra i demo-tilstand.</summary>
    public bool IsAvailable => !_app.IsDemo && _app.HasToken;

    private string Currency => _app.Currency;

    /// <summary>Tokenet læses først, når der faktisk skal kaldes Discogs, og kun én gang pr. session.</summary>
    private DiscogsClient Service()
    {
        if (_app.IsDemo || !_app.HasToken) throw DiscogsException.MissingToken();
        if (_client is not null) return _client;
        var token = _app.LoadToken() ?? throw DiscogsException.MissingToken();
        _client = new DiscogsClient(token, cache: _cache);
        return _client;
    }

    /// <summary>Når tokenet skiftes eller fjernes. Cachen tømmes også (søgeresultaterne har kontoens mærker).</summary>
    public void ResetClient()
    {
        _client = null;
        _cache = new DiscogsResponseCache();
    }

    public bool Owns(DiscogsVersion v) => v.InCollection || _app.Library.Copies.Values.Any(c => c.ReleaseId == v.Id);

    public bool Owns(DiscogsAlbum a)
    {
        if (a.InCollection) return true;
        if (a.IsMaster) return false;
        return _app.Library.Copies.Values.Any(c => c.ReleaseId == a.Id);
    }

    // MARK: - Søgning

    private void ScheduleSearch()
    {
        _searchCts?.Cancel();
        var q = Query.Trim();
        if (q.Length < MinimumQueryLength)
        {
            Albums = Array.Empty<DiscogsAlbum>();
            HasMore = false;
            ResultQuery = "";
            SearchPhase = LoadPhase.Idle;
            LoadingMore = false;
            OnChanged(nameof(Albums));
            return;
        }
        SearchPhase = LoadPhase.Loading;
        LoadingMore = false;
        OnChanged(nameof(SearchPhase));
        var cts = _searchCts = new CancellationTokenSource();
        _ = RunSearch(q, SearchDelay, cts.Token);
    }

    public void RetrySearch()
    {
        _searchCts?.Cancel();
        var q = Query.Trim();
        if (q.Length < MinimumQueryLength) return;
        SearchPhase = LoadPhase.Loading;
        OnChanged(nameof(SearchPhase));
        var cts = _searchCts = new CancellationTokenSource();
        _ = RunSearch(q, TimeSpan.Zero, cts.Token);
    }

    private async Task RunSearch(string q, TimeSpan delay, CancellationToken ct)
    {
        try
        {
            if (delay > TimeSpan.Zero) await Task.Delay(delay, ct);
            var r = await Service().SearchAlbumsAsync(q, 1, Format.Discogs(), ct);
            if (ct.IsCancellationRequested) return;
            Albums = DiscogsAlbum.RankedForQuery(Unique(r.Albums), q);
            HasMore = r.HasMore;
            _page = 1;
            ResultQuery = q;
            SearchPhase = LoadPhase.Loaded;
            OnChanged(nameof(Albums));
        }
        catch (Exception e) when (!ct.IsCancellationRequested && !IsCancellation(e))
        {
            SearchPhase = LoadPhase.Failed;
            SearchError = Message(e);
            OnChanged(nameof(SearchPhase));
        }
        catch { }
    }

    /// <summary>"Vis flere": næste side af søgningen.</summary>
    public async void LoadMore()
    {
        if (!HasMore || LoadingMore || SearchPhase != LoadPhase.Loaded) return;
        var q = ResultQuery;
        int next = _page + 1;
        LoadingMore = true;
        OnChanged(nameof(LoadingMore));
        var cts = _searchCts = new CancellationTokenSource();
        try
        {
            var r = await Service().SearchAlbumsAsync(q, next, Format.Discogs(), cts.Token);
            if (!cts.IsCancellationRequested && q == ResultQuery)
            {
                Albums = Unique(Albums.Concat(r.Albums));
                HasMore = r.HasMore;
                _page = next;
            }
        }
        catch (Exception e) when (!cts.IsCancellationRequested && !IsCancellation(e))
        {
            SearchPhase = LoadPhase.Failed;
            SearchError = Message(e);
        }
        catch { }
        LoadingMore = false;
        OnChanged(nameof(Albums));
    }

    private static List<DiscogsAlbum> Unique(IEnumerable<DiscogsAlbum> list)
    {
        var seen = new HashSet<(int, bool)>();
        return list.Where(a => seen.Add(a.Key())).ToList();
    }

    public void MoveSelection(int delta)
    {
        if (Albums.Count == 0) return;
        int i = SelectedKey is { } k ? Albums.ToList().FindIndex(a => a.Key() == k) : -1;
        SelectedKey = Albums[Math.Clamp(i + delta, 0, Albums.Count - 1)].Key();
    }

    /// <summary>Enter: vælg det markerede album (eller det første) og hent udgaverne med det samme.</summary>
    public void ChooseHighlighted()
    {
        if (SelectedKey is null || !Albums.Any(a => a.Key() == SelectedKey))
        {
            if (Albums.Count == 0) return;
            SelectedKey = Albums[0].Key();
        }
        LoadVersions(TimeSpan.Zero);
    }

    // MARK: - Udgaver

    private void AlbumChanged()
    {
        if (SelectedKey is not { } key || key == SelectedAlbum?.Key()) return;
        var album = Albums.FirstOrDefault(a => a.Key() == key);
        if (album is null) return;
        _versionsCts?.Cancel();
        _pricesCts?.Cancel();
        Versions = Array.Empty<DiscogsVersion>();
        VersionsHasMore = false;
        VersionsTotal = 0;
        _versionsPage = 1;
        LoadingMoreVersions = false;
        _showAll = false;
        SelectedAlbum = album;
        OnChanged(nameof(SelectedAlbum));
        LoadVersions(VersionsDelay);
    }

    public void LoadVersions(TimeSpan delay)
    {
        if (SelectedAlbum is not DiscogsAlbum album) return;
        // Enter på et album, hvis udgaver allerede er hentet: intet nyt kald.
        if (delay == TimeSpan.Zero && VersionsPhase == LoadPhase.Loaded) { LoadCandidatePrices(); return; }
        _versionsCts?.Cancel();
        _pricesCts?.Cancel();
        VersionsPhase = LoadPhase.Loading;
        OnChanged(nameof(Versions));
        var cts = _versionsCts = new CancellationTokenSource();
        _ = FetchVersions(album, delay, Format.Discogs(), cts.Token);
    }

    private async Task FetchVersions(DiscogsAlbum album, TimeSpan delay, string? format, CancellationToken ct)
    {
        try
        {
            if (delay > TimeSpan.Zero) await Task.Delay(delay, ct);
            var svc = Service();
            var all = new List<DiscogsVersion>();
            int page = 0, total = 0;
            bool more = true;
            while (more && page < VersionPagesToRank)
            {
                page++;
                var r = await svc.VersionsAsync(album, page, format, ct);
                if (ct.IsCancellationRequested) return;
                var known = all.Select(v => v.Id).ToHashSet();
                all.AddRange(r.Versions.Where(v => !known.Contains(v.Id)));
                more = r.HasMore;
                total = r.Total;
            }
            if (SelectedAlbum?.Key() != album.Key()) return;
            Versions = DiscogsVersion.MostPopularFirst(all);
            VersionsHasMore = more;
            VersionsTotal = Math.Max(total, all.Count);
            _versionsPage = page;
            VersionsPhase = LoadPhase.Loaded;
            OnChanged(nameof(Versions));
            LoadCandidatePrices();
        }
        catch (Exception e) when (!ct.IsCancellationRequested && !IsCancellation(e))
        {
            VersionsPhase = LoadPhase.Failed;
            VersionsError = Message(e);
            OnChanged(nameof(Versions));
        }
        catch { }
    }

    public void RetryVersions()
    {
        Versions = Array.Empty<DiscogsVersion>();
        VersionsTotal = 0;
        VersionsPhase = LoadPhase.Idle;
        LoadVersions(TimeSpan.Zero);
    }

    /// <summary>"Vis flere": udgaver ud over de første sider (de kommer bagest, uden pris).</summary>
    public async void LoadMoreVersions()
    {
        if (SelectedAlbum is not DiscogsAlbum album || !VersionsHasMore || LoadingMoreVersions) return;
        int next = _versionsPage + 1;
        LoadingMoreVersions = true;
        OnChanged(nameof(Versions));
        var cts = _versionsCts = new CancellationTokenSource();
        try
        {
            var r = await Service().VersionsAsync(album, next, Format.Discogs(), cts.Token);
            if (!cts.IsCancellationRequested && SelectedAlbum?.Key() == album.Key())
            {
                var known = Versions.Select(v => v.Id).ToHashSet();
                Versions = Versions.Concat(r.Versions.Where(v => !known.Contains(v.Id))).ToList();
                VersionsHasMore = r.HasMore;
                VersionsTotal = Math.Max(r.Total, Versions.Count);
                _versionsPage = next;
            }
        }
        catch (Exception e) when (!cts.IsCancellationRequested && !IsCancellation(e))
        {
            VersionsPhase = LoadPhase.Failed;
            VersionsError = Message(e);
        }
        catch { }
        LoadingMoreVersions = false;
        OnChanged(nameof(Versions));
    }

    // MARK: - Priser og billigste køb

    public IReadOnlyList<DiscogsVersion> Candidates => Versions.Take(PricedCount).ToList();
    public IReadOnlyList<DiscogsVersion> OtherVersions => Versions.Skip(PricedCount).ToList();

    private string PriceKey(int releaseId) => $"{releaseId}-{Currency}";

    public PriceState? Price(int releaseId) => _prices.TryGetValue(PriceKey(releaseId), out var p) ? p : null;

    /// <summary>Den købbare pris for en udgave (kendt pris og mindst én til salg).</summary>
    public MarketInfo? BuyablePrice(int releaseId) =>
        Price(releaseId) is { Phase: LoadPhase.Loaded, Market: MarketInfo m } && m.LowestPrice is not null && (m.NumForSale ?? 0) > 0 ? m : null;

    public bool CandidatesPriced => VersionsPhase == LoadPhase.Loaded &&
        Candidates.All(v => Price(v.Id) is { Phase: LoadPhase.Loaded or LoadPhase.Failed });

    /// <summary>Billigste køb blandt alle udgaver med hentet pris (ved lige pris: den mest udbredte).</summary>
    public (DiscogsVersion Version, MarketInfo Market)? BestBuy
    {
        get
        {
            (DiscogsVersion, MarketInfo)? best = null;
            foreach (var v in Versions)
                if (BuyablePrice(v.Id) is MarketInfo m && (best is null || m.LowestPrice < best.Value.Item2.LowestPrice))
                    best = (v, m);
            return best;
        }
    }

    /// <summary>"Andre udgaver": de mest udbredte uden det bedste køb. Når alle priser er hentet: billigst først.</summary>
    public IReadOnlyList<DiscogsVersion> ListedCandidates
    {
        get
        {
            var best = BestBuy?.Version.Id;
            var rest = Candidates.Where(v => v.Id != best).ToList();
            if (!CandidatesPriced) return rest;
            return rest.Select((v, i) => (v, i))
                .OrderBy(x => BuyablePrice(x.v.Id)?.LowestPrice ?? double.PositiveInfinity).ThenBy(x => x.i)
                .Select(x => x.v).ToList();
        }
    }

    private bool NeedsPrice(int releaseId) => Price(releaseId) switch
    {
        { Phase: LoadPhase.Loaded, Market: MarketInfo m } => DateTimeOffset.Now - m.FetchedAt > PriceMaxAge,
        { Phase: LoadPhase.Loading } => false,
        _ => true,
    };

    /// <summary>Henter pris for de mest udbredte udgaver, højst PriceConcurrency ad gangen.</summary>
    public void LoadCandidatePrices()
    {
        var todo = new Queue<int>(Candidates.Select(v => v.Id).Where(NeedsPrice));
        if (todo.Count == 0) return;
        _pricesCts?.Cancel();
        var cts = _pricesCts = new CancellationTokenSource();
        async Task Worker()
        {
            while (!cts.IsCancellationRequested && todo.TryDequeue(out var id)) await FetchPrice(id, cts.Token);
        }
        for (int i = 0; i < PriceConcurrency; i++) _ = Worker();
    }

    /// <summary>"Hent pris" på en mindre udbredt udgave.</summary>
    public void LoadPrice(int releaseId)
    {
        if (NeedsPrice(releaseId)) _ = FetchPrice(releaseId, CancellationToken.None);
    }

    private async Task FetchPrice(int releaseId, CancellationToken ct)
    {
        if (ct.IsCancellationRequested || !NeedsPrice(releaseId)) return;
        var key = PriceKey(releaseId);
        _prices[key] = new PriceState(LoadPhase.Loading);
        OnChanged(nameof(Price));
        try
        {
            var m = await Service().MarketInfoAsync(releaseId, Currency, ct);
            _prices[key] = new PriceState(LoadPhase.Loaded, m);
        }
        catch (Exception e)
        {
            if (e is DiscogsException { Kind: DiscogsErrorKind.Unauthorized }) _client = null;
            if (IsCancellation(e)) _prices.Remove(key);
            else _prices[key] = new PriceState(LoadPhase.Failed, Error: ShortMessage(e));
        }
        OnChanged(nameof(Price));
    }

    /// <summary>Discogs' markedsplads for hele albummet i det valgte format.</summary>
    public Uri OffersUrl(DiscogsAlbum album) =>
        album.IsMaster ? DiscogsClient.MarketplaceUrl(album.Id, Format.Discogs()) : DiscogsClient.MarketplaceUrl(album.Id);

    // MARK: - Ønskeliste

    public WantState? Want(int releaseId) => _wants.TryGetValue(releaseId, out var w) ? w : null;

    public bool IsOnWantlist(int releaseId)
    {
        if (Want(releaseId) is { Phase: LoadPhase.Loaded }) return true;
        if (Versions.Any(v => v.Id == releaseId && v.InWantlist)) return true;
        return SelectedAlbum is { IsMaster: false } a && a.Id == releaseId && a.InWantlist;
    }

    public async void AddToWantlist(int releaseId)
    {
        if (IsOnWantlist(releaseId) || Want(releaseId) is { Phase: LoadPhase.Loading }) return;
        if (_app.Username is not string user || user.Length == 0)
        {
            _wants[releaseId] = new WantState(LoadPhase.Failed, "Appen kender ikke dit Discogs-brugernavn. Forbind til Discogs igen i Indstillinger.");
            OnChanged(nameof(Want));
            return;
        }
        _wants[releaseId] = new WantState(LoadPhase.Loading);
        OnChanged(nameof(Want));
        try
        {
            await Service().AddToWantlistAsync(user, releaseId);
            _wants[releaseId] = new WantState(LoadPhase.Loaded);
        }
        catch (Exception e)
        {
            if (IsCancellation(e)) _wants.Remove(releaseId);
            else _wants[releaseId] = new WantState(LoadPhase.Failed, Message(e));
        }
        OnChanged(nameof(Want));
    }

    // MARK: - Discogs-vinduet

    /// <summary>Siden, som Discogs-vinduet skal åbne.</summary>
    public event Action<Uri>? OpenBrowserRequested;
    public void OpenInBrowser(Uri url) => OpenBrowserRequested?.Invoke(url);

    // MARK: - Fejl på dansk

    public static bool IsCancellation(Exception e) => e is OperationCanceledException;

    public static string Message(Exception e) => e is DiscogsException d ? d.Message : "Noget gik galt. Prøv igen om lidt.";

    public static string ShortMessage(Exception e) => e switch
    {
        DiscogsException { Kind: DiscogsErrorKind.Offline } => "Ingen forbindelse",
        DiscogsException { Kind: DiscogsErrorKind.RateLimited } => "Discogs har travlt",
        DiscogsException { IsNotFound: true } => "Ikke fundet",
        _ => "Kunne ikke hentes",
    };

    private void OnChanged([CallerMemberName] string? name = null) =>
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
}
