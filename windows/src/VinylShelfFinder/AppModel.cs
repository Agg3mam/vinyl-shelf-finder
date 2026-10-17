using System.ComponentModel;
using System.Runtime.CompilerServices;
using Microsoft.UI.Dispatching;
using VinylShelfFinder.Core;

namespace VinylShelfFinder;

public enum SidebarKind { Search, NewRecords, Removed, Away, Section, History, Value, Listen, Plays, FindNew }

/// <summary>Punkt i sidepanelet. <see cref="SectionId"/> bruges kun ved <see cref="SidebarKind.Section"/>.</summary>
public sealed record SidebarItem(SidebarKind Kind, long SectionId = 0)
{
    public static readonly SidebarItem Search = new(SidebarKind.Search);
    public static SidebarItem ForSection(long id) => new(SidebarKind.Section, id);
}

public sealed record StatusNoteRequest(long CopyId, CopyStatus Status, string Note);

public enum SyncPhase { Idle, Running, Failed }

public sealed record SyncState(SyncPhase Phase, int Done = 0, int Total = 0, string? Message = null)
{
    public static readonly SyncState Idle = new(SyncPhase.Idle);
}

/// <summary>
/// Appens tilstand. Svarer til Sources/VinylShelfFinder/AppModel.swift (de dele, Windows-versionen har indtil videre).
/// Alle ændringer sker på UI-tråden; skærmene lytter på <see cref="PropertyChanged"/>.
/// </summary>
public sealed class AppModel : INotifyPropertyChanged
{
    public event PropertyChangedEventHandler? PropertyChanged;

    public ShelfStore Store { get; }
    /// <summary><c>--demo</c>: separat database med eksempeldata, ingen Discogs og intet adgangskodelager.</summary>
    public bool IsDemo { get; }
    private readonly ISecretStore _token;
    private readonly DispatcherQueue? _dispatcher;

    public AppModel(bool demo)
    {
        IsDemo = demo;
        _dispatcher = DispatcherQueue.GetForCurrentThread();
        // Demo-tilstanden må aldrig røre adgangskodelageret: den får en tom hukommelses-udgave.
        _token = demo ? new InMemorySecretStore() : WindowsCredentialStore.Discogs;
        if (demo)
        {
            var dir = Path.GetDirectoryName(ShelfStore.DefaultPath)!;
            Store = new ShelfStore(Path.Combine(dir, "demo.sqlite"));
            DemoData.SeedIfEmpty(Store);
        }
        else
        {
            Store = new ShelfStore(ShelfStore.DefaultPath);
        }
        _rules = Store.LoadSortRules();
        _neighborCount = int.TryParse(Store.Setting("neighbor_count"), out var n) && n > 0 ? n : 1;
        _username = Store.Setting("discogs_username");
        _medium = MediumExtensions.FromRaw(Store.Setting("medium")) ?? Medium.Vinyl;
        _currency = Store.Setting("market_currency") ?? "DKK";
        try { _market = Store.LoadMarket(); } catch { }
        _collectionValue = Store.LoadCollectionValue();
        _hasToken = !demo && SafeExists(_token);
        Reload();
    }

    private static bool SafeExists(ISecretStore s)
    {
        try { return s.Exists; } catch { return false; }
    }

    // MARK: Egenskaber

    private Medium _medium = Medium.Vinyl;
    /// <summary>Den viste hylde: plader eller cd'er. Hver har sine egne reoler og sektioner.</summary>
    public Medium Medium
    {
        get => _medium;
        set
        {
            if (!Set(ref _medium, value)) return;
            Store.SetSetting("medium", value.RawValue());
            Selection = null;
            FindModeCopy = null;
            ReturnCopy = null;
            if (Sidebar.Kind == SidebarKind.Section) Sidebar = SidebarItem.Search;
            Reload();
        }
    }

    private IReadOnlyDictionary<Medium, int> _mediumCounts = new Dictionary<Medium, int>();
    /// <summary>Skiftet "Plader / Cd'er" vises kun, når der er cd'er (eller cd-hylden er valgt).</summary>
    public bool ShowsMediumPicker => _mediumCounts.GetValueOrDefault(Medium.Cd) > 0 || Medium == Medium.Cd;

    private Library _library = Library.Empty;
    public Library Library { get => _library; private set => Set(ref _library, value); }

