using System.Globalization;
using System.Text;
using System.Text.RegularExpressions;
using VinylShelfFinder.Core;

namespace VinylShelfFinder.Checks;

/// Checks for database, sortering, naboer, søgning, opdeling, lytning, backup m.m.
/// Port af de tilsvarende dele af Sources/VinylCoreChecks/main.swift.
static class DataChecks
{
    private static readonly List<string> Dirs = new();

    /// Sti til en ny database i en midlertidig mappe (slettes til sidst).
    private static string TempDb(string tag)
    {
        var d = Check.TempDir();
        Dirs.Add(d);
        return Path.Combine(d, $"vsf-{tag}.sqlite");
    }

    private static DiscogsCollectionItem Item(int inst, int rel, string artist, string title, int? year = null, string? label = null, string? cat = null) =>
        Check.Item(inst, rel, artist, title, year, label, cat);

    private static DiscogsCollectionItem WithRelease(DiscogsCollectionItem i, Func<Release, Release> change) => i with { Release = change(i.Release) };

    private static List<(int, string, IReadOnlyList<long>)> Layout(params (int Shelf, string Section, IEnumerable<long> Copies)[] parts) =>
        parts.Select(p => (p.Shelf, p.Section, (IReadOnlyList<long>)p.Copies.ToList())).ToList();

    private static List<string> PlacementRows(ShelfStore s)
    {
        try
        {
            return s.Db.Query("SELECT copy_id, location_id, position FROM placements ORDER BY copy_id")
                .Select(r => $"{r.Long("copy_id")}:{r.Long("location_id")}:{r.Long("position")}").ToList();
        }
        catch (DatabaseException) { return new() { "fejl" }; }
    }

    private static List<int> Positions(ShelfStore s, long loc)
    {
        try { return s.Db.Query("SELECT position FROM placements WHERE location_id = ? ORDER BY position", loc).Select(r => r.Int("position")!.Value).ToList(); }
        catch (DatabaseException) { return new() { -1 }; }
    }

    private static bool DictEq<K, V>(IReadOnlyDictionary<K, V> a, IReadOnlyDictionary<K, V> b) where K : notnull =>
        a.Count == b.Count && a.All(kv => b.TryGetValue(kv.Key, out var v) && EqualityComparer<V>.Default.Equals(v, kv.Value));

    private static bool SameDay(DateTimeOffset? a, DateTimeOffset b) => a is { } x && x.ToLocalTime().Date == b.ToLocalTime().Date;

    public static void Run()
    {
        Sorting();
        DatabaseWrapper();
        MainStore();
        DiscogsOrder();
        DemoReference();
        SyncDeep();
        MoveDeep();
        ReferenceLent();
        ListenDeep();
        SqliteRobustness();
        Migration();
        SearchUnicode();
        SearchOrder();
        Mobile();
        OutOfShelf();
        DemoIdempotent();
        Backup();
        CoverFlow();
        Planner();
        Cds();
        SortListChecks();
        Transfer();
        Surname();

        foreach (var d in Dirs)
        {
            try { Directory.Delete(d, true); } catch (IOException) { } catch (UnauthorizedAccessException) { }
        }
    }

    // MARK: Sortering

    private static void Sorting() => Check.Section("sortering", () =>
    {
        var r = new SortRules();
        Check.That(r.SortArtist("The Beatles") == "Beatles", "The Beatles → Beatles");
        Check.That(r.SortArtist("Beatles, The") == "Beatles", "Beatles, The → Beatles");
        Check.That(r.SortArtist("AC/DC") == "ACDC", "AC/DC → ACDC");
        Check.That(r.SortArtist("A-ha") == "Aha", "A-ha → Aha");
        Check.That(r.SortArtist("The The") == "The", "The The → The");
        var o = r.Clone(); o.ArtistOverrides["Bob Dylan"] = "Dylan, Bob";
        Check.That(o.SortArtist("Bob Dylan") == "Dylan, Bob", "override");
        Check.That(r.SortArtist("Bob Dylan") == "Bob Dylan" && !r.Equals(o), "en kopi af reglerne deler ikke overrides med originalen");
        Check.That(SortRules.NaturalCompare("2pac", "10cc") < 0, "2Pac før 10cc");
        Check.That(SortRules.NaturalCompare(r.CollationKey("Zappa"), r.CollationKey("Ølbutikken")) < 0, "Ø efter Z (dansk)");
        Check.That(SortRules.NaturalCompare(r.CollationKey("Ølbutikken"), r.CollationKey("Åge Aleksandersen")) < 0, "Å efter Ø");
        Check.That(SortRules.NaturalCompare(r.CollationKey("Æble"), r.CollationKey("Ølbutikken")) < 0, "Æ før Ø");
        var nd = r.Clone(); nd.DanishAlphabet = false;
        Check.That(SortRules.NaturalCompare(nd.CollationKey("Ølbutikken"), nd.CollationKey("Pink")) < 0, "Ø=O i international tilstand");
        Check.That(SortRules.NaturalCompare(nd.CollationKey("Åge"), nd.CollationKey("B")) < 0, "Å=A i international tilstand");
        Check.That(SortRules.NaturalCompare(r.CollationKey("bob dylan"), r.CollationKey("bobby")) < 0, "Bob Dylan før Bobby");
        Check.That(r.CollationKey("Mötley Crüe") == "m|tley crue" && r.CollationKey("Beyoncé") == "beyonce", "diakritika foldes (ö = ø i dansk tilstand)");
        Check.That(SortRules.IsVarious("Various") && SortRules.IsVarious(" various artists") && !SortRules.IsVarious("Variousness"), "Various genkendes");

        // Gemte regler i samme JSON-format som på Mac
        var json = new SortRules { UseDiscogsOrder = false, Various = VariousPlacement.Last, WithinArtist = WithinArtist.Year }.ToJson();
        Check.That(json.Contains("\"useDiscogsOrder\":false") && json.Contains("\"various\":\"last\"") && json.Contains("\"withinArtist\":\"year\"")
                   && json.Contains("\"artistArticles\":[\"The\"]") && !json.Contains("artistOverrides"), $"JSON som Swift-Codable: {json}");
        var back = SortRules.FromJson(json)!;
        Check.That(back.Various == VariousPlacement.Last && !back.UseDiscogsOrder && back.WithinArtist == WithinArtist.Year, "regler læses tilbage");
        Check.That(SortRules.FromJson("ikke json") is null && SortRules.FromJson("{\"various\":\"???\"}") is null, "ugyldige regler → standard");

        // Tal sidst: kunstnere, der starter med et tal, efter Z og Æ Ø Å – også i Discogs' rækkefølge.
        Check.That(r.NumbersLast && SortRules.StartsWithDigit(r.SortArtist("The 1975")) && SortRules.StartsWithDigit("10cc")
                   && !SortRules.StartsWithDigit(r.SortArtist("Blur")) && !SortRules.StartsWithDigit(""), "tal genkendes (efter “The”)");
        static RecordItem Rec(long id, string artist, int? rank) =>
            new(new Copy(id, id, (int)id, DiscogsRank: rank), new Release((int)id, artist, "T"));
        // Discogs' egen rækkefølge: tal først.
        var discogs = new[] { Rec(1, "10cc", 0), Rec(2, "2Pac", 1), Rec(3, "ABBA", 2), Rec(4, "Zappa", 3), Rec(5, "Åge Aleksandersen", 4) };
        Check.That(r.Sorted(discogs).Select(i => i.Artist).SequenceEqual(new[] { "ABBA", "Zappa", "Åge Aleksandersen", "10cc", "2Pac" }),
                   "Discogs-rækkefølge: tal flyttes sidst og beholder deres indbyrdes orden");
        var own = new SortRules { UseDiscogsOrder = false };
        Check.That(own.Sorted(discogs).Select(i => i.Artist).SequenceEqual(new[] { "ABBA", "Zappa", "Åge Aleksandersen", "2Pac", "10cc" }),
                   "egne regler: bogstaver, Æ Ø Å, og så tal i talorden");
        var first = new SortRules { NumbersLast = false };
        Check.That(first.Sorted(discogs).First().Artist == "10cc", "kan slås fra (tal først som i Discogs)");
        var nlJson = new SortRules { NumbersLast = false }.ToJson();
        Check.That(nlJson.Contains("\"numbersLast\":false") && SortRules.FromJson(nlJson)!.NumbersLast == false
                   && SortRules.FromJson("{\"danishAlphabet\":true}")!.NumbersLast, "tal-reglen gemmes; gamle regler får standarden (tal sidst)");
    });

    // MARK: Database-wrapperen

    private static void DatabaseWrapper() => Check.Section("database", () =>
    {
        Check.That(Database.NumberPlaceholders("INSERT INTO t(a, b) VALUES(?, ?)") == "INSERT INTO t(a, b) VALUES(?1, ?2)", "? nummereres");
        Check.That(Database.NumberPlaceholders("SELECT '?' , \"x?\" WHERE a = ?") == "SELECT '?' , \"x?\" WHERE a = ?1", "? i tekst røres ikke");
        using var db = new Database(TempDb("db"));
        db.Execute("CREATE TABLE t(id INTEGER PRIMARY KEY, a TEXT, b REAL, c INTEGER)");
        var id = db.Run("INSERT INTO t(a, b, c) VALUES(?, ?, ?)", "x'y", 1.5, true);
        db.Run("INSERT INTO t(a, b, c) VALUES(?, ?, ?)", null, null, 7L);
        var rows = db.Query("SELECT * FROM t ORDER BY id");
        Check.That(id == 1 && rows.Count == 2 && rows[0].Text("a") == "x'y" && rows[0].Double("b") == 1.5 && rows[0].Long("c") == 1
                   && rows[1].Text("a") is null && rows[1].Int("c") == 7, "binding og læsning");
        Check.That(db.Query("PRAGMA journal_mode").First().Text("journal_mode") == "wal"
                   && db.Query("PRAGMA foreign_keys").First().Long("foreign_keys") == 1, "WAL og fremmednøgler er slået til");
        bool threw = false;
        try { db.Transaction(() => { db.Run("INSERT INTO t(a) VALUES('rul')"); throw new InvalidOperationException("stop"); }); }
        catch (InvalidOperationException) { threw = true; }
        Check.That(threw && db.Query("SELECT COUNT(*) AS n FROM t").First().Long("n") == 2, "transaktion rulles tilbage ved fejl");
        Check.That(SqlRow.AsLong(double.NaN) is null && SqlRow.AsLong(1e300) is null && SqlRow.AsLong(3.9) == 3, "REAL→Int crasher ikke");
    });

    // MARK: Store + naboer + sync, søgning, værdi, lyttelog