    private SearchIndex _searchIndex = new(Library.Empty);
    public SearchIndex SearchIndex => _searchIndex;

    private SortRules _rules;
    public SortRules Rules { get => _rules; private set => Set(ref _rules, value); }

    private ListeningStats _stats = ListeningStats.Empty;
    public ListeningStats Stats { get => _stats; private set => Set(ref _stats, value); }

    private SidebarItem _sidebar = SidebarItem.Search;
    public SidebarItem Sidebar
    {
        get => _sidebar;
        set
        {
            if (_sidebar == value) return;
            _sidebar = value;
            OnChanged();
            // Ryd valg, der ikke hører til søgningen.
            if (value.Kind == SidebarKind.Search && Selection is long s && !Results.Contains(s))
                Selection = Results.Count > 0 ? Results[0] : null;
        }
    }

    private string _query = "";
    public string Query
    {
        get => _query;
        set
        {
            if (_query == value) return;
            _query = value;
            OnChanged();
            RunSearch(autoSelect: true);
        }
    }

    private IReadOnlyList<long> _results = Array.Empty<long>();
    public IReadOnlyList<long> Results { get => _results; private set => Set(ref _results, value); }

    private long? _selection;
    public long? Selection { get => _selection; set => Set(ref _selection, value); }

    private int _neighborCount;
    public int NeighborCount
    {
        get => _neighborCount;
        set
        {
            if (!Set(ref _neighborCount, value)) return;
            Store.SetSetting("neighbor_count", value.ToString());
        }
    }

    private string? _username;
    public string? Username { get => _username; private set => Set(ref _username, value); }

    private bool _hasToken;
    public bool HasToken { get => _hasToken; private set => Set(ref _hasToken, value); }

    private SyncState _syncState = SyncState.Idle;
    public SyncState SyncState { get => _syncState; private set => Set(ref _syncState, value); }

    private string? _errorMessage;
    public string? ErrorMessage { get => _errorMessage; set => Set(ref _errorMessage, value); }

    // Ark/overlays
    private long? _findModeCopy;
    public long? FindModeCopy { get => _findModeCopy; set => Set(ref _findModeCopy, value); }

    /// <summary>"Sæt tilbage"-guiden: viser præcis, hvor en plade, der har været ude, skal stå.</summary>
    private long? _returnCopy;
    public long? ReturnCopy { get => _returnCopy; set => Set(ref _returnCopy, value); }

    private long? _moveCopy;
    public long? MoveCopy { get => _moveCopy; set => Set(ref _moveCopy, value); }

    private bool _forceOnboarding;
    public bool ForceOnboarding
    {
        get => _forceOnboarding;
        set { if (Set(ref _forceOnboarding, value)) OnChanged(nameof(NeedsOnboarding)); }
    }

    private int _focusSearchRequest;
    public int FocusSearchRequest { get => _focusSearchRequest; private set => Set(ref _focusSearchRequest, value); }
    public void RequestSearchFocus() => FocusSearchRequest++;

    public bool NeedsOnboarding => ForceOnboarding || (!HasToken && !IsDemo) || Library.Locations.Count == 0;

    // MARK: Data

    public void Reload()
    {
        try
        {
            var lib = Store.LoadLibrary(Medium);
            _mediumCounts = Store.MediumCounts();
            _searchIndex = new SearchIndex(lib);
            Stats = new ListeningStats(Store.LoadPlays());
            Library = lib;
            OnChanged(nameof(NeedsOnboarding));
            // Efter en handling må valget kun skifte, når man står i søgningen.
            RunSearch(autoSelect: Sidebar.Kind == SidebarKind.Search);
        }
        catch (Exception ex)
        {
            ErrorMessage = Describe(ex);
        }
    }

    private void RunSearch(bool autoSelect)
    {
        var q = Query.Trim();
        if (q.Length == 0)
        {
            if (Results.Count > 0) Results = Array.Empty<long>();
            return;
        }
        var found = _searchIndex.Search(q);
        if (!found.SequenceEqual(Results)) Results = found;
        if (!autoSelect) return;
        if (Results.Count == 0)
        {
            Selection = null;
            return;
        }
        if (Selection is long s && Results.Contains(s)) return;
        Selection = Results[0];
    }

    public void MoveSelection(int delta)
    {
        if (Results.Count == 0) return;
        int i = Selection is long s ? IndexOf(Results, s) : -1;
        Selection = Results[Math.Max(0, Math.Min(Results.Count - 1, i + delta))];
    }