    private static void MainStore() => Check.Section("store, naboer og sync", () =>
    {
        using var store = new ShelfStore(TempDb("main"));
        var rules = new SortRules { UseDiscogsOrder = false };
        var collection = new List<DiscogsCollectionItem>
        {
            Item(1, 101, "ABBA", "Arrival", year: 1976),
            Item(2, 102, "AC/DC", "Highway To Hell", year: 1979),
            Item(3, 103, "David Bowie", "Low", year: 1977),
            Item(4, 104, "David Bowie", "\"Heroes\"", year: 1977),
            Item(5, 105, "Dire Straits", "Brothers In Arms", year: 1985),
            Item(6, 106, "Pink Floyd", "The Dark Side Of The Moon", year: 1973, label: "Harvest", cat: "SHVL 804"),
            Item(7, 107, "Pink Floyd", "The Dark Side Of The Moon", year: 1973, label: "Capitol", cat: "SMAS-11163"),
            Item(8, 108, "Pink Floyd", "Wish You Were Here", year: 1975, label: "Harvest", cat: "SHVL 814"),
            Item(9, 109, "Pink Floyd", "Animals", year: 1977),
            Item(10, 110, "Queen", "A Night At The Opera", year: 1975),
            Item(11, 111, "The Beatles", "Abbey Road", year: 1969),
            Item(12, 112, "Led Zeppelin", "Led Zeppelin IV", year: 1971, label: "Atlantic", cat: "K 50014"),
            Item(13, 106, "Pink Floyd", "The Dark Side Of The Moon", year: 1973, label: "Harvest", cat: "SHVL 804"), // dublet af samme release
        };
        var report = store.ApplyCollection(collection);
        Check.That(report.NewCopies.Count == 13, "13 nye kopier (inkl. dublet af samme release)");
        var lib = store.LoadLibrary();
        Check.That(lib.Releases.Count == 12, "12 unikke releases");
        var sorted = rules.Sorted(lib.AllItems);
        var names = sorted.Select(i => i.FullName).ToList();
        Check.That(names[0] == "ABBA – Arrival" && names[1] == "AC/DC – Highway To Hell", $"ABBA, AC/DC først: {string.Join(", ", names.Take(3))}");
        Check.That(names.IndexOf("The Beatles – Abbey Road") < names.IndexOf("David Bowie – Low"), "Beatles sorteres under B");

        // Onboarding: to sektioner
        var plan = LayoutPlanner.EvenPlan(sorted.Count, new[] { 2 });
        Check.That(plan.Select(p => p.Count).SequenceEqual(new[] { 7, 6 }), "jævn fordeling 7/6");
        var parts = LayoutPlanner.Split(sorted.Select(i => i.Id).ToList(), plan);
        store.CreateLayout(plan.Zip(parts, (p, ids) => (p.Shelf, p.Section, (IReadOnlyList<long>)ids)).ToList());
        lib = store.LoadLibrary();
        Check.That(lib.Unplaced.Count == 0, "alle placeret");
        Check.That(lib.GlobalOrder.SequenceEqual(sorted.Select(i => i.Id)), "fysisk rækkefølge = sorteret");

        long CopyId(int inst) => lib.Copies.Values.First(c => c.InstanceId == inst).Id;
        string Name(long? id) => id is long i && lib.Item(i) is RecordItem it ? it.FullName : "∅";

        var heroes = CopyId(4);
        var n = lib.NeighborsOf(heroes, 1)!;
        Check.That(n.Before.FirstOrDefault()?.Title == "Low" || n.After.FirstOrDefault()?.Title == "Low",
                   $"Heroes nabo til Low: før={Name(n.Before.FirstOrDefault()?.Id)} efter={Name(n.After.FirstOrDefault()?.Id)}");

        // Første plade i samlingen: ingen før, start af sektion
        var abba = CopyId(1);
        var na = lib.NeighborsOf(abba)!;
        Check.That(na.Before.Count == 0 && na.ReachedSectionStart && na.PreviousSection is null, "ABBA: starten af sektionen");

        // Sektionsgrænse: sidste plade i sektion A skal pege på første i sektion B
        var secA = lib.Locations[0].Id;
        var lastA = lib.Sections[secA][^1];
        var nl = lib.NeighborsOf(lastA)!;
        Check.That(nl.After.Count == 0 && nl.ReachedSectionEnd && nl.NextSection?.First?.Id == lib.Sections[lib.Locations[1].Id][0],
                   "sektionsslut peger på næste sektions første plade");

        // 3 naboer
        var wish = CopyId(8);
        var n3 = lib.NeighborsOf(wish, 3)!;
        Check.That(n3.Before.Count <= 3 && n3.After.Count <= 3, "højst 3 naboer");

        // Udlånt plade springes over som reference, men positionen bevares
        var animals = CopyId(9);
        var afterAnimals = lib.GlobalOrder[lib.GlobalIndex[animals] + 1];
        var refPos = lib.GlobalIndex[animals];
        store.SetStatus(animals, CopyStatus.Lent, "Peter");
        lib = store.LoadLibrary();
        Check.That(lib.GlobalIndex[animals] == refPos, "status ændrer ikke position");
        var nw = lib.NeighborsOf(afterAnimals)!;
        Check.That(nw.Before.FirstOrDefault()?.Id != animals && nw.AbsentBetweenBefore.FirstOrDefault()?.Id == animals && nw.ReachedSectionStart,
                   "udlånt plade springes over som reference");
        store.SetStatus(animals, CopyStatus.Home, null);
        {
            var h = store.History(2);
            Check.That(h[^1].Summary == "Pink Floyd – Animals: status ændret til “Udlånt” (Peter)" && h[0].Summary == "Pink Floyd – Animals: status ændret til “På plads”",
                       $"historik: status med ord, ikke emoji: {string.Join(" | ", h.Select(x => x.Summary))}");
        }

        // Flyt: naboer opdateres automatisk
        lib = store.LoadLibrary();
        var secB = lib.Locations[1].Id;
        store.Move(abba, secB, 0);
        lib = store.LoadLibrary();
        Check.That(lib.Sections[secB][0] == abba, "ABBA flyttet først i sektion B");
        Check.That(lib.Sections[secA].Count == 6, "sektion A har nu 6");
        var posA = Positions(store, secA);
        Check.That(posA.SequenceEqual(Enumerable.Range(1, 6)), $"positioner omnummereret: {string.Join(",", posA)}");
        var moveSummary = store.History(1).FirstOrDefault()?.Summary;
        Check.That(moveSummary == "ABBA – Arrival flyttet fra Reol 1 · Sektion A, plads 1 til Reol 1 · Sektion B, plads 1",
                   $"historik: flyt med ens placeringsformat: {moveSummary}");
        store.Move(abba, secA, 0);
        lib = store.LoadLibrary();

        // Sync: metadata ændres → placering bevares
        var bowieLowBefore = (lib.LocationOfCopy[CopyId(3)], lib.IndexInSection[CopyId(3)]);
        collection[2] = WithRelease(collection[2], r => r with { Title = "Low (Remastered)", Year = 1977 });
        report = store.ApplyCollection(collection);
        lib = store.LoadLibrary();
        Check.That(report.UpdatedReleases == 1 && report.NewCopies.Count == 0, "1 opdateret release, ingen nye");
        Check.That(lib.Item(CopyId(3))!.Title == "Low (Remastered)", "metadata opdateret");
        Check.That((lib.LocationOfCopy[CopyId(3)], lib.IndexInSection[CopyId(3)]) == bowieLowBefore, "placering bevaret efter metadata-ændring");

        // Sync: plade fjernet fra Discogs → markeres, placering bevares
        var queen = CopyId(10);
        var queenLoc = lib.LocationOfCopy[queen];
        collection.RemoveAll(c => c.InstanceId == 10);
        report = store.ApplyCollection(collection);
        lib = store.LoadLibrary();
        Check.That(report.RemovedCopies.SequenceEqual(new[] { queen }), "Queen markeret som fjernet");
        Check.That(!lib.Copies[queen].InDiscogs && lib.Copies[queen].RemovedFromDiscogsAt is not null && lib.LocationOfCopy[queen] == queenLoc,
                   "Queen stadig placeret fysisk");
        Check.That(store.History(5).Any(h => h.Kind == HistoryKind.RemovedFromDiscogs
                   && h.Summary == "Queen – A Night At The Opera er ikke længere i din Discogs-samling. Pladsen i reolen er bevaret."),
                   "historik: fjernet fra Discogs");

        // Sync: ny plade → uplaceret + forslag mellem de rigtige naboer
        collection.Add(Item(20, 120, "David Bowie", "Hunky Dory", year: 1971));
        report = store.ApplyCollection(collection);
        lib = store.LoadLibrary();
        var hunky = report.NewCopies[0];
        Check.That(lib.Unplaced.SequenceEqual(new[] { hunky }), "ny plade er uplaceret");
        Check.That(store.Setting("last_sync") is string ls && double.TryParse(ls, NumberStyles.Float, CultureInfo.InvariantCulture, out _),
                   "last_sync gemmes som sekunder (som på Mac)");
        var sug = lib.SuggestPlacement(hunky, rules)!;
        Check.That(Name(sug.Before) == "David Bowie – \"Heroes\"" && Name(sug.After) == "David Bowie – Low (Remastered)",
                   $"forslag: mellem Heroes og Low, fik {Name(sug.Before)} / {Name(sug.After)}");
        store.Move(hunky, sug.LocationId, sug.Index);
        lib = store.LoadLibrary();
        var nh = lib.NeighborsOf(hunky)!;
        Check.That(nh.Before.FirstOrDefault()?.Id == sug.Before && nh.After.FirstOrDefault()?.Id == sug.After, "ny plade indsat – naboer opdateret");
        Check.That(lib.NeighborsOf(sug.Before!.Value)!.After.FirstOrDefault()?.Id == hunky, "forgængerens næste = ny plade");
        Check.That(store.History(1).FirstOrDefault()?.Summary.StartsWith("David Bowie – Hunky Dory placeret på Reol 1 · Sektion A, plads ", StringComparison.Ordinal) == true,
                   "historik: placering af ny plade");

        // Genkommer fra Discogs
        collection.Add(Item(10, 110, "Queen", "A Night At The Opera", year: 1975));
        report = store.ApplyCollection(collection);
        Check.That(report.ReturnedCopies.SequenceEqual(new[] { queen }), "Queen tilbage i Discogs");

        // Ude af rækkefølge
        Check.That(lib.OutOfOrder(secA, rules).Count == 0, "sektion A i orden");
        {
            // To plader byttet om → kun de byttede markeres
            var ids = lib.Sections[secA].ToList();
            var swapped = ids.ToList(); (swapped[1], swapped[4]) = (swapped[4], swapped[1]);
            var pl = lib.Locations.SelectMany(l => (l.Id == secA ? swapped : lib.Sections[l.Id].ToList()).Select((c, i) => (c, l.Id, i + 1)));
            var bad = new Library(lib.Releases, lib.Copies, lib.Locations, pl).OutOfOrder(secA, rules);
            Check.That(bad.Count is >= 1 and <= 2 && bad.All(x => x == ids[1] || x == ids[4]), "byttede plader markeres som ude af rækkefølge");
        }

        // Reference-mode
        Check.That(lib.ReferenceAdviceFor(wish) is not null, "reference-råd for Wish You Were Here");

        // MARK: Søgning
        var idx = new SearchIndex(lib);
        string Top(string q) => Name(idx.Search(q).Cast<long?>().FirstOrDefault());
        Check.That(idx.Search("pink floyd").Count == 5, $"5 Pink Floyd-kopier: {idx.Search("pink floyd").Count}");
        Check.That(Top("dark side").Contains("Dark Side"), "dark side");
        Check.That(idx.Search("shvl").Count == 3, "shvl finder SHVL 804 ×2 og SHVL 814");
        Check.That(Top("smas11163").Contains("Dark Side"), "katalognummer uden bindestreg");
        Check.That(Top("zepelin").Contains("Led Zeppelin"), "stavefejl: zepelin");
        Check.That(Top("led zeppelin iv").Contains("Led Zeppelin IV"), "led zeppelin iv");
        Check.That(Top("108") == "Pink Floyd – Wish You Were Here", "release ID");
        Check.That(Top("beatles abbey") == "The Beatles – Abbey Road", "artist + titel");
        Check.That(Top("acdc").StartsWith("AC/DC", StringComparison.Ordinal), "acdc finder AC/DC");
        Check.That(SearchIndex.Normalize("Mötley Crüe & Ætheria!") == "motley crue and aetheria"
                   && SearchIndex.Words("  AC/DC  ").SequenceEqual(new[] { "ac", "dc" }), "normalisering til iMusic-matcheren");
        Check.That(SearchIndex.EditDistance("zepelin", "zeppelin", 1) == 1 && SearchIndex.EditDistance("abcd", "abdc", 1) == 1
                   && SearchIndex.EditDistance("abc", "xyz", 1) == 2 && SearchIndex.EditDistance("", "ab", 2) == 2, "redigeringsafstand (med ombytning)");

        // MARK: Værdi
        var m = new MarketInfo(24.99, "EUR", 17, 5120, 1830);
        Check.That(new MarketInfo(null, "EUR", 0, null, null).Demand is null && Math.Abs(m.Demand!.Value - 1830.0 / 5120) < 1e-9, "efterspørgsel");
        store.SaveMarket(106, m);
        var loaded = store.LoadMarket().GetValueOrDefault(106);
        Check.That(loaded?.LowestPrice == 24.99 && loaded?.Want == 1830 && loaded?.Currency == "EUR"
                   && Math.Abs((loaded.FetchedAt - m.FetchedAt).TotalSeconds) < 0.01, "markedsdata gemmes");

        // MARK: Lyttelog + forslag + skilte
        {
            var l = store.LoadLibrary();
            var now = DateTimeOffset.Now;
            var ids = l.GlobalOrder;
            var pid = store.LogPlay(ids[0], now.AddDays(-400));
            store.LogPlay(ids[0], now.AddDays(-10));
            store.LogPlay(ids[1], now.AddDays(-200));
            var stats = new ListeningStats(store.LoadPlays());
            Check.That(stats.Count.GetValueOrDefault(ids[0]) == 2 && stats.MostPlayed(1).FirstOrDefault().CopyId == ids[0], "lyttelog tæller");
            Check.That(stats.PlaysSince(now.AddDays(-30)) == 1, "spillet sidste 30 dage");
            store.DeletePlay(pid);
            stats = new ListeningStats(store.LoadPlays());
            Check.That(stats.Count.GetValueOrDefault(ids[0]) == 1, "fortryd afspilning");

            var items = l.AllItems;
            var never = ListenPicker.Candidates(items, l, new ListenFilter(Freshness: Freshness.NeverPlayed), stats, now);
            Check.That(!never.Any(x => x.Id == ids[0] || x.Id == ids[1]) && never.Count > 0, "aldrig spillet-filter");
            var q3 = ListenPicker.Candidates(items, l, new ListenFilter(Freshness: Freshness.NotIn3Months), stats, now);
            Check.That(q3.Any(x => x.Id == ids[1]) && !q3.Any(x => x.Id == ids[0]), "ikke hørt i 3 måneder");
            var seventies = ListenPicker.Candidates(items, l, new ListenFilter(Decade: 1970), stats, now);
            Check.That(seventies.Count > 0 && seventies.All(x => (x.Release.Year ?? 0) / 10 == 197), "årti-filter");
            var recent = never.Skip(1).Select(x => x.Id).ToList();
            Check.That(ListenPicker.Pick(never, stats, recent, now, new Random(7))?.Id == never[0].Id, "undgår nylige forslag");

            var labels = ShelfLabel.Labels(l);
            Check.That(labels.Count == l.Locations.Count && labels[0].FirstArtist == "ABBA", "skilte: første kunstner");
            Check.That(ShelfLabel.LocationIdFromScanCode(labels[1].ScanCode) == labels[1].Location.Id, "QR-kode kan læses tilbage");
            Check.That(ShelfLabel.LocationIdFromScanCode("https://section/3") is null && ShelfLabel.LocationIdFromScanCode("vinylshelf://record/3") is null
                       && ShelfLabel.LocationIdFromScanCode("vinylshelf://section/") is null && ShelfLabel.LocationIdFromScanCode("vrøvl") is null,
                       "andre koder afvises");
            store.SetScanCode(labels[0].Location.Id, labels[0].ScanCode);
            var reloaded = store.LoadLibrary();
            Check.That(reloaded.Locations[0].ScanCode == labels[0].ScanCode, "scan-kode gemt på sektion");
        }
    });

    // MARK: Præcis Discogs-rækkefølge

    private static void DiscogsOrder() => Check.Section("Discogs-rækkefølge", () =>
    {
        using var s = new ShelfStore(TempDb("rank"));
        // Discogs' rækkefølge afviger bevidst fra appens regler ("The" og titel-orden).
        var discogsOrder = new[] { Item(1, 1, "Pink Floyd", "Wish You Were Here"), Item(2, 2, "Pink Floyd", "Animals"), Item(3, 3, "The Beatles", "Abbey Road") };
        s.ApplyCollection(discogsOrder);
        var l = s.LoadLibrary();
        var d = new SortRules();   // standard: UseDiscogsOrder = true
        Check.That(d.UseDiscogsOrder, "Discogs-rækkefølge er standard");
        Check.That(d.Sorted(l.AllItems).Select(i => i.Copy.InstanceId!.Value).SequenceEqual(new long[] { 1, 2, 3 }), "sorteret præcis som Discogs");
        // Ny plade midt i Discogs-listen → forslag efter dens forgænger i Discogs
        var sorted = d.Sorted(l.AllItems).Select(i => i.Id).ToList();
        var locId = s.AddSection(1, "A");
        for (int i = 0; i < sorted.Count; i++) s.Move(sorted[i], locId, i);
        s.ApplyCollection(new[] { discogsOrder[0], Item(4, 4, "Pink Floyd", "Meddle"), discogsOrder[1], discogsOrder[2] });
        l = s.LoadLibrary();
        var meddle = l.Unplaced[0];
        var sug = l.SuggestPlacement(meddle, d)!;
        Check.That(l.Item(sug.Before!.Value)?.Title == "Wish You Were Here" && l.Item(sug.After!.Value)?.Title == "Animals",
                   "forslag følger Discogs-rækkefølgen");
        // Gamle gemte regler uden feltet dekodes stadig
        var old = SortRules.FromJson("{\"danishAlphabet\":false}")!;
        Check.That(old.UseDiscogsOrder && !old.DanishAlphabet, "tolerant dekodning af gamle regler");
        // Regler og kunstner-overrides gemmes og læses
        var rules = new SortRules { UseDiscogsOrder = false };
        rules.ArtistOverrides["Bob Dylan"] = "Dylan, Bob";
        rules.ArtistOverrides["Tom"] = "  ";
        s.SaveSortRules(rules);
        var back = s.LoadSortRules();
        Check.That(!back.UseDiscogsOrder && back.ArtistOverrides.Count == 1 && back.ArtistOverrides["Bob Dylan"] == "Dylan, Bob",
                   "regler gemmes; kunstner-overrides i egen tabel, tomme droppes");
        Check.That(!(s.Setting("sort_rules") ?? "").Contains("Dylan"), "kunstner-overrides står ikke i sort_rules");

        // instance_id over int.MaxValue gemmes, læses og genkendes ved næste sync (ingen dubletter).
        using var bigStore = new ShelfStore(TempDb("big-instance"));
        var bigItem = Item(1, 7, "Kim Larsen", "Værsgo") with { InstanceId = 2_400_000_123L };
        bigStore.ApplyCollection(new[] { bigItem });
        var again = bigStore.ApplyCollection(new[] { bigItem });
        var bigLib = bigStore.LoadLibrary();
        Check.That(bigLib.Copies.Count == 1 && bigLib.Copies.Values.Single().InstanceId == 2_400_000_123L && again.NewCopies.Count == 0,
                   "instance_id over int.MaxValue overlever databasen og to syncs");
    });

    // MARK: Cd'er: egen hylde i samme samling (samme checks som på Mac)