    private static int IndexOf(IReadOnlyList<long> list, long id)
    {
        for (int i = 0; i < list.Count; i++) if (list[i] == id) return i;
        return -1;
    }

    /// <summary>Hop til en plade (fx en nabo) og vis den i søgningen eller i dens sektion.</summary>
    public void Reveal(long copyId)
    {
        if (Sidebar.Kind == SidebarKind.Section)
        {
            Selection = copyId;
            if (Library.LocationOfCopy.TryGetValue(copyId, out var loc)) Sidebar = SidebarItem.ForSection(loc);
            return;
        }
        Sidebar = SidebarItem.Search;
        if (!Results.Contains(copyId) && Library.Item(copyId) is RecordItem it)
            Query = $"{it.Artist} {it.Title}";
        Selection = copyId;
    }

    public List<RecordItem> UnplacedItems => Rules.Sorted(Library.Unplaced.Select(Library.Item).OfType<RecordItem>()).ToList();
    public List<RecordItem> RemovedItems =>
        Rules.Sorted(Library.AllItems.Where(i => !i.Copy.InDiscogs && i.Copy.RemovedFromDiscogsAt is not null)).ToList();
    public List<RecordItem> AwayItems => Rules.Sorted(Library.AllItems.Where(i => i.Copy.Status != CopyStatus.Home)).ToList();

    // MARK: Handlinger

    private void Perform(Action body)
    {
        try { body(); }
        catch (Exception ex) { ErrorMessage = Describe(ex); }
        Reload();
    }

    public static string Describe(Exception ex) => ex switch
    {
        DatabaseException d => d.UserMessage,
        DiscogsException d => d.Message,
        _ => ex.Message,
    };

    public void Move(long copyId, long locationId, int index) => Perform(() => Store.Move(copyId, locationId, index));

    public void PlaceAllAsSuggested()
    {
        foreach (var id in UnplacedItems.Select(i => i.Id))
        {
            if (Library.SuggestPlacement(id, Rules) is not PlacementSuggestion s) continue;
            try { Store.Move(id, s.LocationId, s.Index); }
            catch (Exception ex) { ErrorMessage = Describe(ex); break; }
            try { Library = Store.LoadLibrary(Medium); } catch { }
        }
        Reload();
    }

    public void SetStatus(long copyId, CopyStatus status, string? note = null) =>
        Perform(() => Store.SetStatus(copyId, status, note));

    /// <summary>
    /// Status fra en menu. "Udlånt" og "Opbevaret andet sted" spørger først efter navn eller sted.
    /// "På plads" for en plade, der er ude, åbner "Sæt tilbage"-guiden.
    /// </summary>
    public void ChooseStatus(long copyId, CopyStatus status)
    {
        if (status == CopyStatus.Home && IsAway(copyId))
            StartReturn(copyId);
        else if (status is CopyStatus.Lent or CopyStatus.Stored)
            StatusNoteRequest = new StatusNoteRequest(copyId, status,
                Library.Copies.TryGetValue(copyId, out var c) ? c.StatusNote ?? "" : "");
        else
            SetStatus(copyId, status);
    }

    private StatusNoteRequest? _statusNoteRequest;
    /// <summary>Spørgsmålet om navn (udlånt) eller sted (opbevaret andet sted); vises som dialog i hovedvinduet.</summary>
    public StatusNoteRequest? StatusNoteRequest { get => _statusNoteRequest; set => Set(ref _statusNoteRequest, value); }

    /// <summary>Pladen står ikke i reolen (på væggen, udlånt, opbevaret andet sted eller mangler).</summary>
    public bool IsAway(long copyId) => Library.Copies.TryGetValue(copyId, out var c) && !c.Status.IsOnShelf();

    /// <summary>
    /// Start på at sætte en plade tilbage. Har den en plads i reolen, vises guiden. En plade uden plads
    /// får status "På plads" og går til den almindelige placering (Flyt-arket).
    /// </summary>
    public void StartReturn(long copyId)
    {
        if (!Library.Copies.ContainsKey(copyId)) return;
        if (Library.LocationOfCopy.ContainsKey(copyId))
        {
            ReturnCopy = copyId;
        }
        else
        {
            if (IsAway(copyId)) SetStatus(copyId, CopyStatus.Home);
            MoveCopy = copyId;
        }
    }