    private static void Cds() => Check.Section("cd'er", () =>
    {
        Check.That(MediumExtensions.Of("CD, Album") == Medium.Cd && MediumExtensions.Of("2×CD, Compilation") == Medium.Cd
                   && MediumExtensions.Of("CDr, Album") == Medium.Cd && MediumExtensions.Of("SACD, Hybrid") == Medium.Cd, "cd-formater genkendes");
        Check.That(MediumExtensions.Of("Vinyl, LP, Album") == Medium.Vinyl && MediumExtensions.Of("2×Vinyl, LP") == Medium.Vinyl
                   && MediumExtensions.Of("Cassette, Album") == Medium.Vinyl && MediumExtensions.Of(null) == Medium.Vinyl
                   && MediumExtensions.Of("Box Set, CD") == Medium.Vinyl, "alt andet hører til pladerne (kun første format tæller)");
        Check.That(Medium.Cd.RawValue() == "cd" && MediumExtensions.FromRaw("vinyl") == Medium.Vinyl, "gemmes som samme tekst som på Mac");

        using var s = new ShelfStore(TempDb("cd"));
        static DiscogsCollectionItem It(int i, string artist, string title, string format) =>
            new(70_000 + i, null, new Release(700_000 + i, artist, title, Format: format));
        var all = new List<DiscogsCollectionItem> { It(0, "ABBA", "Arrival", "Vinyl, LP"), It(1, "Blur", "Parklife", "CD, Album"),
            It(2, "Bowie", "Low", "Vinyl, LP"), It(3, "Radiohead", "Kid A", "CD, Album"), It(4, "Radiohead", "OK Computer", "CD, Album") };
        s.ApplyCollection(all);
        var counts = s.MediumCounts();
        Check.That(counts.GetValueOrDefault(Medium.Vinyl) == 2 && counts.GetValueOrDefault(Medium.Cd) == 3, "antal pr. hylde");
        var vinyl = s.LoadLibrary();
        var cds = s.LoadLibrary(Medium.Cd);
        Check.That(vinyl.Copies.Count == 2 && cds.Copies.Count == 3 && cds.Medium == Medium.Cd, "samlingen deles op i plader og cd'er");

        var rules = new SortRules();
        var cdIds = rules.Sorted(cds.AllItems).Select(i => i.Id).ToList();
        s.CreateLayout(new List<(int, string, IReadOnlyList<long>)> { (1, "A", rules.Sorted(vinyl.AllItems).Select(i => i.Id).ToList()) });
        s.CreateLayout(new List<(int, string, IReadOnlyList<long>)> { (1, "A", cdIds) }, Medium.Cd);
        var v = s.LoadLibrary();
        var c = s.LoadLibrary(Medium.Cd);
        Check.That(v.Locations.Count == 1 && c.Locations.Count == 1 && v.Locations[0].Id != c.Locations[0].Id
                   && v.Unplaced.Count == 0 && c.Unplaced.Count == 0, "egne reoler pr. hylde");
        Check.That(c.Locations[0].Name == "Cd-reol 1 · Sektion A" && v.Locations[0].Name == "Reol 1 · Sektion A", "cd-reolens navn");

        s.CreateLayout(new List<(int, string, IReadOnlyList<long>)> { (1, "A", cdIds.Take(1).ToList()), (1, "B", cdIds.Skip(1).ToList()) }, Medium.Cd);
        v = s.LoadLibrary();
        c = s.LoadLibrary(Medium.Cd);
        Check.That(v.Locations.Count == 1 && v.GlobalOrder.Count == 2 && c.Locations.Count == 2 && c.GlobalOrder.Count == 3,
                   "ny cd-opdeling rører ikke pladereolen");

        var kidA = c.AllItems.First(i => i.Title == "Kid A").Id;
        var adv = c.ReferenceAdviceFor(kidA)!;
        Check.That(adv.PlacementHint.StartsWith("Cd ") && !adv.PlacementHint.Contains("Plade"), $"Find på cd: {adv.PlacementHint}");
        Check.That(adv.Primary.Reason.Contains("cd") && !adv.Primary.Reason.Contains("plade"), $"Find på cd: {adv.Primary.Reason}");
        var low = v.AllItems.First(i => i.Title == "Low").Id;
        Check.That(v.ReferenceAdviceFor(low)!.PlacementHint.StartsWith("Plade "), "pladerne siger stadig plade");

        var newCd = s.AddSection(2, "A", Medium.Cd);
        c = s.LoadLibrary(Medium.Cd);
        v = s.LoadLibrary();
        Check.That(c.LocationById(newCd)?.Name == "Cd-reol 2 · Sektion A" && v.LocationById(newCd) is null && c.Locations[^1].Id == newCd,
                   "ny cd-sektion står sidst på cd-hylden");

        s.SetMedium(kidA, Medium.Vinyl);
        v = s.LoadLibrary();
        c = s.LoadLibrary(Medium.Cd);
        Check.That(v.Unplaced.Contains(kidA) && !c.Copies.ContainsKey(kidA) && v.Item(kidA)?.Medium == Medium.Vinyl,
                   "skift til plader: uplaceret blandt pladerne");
        Check.That(s.History().FirstOrDefault()?.Kind == HistoryKind.Unplaced, "skiftet står i historikken");
        s.SetMedium(kidA, null);
        Check.That(s.LoadLibrary(Medium.Cd).Unplaced.Contains(kidA), "tilbage til Discogs' format: cd igen (uden plads)");

        s.SetMedium(kidA, Medium.Vinyl);
        s.ApplyCollection(all);
        Check.That(s.LoadLibrary().Copies.GetValueOrDefault(kidA)?.MediumOverride == Medium.Vinyl, "sync bevarer valget af hylde");

        // Digitale filer ("File") står ikke fysisk nogen steder: hverken på plade- eller cd-hylden.
        Check.That(MediumExtensions.IsDigital("File, MP3, Album") && MediumExtensions.IsDigital("8×File, FLAC")
                   && !MediumExtensions.IsDigital("Vinyl, LP") && !MediumExtensions.IsDigital("Box Set, CD") && !MediumExtensions.IsDigital(null),
                   "digitale filer genkendes (kun første format)");
        using var f = new ShelfStore(TempDb("digital"));
        var withFile = new List<DiscogsCollectionItem> { It(0, "ABBA", "Arrival", "Vinyl, LP"), It(1, "Blur", "Parklife", "CD, Album"),
            It(5, "Moby", "Play", "File, MP3, Album"), It(6, "Björk", "Vespertine", "2×DVD, Album") };
        var fr = f.ApplyCollection(withFile);
        var fc = f.MediumCounts();
        Check.That(fc.GetValueOrDefault(Medium.Vinyl) == 2 && fc.GetValueOrDefault(Medium.Cd) == 1 && fr.NewCopies.Count == 3,
                   "fil tælles ikke med; dvd bliver på pladehylden");
        Check.That(f.LoadLibrary().AllItems.All(i => i.Title != "Play") && f.LoadLibrary(Medium.Cd).AllItems.All(i => i.Title != "Play"),
                   "filen står hverken blandt plader eller cd'er");
        var again = f.ApplyCollection(withFile);
        Check.That(again.NewCopies.Count == 0 && again.RemovedCopies.Count == 0, "filen gemmes og ses ikke som ny eller fjernet ved næste sync");
        var playId = f.Db.Query("SELECT c.id FROM copies c WHERE c.release_id = 700005").Single().Long("id")!.Value;
        f.SetMedium(playId, Medium.Cd);
        Check.That(f.LoadLibrary(Medium.Cd).Unplaced.Contains(playId), "brugeren kan selv sætte en fil på en hylde");
        var cdLoc = f.AddSection(1, "A", Medium.Cd);
        f.Move(playId, cdLoc, 0);
        f.SetMedium(playId, null);
        Check.That(f.Db.Query("SELECT copy_id FROM placements WHERE copy_id = ?", playId).Count == 0,"fil tilbage til Discogs' format: pladsen fjernes (ingen skjult placering)");
        var gone = f.ApplyCollection(withFile.Where(i => i.Release.Title != "Play").ToList());
        Check.That(gone.RemovedCopies.Count == 0, "en fil, der forsvinder fra Discogs, meldes ikke som fjernet plade");

        using var d = new ShelfStore(TempDb("cd-demo"));
        DemoData.SeedIfEmpty(d);
        var dcd = d.LoadLibrary(Medium.Cd);
        Check.That(dcd.Copies.Count == 10 && dcd.Locations.Count == 2 && dcd.Unplaced.Count == 0, "demo: cd-reol med 2 sektioner");
        Check.That(d.LoadLibrary().Copies.Count == 43, "demo: pladerne er uændrede");
    });

    // MARK: Sorteringslisten (plader og cd'er hver for sig)

    private static void SortListChecks() => Check.Section("sorteringsliste", () =>
    {
        using var s = new ShelfStore(TempDb("sortlist"));
        static DiscogsCollectionItem It(int i, string artist, string title, string format) =>
            new(80_000 + i, null, new Release(800_000 + i, artist, title, Format: format));
        // Discogs blander formaterne: ABBA (lp), Blur (cd), Bowie (lp), Radiohead (cd).
        s.ApplyCollection(new[] { It(0, "ABBA", "Arrival", "Vinyl, LP"), It(1, "Blur", "Parklife", "CD, Album"),
            It(2, "Bowie", "Low", "Vinyl, LP"), It(3, "Radiohead", "Kid A", "CD, Album") });
        var rules = new SortRules();
        var vinyl = SortList.Build(s.LoadLibrary(), rules);
        var cds = SortList.Build(s.LoadLibrary(Medium.Cd), rules);
        Check.That(vinyl.Select(e => e.Item.Title).SequenceEqual(new[] { "Arrival", "Low" }) && vinyl.Select(e => e.Number).SequenceEqual(new int?[] { 1, 2 }),
                   "uden reoler: pladerne nummereret 1, 2 uden cd'er imellem");
        Check.That(cds.Select(e => e.Item.Title).SequenceEqual(new[] { "Parklife", "Kid A" }) && cds.All(e => e.Location is null),
                   "cd'erne har deres egen liste");

        // Med reoler: fysisk rækkefølge sektion for sektion, nye til sidst.
        var lib = s.LoadLibrary();
        var ids = rules.Sorted(lib.AllItems).Select(i => i.Id).ToList();
        s.CreateLayout(new List<(int, string, IReadOnlyList<long>)> { (1, "A", ids.Take(1).ToList()), (1, "B", ids.Skip(1).ToList()) });
        s.ApplyCollection(new[] { It(0, "ABBA", "Arrival", "Vinyl, LP"), It(1, "Blur", "Parklife", "CD, Album"),
            It(2, "Bowie", "Low", "Vinyl, LP"), It(3, "Radiohead", "Kid A", "CD, Album"), It(4, "Air", "Moon Safari", "Vinyl, LP") });
        lib = s.LoadLibrary();
        var low = lib.AllItems.First(i => i.Title == "Low").Id;
        s.SetStatus(low, CopyStatus.Lent, "Mads");
        var list = SortList.Build(s.LoadLibrary(), rules);
        Check.That(list.Select(e => e.Item.Title).SequenceEqual(new[] { "Arrival", "Low", "Moon Safari" })
                   && list[0].Location?.Section == "A" && list[1].Location?.Section == "B" && list[2].Location is null,
                   "med reoler: sektion A, sektion B, og ny plade uden plads til sidst");
        Check.That(list[1].Number is null && list[2].Number == 2 && SortList.Countable(list) == 2, "udlånt plade har intet nummer og tæller ikke med");

        // Flueben gemmes pr. hylde.
        var arrival = list[0].Item.Id;
        s.SetSortChecked(Medium.Vinyl, arrival, true);
        s.SetSortChecked(Medium.Vinyl, arrival, true);
        Check.That(s.SortChecked(Medium.Vinyl).SetEquals(new[] { arrival }) && s.SortChecked(Medium.Cd).Count == 0, "flueben gemmes pr. hylde");
        Check.That(SortList.NextUnchecked(list, s.SortChecked(Medium.Vinyl))?.Item.Title == "Moon Safari", "næste uden flueben springer udlånte over");
        s.SetSortChecked(Medium.Vinyl, arrival, false);
        Check.That(s.SortChecked(Medium.Vinyl).Count == 0, "flueben kan fjernes");
        s.SetSortChecked(Medium.Cd, cds[0].Item.Id, true);
        s.ClearSortChecked(Medium.Cd);
        Check.That(s.SortChecked(Medium.Cd).Count == 0, "start forfra rydder fluebenene");
    });

    // MARK: Efternavn først

    private static void Surname() => Check.Section("efternavn først", () =>
    {
        Check.That(SurnameSort.Reverse("Bob Dylan") == "Dylan, Bob" && SurnameSort.Reverse("Kim Larsen") == "Larsen, Kim", "for- og efternavn vendes");
        Check.That(SurnameSort.Reverse("Ludwig van Beethoven") == "Beethoven, Ludwig van" && SurnameSort.Reverse("Sammy Davis Jr.") == "Davis, Sammy Jr.",
                   "partikel bliver hos fornavnet, Jr. bliver bagerst");
        Check.That(SurnameSort.Reverse("Gasolin'") is null && SurnameSort.Reverse("The Beatles") is null && SurnameSort.Reverse("Simon & Garfunkel") is null
                   && SurnameSort.Reverse("Various") is null && SurnameSort.Reverse("UB40") is null && SurnameSort.Reverse("Earth Wind and Fire") is null
                   && SurnameSort.Reverse("Crosby Stills Nash Young") is null, "ét ord, The, &, tal, and og fire ord vendes ikke");
        Check.That(SurnameSort.LooksLikePerson("Leonard Cohen") && !SurnameSort.LooksLikePerson("Pink Floyd") && !SurnameSort.LooksLikePerson("Massive Attack")
                   && !SurnameSort.LooksLikePerson("The Allman Brothers Band"), "gættet: person eller band");
        Check.That(!SurnameSort.LooksLikePerson("Black Stone Cherry") && !SurnameSort.LooksLikePerson("Blue Cheer") && SurnameSort.Reverse("A Perfect Circle") is null
                   && SurnameSort.Reverse("Beethoven - Schubert") is null && SurnameSort.LooksLikePerson("B.B. King") && SurnameSort.LooksLikePerson("Alice Cooper"),
                   "typiske bandnavne gættes som bands; B.B. King er stadig en person");

        var cands = SurnameSort.Candidates(new[] { "Bob Dylan", "Pink Floyd", "Bob Dylan", "Kim Larsen", "ABBA" });
        Check.That(cands.Select(c => c.Artist).SequenceEqual(new[] { "Bob Dylan", "Kim Larsen", "Pink Floyd" }), "hver kunstner én gang, kun dem der kan vendes");

        var rules = new SortRules();
        rules.ArtistOverrides["Kim Larsen"] = "Larsen, Kim (Gasolin')";
        var applied = SurnameSort.Apply(rules, cands, new HashSet<string> { "Bob Dylan", "Kim Larsen" });
        Check.That(applied.ArtistOverrides["Bob Dylan"] == "Dylan, Bob" && applied.ArtistOverrides["Kim Larsen"] == "Larsen, Kim (Gasolin')"
                   && !applied.ArtistOverrides.ContainsKey("Pink Floyd") && !applied.UseDiscogsOrder && rules.UseDiscogsOrder,
                   "valgte får efternavn (eget navn beholdes), Discogs-rækkefølge slås fra, originalen røres ikke");
        var undone = SurnameSort.Apply(applied, cands, new HashSet<string> { "Kim Larsen" });
        Check.That(!undone.ArtistOverrides.ContainsKey("Bob Dylan") && undone.ArtistOverrides.ContainsKey("Kim Larsen"), "fravalgt: det vendte navn fjernes igen");

        // Sorteringen bruger det: Cohen før Dylan før Larsen, uanset fornavn.
        static RecordItem Rec(long id, string artist) => new(new Copy(id, id, (int)id), new Release((int)id, artist, "T"));
        var withCohen = SurnameSort.Apply(applied, SurnameSort.Candidates(new[] { "Leonard Cohen" }), new HashSet<string> { "Leonard Cohen" });
        var sorted = withCohen.Sorted(new[] { Rec(1, "Kim Larsen"), Rec(2, "Bob Dylan"), Rec(3, "Leonard Cohen") });
        Check.That(sorted.Select(i => i.Artist).SequenceEqual(new[] { "Leonard Cohen", "Bob Dylan", "Kim Larsen" }), "sorteres efter efternavn");

        using var s = new ShelfStore(TempDb("surname"));
        s.SaveSurnameNotPersons(new[] { "Pink Floyd", "Daft Punk", "Pink Floyd" });
        Check.That(s.SurnameNotPersons().SetEquals(new[] { "Daft Punk", "Pink Floyd" }), "ikke-personer huskes");
        s.SetSetting("surname_not_persons", "ødelagt");
        Check.That(s.SurnameNotPersons().Count == 0, "ødelagt gemt liste → tom, ingen fejl");
    });

    // MARK: Eksport, import og nulstilling

    private static void Transfer() => Check.Section("eksport, import og nulstilling", () =>
    {
        var dir = Check.TempDir();
        Dirs.Add(dir);
        var dbPath = Path.Combine(dir, "vinyl.sqlite");
        var export = Path.Combine(dir, "ud", DataTransfer.ExportFileName(new DateTimeOffset(2026, 10, 17, 21, 5, 0, TimeSpan.FromHours(2))));
        Check.That(Path.GetFileName(export) == "Vinyl Shelf Finder 2026-10-17.sqlite", "eksportens filnavn");
        Check.That(DataTransfer.SafetyFileName("nulstilling", new DateTimeOffset(2026, 10, 17, 21, 5, 0, TimeSpan.FromHours(2)))
                   .StartsWith("før-nulstilling-2026-10-17-") && DatabaseBackup.DateFromFileName("før-nulstilling-2026-10-17-2105.sqlite") is null,
                   "sikkerhedskopien før nulstilling ryddes ikke væk som en daglig kopi");

        using (var s = new ShelfStore(dbPath))
        {
            s.ApplyCollection(new[] { Item(1, 1, "ABBA", "Arrival"), Item(2, 2, "Bowie", "Low") });
            var ids = s.LoadLibrary().AllItems.Select(i => i.Id).ToList();
            s.CreateLayout(new List<(int, string, IReadOnlyList<long>)> { (1, "A", ids) });
            s.SetSortChecked(Medium.Vinyl, ids[0], true);
            DataTransfer.Export(s, export);
            DataTransfer.Export(s, export); // en eksisterende fil erstattes
        }
        Check.That(File.Exists(export) && !Directory.GetFiles(Path.GetDirectoryName(export)!).Any(f => f.EndsWith(".partial")), "eksport gemmes som én fil");

        // Nulstilling: tom database ved næste start.
        DataTransfer.RequestReset(dbPath);
        Check.That(DataTransfer.ApplyPending(dbPath) == DataTransfer.Applied.Reset && !File.Exists(dbPath), "nulstilling sletter databasen før start");
        Check.That(DataTransfer.ApplyPending(dbPath) == DataTransfer.Applied.None, "intet at gøre bagefter");
        using (var s = new ShelfStore(dbPath))
            Check.That(s.LoadLibrary().Copies.Count == 0 && s.LoadLibrary().Locations.Count == 0 && s.SortChecked(Medium.Vinyl).Count == 0, "appen starter helt forfra");

        // Import: det gamle system kommer tilbage.
        var summary = DataTransfer.RequestImport(dbPath, export);
        Check.That(summary == new ImportSummary(2, 0, 1), $"import viser indholdet først: {summary}");
        Check.That(File.Exists(export), "den valgte fil røres ikke");
        // Lukkes appen, før brugeren har sagt ja, sker der intet ved næste start.
        Check.That(DataTransfer.ApplyPending(dbPath) == DataTransfer.Applied.None && !File.Exists(DataTransfer.StagedImport(dbPath)),
                   "en import uden bekræftelse bruges ikke og ryddes væk");
        using (var s = new ShelfStore(dbPath)) Check.That(s.LoadLibrary().Copies.Count == 0, "databasen er urørt uden bekræftelse");
        DataTransfer.RequestImport(dbPath, export);
        DataTransfer.CommitImport(dbPath);
        Check.That(DataTransfer.ApplyPending(dbPath) == DataTransfer.Applied.Import, "bekræftet import udføres ved start");
        using (var s = new ShelfStore(dbPath))
        {
            var lib = s.LoadLibrary();
            Check.That(lib.Copies.Count == 2 && lib.Locations.Count == 1 && lib.Unplaced.Count == 0 && s.SortChecked(Medium.Vinyl).Count == 1,
                       "reoler, placeringer og flueben er tilbage");
        }

        // Forkerte filer afvises, og intet bestilles.
        var junk = Path.Combine(dir, "noter.sqlite");
        File.WriteAllText(junk, "ikke en database");
        bool refused = false;
        try { DataTransfer.RequestImport(dbPath, junk); }
        catch (DatabaseException e) { refused = e.UserFacing && e.UserMessage.Contains("ikke en eksport"); }
        Check.That(refused && !File.Exists(DataTransfer.ImportFile(dbPath)), "en fil, der ikke er en eksport, afvises");
        var empty = Path.Combine(dir, "tom.sqlite");
        using (new ShelfStore(empty)) { }
        bool emptyRefused = false;
        try { DataTransfer.RequestImport(dbPath, empty); }
        catch (DatabaseException e) { emptyRefused = e.UserFacing && e.UserMessage.Contains("ingen plader"); }
        Check.That(emptyRefused && !File.Exists(DataTransfer.StagedImport(dbPath)), "en tom database afvises");
        bool own = false;
        try { DataTransfer.RequestImport(dbPath, dbPath); }
        catch (DatabaseException e) { own = e.UserFacing; }
        Check.That(own, "appens egen database kan ikke importeres");

        // Fortryd: en bestilt nulstilling kan aflyses.
        DataTransfer.RequestReset(dbPath);
        DataTransfer.CancelPending(dbPath);
        Check.That(DataTransfer.ApplyPending(dbPath) == DataTransfer.Applied.None && File.Exists(dbPath), "bestilt nulstilling kan fortrydes");
    });

    // MARK: Reference-mode på demo-data

    private static void DemoReference() => Check.Section("reference-mode på demo", () =>
    {
        using var demo = new ShelfStore(TempDb("demo"));
        DemoData.SeedIfEmpty(demo);
        var dl = demo.LoadLibrary();
        Check.That(DemoData.Collection.Count == 53 && dl.Copies.Count == 43, "demo: 43 eksempelplader og 10 cd'er");
        Check.That(dl.Unplaced.Count == 0 && dl.Locations.Count == 3, "demo: 3 sektioner, alt placeret");
        var station = dl.AllItems.First(i => i.Title == "Station To Station").Id;
        var adv = dl.ReferenceAdviceFor(station)!;
        Check.That(adv.Primary.Reason.Contains("højre kant") && adv.Primary.Reason.Contains("tæl mod venstre: din plade er nr. 2"),
                   $"blok ved sektionskant: {adv.Primary.Reason}");
        var lamb = dl.AllItems.First(i => i.Title == "The Lamb Lies Down On Broadway").Id;
        var lambAdv = dl.ReferenceAdviceFor(lamb)!;
        Check.That(lambAdv.Primary.Reason.Contains("blandt 6 Genesis-plader") && lambAdv.ArtistBlockHint is null,
                   $"midt i Genesis-blokken: tællingen står kun ét sted: {lambAdv.Primary.Reason} / {lambAdv.ArtistBlockHint ?? "nil"}");
        var genesis = dl.GlobalOrder.Where(id => dl.Item(id)?.Artist == "Genesis").ToList();
        Check.That(dl.ReferenceAdviceFor(genesis[0])!.ArtistBlockHint == "Der står 6 Genesis-plader i træk, og din plade er den længst til venstre."
                   && dl.ReferenceAdviceFor(genesis[^1])!.ArtistBlockHint == "Der står 6 Genesis-plader i træk, og din plade er den længst til højre.",
                   "Genesis-blok hint ved blokkens kanter");

        // Teksterne er entydige: set fra din plade, venstre/højre, aldrig "før"/"efter".
        var ambiguous = new List<string>(); var wrongSide = new List<string>(); var badHint = new List<string>(); var tripled = new List<string>();
        foreach (var id in dl.GlobalOrder)
        {
            var a = dl.ReferenceAdviceFor(id)!;
            var texts = new[] { a.Primary.Reason, a.Secondary?.Reason, a.ArtistBlockHint, a.PlacementHint, a.SectionEdgeHint }.OfType<string>();
            foreach (var t in texts)
                if (t.Contains(" før") || t.Contains(" efter") || t.StartsWith("Står ") || t.StartsWith("Pladen ") || t.Contains("?.")) ambiguous.Add(t);
            foreach (var r in new[] { a.Primary, a.Secondary }.OfType<Reference>())
            {
                switch (r.Side)
                {
                    case ReferenceSide.Before: if (!r.Reason.Contains("til venstre for din plade") && !r.Reason.Contains("lige til højre for")) wrongSide.Add(r.Reason); break;
                    case ReferenceSide.After: if (!r.Reason.Contains("til højre for din plade") && !r.Reason.Contains("lige til venstre for")) wrongSide.Add(r.Reason); break;
                    case ReferenceSide.SectionStart: if (r.Reason != "Din plade står yderst til venstre i sektionen.") wrongSide.Add(r.Reason); break;
                    case ReferenceSide.SectionEnd: if (r.Reason != "Din plade står yderst til højre i sektionen.") wrongSide.Add(r.Reason); break;
                }
            }
            if (a.Secondary is { Item: RecordItem it } s && it.Title != dl.Item(id)!.Title)
            {
                var expected = $"{it.Title} står lige til {(s.Side == ReferenceSide.Before ? "venstre" : "højre")} for din plade.";
                if (s.Reason != expected) wrongSide.Add(s.Reason);
            }
            var nb = dl.NeighborsOf(id)!;
            if (a.PlacementHint != $"Plade {nb.Position} af {nb.SectionCount} fra venstre") badHint.Add(a.PlacementHint);
            if (a.ArtistBlockHint is not null && a.Primary.Reason.Contains("tæl")) tripled.Add(a.Primary.Reason);
        }
        Check.That(ambiguous.Count == 0, $"ingen tvetydige tekster: {string.Join(" | ", ambiguous.Take(3))}");
        Check.That(wrongSide.Count == 0, $"referencer siger venstre/højre set fra din plade: {string.Join(" | ", wrongSide.Take(3))}");
        Check.That(badHint.Count == 0, $"kort placeringstekst: {string.Join(" | ", badHint.Take(3))}");
        Check.That(tripled.Count == 0, $"tælleinstruktion og blok-hint gentager ikke hinanden: {string.Join(" | ", tripled.Take(2))}");
        var hunky = dl.AllItems.First(i => i.Title == "Hunky Dory").Id;
        Check.That(dl.ReferenceAdviceFor(hunky)!.Primary.Reason ==
                   "Din plade står blandt 5 David Bowie-plader i træk. Find Bob Dylan – John Wesley Harding, som står lige til venstre for dem, og tæl mod højre: din plade er nr. 2, lige til højre for \"Heroes\".",
                   $"tælleinstruktion fra venstre: {dl.ReferenceAdviceFor(hunky)!.Primary.Reason}");
        var lastA = dl.Sections[dl.Locations[0].Id][^1];
        Check.That(dl.ReferenceAdviceFor(lastA)!.SectionEdgeHint == "Næste sektion (1B) begynder med Dire Straits – Brothers In Arms.",
                   $"sektionskant: næste sektion nævnes: {dl.ReferenceAdviceFor(lastA)!.SectionEdgeHint ?? "nil"}");
        var lastB = dl.Sections[dl.Locations[1].Id][^1];
        Check.That(dl.ReferenceAdviceFor(lastB)!.SectionEdgeHint?.EndsWith("Morning Glory?") == true, "titel med ? får ikke ekstra punktum");
        var darkSides = dl.GlobalOrder.Where(id => dl.Item(id)?.Title == "The Dark Side Of The Moon").ToList();
        Check.That(dl.ReferenceAdviceFor(darkSides[0])!.Secondary?.Reason == "Et andet eksemplar af The Dark Side Of The Moon står lige til højre for din plade.",
                   "andet eksemplar af samme plade nævnes som sådan");
        Check.That(dl.ReferenceAdviceFor(dl.GlobalOrder[5])!.ArtistBlockHint is null && dl.ReferenceAdviceFor(dl.GlobalOrder[5])!.SectionEdgeHint is null,
                   "ingen ekstra hints midt i sektionen mellem andre kunstnere");
        var aage = dl.AllItems.First(i => i.Artist == "Åge Aleksandersen").Id;
        Check.That(dl.GlobalOrder[^1] == aage, "Åge Aleksandersen står sidst (Å efter Z)");
    });

    // MARK: Deep scan – ende-til-ende-flows og grænsetilfælde

    // Sync: dubletter, metadata-tælling, genrer og placeringer
    private static void SyncDeep() => Check.Section("sync i dybden", () =>
    {
        using var s = new ShelfStore(TempDb("sync"));
        var c = new List<DiscogsCollectionItem> { Item(1, 1, "ABBA", "Arrival"), Item(2, 2, "Bowie", "Low"), Item(3, 2, "Bowie", "Low"), Item(4, 3, "Queen", "Jazz") };
        var r = s.ApplyCollection(c.Append(c[0]));   // instance 1 to gange (sideskift under sync)
        Check.That(r.NewCopies.Count == 4 && r.Total == 4, "sync: dublet-instance giver ikke fejl og kun én kopi");
        Check.That(r.UpdatedReleases == 0, $"sync: ny release med to kopier tælles ikke som opdateret (fik {r.UpdatedReleases})");
        var l = s.LoadLibrary();
        var loc = s.AddSection(1, "A");
        var order = new SortRules().Sorted(l.AllItems).Select(i => i.Id).ToList();
        for (int i = 0; i < order.Count; i++) s.Move(order[i], loc, i);
        var before = PlacementRows(s);
        r = s.ApplyCollection(c);
        Check.That(r.UpdatedReleases == 0 && r.NewCopies.Count == 0 && r.RemovedCopies.Count == 0, "sync: uændret samling giver tom rapport");
        c[1] = WithRelease(c[1], x => x with { Genres = "Rock" }); c[2] = WithRelease(c[2], x => x with { Genres = "Rock" });
        r = s.ApplyCollection(c);
        l = s.LoadLibrary();
        Check.That(r.UpdatedReleases == 1 && l.Releases[2].Genres == "Rock", "sync: ændrede genrer opdateres (én gang pr. release)");
        Check.That(s.History(1)[0].Summary == "Oplysninger fra Discogs opdateret for 1 plade", "historik: metadata opdateret");
        // Fjernet + ny + ændret metadata i samme sync: placeringer er uberørte.
        c.RemoveAll(x => x.InstanceId == 4);
        c[0] = WithRelease(c[0], x => x with { Title = "Arrival (Deluxe)" });
        c.Add(Item(5, 9, "Zappa", "Hot Rats"));
        r = s.ApplyCollection(c);
        Check.That(PlacementRows(s).SequenceEqual(before), "sync: placements uændret efter fjernet/ny/ændret");
        l = s.LoadLibrary();
        Check.That(l.Unplaced.Count == 1 && l.Copies[l.Unplaced[0]].DiscogsRank == 3, "sync: ny plade uplaceret med discogs_rank");
        var queen = l.Copies.Values.First(x => x.InstanceId == 4);
        Check.That(!queen.InDiscogs && queen.DiscogsRank is null && l.LocationOfCopy[queen.Id] == loc, "sync: fjernet plade beholder placering, mister rank");
        s.KeepLocalOnly(queen.Id);
        Check.That(s.LoadLibrary().Copies[queen.Id].RemovedFromDiscogsAt is null && !s.LoadLibrary().Copies[queen.Id].InDiscogs, "behold lokalt: kun datoen nulstilles");
        // Sletning af en kopi: placering væk, release ryddet op, historik
        s.DeleteCopy(queen.Id);
        l = s.LoadLibrary();
        Check.That(!l.Copies.ContainsKey(queen.Id) && !l.Releases.ContainsKey(3) && Positions(s, loc).SequenceEqual(new[] { 1, 2, 3 }),
                   "slet kopi: placering og release fjernes, resten omnummereres");
        Check.That(s.History(1)[0].Summary == "Queen – Jazz slettet fra appen" && s.History(1)[0].Kind == HistoryKind.Deleted, "historik: slettet");
        // Sortering-overrides
        s.SetSortOverrides(l.GlobalOrder[0], "  Zzz  ", " ");
        var cp = s.LoadLibrary().Copies[l.GlobalOrder[0]];
        Check.That(cp.SortArtistOverride == "Zzz" && cp.SortTitleOverride is null, "sorterings-overrides trimmes, tomme bliver null");
    });