    /// <summary>"Sat på plads" i guiden: nu står pladen i reolen igen.</summary>
    public void FinishReturn(long copyId)
    {
        if (IsAway(copyId)) SetStatus(copyId, CopyStatus.Home);
        if (ReturnCopy == copyId) ReturnCopy = null;
    }

    public void Unplace(long copyId) => Perform(() => Store.Unplace(copyId));

    public void SetSortOverrides(long copyId, string? artist, string? title) =>
        Perform(() => Store.SetSortOverrides(copyId, artist, title));

    /// <summary>"Flyt til cd-hylden" / "Flyt til pladehylden" (null: følg Discogs' format). Kopien venter
    /// derefter under "Nye cd'er"/"Nye plader" på den anden hylde.</summary>
    public void SetMedium(long copyId, Medium? medium)
    {
        if (Selection == copyId) Selection = null;
        Perform(() => Store.SetMedium(copyId, medium));
    }

    /// <summary>"Fortryd" i historikken: sæt pladen tilbage, hvor den stod før.</summary>
    public void Undo(HistoryEntry entry)
    {
        if (entry.CopyId is not long copy || entry.FromLocationId is not long from || entry.FromPosition is not int pos
            || Library.LocationById(from) is null || !Library.Copies.ContainsKey(copy))
        {
            ErrorMessage = "Denne ændring kan ikke fortrydes (pladen eller sektionen findes ikke længere).";
            return;
        }
        Move(copy, from, pos - 1);
    }

    // MARK: Reol

    public void AddSection(int shelf)
    {
        int existing = Library.Locations.Count(l => l.Shelf == shelf);
        Perform(() => Store.AddSection(shelf, LayoutPlanner.SectionLetter(existing), Medium));
    }

    public void DeleteSection(long id)
    {
        if (Sidebar == SidebarItem.ForSection(id)) Sidebar = SidebarItem.Search;
        Perform(() => Store.DeleteEmptySection(id));
    }

    public DateTimeOffset? LastSync =>
        double.TryParse(Store.Setting("last_sync"), System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out var t)
            ? DateTimeOffset.FromUnixTimeMilliseconds((long)(t * 1000)) : null;

    // MARK: Sikkerhedskopi (én gang om dagen, se DatabaseBackup)

    public string BackupFolder { get; } = DatabaseBackup.DefaultFolder();

    private DateTimeOffset? _lastBackup;
    public DateTimeOffset? LastBackup { get => _lastBackup; private set => Set(ref _lastBackup, value); }

    private string? _backupError;
    public string? BackupError { get => _backupError; private set => Set(ref _backupError, value); }

    /// <summary>Ved start og derefter hver time: tag dagens kopi, hvis den mangler. Aldrig i demo.</summary>
    public void StartBackups()
    {
        if (IsDemo) return;
        try { LastBackup = DatabaseBackup.Latest(BackupFolder); } catch { }
        BackupIfDue();
        var timer = _dispatcher?.CreateTimer();
        if (timer is null) return;
        timer.Interval = TimeSpan.FromHours(1);
        timer.Tick += (_, _) => BackupIfDue();
        timer.Start();
    }

    private void BackupIfDue()
    {
        if (DatabaseBackup.IsDue(LastBackup)) BackupNow();
    }

    public void BackupNow()
    {
        if (IsDemo) return;
        try
        {
            DatabaseBackup.Run(Store, BackupFolder);
            LastBackup = DateTimeOffset.Now;
            BackupError = null;
        }
        catch (Exception ex)
        {
            BackupError = Describe(ex);
        }
    }

    // MARK: Værdi

    private Dictionary<int, MarketInfo> _market = new();
    public IReadOnlyDictionary<int, MarketInfo> Market => _market;

    private CollectionValue? _collectionValue;
    public CollectionValue? CollectionValue { get => _collectionValue; private set => Set(ref _collectionValue, value); }

    private SyncState _valueState = SyncState.Idle;
    public SyncState ValueState { get => _valueState; private set => Set(ref _valueState, value); }

    private string _currency;
    public string Currency
    {
        get => _currency;
        set { if (Set(ref _currency, value)) Store.SetSetting("market_currency", value); }
    }