    // Flyt, omnummerering, rollback og fortryd
    private static void MoveDeep() => Check.Section("flyt i dybden", () =>
    {
        using var s = new ShelfStore(TempDb("move"));
        s.ApplyCollection(Enumerable.Range(1, 5).Select(i => Item(i, i, $"Artist {i}", $"T{i}")));
        var l = s.LoadLibrary();
        var ids = new SortRules().Sorted(l.AllItems).Select(i => i.Id).ToList();
        s.CreateLayout(Layout((1, "A", ids.Take(4)), (1, "B", new[] { ids[4] })));
        Check.That(s.History(1)[0].Summary == "Reolerne er oprettet: 2 sektioner, 5 plader" && s.History(1)[0].CopyId is null, "historik: reoler oprettet");
        l = s.LoadLibrary();
        long a = l.Locations[0].Id, b = l.Locations[1].Id;
        // Flyt ned i samme sektion
        s.Move(ids[0], a, 2);
        l = s.LoadLibrary();
        Check.That(l.Sections[a].SequenceEqual(new[] { ids[1], ids[2], ids[0], ids[3] }) && Positions(s, a).SequenceEqual(new[] { 1, 2, 3, 4 }),
                   "flyt ned i samme sektion + omnummerering");
        // Fortryd (som appen gør det: tilbage til from-position)
        var e = s.History().First(h => h.Kind == HistoryKind.Moved);
        s.Move(e.CopyId!.Value, e.FromLocationId!.Value, e.FromPosition!.Value - 1);
        l = s.LoadLibrary();
        Check.That(l.Sections[a].SequenceEqual(ids.Take(4)), "fortryd flyt genskaber rækkefølgen");
        // Flyt til ikke-eksisterende sektion: fejler og rulles tilbage
        var snapshot = PlacementRows(s);
        bool threw = false;
        try { s.Move(ids[1], 9999, 0); } catch (DatabaseException) { threw = true; }
        Check.That(threw && PlacementRows(s).SequenceEqual(snapshot), "flyt til ukendt sektion rulles tilbage");
        // Sidste plade ud af sektion B → tom sektion; grænser og naboer holder
        s.Move(ids[4], a, int.MaxValue);
        l = s.LoadLibrary();
        Check.That(l.Sections[b].Count == 0 && l.Sections[a][^1] == ids[4] && Positions(s, a).SequenceEqual(new[] { 1, 2, 3, 4, 5 }), "sidste plade flyttet ud – tom sektion");
        var nLast = l.NeighborsOf(ids[4])!;
        Check.That(nLast.ReachedSectionEnd && nLast.NextSection?.Location.Id == b && nLast.NextSection?.First is null, "naboer ved tom næste sektion");
        var lbl = ShelfLabel.Labels(l).First(x => x.Location.Id == b);
        Check.That(lbl.Count == 0 && lbl.FirstArtist is null, "skilt for tom sektion");
        Check.That(l.SuggestPlacement(ids[0], new SortRules(), restrictTo: b)?.Index == 0, "forslag i tom sektion = først");
        // Fjern fra reolen og læg tilbage
        s.Unplace(ids[2]);
        l = s.LoadLibrary();
        Check.That(l.Unplaced.SequenceEqual(new[] { ids[2] }) && Positions(s, a).SequenceEqual(new[] { 1, 2, 3, 4 }), "unplace omnummererer");
        var sug = l.SuggestPlacement(ids[2], new SortRules())!;
        Check.That(sug.LocationId == a && sug.Before == ids[1] && sug.After == ids[3], "forslag lægger pladen tilbage mellem sine naboer");
        s.Move(ids[2], sug.LocationId, sug.Index);
        l = s.LoadLibrary();
        Check.That(l.Sections[a].SequenceEqual(new[] { ids[0], ids[1], ids[2], ids[3], ids[4] }), "placering efter forslag");
        s.DeleteEmptySection(b);
        bool refused = false;
        try { s.DeleteEmptySection(a); } catch (DatabaseException) { refused = true; }
        Check.That(refused && s.LoadLibrary().Locations.Count == 1, "kun tomme sektioner kan slettes");
        try { s.DeleteEmptySection(a); }
        catch (DatabaseException ex) { Check.That(ex.UserMessage == "Sektionen er ikke tom. Flyt pladerne ud af den først.", $"fejltekst på dansk: {ex.UserMessage}"); }
        try { s.Db.Query("SELECT nope FROM nowhere"); Check.That(false, "ugyldig SQL skal fejle"); }
        catch (DatabaseException ex)
        {
            Check.That(ex.UserMessage == "Der opstod en fejl i databasen. Prøv igen." && ex.ToString().Contains("nowhere"),
                       $"databasefejl: dansk for brugeren, teknisk i log: {ex.UserMessage}");
        }
        var hist = s.History().Select(h => h.Summary).ToList();
        Check.That(hist.Any(h => h.EndsWith("fjernet fra Reol 1 · Sektion A, plads 3")), "historik: fjernet fra reolen");
        static bool HasEmoji(string t) => t.EnumerateRunes().Any(r => r.Value >= 0x1F000 || (r.Value >= 0x2600 && r.Value <= 0x27BF));
        Check.That(!hist.Any(h => h.Contains(" / ") || HasEmoji(h)), "historik: ingen emoji og ens placeringsformat");
        // Gamle poster i databasen vises uændret.
        s.Db.Run("INSERT INTO history(at, kind, summary) VALUES(?, 'statusChanged', ?)", 1.0, "X – Y: 👤 Udlånt");
        Check.That(s.History(1).FirstOrDefault()?.Summary == "X – Y: 👤 Udlånt", "eksisterende historik ændres ikke");
        // Én plade i sektionen
        var one = s.AddSection(2, "A");
        s.Move(ids[0], one, 0);
        l = s.LoadLibrary();
        var adv1 = l.ReferenceAdviceFor(ids[0])!;
        Check.That(adv1.Primary.Side == ReferenceSide.SectionStart && adv1.Secondary is null && adv1.PlacementHint == "Plade 1 af 1 fra venstre",
                   "reference: eneste plade i sektionen");
        // Ny sektion i en lavere reol indsættes før de højere reoler
        var mid = s.AddSection(1, "B");
        l = s.LoadLibrary();
        Check.That(l.Locations.Select(x => x.ShortName).SequenceEqual(new[] { "1A", "1B", "2A" }) && l.Locations[1].Id == mid
                   && l.Shelves.SequenceEqual(new[] { 1, 2 }), "ny sektion sættes ind efter sin reol");
    });

    // Reference: udlånte plader i en kunstnerblok tælles ikke med
    private static void ReferenceLent() => Check.Section("reference med udlånte", () =>
    {
        using var s = new ShelfStore(TempDb("ref"));
        var c = new List<DiscogsCollectionItem> { Item(1, 1, "Abba", "A") };
        for (int i = 2; i <= 7; i++) c.Add(Item(i, i, "Genesis", $"G{i}"));
        c.Add(Item(8, 8, "Queen", "Q"));
        s.ApplyCollection(c);
        var l = s.LoadLibrary();
        var ids = l.Copies.Values.OrderBy(x => x.InstanceId).Select(x => x.Id).ToList();
        s.CreateLayout(Layout((1, "A", ids)));
        // Abba, G2, G3(udlånt), G4 = mål, G5, G6, G7, Queen
        s.SetStatus(ids[2], CopyStatus.Lent, null);
        l = s.LoadLibrary();
        var adv = l.ReferenceAdviceFor(ids[3])!;
        Check.That(adv.Primary.Reason.Contains("tæl mod højre: din plade er nr. 2") && adv.Primary.Reason.Contains("Abba"),
                   $"udlånt plade i blok tælles ikke: {adv.Primary.Reason}");
        Check.That(adv.Primary.Reason.Contains("blandt 5 Genesis-plader") && adv.ArtistBlockHint is null, $"blokken tæller kun plader i reolen: {adv.Primary.Reason}");
        // Landmærket (Abba) udlånt → ingen plade at finde; brug sektionens kant
        s.SetStatus(ids[0], CopyStatus.Lent, null);
        l = s.LoadLibrary();
        Check.That(l.ReferenceAdviceFor(ids[3])!.Primary.Reason.Contains("venstre kant"), "udlånt landmærke bruges ikke");
    });

    // Lyttelog med fortryd, forslag og værdi
    private static void ListenDeep() => Check.Section("lyttelog i dybden", () =>
    {
        using var s = new ShelfStore(TempDb("listen"));
        s.ApplyCollection(new[] { Item(1, 1, "A", "a", year: 1975), Item(2, 2, "B", "b", year: 1983) });
        var l = s.LoadLibrary();
        s.CreateLayout(Layout((1, "A", l.Copies.Keys.OrderBy(k => k))));
        l = s.LoadLibrary();
        var id = l.GlobalOrder[0];
        var now = DateTimeOffset.Now;
        var p = s.LogPlay(id, now);
        Check.That(new ListeningStats(s.LoadPlays()).Count.GetValueOrDefault(id) == 1, "spillet registreret");
        s.DeletePlay(p);
        Check.That(!new ListeningStats(s.LoadPlays()).Count.ContainsKey(id), "fortryd spillet");
        // Afspilninger i fremtiden (forkert ur) må ikke crashe forslaget
        foreach (var cid in l.GlobalOrder) s.LogPlay(cid, now.AddDays(3 * 365));
        var stats = new ListeningStats(s.LoadPlays());
        var rng = new Random(3);
        var cands = ListenPicker.Candidates(l.AllItems, l, new ListenFilter(), stats, now);
        Check.That(ListenPicker.Pick(cands, stats, Array.Empty<long>(), now, rng) is not null, "forslag med fremtidige afspilninger");
        Check.That(ListenPicker.Pick(Array.Empty<RecordItem>(), stats, Array.Empty<long>(), now, rng) is null, "forslag uden kandidater = nil");
        Check.That(ListenPicker.Decades(l.AllItems).SequenceEqual(new[] { 1970, 1980 }), "årtier");
        Check.That(Freshness.NotIn3Months.Label() == "Ikke hørt i 3 måneder", "friskhed: dansk tekst");
        // Værdi: gem/indlæs og valutaskift overskriver
        var v = ShelfStore.CollectionValueFromJson("{\"minimum\":\"€1\",\"median\":\"€2\",\"maximum\":\"€3\",\"fetchedAt\":1000}")!;
        Check.That(v.FetchedAt == new DateTimeOffset(2001, 1, 1, 0, 16, 40, TimeSpan.Zero), "værdi: dato som Swift (sekunder siden 2001)");
        s.SaveCollectionValue(v);
        Check.That(s.LoadCollectionValue() == v, "samlingsværdi gemmes");
        s.SaveMarket(1, new MarketInfo(10, "EUR", 1, 0, 3));
        s.SaveMarket(1, new MarketInfo(90, "SEK", null, null, null));
        var m = s.LoadMarket();
        Check.That(m.Count == 1 && m[1].Currency == "SEK" && m[1].LowestPrice == 90 && m[1].Have is null, "markedsdata overskrives ved valutaskift");
        Check.That(new MarketInfo(null, "EUR", null, 0, 5).Demand is null, "efterspørgsel: ingen division med 0");
        s.ClearMarket();
        Check.That(s.LoadMarket().Count == 0, "markedsdata kan ryddes");
        // Genrer
        Check.That(ListenPicker.Genres(DemoData.Collection.Select(x => new RecordItem(new Copy(1, x.InstanceId, x.Release.Id), x.Release)))
                   .SequenceEqual(new[] { "Funk / Soul", "Pop", "Rock" }), "genrer fra kommaliste");
    });

    // SQLite-robusthed
    private static void SqliteRobustness() => Check.Section("SQLite-robusthed", () =>
    {
        bool threw = false;
        var dirAsDb = Check.TempDir();
        Dirs.Add(dirAsDb);
        try { using var _ = new ShelfStore(dirAsDb); } catch (DatabaseException) { threw = true; }
        Check.That(threw, "database-sti der er en mappe giver fejl (ikke crash)");
        var path = TempDb("schema");
        using (var s = new ShelfStore(path))
        {
            Check.That(s.Db.UserVersion == 5, "skema v5");
            s.ApplyCollection(new[] { Item(1, 1, "O'Brien", "Robert'); DROP TABLE copies;--") });
        }
        using var reopened = new ShelfStore(path);
        Check.That(reopened.LoadLibrary().AllItems.FirstOrDefault()?.Title == "Robert'); DROP TABLE copies;--", "genåbning + strenge bindes sikkert");
        var tables = reopened.Db.Query("SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name").Select(r => r.Text("name")).ToList();
        Check.That(new[] { "artist_sort_overrides", "copies", "history", "locations", "placements", "plays", "release_market", "releases", "scan_codes", "settings" }
                   .All(t => tables.Contains(t)), $"samme tabeller som på Mac: {string.Join(",", tables)}");
    });

    // Migration v3 → v4 bevarer data
    private static void Migration() => Check.Section("migration", () =>
    {
        var path = TempDb("migr");
        using (var s = new ShelfStore(path))
        {
            s.ApplyCollection(new[] { Item(1, 1, "A", "a") });
            s.Db.Execute("DROP TABLE plays; PRAGMA user_version = 3;");
        }
        using var up = new ShelfStore(path);
        var cid = up.LoadLibrary().Copies.Keys.First();
        bool ok;
        try { up.LogPlay(cid); ok = true; } catch (DatabaseException) { ok = false; }
        Check.That(up.Db.UserVersion == 5 && ok, "migration v3→v5 opretter plays og bevarer kopier");
    });

    // Søgning: Unicode og grænsetilfælde
    private static void SearchUnicode() => Check.Section("søgning: unicode", () =>
    {
        using var s = new ShelfStore(TempDb("search"));
        s.ApplyCollection(new[] { Item(1, 1, "Kim Larsen", "Værsgo"), Item(2, 2, "Åge Aleksandersen", "Levva Livet"),
                                  Item(3, 3, "Mötley Crüe", "Dr. Feelgood"), Item(4, 4, "Simon & Garfunkel", "Bookends") });
        var ix = new SearchIndex(s.LoadLibrary());
        Check.That(ix.Search("").Count == 0 && ix.Search("   ").Count == 0 && ix.Search("!!!").Count == 0, "tom søgning");
        Check.That(ix.Search("VÆRSGO").Count == 1 && ix.Search("vaersgo").Count == 1, "Æ søges uafhængigt af store/små og ae");
        Check.That(ix.Search("åge").Count == 1 && ix.Search("motley crue").Count == 1, "Å og diakritika");
        Check.That(ix.Search("simon and garfunkel").Count == 1, "& = and");
        ix.Search("🎵"); ix.Search("a"); ix.Search(new string('x', 40));
        Check.That(ix.Search("varsgo").Count == 1, "stavefejl uden crash");
    });

    // Søgning: samme relevans → reolens rækkefølge (sektion, position), uplacerede sidst
    private static void SearchOrder() => Check.Section("søgning: rækkefølge", () =>
    {
        using var s = new ShelfStore(TempDb("searchorder"));
        // Uplaceret plade får det laveste id, og sektionernes id'er er omvendt af reolens rækkefølge.
        s.ApplyCollection(new[] { Item(1, 1, "Pink Floyd", "Ummagumma"), Item(2, 2, "Pink Floyd", "The Wall"),
                                  Item(3, 3, "Pink Floyd", "Animals"), Item(4, 4, "Pink Floyd", "Wish You Were Here"),
                                  Item(5, 5, "Pink Floyd", "Meddle"), Item(6, 6, "Pink Floyd", "The Dark Side Of The Moon") });
        var l = s.LoadLibrary();
        long Cid(string title) => l.AllItems.First(i => i.Title == title).Id;
        var second = s.AddSection(2, "A");
        var first = s.AddSection(1, "A");
        var t1 = new[] { "Meddle", "The Dark Side Of The Moon", "Wish You Were Here" };
        for (int i = 0; i < t1.Length; i++) s.Move(Cid(t1[i]), first, i);
        var t2 = new[] { "Animals", "The Wall" };
        for (int i = 0; i < t2.Length; i++) s.Move(Cid(t2[i]), second, i);
        l = s.LoadLibrary();
        var ix = new SearchIndex(l);
        var expected = new[] { "Meddle", "The Dark Side Of The Moon", "Wish You Were Here", "Animals", "The Wall", "Ummagumma" };
        var got = ix.Search("pink floid").Select(id => l.Item(id)!.Title).ToList();
        Check.That(got.SequenceEqual(expected), $"samme relevans i reolens rækkefølge, uplacerede sidst: {string.Join(", ", got)}");
        Check.That(ix.Search("pink floyd").Select(id => l.Item(id)!.Title).SequenceEqual(expected), "også uden stavefejl");
        Check.That(ix.Search("pink floyd wall").Select(id => l.Item(id)!.Title).FirstOrDefault() == "The Wall", "bedre match kommer stadig først");
        Check.That(ix.Search("pink floyd", limit: 2).Count == 2, "grænse for antal hits");
    });

    // Mobilside: parsing, routing og escaping
    private static void Mobile() => Check.Section("mobilside", () =>
    {
        static MobileSite.Request? Req(string raw) => MobileSite.Request.Parse(Encoding.UTF8.GetBytes(raw));
        Check.That(Req("GET /?q=AC%2BDC+live HTTP/1.1\r\nHost: x\r\n\r\n")?.Query.GetValueOrDefault("q") == "AC+DC live", "query: + er mellemrum, %2B er plus");
        Check.That(Req("GET /?q=%C3%A6%C3%B8%C3%A5 HTTP/1.1\r\n\r\n")?.Query.GetValueOrDefault("q") == "æøå", "query: procent-dekodet UTF-8");
        Check.That(Req("GET /?q=%zz HTTP/1.1\r\n\r\n")?.Query.GetValueOrDefault("q") == "%zz", "query: ugyldig procent-kode crasher ikke");
        Check.That(Req("") is null && Req("GARBAGE") is null && Req("\r\n\r\n") is null, "ugyldig request = nil");
        var bad = Encoding.UTF8.GetBytes("GET /section/3 HTTP/1.1\r\nX: ").Concat(new byte[] { 0xFF, 0xFE }).Concat(Encoding.UTF8.GetBytes("\r\n\r\n")).ToArray();
        Check.That(MobileSite.Request.Parse(bad)?.Path == "/section/3", "ugyldig UTF-8 i header afviser ikke requesten");
        Check.That(Req("POST /record/5/play HTTP/1.1\n\n")?.Method == "POST", "linjeskift uden \\r");

        using var s = new ShelfStore(TempDb("mobile"));
        s.ApplyCollection(new[] { Item(1, 77, "<script>alert(1)</script>", "\"><img src=x onerror=alert(1)>"), Item(2, 78, "Bob", "Plain") });
        var l = s.LoadLibrary();
        var ids = l.Copies.Keys.OrderBy(k => k).ToList();
        s.CreateLayout(Layout((1, "<b>X", ids)));
        l = s.LoadLibrary();
        var loc = l.Locations[0].Id;
        MobileSite.Reply Route(string m, string path, Dictionary<string, string>? q = null) =>
            MobileSite.Route(new MobileSite.Request(m, path, q ?? new()), l, ListeningStats.Empty);
        static string Html(MobileSite.Reply r) => r is MobileSite.Reply.Html h ? h.Content : "";
        var pages = new[] { Html(Route("GET", "/")), Html(Route("GET", "/", new() { ["q"] = "bob" })), Html(Route("GET", "/", new() { ["q"] = "script" })),
                            Html(Route("GET", $"/section/{loc}", new() { ["mark"] = $"{ids[0]}" })), Html(Route("GET", $"/record/{ids[0]}")),
                            Html(Route("GET", $"/record/{ids[1]}")) };
        Check.That(pages.All(p => p.Length > 0), "mobilside: alle sider renderes");
        Check.That(pages.All(p => !p.Contains("<script>alert") && !p.Contains("<img src=x") && !p.Contains("<b>X")), "mobilside: titler, kunstnere og sektionsnavne escapes");
        var nf = new MobileSite.Reply.NotFound();
        Check.That(Route("GET", "/section/999") == nf && Route("GET", "/section/abc") == nf && Route("GET", "/record/999") == nf, "mobilside: ukendte id'er = 404");
        Check.That(Route("POST", $"/record/{ids[0]}/play") == new MobileSite.Reply.LogPlay(ids[0], $"/record/{ids[0]}?played=1"), "mobilside: Spillet-knap");
        Check.That(Route("GET", $"/record/{ids[0]}/play") == nf && Route("POST", "/") == nf, "mobilside: forkert metode = 404");
        Check.That(Route("GET", "/cover/77", new() { ["s"] = "l" }) == new MobileSite.Reply.Cover(77, true) && Route("GET", "/cover/1") == nf, "mobilside: cover-route");
        Check.That(Html(Route("GET", $"/record/{ids[0]}", new() { ["played"] = "1" })).Contains("Registreret"), "mobilside: bekræftelse efter Spillet");
        var resp = MobileSite.Response(200, "text/html; charset=utf-8", Encoding.UTF8.GetBytes("æ"));
        Check.That(Encoding.UTF8.GetString(resp).Contains("Content-Length: 2\r\n"), "Content-Length tæller bytes");
        // Afspilninger vises på pladens side
        var stats = new ListeningStats(new[] { new Play(1, ids[1], DateTimeOffset.Now.AddDays(-3)), new Play(2, ids[1], DateTimeOffset.Now.AddDays(-40)) });
        var rec = Html(MobileSite.Route(new MobileSite.Request("GET", $"/record/{ids[1]}"), l, stats));
        Check.That(rec.Contains("Spillet 2 gange · senest for 3 dage siden"), "mobil plade: lyttelog");
    });

    // MARK: Ude af reolen (fx På væggen): fysisk nummerering og "sæt tilbage"

    /// Kontrollerer reglerne for fysisk nummerering og ReturnAdviceFor for alle plader,
    /// mens pladerne i `outIds` er ude af reolen. Returnerer en liste over fejl (tom = alt i orden).
    private static List<string> PhysicalSweep(Library b, IEnumerable<long> outIds)
    {
        var outSet = outIds.ToHashSet();
        var copies = b.Copies.ToDictionary(kv => kv.Key, kv => outSet.Contains(kv.Key) ? kv.Value with { Status = CopyStatus.Wall } : kv.Value);
        var placements = b.Locations.SelectMany(loc => b.Sections[loc.Id].Select((c, i) => (c, loc.Id, i + 1))).ToList();
        var lib = new Library(b.Releases, copies, b.Locations, placements);
        var problems = new List<string>();
        foreach (var loc in lib.Locations)
        {
            var onShelf = lib.Sections[loc.Id].Where(x => !outSet.Contains(x)).ToList();
            var expected = onShelf.Select((x, i) => (x, i + 1)).ToDictionary(t => t.x, t => t.Item2);
            if (!DictEq(lib.ShelfNumbers(loc.Id), expected)) problems.Add($"shelfNumbers i {loc.ShortName}");
            if (lib.OnShelfCount(loc.Id) != onShelf.Count) problems.Add($"onShelfCount i {loc.ShortName}");
        }
        foreach (var target in lib.GlobalOrder)
        {
            var title = lib.Item(target)!.Title;
            var loc = lib.LocationOfCopy[target];
            var physical = lib.Sections[loc].Where(x => x == target || !outSet.Contains(x)).ToList();
            int t = physical.IndexOf(target);
            var n = lib.NeighborsOf(target)!;
            if (n.Position != t + 1 || n.SectionCount != physical.Count) problems.Add($"position/antal for {title}: {n.Position}/{n.SectionCount}");
            if (!outSet.Contains(target) && lib.ShelfNumbers(loc).GetValueOrDefault(target) != n.Position) problems.Add($"shelfNumbers ≠ position for {title}");
            // Når en ude-plade sættes tilbage, får den præcis det nummer, der blev sagt.
            if (outSet.Contains(target))
            {
                var back = new Dictionary<long, Copy>(copies) { [target] = copies[target] with { Status = CopyStatus.Home } };
                var after = new Library(lib.Releases, back, lib.Locations, placements);
                if (after.ShelfNumbers(loc).GetValueOrDefault(target) != t + 1 || after.OnShelfCount(loc) != physical.Count)
                    problems.Add($"tilbage på en anden plads end sagt: {title}");
            }
            if (lib.ReferenceAdviceFor(target)!.PlacementHint != $"Plade {t + 1} af {physical.Count} fra venstre") problems.Add($"Find-placementHint for {title}");

            var r = lib.ReturnAdviceFor(target)!;
            var texts = new[] { r.Primary.Reason, r.Secondary?.Reason, r.ArtistBlockHint, r.PlacementHint, r.SectionEdgeHint }.OfType<string>().ToList();
            if (r.PlacementHint != $"Plads {t + 1} af {physical.Count} fra venstre") problems.Add($"placementHint: {r.PlacementHint}");
            foreach (var txt in texts)
                if (txt.Contains(" før") || txt.Contains(" efter") || txt.Contains("?.") || txt.Contains("din plade er")
                    || txt.Contains("står lige til venstre for din") || txt.Contains("står lige til højre for din"))
                    problems.Add($"tekst set fra reolen, ikke fra pladen: {txt}");
            foreach (var txt in new[] { r.Primary.Reason, r.Secondary?.Reason, r.ArtistBlockHint }.OfType<string>())
                if (!txt.StartsWith("Sæt den ") && !txt.StartsWith("Din plade skal stå ")) problems.Add($"tekst siger ikke 'sæt den'/'skal stå': {txt}");
            foreach (var txt in texts)
                if (txt.Contains("tæl") && !txt.Contains("skal stå")) problems.Add($"tælleinstruktion uden 'skal stå': {txt}");
            // Nævner aldrig en plade, der selv er ude. Navne på plader i reolen fjernes først, så fx
            // "Hunting High And Low" ikke forveksles med "Low", og et andet eksemplar ikke tæller.
            var shelfNames = lib.GlobalOrder.Where(x => !outSet.Contains(x))
                .SelectMany(x => new[] { lib.Item(x)!.FullName, lib.Item(x)!.Title }).OrderByDescending(x => x.Length).ToList();
            var rest = string.Join(" | ", texts);
            foreach (var name in shelfNames) rest = rest.Replace(name, "#");
            foreach (var id in outSet.Where(x => x != target))
            {
                var other = lib.Item(id)!;
                if (rest.Contains(other.Title) || r.Primary.Item?.Id == id || r.Secondary?.Item?.Id == id)
                    problems.Add($"{title}: nævner {other.Title}, som er ude: {string.Join(" | ", texts)}");
            }
            foreach (var it in new[] { r.Primary.Item, r.Secondary?.Item }.OfType<RecordItem>())
                if (outSet.Contains(it.Id)) problems.Add($"{title}: reference til en plade, der er ude");
            // Venstre/højre: en plade til venstre for pladen → "sæt den lige til højre for" den, og omvendt.
            foreach (var rf in new[] { r.Primary, r.Secondary }.OfType<Reference>())
            {
                var core = rf.Reason.Replace("som står lige til venstre for dem", "").Replace("som står lige til højre for dem", "");
                switch (rf.Side)
                {
                    case ReferenceSide.Before:
                        if (rf.Item?.Id != (t > 0 ? physical[t - 1] : null) || !core.Contains("lige til højre for") || core.Contains("lige til venstre for"))
                            problems.Add($"venstre nabo forkert for {title}: {rf.Reason}");
                        break;
                    case ReferenceSide.After:
                        if (rf.Item?.Id != (t + 1 < physical.Count ? physical[t + 1] : null) || !core.Contains("lige til venstre for") || core.Contains("lige til højre for"))
                            problems.Add($"højre nabo forkert for {title}: {rf.Reason}");
                        break;
                    case ReferenceSide.SectionStart:
                        if (t != 0 || rf.Reason != "Sæt den yderst til venstre i sektionen.") problems.Add($"venstre kant for {title}: {rf.Reason}");
                        break;
                    case ReferenceSide.SectionEnd:
                        if (t != physical.Count - 1 || rf.Reason != "Sæt den yderst til højre i sektionen.") problems.Add($"højre kant for {title}: {rf.Reason}");
                        break;
                }
            }
        }
        return problems;
    }