    /// <summary>
    /// Henter Discogs' samlingsestimat og markedsdata pr. release. Springer releases over, der er
    /// hentet i samme valuta inden for 7 dage. Ca. 1 sekund pr. plade (Discogs' grænse).
    /// </summary>
    public async Task RefreshValuesAsync()
    {
        if (ValueState.Phase == SyncPhase.Running || IsDemo) return;
        string? token = null;
        try { token = _token.Load(); } catch { }
        if (token is null || Username is not string user)
        {
            ValueState = new SyncState(SyncPhase.Failed, Message: DiscogsException.MissingToken().Message);
            return;
        }
        var client = new DiscogsClient(token);
        var cutoff = DateTimeOffset.Now.AddDays(-7);
        var stale = Library.Copies.Values.Where(c => c.InDiscogs).Select(c => c.ReleaseId).Distinct().OrderBy(i => i)
            .Where(id => !_market.TryGetValue(id, out var m) || m.Currency != Currency || m.FetchedAt < cutoff).ToList();
        ValueState = new SyncState(SyncPhase.Running, 0, stale.Count);
        try
        {
            try
            {
                var v = await client.CollectionValueAsync(user);
                Store.SaveCollectionValue(v);
                CollectionValue = v;
            }
            catch { }
            string? discogsCurrency = null;
            if (stale.Count > 0) { try { discogsCurrency = await client.UserCurrencyAsync(user); } catch { } }
            for (int i = 0; i < stale.Count; i++)
            {
                try
                {
                    var m = await client.ReleaseMarketInfoAsync(stale[i], discogsCurrency, Currency);
                    Store.SaveMarket(stale[i], m);
                    _market[stale[i]] = m;
                }
                catch (DiscogsException e) when (e.IsNotFound)
                {
                    // Releasen findes ikke længere på Discogs – spring den over.
                }
                ValueState = new SyncState(SyncPhase.Running, i + 1, stale.Count);
                OnChanged(nameof(Market));
                // Hold os under Discogs' grænse på 60 forespørgsler i minuttet.
                await Task.Delay(1050);
            }
            ValueState = SyncState.Idle;
        }
        catch (Exception ex)
        {
            ValueState = new SyncState(SyncPhase.Failed, Message: Describe(ex));
        }
    }

    // MARK: Lytning

    private ListenFilter _listenFilter = new();
    public ListenFilter ListenFilter
    {
        get => _listenFilter;
        set { if (Set(ref _listenFilter, value)) ClearPick(); }
    }

    private long? _currentPick;
    public long? CurrentPick { get => _currentPick; private set => Set(ref _currentPick, value); }
    private readonly List<long> _recentPicks = new();

    public List<RecordItem> ListenCandidates => ListenPicker.Candidates(Library.AllItems, Library, ListenFilter, Stats);

    /// <summary>"Giv mig en plade": vægtet mod plader, der ikke er hørt længe, og undgår de seneste forslag.</summary>
    public void PickRecord()
    {
        if (ListenPicker.Pick(ListenCandidates, Stats, _recentPicks) is not RecordItem pick)
        {
            // Ingen plader passer: vis ikke et gammelt forslag, der ikke matcher filteret.
            ClearPick();
            return;
        }
        CurrentPick = pick.Id;
        Selection = pick.Id;
        _recentPicks.Add(pick.Id);
        if (_recentPicks.Count > 20) _recentPicks.RemoveAt(0);
    }

    /// <summary>Nulstiller forslaget og – hvis det var forslaget, der var valgt – også valget.</summary>
    public void ClearPick()
    {
        if (CurrentPick is not long pick) return;
        if (Selection == pick) Selection = null;
        CurrentPick = null;
    }

    public void DeletePlay(long id) => Perform(() => Store.DeletePlay(id));

    public void KeepLocalOnly(long copyId) => Perform(() => Store.KeepLocalOnly(copyId));

    public void DeleteCopy(long copyId)
    {
        if (Selection == copyId) Selection = null;
        if (FindModeCopy == copyId) FindModeCopy = null;
        if (ReturnCopy == copyId) ReturnCopy = null;
        if (MoveCopy == copyId) MoveCopy = null;
        Perform(() => Store.DeleteCopy(copyId));
    }

    /// <summary>Tidsrum, hvor endnu et "Spillet" på samme plade regnes som et dobbelttryk.</summary>
    public static readonly TimeSpan ReplayWindow = TimeSpan.FromSeconds(120);

    /// <summary>Et dobbelttryk (samme plade inden for 2 minutter) registreres kun én gang.</summary>
    public bool LogPlay(long copyId)
    {
        if (Stats.LastPlayed.TryGetValue(copyId, out var last) && DateTimeOffset.Now - last < ReplayWindow) return false;
        Perform(() => Store.LogPlay(copyId));
        return true;
    }

    public void UpdateRules(SortRules rules)
    {
        Rules = rules;
        try { Store.SaveSortRules(rules); } catch (Exception ex) { ErrorMessage = Describe(ex); }
    }

    public void CreateLayout(IReadOnlyList<LayoutPlanner.SectionPlan> plan)
    {
        var sorted = Rules.Sorted(Library.AllItems.Where(i => i.Copy.InDiscogs)).Select(i => i.Id).ToList();
        var parts = LayoutPlanner.Split(sorted, plan);
        Perform(() => Store.CreateLayout(plan.Zip(parts, (p, ids) => (p.Shelf, p.Section, (IReadOnlyList<long>)ids)).ToList(), Medium));
        ForceOnboarding = false;
        Sidebar = SidebarItem.Search;
        RequestSearchFocus();
    }

    // MARK: Discogs

    public async Task<bool> ConnectAsync(string token)
    {
        token = token.Trim();
        if (token.Length == 0) return false;
        // Demo-tilstand må hverken røre adgangskodelageret eller Discogs.
        if (IsDemo)
        {
            ErrorMessage = "Demo-tilstanden forbinder ikke til Discogs. Start appen uden --demo.";
            return false;
        }
        try
        {
            var name = await new DiscogsClient(token).IdentityAsync();
            _token.Save(token);
            Store.SetSetting("discogs_username", name);
            Username = name;
            HasToken = true;
            OnChanged(nameof(NeedsOnboarding));
            return true;
        }
        catch (Exception ex)
        {
            ErrorMessage = Describe(ex);
            return false;
        }
    }

    public void Disconnect()
    {
        if (IsDemo) return;
        try { _token.Delete(); } catch { }
        HasToken = false;
        OnChanged(nameof(NeedsOnboarding));
    }

    /// <summary>Rapporten fra den seneste synkronisering; vises som dialog i hovedvinduet.</summary>
    private SyncReport? _syncReport;
    public SyncReport? SyncReportToShow { get => _syncReport; set => Set(ref _syncReport, value); }

    /// <summary>"Kontrollér sektion": hovedvinduet viser kontrollen for denne sektion.</summary>
    private long? _checkSection;
    public long? CheckSection { get => _checkSection; set => Set(ref _checkSection, value); }

    public async Task SyncAsync(bool showReport = true)
    {
        if (SyncState.Phase == SyncPhase.Running || IsDemo) return;
        string? token = null;
        try { token = _token.Load(); } catch { }
        if (token is null || Username is not string user)
        {
            SyncState = new SyncState(SyncPhase.Failed, Message: DiscogsException.MissingToken().Message);
            return;
        }
        SyncState = new SyncState(SyncPhase.Running);
        try
        {
            var items = await new DiscogsClient(token).FetchCollectionAsync(user, (done, total) =>
                _dispatcher?.TryEnqueue(() =>
                {
                    // Kan nå frem efter at sync er færdig – må ikke sætte tilstanden tilbage til "running".
                    if (SyncState.Phase == SyncPhase.Running) SyncState = new SyncState(SyncPhase.Running, done, total);
                }));
            token = null;
            var report = Store.ApplyCollection(items);
            SyncState = SyncState.Idle;
            Reload();
            if (showReport && Library.Locations.Count > 0) SyncReportToShow = report;
            if (report.NewCopies.Count > 0 && Library.Locations.Count > 0) Sidebar = new SidebarItem(SidebarKind.NewRecords);
        }
        catch (Exception ex)
        {
            SyncState = new SyncState(SyncPhase.Failed, Message: Describe(ex));
        }
    }

    // MARK: INotifyPropertyChanged

    private bool Set<T>(ref T field, T value, [CallerMemberName] string? name = null)
    {
        if (EqualityComparer<T>.Default.Equals(field, value)) return false;
        field = value;
        OnChanged(name);
        return true;
    }

    private void OnChanged([CallerMemberName] string? name = null) =>
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
}