    private static void OutOfShelf() => Check.Section("ude af reolen", () =>
    {
        Check.That(CopyStatus.Wall.RawValue() == "wall" && CopyStatus.Wall.Label() == "På væggen" && !CopyStatus.Wall.IsOnShelf(),
                   "På væggen: rawValue, label og står ikke i reolen");
        Check.That(CopyStatusExtensions.All.SequenceEqual(new[] { CopyStatus.Home, CopyStatus.Wall, CopyStatus.Lent, CopyStatus.Stored, CopyStatus.Missing }),
                   "rækkefølge af statusser");
        Check.That(CopyStatusExtensions.All.Where(x => x.IsOnShelf()).SequenceEqual(new[] { CopyStatus.Home }), "kun På plads tæller som i reolen");

        using var s = new ShelfStore(TempDb("wall"));
        var records = new (string, string)[] { ("ABBA", "Arrival"), ("Aurora", "All My Demons Greeting Me as a Friend"), ("The Beatles", "Abbey Road"),
                       ("The Beatles", "Help!"), ("The Beatles", "Revolver"), ("Bob Dylan", "Blonde On Blonde"),
                       ("Genesis", "Trespass"), ("Genesis", "Nursery Cryme"), ("Genesis", "Foxtrot"),
                       ("Genesis", "Selling England By The Pound"), ("Queen", "Jazz"), ("Frank Zappa", "Hot Rats") };
        var coll = records.Select((r, i) => Item(i + 1, 500 + i, r.Item1, r.Item2)).ToList();
        s.ApplyCollection(coll);
        var l = s.LoadLibrary();
        var ids = l.Copies.Values.OrderBy(x => x.InstanceId).Select(x => x.Id).ToList();
        s.CreateLayout(Layout((1, "A", ids.Take(6)), (1, "B", ids.Skip(6).Take(5)), (2, "A", new[] { ids[11] })));
        l = s.LoadLibrary();
        long a = l.Locations[0].Id, b = l.Locations[1].Id, c = l.Locations[2].Id;
        long abba = ids[0], aurora = ids[1], abbey = ids[2], help = ids[3], revolver = ids[4], dylan = ids[5];
        long trespass = ids[6], nursery = ids[7], foxtrot = ids[8], selling = ids[9], queen = ids[10], zappa = ids[11];
        var original = PlacementRows(s);
        bool Unmoved() => PlacementRows(s).SequenceEqual(original);
        string Pos(long id) => l.NeighborsOf(id) is { } nb ? $"{nb.Position ?? -1}/{nb.SectionCount}" : "nil";
        void Set(long id, CopyStatus st) { s.SetStatus(id, st, null); l = s.LoadLibrary(); }
        static List<string> Texts(ReferenceAdvice r) =>
            new[] { r.Primary.Reason, r.Secondary?.Reason, r.ArtistBlockHint, r.PlacementHint, r.SectionEdgeHint }.OfType<string>().ToList();
        static Dictionary<long, int> D(params (long, int)[] kv) => kv.ToDictionary(x => x.Item1, x => x.Item2);

        // Før: alle står i reolen.
        Check.That(Pos(revolver) == "5/6" && l.ReferenceAdviceFor(revolver)?.PlacementHint == "Plade 5 af 6 fra venstre", "før: Plade 5 af 6");
        Check.That(DictEq(l.ShelfNumbers(a), D((abba, 1), (aurora, 2), (abbey, 3), (help, 4), (revolver, 5), (dylan, 6))) && l.OnShelfCount(a) == 6,
                   "før: shelfNumbers 1…6 og onShelfCount 6");

        // Aurora hænges på væggen.
        Set(aurora, CopyStatus.Wall);
        Check.That(Unmoved(), "På væggen flytter ikke placements");
        var storedStatus = s.Db.Query("SELECT status FROM copies WHERE id = ?", aurora).FirstOrDefault()?.Text("status");
        Check.That(storedStatus == "wall" && l.Copies[aurora].Status == CopyStatus.Wall, "status gemmes som teksten 'wall' og læses tilbage");
        Check.That(l.Sections[a].Count == 6 && l.IndexInSection[aurora] == 1 && l.LocationOfCopy[aurora] == a, "pladen på væggen beholder sin plads i databasen");
        Check.That(Pos(revolver) == "4/5" && l.ReferenceAdviceFor(revolver)?.PlacementHint == "Plade 4 af 5 fra venstre",
                   $"plader til højre rykker sammen: Plade 5 af 6 → 4 af 5 (fik {Pos(revolver)})");
        Check.That(Pos(abba) == "1/5", $"plade til venstre beholder sit nummer: {Pos(abba)}");
        Check.That(Pos(aurora) == "2/6", $"ude-plade: nummeret når den sættes tilbage, talt med sig selv: {Pos(aurora)}");
        Check.That(DictEq(l.ShelfNumbers(a), D((abba, 1), (abbey, 2), (help, 3), (revolver, 4), (dylan, 5))), "shelfNumbers springer pladen på væggen over");
        Check.That(l.OnShelfCount(a) == 5 && l.OnShelfCount(b) == 5 && l.OnShelfCount(c) == 1, "onShelfCount");
        var ra = l.ReturnAdviceFor(aurora)!;
        Check.That(ra.Primary.Side == ReferenceSide.Before && ra.Primary.Item?.Id == abba && ra.Primary.Reason == "Sæt den lige til højre for ABBA – Arrival.",
                   $"sæt tilbage: til højre for pladen til venstre: {ra.Primary.Reason}");
        Check.That(ra.Secondary?.Side == ReferenceSide.After && ra.Secondary?.Item?.Id == abbey && ra.Secondary?.Reason == "Sæt den lige til venstre for The Beatles – Abbey Road.",
                   $"sæt tilbage: til venstre for pladen til højre: {ra.Secondary?.Reason ?? "nil"}");
        Check.That(ra.PlacementHint == "Plads 2 af 6 fra venstre" && ra.ArtistBlockHint is null && ra.SectionEdgeHint is null,
                   $"sæt tilbage: Plads 2 af 6 (tæller sig selv med): {ra.PlacementHint}");
        var findAbbey = l.ReferenceAdviceFor(abbey)!;
        Check.That(findAbbey.Primary.Item?.Id == abba && findAbbey.Primary.Reason == "Arrival står lige til venstre for din plade. Det er en anden kunstner, så den er let at få øje på."
                   && !Texts(findAbbey).Any(x => x.Contains("Aurora")) && findAbbey.PlacementHint == "Plade 2 af 5 fra venstre",
                   $"Find: naboen springer pladen på væggen over: {string.Join(" | ", Texts(findAbbey))}");

        // Sat tilbage: samme plads som sagt, og numrene rykker igen.
        var saidPosition = Pos(aurora);
        Set(aurora, CopyStatus.Home);
        Check.That(Unmoved() && Pos(aurora) == saidPosition && Pos(revolver) == "5/6" && l.OnShelfCount(a) == 6,
                   "sat tilbage: står hvor returnAdvice sagde, og numrene rykker tilbage");

        // Revolver på væggen: anden kunstner til højre, blok-hint og titel med "!".
        Set(revolver, CopyStatus.Wall);
        var rr = l.ReturnAdviceFor(revolver)!;
        Check.That(rr.Primary.Side == ReferenceSide.After && rr.Primary.Item?.Id == dylan
                   && rr.Primary.Reason == "Sæt den lige til venstre for Bob Dylan – Blonde On Blonde. Det er en anden kunstner, så den er let at få øje på.",
                   $"sæt tilbage: anden kunstner til højre: {rr.Primary.Reason}");
        Check.That(rr.Secondary?.Item?.Id == help && rr.Secondary?.Reason == "Sæt den lige til højre for Help!", $"samme kunstner nævnes med titel, ingen ekstra punktum: {rr.Secondary?.Reason ?? "nil"}");
        Check.That(rr.ArtistBlockHint == "Din plade skal stå længst til højre blandt 3 The Beatles-plader i træk." && rr.PlacementHint == "Plads 5 af 6 fra venstre",
                   $"blok-hint ved sæt tilbage: {rr.ArtistBlockHint ?? "nil"}");
        Set(revolver, CopyStatus.Home);

        // Help! på væggen og Aurora udlånt: tælleinstruktion, og landmærket er ikke Aurora.
        Set(help, CopyStatus.Wall); Set(aurora, CopyStatus.Lent);
        var rh = l.ReturnAdviceFor(help)!;
        Check.That(rh.Primary.Reason == "Din plade skal stå blandt 3 The Beatles-plader i træk. Find ABBA – Arrival, som står lige til venstre for dem, og tæl mod højre: din plade skal stå som nr. 2, lige til højre for Abbey Road.",
                   $"tælleinstruktion med 'skal stå': {rh.Primary.Reason}");
        Check.That(rh.Secondary?.Reason == "Sæt den lige til venstre for Revolver." && rh.PlacementHint == "Plads 3 af 5 fra venstre" && rh.ArtistBlockHint is null,
                   $"sæt tilbage midt i blok: {rh.Secondary?.Reason ?? "nil"} / {rh.PlacementHint}");
        Check.That(!Texts(rh).Any(x => x.Contains("Aurora")) && !Texts(l.ReturnAdviceFor(aurora)!).Any(x => x.Contains("Help!")),
                   "returnAdvice nævner aldrig en plade, der selv er ude");
        Set(help, CopyStatus.Home); Set(aurora, CopyStatus.Home);

        // Kant: første plade.
        Set(abba, CopyStatus.Wall);
        var rf = l.ReturnAdviceFor(abba)!;
        Check.That(rf.Primary.Side == ReferenceSide.SectionStart && rf.Primary.Item is null && rf.Primary.Reason == "Sæt den yderst til venstre i sektionen."
                   && rf.Secondary?.Reason == "Sæt den lige til venstre for Aurora – All My Demons Greeting Me as a Friend." && rf.PlacementHint == "Plads 1 af 6 fra venstre",
                   $"første plade: {string.Join(" | ", Texts(rf))}");
        var lbl = ShelfLabel.Labels(l)[0];
        Check.That(lbl.FirstArtist == "Aurora" && lbl.LastArtist == "Bob Dylan" && lbl.Count == 5, $"skilt: første kunstner og antal tæller kun plader i reolen: {lbl}");
        Set(abba, CopyStatus.Home);

        // Kant: sidste plade.
        Set(dylan, CopyStatus.Wall);
        var rl = l.ReturnAdviceFor(dylan)!;
        Check.That(rl.Primary.Side == ReferenceSide.SectionEnd && rl.Primary.Reason == "Sæt den yderst til højre i sektionen."
                   && rl.Secondary?.Reason == "Sæt den lige til højre for The Beatles – Revolver." && rl.PlacementHint == "Plads 6 af 6 fra venstre"
                   && rl.SectionEdgeHint == "Næste sektion (1B) begynder med Genesis – Trespass.",
                   $"sidste plade: {string.Join(" | ", Texts(rl))}");
        lbl = ShelfLabel.Labels(l)[0];
        Check.That(lbl.FirstArtist == "ABBA" && lbl.LastArtist == "The Beatles" && lbl.Count == 5, $"skilt: sidste kunstner tæller kun plader i reolen: {lbl}");
        Set(dylan, CopyStatus.Home);

        // Sektion, hvor alle andre er ude.
        foreach (var (id, st) in new[] { (trespass, CopyStatus.Lent), (nursery, CopyStatus.Stored), (foxtrot, CopyStatus.Missing), (queen, CopyStatus.Wall), (selling, CopyStatus.Wall) })
            Set(id, st);
        Check.That(Unmoved(), "flere statusskift flytter ikke placements");
        var rb = l.ReturnAdviceFor(selling)!;
        Check.That(rb.Primary.Side == ReferenceSide.SectionStart && rb.Secondary is null && rb.PlacementHint == "Plads 1 af 1 fra venstre" && Pos(selling) == "1/1",
                   $"alle andre ude: {string.Join(" | ", Texts(rb))}");
        Check.That(rb.SectionEdgeHint == "Forrige sektion (1A) slutter med Bob Dylan – Blonde On Blonde. Næste sektion (2A) begynder med Frank Zappa – Hot Rats.",
                   $"alle andre ude: nabosektioner nævnes: {rb.SectionEdgeHint ?? "nil"}");
        Check.That(l.OnShelfCount(b) == 0 && l.ShelfNumbers(b).Count == 0, "alle ude: onShelfCount 0 og ingen numre");
        lbl = ShelfLabel.Labels(l)[1];
        Check.That(lbl.Count == 0 && lbl.FirstArtist is null && lbl.LastArtist is null, "skilt: sektion hvor alle er ude");
        Check.That(l.NeighborsOf(dylan)!.NextSection?.First is null && l.ReturnAdviceFor(dylan)!.SectionEdgeHint is null,
                   "næste sektion uden plader i reolen nævnes ikke med en ude-plade");
        {
            var home = MobileSite.Route(new MobileSite.Request("GET", "/"), l, ListeningStats.Empty) is MobileSite.Reply.Html h ? h.Content : "";
            Check.That(home.Contains("(alle plader er ude)") && home.Contains("ABBA → Bob Dylan"), "mobil forside: sektion hvor alle er ude");
        }
        Set(foxtrot, CopyStatus.Home);
        var rb2 = l.ReturnAdviceFor(selling)!;
        Check.That(Pos(foxtrot) == "1/1" && l.ReferenceAdviceFor(foxtrot)?.PlacementHint == "Plade 1 af 1 fra venstre"
                   && rb2.Primary.Side == ReferenceSide.SectionEnd && rb2.Secondary?.Reason == "Sæt den lige til højre for Foxtrot." && rb2.PlacementHint == "Plads 2 af 2 fra venstre",
                   $"én plade tilbage i sektionen: {string.Join(" | ", Texts(rb2))}");
        foreach (var id in new[] { trespass, nursery, queen, selling }) Set(id, CopyStatus.Home);

        // Sektion med én plade.
        Set(zappa, CopyStatus.Wall);
        var rz = l.ReturnAdviceFor(zappa)!;
        Check.That(rz.Primary.Side == ReferenceSide.SectionStart && rz.Secondary is null && rz.PlacementHint == "Plads 1 af 1 fra venstre" && l.OnShelfCount(c) == 0
                   && rz.SectionEdgeHint == "Forrige sektion (1B) slutter med Queen – Jazz.",
                   $"sektion med én plade: {string.Join(" | ", Texts(rz))}");
        Check.That(ShelfLabel.Labels(l)[2].Count == 0 && ShelfLabel.Labels(l)[2].FirstArtist is null, "skilt: eneste plade på væggen");
        Set(zappa, CopyStatus.Home);
        Check.That(l.ReferenceAdviceFor(zappa)?.PlacementHint == "Plade 1 af 1 fra venstre" && l.OnShelfCount(c) == 1, "sektion med én plade tilbage");

        // Statusskift ændrer aldrig placements – heller ikke frem og tilbage gennem alle statusser.
        var moved = new List<string>();
        foreach (var st in CopyStatusExtensions.All.Append(CopyStatus.Home)) { Set(help, st); if (!Unmoved()) moved.Add(st.RawValue()); }
        Check.That(moved.Count == 0 && Unmoved(), $"statusskift (alle statusser) ændrer aldrig placements: {string.Join(",", moved)}");
        Check.That(l.Unplaced.Count == 0 && l.ShelfNumbers(a).Count == 6, "alt er tilbage");

        // Mobilside: kun plader i reolen nummereres; ude-plader nedtonet uden nummer og med status.
        Set(aurora, CopyStatus.Wall);
        string Html(string path, Dictionary<string, string>? q = null) =>
            MobileSite.Route(new MobileSite.Request("GET", path, q ?? new()), l, ListeningStats.Empty) is MobileSite.Reply.Html h ? h.Content : "";
        static Dictionary<long, string> RowNumbers(string h)
        {
            var re = new Regex("<li id=\"c(\\d+)\" class=\"[^\"]*\"><a class=\"row\" href=\"/record/\\d+\"><span class=\"num\">([^<]*)</span>");
            return re.Matches(h).ToDictionary(m => long.Parse(m.Groups[1].Value, CultureInfo.InvariantCulture), m => m.Groups[2].Value);
        }
        var sec = Html($"/section/{a}");
        var expectedRows = new Dictionary<long, string> { [abba] = "1", [aurora] = "", [abbey] = "2", [help] = "3", [revolver] = "4", [dylan] = "5" };
        Check.That(DictEq(RowNumbers(sec), expectedRows), "mobil sektion: fysiske numre, intet nummer på væggen");
        Check.That(sec.Contains($"<li id=\"c{aurora}\" class=\"away\">") && sec.Contains("<span class=\"sub\">På væggen</span>") && sec.Contains("5 plader (+1 ude)"),
                   "mobil sektion: pladen på væggen er nedtonet med status, og antallet tæller kun plader i reolen");
        var marked = Html($"/section/{a}", new() { ["mark"] = $"{aurora}" });
        Check.That(RowNumbers(marked).GetValueOrDefault(aurora) == "" && marked.Contains("class=\"away mark\""), "mobil sektion: markeret ude-plade");
        var recRev = Html($"/record/{revolver}");
        Check.That(recRev.Contains("Plade 4 af 5 fra venstre") && recRev.Contains("Gå til") && !recRev.Contains("Aurora"), "mobil plade: fysiske tal for plade i reolen");
        var recAur = Html($"/record/{aurora}");
        Check.That(recAur.Contains("Plads 2 af 6 fra venstre") && recAur.Contains("Hører til") && recAur.Contains("Sæt tilbage")
                   && recAur.Contains("Sæt den lige til højre for ABBA – Arrival.") && recAur.Contains("“På væggen”"),
                   "mobil plade: ude-plade viser, hvor den skal sættes tilbage");
        var homePage = Html("/");
        Check.That(homePage.Contains("ABBA → Bob Dylan") && homePage.Contains("5 plader") && !homePage.Contains("6 plader"), "mobil forside: antal tæller kun plader i reolen");
        Check.That(Html("/", new() { ["q"] = "revolver" }).Contains("1A · plads 4") && Html("/", new() { ["q"] = "aurora" }).Contains("1A · på væggen")
                   && !Html("/", new() { ["q"] = "aurora" }).Contains("plads 2"), "mobil søgning: fysisk plads, intet nummer for ude-plade");
        Set(aurora, CopyStatus.Home);
        Check.That(RowNumbers(Html($"/section/{a}")).GetValueOrDefault(aurora) == "2" && RowNumbers(Html($"/section/{a}")).GetValueOrDefault(revolver) == "5",
                   "mobil sektion: numrene rykker igen efter tilbagesætning");

        // Uplaceret plade har intet "sæt tilbage"-råd.
        s.ApplyCollection(coll.Append(Item(99, 999, "Ny", "Plade")));
        l = s.LoadLibrary();
        Check.That(l.Unplaced.Count == 1 && l.ReturnAdviceFor(l.Unplaced[0]) is null && l.ReferenceAdviceFor(l.Unplaced[0]) is null, "returnAdvice = nil uden placering");
        Check.That(Unmoved(), "sync flytter ikke placeringer");

        // Gennemløb af alle plader med forskellige mønstre af plader, der er ude.
        var patterns = new List<long[]> { Array.Empty<long>(), new[] { aurora }, new[] { abbey, revolver }, new[] { help, dylan, foxtrot },
                                          new[] { trespass, nursery, foxtrot, queen }, new[] { zappa, abba },
                                          ids.Where((_, i) => i % 2 == 0).ToArray(), ids.Where((_, i) => i % 3 == 1).ToArray() };
        var sweep = patterns.SelectMany(p => PhysicalSweep(l, p)).ToList();
        Check.That(sweep.Count == 0, $"fysisk nummerering og returnAdvice for alle plader: {string.Join(" | ", sweep.Take(4))}");

        using var d = new ShelfStore(TempDb("wall-demo"));
        DemoData.SeedIfEmpty(d);
        var dl = d.LoadLibrary();
        var genesis = dl.GlobalOrder.Where(x => dl.Item(x)?.Artist == "Genesis").ToList();
        var demoPatterns = new List<long[]> { Array.Empty<long>(), genesis.Take(2).ToArray(), new[] { genesis[2] },
                                              dl.GlobalOrder.Where((_, i) => i % 4 == 0).ToArray(), dl.GlobalOrder.Where((_, i) => i % 5 == 2).ToArray() };
        var demoSweep = demoPatterns.SelectMany(p => PhysicalSweep(dl, p)).ToList();
        Check.That(demoSweep.Count == 0, $"demo: fysisk nummerering og returnAdvice for alle plader: {string.Join(" | ", demoSweep.Take(4))}");
    });

    // Demo-data kan seedes igen uden at ændre noget
    private static void DemoIdempotent() => Check.Section("demo idempotent", () =>
    {
        using var d = new ShelfStore(TempDb("demo2"));
        DemoData.SeedIfEmpty(d);
        var first = PlacementRows(d);
        DemoData.SeedIfEmpty(d);
        Check.That(PlacementRows(d).SequenceEqual(first) && first.Count > 0, "demo: seedIfEmpty er idempotent");
        Check.That(!d.LoadSortRules().UseDiscogsOrder, "demo: bruger appens egne sorteringsregler");
    });

    // MARK: Sikkerhedskopi af databasen

    private static void Backup() => Check.Section("sikkerhedskopi", () =>
    {
        var day = new DateTimeOffset(new DateTime(2026, 10, 1, 14, 0, 0, DateTimeKind.Local));
        Check.That(DatabaseBackup.FileName(day) == "vinyl-2026-10-01.sqlite", "backup: filnavn med dato");
        Check.That(SameDay(DatabaseBackup.DateFromFileName("vinyl-2026-10-01.sqlite"), day), "backup: dato læses fra filnavnet");
        Check.That(DatabaseBackup.DateFromFileName("vinyl.sqlite") is null && DatabaseBackup.DateFromFileName("noter-2026-10-01.sqlite") is null
                   && DatabaseBackup.DateFromFileName("vinyl-2026-10-01.sqlite-wal") is null && DatabaseBackup.DateFromFileName("vinyl-2026-13-01.sqlite") is null,
                   "backup: andre filer genkendes ikke");
        Check.That(DatabaseBackup.IsDue(null, day), "backup: ingen kopi → tag en");
        Check.That(!DatabaseBackup.IsDue(day.AddHours(-1), day), "backup: allerede taget i dag → ikke igen");
        Check.That(DatabaseBackup.IsDue(day.AddHours(-24), day), "backup: sidste kopi er fra i går → tag en");

        var names = Enumerable.Range(1, 20).Select(i => $"vinyl-2026-09-{i:00}.sqlite").Concat(new[] { "vinyl.sqlite", "egne noter.txt" }).ToList();
        var delete = DatabaseBackup.NamesToDelete(names.OrderBy(_ => Guid.NewGuid()), keep: 14);
        Check.That(delete.ToHashSet().SetEquals(Enumerable.Range(1, 6).Select(i => $"vinyl-2026-09-{i:00}.sqlite")),
                   $"backup: de 6 ældste af 20 slettes: {string.Join(",", delete.OrderBy(x => x))}");
        Check.That(DatabaseBackup.NamesToDelete(names, keep: 30).Count == 0, "backup: færre end keep → intet slettes");

        // Ende-til-ende: kopi af en rigtig database, oprydning, og kopien kan åbnes.
        var dir = Check.TempDir();
        Dirs.Add(dir);
        var folder = Path.Combine(dir, "Vinyl Shelf Finder's backup");   // mellemrum og apostrof
        Directory.CreateDirectory(folder);
        using var src = new ShelfStore(Path.Combine(dir, "kilde.sqlite"));
        src.ApplyCollection(new[] { Item(1, 101, "ABBA", "Arrival"), Item(2, 102, "Queen", "Jazz") });
        for (int d = 1; d <= 3; d++) File.WriteAllBytes(Path.Combine(folder, $"vinyl-2026-09-{d:00}.sqlite"), Array.Empty<byte>());
        File.WriteAllText(Path.Combine(folder, "noter.txt"), "mine");
        var made = DatabaseBackup.Run(src, folder, day, keep: 2);
        using (var copy = new ShelfStore(made))
        {
            var cl = copy.LoadLibrary();
            Check.That(cl.Copies.Count == 2 && cl.Releases.Count == 2, "backup: kopien kan åbnes og indeholder pladerne");
        }
        var left = Directory.GetFiles(folder).Select(Path.GetFileName).ToHashSet();
        Check.That(left.SetEquals(new[] { "vinyl-2026-10-01.sqlite", "vinyl-2026-09-03.sqlite", "noter.txt" })
                   || left.SetEquals(new[] { "vinyl-2026-10-01.sqlite", "vinyl-2026-09-03.sqlite", "noter.txt", "vinyl-2026-10-01.sqlite-wal", "vinyl-2026-10-01.sqlite-shm" }),
                   $"backup: de 2 nyeste kopier beholdes, andre filer røres ikke: {string.Join(",", left.OrderBy(x => x))}");
        Check.That(SameDay(DatabaseBackup.Latest(folder), day), "backup: nyeste kopi findes ud fra filnavnet");
        src.ApplyCollection(new[] { Item(1, 101, "ABBA", "Arrival"), Item(2, 102, "Queen", "Jazz"), Item(3, 103, "Bowie", "Low") });
        var again = DatabaseBackup.Run(src, folder, day, keep: 2);
        using (var newer = new ShelfStore(again))
            Check.That(newer.LoadLibrary().Copies.Count == 3, "backup: en ny kopi samme dag erstatter dagens kopi");
        var oneDrive = Path.Combine(dir, "OneDrive");
        Check.That(DatabaseBackup.IsInOneDrive(Path.Combine(oneDrive, "Vinyl Shelf Finder backup"), oneDrive)
                   && !DatabaseBackup.IsInOneDrive(folder, oneDrive) && !DatabaseBackup.IsInOneDrive(Path.Combine(dir, "OneDriveX", "b"), oneDrive),
                   "backup: OneDrive-mappen genkendes");
        Check.That(DatabaseBackup.DefaultFolder().EndsWith("Vinyl Shelf Finder backup"), "backup: standardmappen hedder som på Mac");
        bool threw = false;
        try { src.Backup(made); } catch (DatabaseException e) { threw = e.UserMessage == "Sikkerhedskopien kunne ikke gemmes."; }
        Check.That(threw, "backup: eksisterende fil giver en dansk fejl");
    });

    // MARK: Cover Flow

    private static void CoverFlow() => Check.Section("cover flow", () =>
    {
        // Coverets størrelse
        Check.That(CoverFlowGeometry.Side(100, 50) == 80, "cover flow: siden er aldrig under 80");
        Check.That(CoverFlowGeometry.Side(10_000, 10_000) == 360, "cover flow: siden er aldrig over 360");
        Check.That(Math.Abs(CoverFlowGeometry.Side(500, 1000) - 180) < 0.0001, "cover flow: siden begrænses af bredden (36 %)");
        Check.That(Math.Abs(CoverFlowGeometry.Side(2000, 300) - 186) < 0.0001, "cover flow: siden begrænses af højden (62 %, plads til spejling)");
        bool sizesOK = true;
        for (double w = 0; w <= 3000; w += 137)
            for (double h = 0; h <= 2000; h += 91)
            {
                var sd = CoverFlowGeometry.Side(w, h);
                if (sd < 80 || sd > 360) sizesOK = false;
            }
        Check.That(sizesOK, "cover flow: siden ligger altid mellem 80 og 360");

        // Vandret placering
        const double side = 200.0;
        Check.That(CoverFlowGeometry.X(0, side) == 0, "cover flow: midtercoveret står i midten");
        Check.That(Math.Abs(CoverFlowGeometry.X(1, side) - 0.62 * side) < 0.0001, "cover flow: første sidecover står 0,62 × siden fra midten");
        bool symmetric = true, increasing = true;
        for (int d = 1; d <= 10; d++)
        {
            if (Math.Abs(CoverFlowGeometry.X(-d, side) + CoverFlowGeometry.X(d, side)) > 0.0001) symmetric = false;
            if (!(CoverFlowGeometry.X(d + 1, side) > CoverFlowGeometry.X(d, side))) increasing = false;
            if (!(CoverFlowGeometry.X(-(d + 1), side) < CoverFlowGeometry.X(-d, side))) increasing = false;
        }
        Check.That(symmetric, "cover flow: x er symmetrisk om midten");
        Check.That(increasing, "cover flow: afstanden fra midten vokser med |d|");
        Check.That(CoverFlowGeometry.X(1, side) > 0 && CoverFlowGeometry.X(-1, side) < 0, "cover flow: højre er positiv, venstre negativ");

        // Drejning, skala og lag
        Check.That(CoverFlowGeometry.Angle(0) == 0, "cover flow: midtercoveret vender lige frem");
        Check.That(CoverFlowGeometry.Angle(1) == -CoverFlowGeometry.Tilt && CoverFlowGeometry.Angle(5) == -CoverFlowGeometry.Tilt, "cover flow: covers til højre drejes -tilt (yderkanten nærmest)");
        Check.That(CoverFlowGeometry.Angle(-1) == CoverFlowGeometry.Tilt && CoverFlowGeometry.Angle(-5) == CoverFlowGeometry.Tilt, "cover flow: covers til venstre drejes +tilt (yderkanten nærmest)");
        Check.That(CoverFlowGeometry.Scale(0) == 1, "cover flow: midtercoveret har fuld størrelse");
        Check.That(CoverFlowGeometry.Scale(1) < 1 && CoverFlowGeometry.Scale(-1) < 1 && CoverFlowGeometry.Scale(4) < 1, "cover flow: sidecovers er mindre");
        bool layersOK = true;
        for (int d = 0; d <= CoverFlowGeometry.Visible; d++)
        {
            if (!(CoverFlowGeometry.ZIndex(d) > CoverFlowGeometry.ZIndex(d + 1)) || !(CoverFlowGeometry.ZIndex(-d) > CoverFlowGeometry.ZIndex(-(d + 1)))) layersOK = false;
            if (CoverFlowGeometry.ZIndex(d) != CoverFlowGeometry.ZIndex(-d)) layersOK = false;
        }
        Check.That(layersOK, "cover flow: nærmere covers ligger øverst");
        Check.That(CoverFlowGeometry.ZIndex(0) > CoverFlowGeometry.ZIndex(1) && CoverFlowGeometry.ZIndex(0) > CoverFlowGeometry.ZIndex(-1), "cover flow: midtercoveret ligger øverst");

        // Synlige plader
        static bool Empty((int Start, int End) r) => r.End <= r.Start;
        const int V = CoverFlowGeometry.Visible;
        Check.That(Empty(CoverFlowGeometry.VisibleRange(0, 0)), "cover flow: ingen plader → intet at tegne");
        Check.That(Empty(CoverFlowGeometry.VisibleRange(3, 0)), "cover flow: ingen plader → intet at tegne, uanset midte");
        Check.That(CoverFlowGeometry.VisibleRange(0, 100) == (0, V + 1), "cover flow: klemmes i starten");
        Check.That(CoverFlowGeometry.VisibleRange(99, 100) == (99 - V, 100), "cover flow: klemmes i slutningen");
        Check.That(CoverFlowGeometry.VisibleRange(50, 100) == (50 - V, 51 + V), "cover flow: midt i samlingen");
        Check.That(CoverFlowGeometry.VisibleRange(1, 3) == (0, 3), "cover flow: lille samling vises helt");
        Check.That(CoverFlowGeometry.VisibleRange(-5, 10) == CoverFlowGeometry.VisibleRange(0, 10), "cover flow: negativ midte klemmes til 0");
        Check.That(CoverFlowGeometry.VisibleRange(20, 10) == CoverFlowGeometry.VisibleRange(9, 10), "cover flow: midte efter sidste plade klemmes");
        var r10 = CoverFlowGeometry.VisibleRange(10, 10);
        Check.That(9 >= r10.Start && 9 < r10.End, "cover flow: midte == antal klemmes til sidste plade");
        bool rangeOK = true;
        for (int count = 1; count <= 30; count++)
            for (int center = -3; center <= count + 3; center++)
            {
                var r = CoverFlowGeometry.VisibleRange(center, count);
                int c = Math.Min(Math.Max(center, 0), count - 1);
                if (r.End - r.Start > 2 * V + 1 || !(c >= r.Start && c < r.End) || r.Start < 0 || r.End > count) rangeOK = false;
            }
        Check.That(rangeOK, "cover flow: højst 2×visible+1 plader, altid med midten, aldrig uden for samlingen");

        // Rulning
        var st = new ScrollStepper();
        int a1 = st.Add(10, true), a2 = st.Add(10, true), a3 = st.Add(10, true);
        Check.That(a1 == 0 && a2 == 0 && a3 == 1, "rulning: små trackpad-bevægelser lægges sammen (10+10+10 → 1 trin)");
        Check.That(st.Add(26, true) == 1, "rulning: resten (2) gemmes til næste trin");
        st.Reset();
        int n1 = st.Add(-10, true), n2 = st.Add(-20, true);
        Check.That(n1 == 0 && n2 == -1, "rulning: negativ retning giver negative trin");
        st.Reset();
        Check.That(st.Add(100, true) == 3, "rulning: stor bevægelse giver flere trin på én gang");
        Check.That(st.Add(-100, true) == -3, "rulning: stor negativ bevægelse giver flere trin baglæns");
        st.Reset();
        int w1 = st.Add(1, false), w2 = st.Add(-1, false), w3 = st.Add(3, false);
        Check.That(w1 == 1 && w2 == -1 && w3 == 3, "rulning: musehjul giver ét trin pr. hak");
        st.Reset();
        st.Add(20, true);
        st.Reset();
        Check.That(st.Add(20, true) == 0, "rulning: Reset() nulstiller resten");
        st.Reset();
        int d1 = st.Add(20, true), d2 = st.Add(-20, true), d3 = st.Add(20, true);
        Check.That(d1 == 0 && d2 == 0 && d3 == 0, "rulning: retningsskift ophæver hinanden");

        // Glidende position (kommatal) og glid under trackpad
        Check.That(Math.Abs(CoverFlowGeometry.X(0.5, side) - 0.31 * side) < 0.0001 && Math.Abs(CoverFlowGeometry.Angle(0.5) + CoverFlowGeometry.Tilt / 2) < 0.0001,
                   "cover flow: halvvejs mellem to pladser står coveret halvvejs og halvt drejet");
        Check.That(CoverFlowGeometry.Angle(3.7) == -CoverFlowGeometry.Tilt, "cover flow: kommatal ud over første plads drejes fuldt");
        bool smooth = true;
        for (int k = -40; k <= 40; k++)
        {
            double o = k / 10.0;
            if (!(CoverFlowGeometry.X(o + 0.1, side) > CoverFlowGeometry.X(o, side))) smooth = false;
        }
        Check.That(smooth, "cover flow: coverne glider jævnt (x vokser hele vejen)");
        var g1 = CoverFlowGeometry.Glide(5, 0.4, 10);
        Check.That(g1.Center == 5 && Math.Abs(g1.Shift - 0.4) < 0.0001, "glid: under en halv plade bliver midten");
        var g2 = CoverFlowGeometry.Glide(5, 0.7, 10);
        Check.That(g2.Center == 6 && Math.Abs(g2.Shift + 0.3) < 0.0001, "glid: over en halv plade skifter midten uden hop");
        var g3 = CoverFlowGeometry.Glide(5, -2.6, 10);
        Check.That(g3.Center == 2 && Math.Abs(g3.Shift - 0.4) < 0.0001, "glid: flere plader baglæns");
        var g4 = CoverFlowGeometry.Glide(0, -3, 10);
        Check.That(g4.Center == 0 && Math.Abs(g4.Shift + 0.3) < 0.0001, "glid: i starten kan man kun skubbe lidt (gummibånd)");
        var g5 = CoverFlowGeometry.Glide(9, 5, 10);
        Check.That(g5.Center == 9 && Math.Abs(g5.Shift - 0.3) < 0.0001, "glid: i slutningen kan man kun skubbe lidt");
        var g6 = CoverFlowGeometry.Glide(3, 1, 0);
        Check.That(g6.Center == 0 && g6.Shift == 0, "glid: tom sektion");
    });

    // MARK: Opdeling (onboarding)

    private static void Planner() => Check.Section("opdeling", () =>
    {
        Check.That(LayoutPlanner.SectionLetter(0) == "A" && LayoutPlanner.SectionLetter(25) == "Z" && LayoutPlanner.SectionLetter(26) == "S27", "sektionsbogstaver");
        var plan = LayoutPlanner.EvenPlan(10, new[] { 2, 0, 1 });
        Check.That(plan.Select(p => $"{p.Shelf}{p.Section}:{p.Count}").SequenceEqual(new[] { "1A:3", "1B:3", "2A:2", "3A:2" }), "jævn plan; reol med 0 sektioner får én");
        LayoutPlanner.Adjust(plan, 0, 5);
        Check.That(plan[0].Count == 5 && plan[1].Count == 1 && plan.Sum(p => p.Count) == 10, "juster: grænsen til næste sektion flyttes");
        LayoutPlanner.Adjust(plan, 3, 99);
        Check.That(plan[3].Count == 4 && plan[2].Count == 0 && plan.Sum(p => p.Count) == 10, "juster sidste: grænsen til forrige flyttes, summen bevares");
        var parts = LayoutPlanner.Split(Enumerable.Range(1, 10).ToList(), plan);
        Check.That(parts.Select(p => p.Count).SequenceEqual(new[] { 5, 1, 0, 4 }) && parts.SelectMany(p => p).SequenceEqual(Enumerable.Range(1, 10)), "opdeling efter planen");
        Check.That(LayoutPlanner.EvenPlan(5, Array.Empty<int>()).Count == 0, "ingen reoler → ingen plan");
    });
}
