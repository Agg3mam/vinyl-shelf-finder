using System.Globalization;
using System.Text.Json.Nodes;

namespace VinylShelfFinder.Core;

// Port af Sources/VinylCore/Store.swift (+ ShelfStore-udvidelsen i Market.swift).
// Skema, migrationer, tabelnavne, kolonnenavne og tekster er de samme som på Mac,
// så en vinyl.sqlite kan flyttes mellem Mac og Windows.

/// Resultatet af en Discogs-sync.
public sealed class SyncReport
{
    public List<long> NewCopies { get; } = new();
    public List<long> RemovedCopies { get; } = new();
    public List<long> ReturnedCopies { get; } = new();
    public int UpdatedReleases { get; set; }
    public int Total { get; set; }
}

/// Lokal SQLite-database. Holder Discogs-data (releases) og fysiske data
/// (copies, locations, placements) adskilt, så en sync aldrig rører placeringer.
public sealed partial class ShelfStore : IDisposable
{
    public Database Db { get; }

    /// %LOCALAPPDATA%\VinylShelfFinder\vinyl.sqlite (mappen oprettes).
    public static string DefaultPath
    {
        get
        {
            var dir = System.IO.Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "VinylShelfFinder");
            try { Directory.CreateDirectory(dir); } catch (IOException) { } catch (UnauthorizedAccessException) { }
            return System.IO.Path.Combine(dir, "vinyl.sqlite");
        }
    }

    public ShelfStore(string path)
    {
        Db = new Database(path);
        try { Migrate(); KeepPlacedDigitalFiles(); }
        catch { Db.Dispose(); throw; }
    }

    /// Digitale filer står ikke på en hylde. Men en fil, der allerede har en plads (fra før appen
    /// kendte forskel), bliver stående: den får den hylde, den står på, som brugerens valg. Ellers
    /// ville pladerne efter den skifte nummer ved en opdatering. Samme regel på Mac.
    internal void KeepPlacedDigitalFiles()
    {
        var rows = Db.Query("""
            SELECT c.id, r.format, l.medium FROM copies c
            JOIN placements p ON p.copy_id = c.id
            JOIN locations l ON l.id = p.location_id
            JOIN releases r ON r.discogs_release_id = c.release_id
            WHERE c.medium_override IS NULL
            """);
        foreach (var r in rows)
        {
            if (!MediumExtensions.IsDigital(r.Text("format")) || r.Long("id") is not long id || r.Text("medium") is not string m) continue;
            Db.Run("UPDATE copies SET medium_override = ? WHERE id = ?", m, id);
        }
    }

    public void Dispose() => Db.Dispose();

    internal static double Unix(DateTimeOffset d) => d.ToUnixTimeMilliseconds() / 1000.0;
    internal static DateTimeOffset FromUnix(double s) =>
        DateTimeOffset.FromUnixTimeMilliseconds((long)Math.Round(Math.Clamp(s, -6e10, 2.5e11) * 1000));

    // MARK: Skema

    /// Hvert trin kører i én transaktion sammen med user_version, så et afbrudt trin
    /// (fx ALTER TABLE uden opdateret version) ikke efterlader en database, der ikke kan åbnes.
    private void Migrate()
    {
        if (Db.UserVersion < 1)
        {
            Db.Transaction(() =>
            {
                Db.Execute("""
                CREATE TABLE IF NOT EXISTS releases (
                    discogs_release_id INTEGER PRIMARY KEY,
                    artist TEXT NOT NULL,
                    title TEXT NOT NULL,
                    year INTEGER,
                    label TEXT,
                    catalog_number TEXT,
                    format TEXT,
                    cover_url TEXT,
                    thumb_url TEXT,
                    genres TEXT,
                    updated_at REAL
                );
                CREATE TABLE IF NOT EXISTS copies (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    discogs_instance_id INTEGER UNIQUE,
                    release_id INTEGER NOT NULL REFERENCES releases(discogs_release_id),
                    status TEXT NOT NULL DEFAULT 'home',
                    status_note TEXT,
                    in_discogs INTEGER NOT NULL DEFAULT 1,
                    removed_from_discogs_at REAL,
                    sort_artist_override TEXT,
                    sort_title_override TEXT,
                    date_added TEXT,
                    created_at REAL
                );
                CREATE TABLE IF NOT EXISTS locations (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    shelf INTEGER NOT NULL,
                    section TEXT NOT NULL,
                    sort_index INTEGER NOT NULL,
                    scan_code TEXT UNIQUE
                );
                CREATE TABLE IF NOT EXISTS placements (
                    copy_id INTEGER PRIMARY KEY REFERENCES copies(id) ON DELETE CASCADE,
                    location_id INTEGER NOT NULL REFERENCES locations(id),
                    position INTEGER NOT NULL
                );
                CREATE INDEX IF NOT EXISTS placements_by_location ON placements(location_id, position);
                CREATE TABLE IF NOT EXISTS artist_sort_overrides (
                    artist TEXT PRIMARY KEY,
                    sort_name TEXT NOT NULL
                );
                CREATE TABLE IF NOT EXISTS settings (
                    key TEXT PRIMARY KEY,
                    value TEXT
                );
                CREATE TABLE IF NOT EXISTS history (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    at REAL NOT NULL,
                    copy_id INTEGER,
                    kind TEXT NOT NULL,
                    summary TEXT NOT NULL,
                    from_location_id INTEGER,
                    from_position INTEGER,
                    to_location_id INTEGER,
                    to_position INTEGER
                );
                -- Forberedt til fremtidig QR/barcode-scanning: kode → plade, release eller sektion.
                CREATE TABLE IF NOT EXISTS scan_codes (
                    code TEXT PRIMARY KEY,
                    kind TEXT NOT NULL CHECK (kind IN ('copy','release','location')),
                    target_id INTEGER NOT NULL
                );
                """);
                Db.Execute("PRAGMA user_version = 1");
            });
        }
        if (Db.UserVersion < 2)
        {
            Db.Transaction(() =>
            {
                Db.Execute("ALTER TABLE copies ADD COLUMN discogs_rank INTEGER");
                Db.Execute("PRAGMA user_version = 2");
            });
        }
        if (Db.UserVersion < 3)
        {
            Db.Transaction(() =>
            {
                Db.Execute("""
                CREATE TABLE IF NOT EXISTS release_market (
                    release_id INTEGER PRIMARY KEY,
                    lowest_price REAL,
                    currency TEXT,
                    num_for_sale INTEGER,
                    have INTEGER,
                    want INTEGER,
                    fetched_at REAL
                );
                """);
                Db.Execute("PRAGMA user_version = 3");
            });
        }
        if (Db.UserVersion < 4)
        {
            Db.Transaction(() =>
            {
                Db.Execute("""
                CREATE TABLE IF NOT EXISTS plays (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    copy_id INTEGER NOT NULL REFERENCES copies(id) ON DELETE CASCADE,
                    played_at REAL NOT NULL
                );
                CREATE INDEX IF NOT EXISTS plays_by_copy ON plays(copy_id, played_at);
                """);
                Db.Execute("PRAGMA user_version = 4");
            });
        }
        if (Db.UserVersion < 5)
        {
            // Cd'er: egne reoler (locations.medium) og brugerens eget valg pr. kopi. Kan køres igen.
            Db.Transaction(() =>
            {
                if (!HasColumn("locations", "medium"))
                    Db.Execute("ALTER TABLE locations ADD COLUMN medium TEXT NOT NULL DEFAULT 'vinyl'");
                if (!HasColumn("copies", "medium_override"))
                    Db.Execute("ALTER TABLE copies ADD COLUMN medium_override TEXT");
                Db.Execute("PRAGMA user_version = 5");
            });
        }
        if (Db.UserVersion < 6)
        {
            // Synkronisering mellem enheder: fælles ID'er (uid) og det, der sidst blev synkroniseret.
            // Samme skema på Mac. Kan køres igen.
            Db.Transaction(() =>
            {
                foreach (var table in new[] { "copies", "locations", "plays" })
                    if (!HasColumn(table, "uid")) Db.Execute($"ALTER TABLE {table} ADD COLUMN uid TEXT");
                Db.Execute("""
                    CREATE UNIQUE INDEX IF NOT EXISTS copies_uid ON copies(uid) WHERE uid IS NOT NULL;
                    CREATE UNIQUE INDEX IF NOT EXISTS locations_uid ON locations(uid) WHERE uid IS NOT NULL;
                    CREATE UNIQUE INDEX IF NOT EXISTS plays_uid ON plays(uid) WHERE uid IS NOT NULL;
                    CREATE TABLE IF NOT EXISTS sync_state (
                        kind TEXT NOT NULL,
                        key TEXT NOT NULL,
                        data TEXT,
                        PRIMARY KEY (kind, key)
                    );
                    """);
                Db.Execute("PRAGMA user_version = 6");
            });
        }
    }

    private bool HasColumn(string table, string column) =>
        Db.Query("SELECT name FROM pragma_table_info(?)", table).Any(r => r.Text("name") == column);

    // MARK: Indlæsning

    /// Samlingen for én slags hylde: kun plader (standard) eller kun cd'er, med deres egne reoler.
    public Library LoadLibrary(Medium medium = Medium.Vinyl)
    {
        var releases = new Dictionary<int, Release>();
        foreach (var r in Db.Query("SELECT * FROM releases"))
        {
            var rel = ReleaseFrom(r);
            releases[rel.Id] = rel;
        }
        var copies = new Dictionary<long, Copy>();
        foreach (var r in Db.Query("SELECT * FROM copies"))
        {
            var c = CopyFrom(r);
            // Digitale filer kommer hverken på plade- eller cd-hylden.
            var m = MediumExtensions.ShelfOf(c.MediumOverride, releases.TryGetValue(c.ReleaseId, out var rel) ? rel.Format : null);
            if (m == medium) copies[c.Id] = c;
        }
        var locations = Db.Query("SELECT * FROM locations WHERE medium = ?", medium.RawValue()).Select(r =>
            new Location(r.Long("id")!.Value, r.Int("shelf") ?? 0, r.Text("section") ?? "", r.Int("sort_index") ?? 0, r.Text("scan_code"), medium)).ToList();
        var locationIds = locations.Select(l => l.Id).ToHashSet();
        // En kopi, der står på en reol af den anden slags (fx efter "Flyt til cd-hylden"), regnes som uplaceret.
        var placements = Db.Query("SELECT * FROM placements").Select(r =>
            (r.Long("copy_id")!.Value, r.Long("location_id")!.Value, r.Int("position") ?? 0))
            .Where(p => copies.ContainsKey(p.Item1) && locationIds.Contains(p.Item2)).ToList();
        return new Library(releases, copies, locations, placements, medium);
    }

    /// Antal kopier pr. slags hylde (til skiftet "Plader / Cd'er", når der er cd'er).
    public Dictionary<Medium, int> MediumCounts()
    {
        var counts = new Dictionary<Medium, int>();
        foreach (var r in Db.Query("SELECT c.medium_override, r.format FROM copies c JOIN releases r ON r.discogs_release_id = c.release_id"))
        {
            if (MediumExtensions.ShelfOf(MediumExtensions.FromRaw(r.Text("medium_override")), r.Text("format")) is Medium m)
                counts[m] = counts.GetValueOrDefault(m) + 1;
        }
        return counts;
    }

    private static Release ReleaseFrom(SqlRow r) => new(
        (int)r.Long("discogs_release_id")!.Value, r.Text("artist") ?? "", r.Text("title") ?? "",
        r.Int("year"), r.Text("label"), r.Text("catalog_number"), r.Text("format"),
        r.Text("cover_url"), r.Text("thumb_url"), r.Text("genres"));

    private static Copy CopyFrom(SqlRow r) => new(
        r.Long("id")!.Value,
        r.Long("discogs_instance_id"),
        r.Int("release_id") ?? 0,
        CopyStatusExtensions.FromRaw(r.Text("status") ?? "home") ?? CopyStatus.Home,
        r.Text("status_note"),
        (r.Long("in_discogs") ?? 1) != 0,
        r.Double("removed_from_discogs_at") is double d ? FromUnix(d) : null,
        r.Text("sort_artist_override"),
        r.Text("sort_title_override"),
        r.Text("date_added"),
        r.Int("discogs_rank"),
        MediumExtensions.FromRaw(r.Text("medium_override")));

    // MARK: Indstillinger

    public string? Setting(string key)
    {
        try { return Db.Query("SELECT value FROM settings WHERE key = ?", key).FirstOrDefault()?.Text("value"); }
        catch (DatabaseException) { return null; }
    }

    public void SetSetting(string key, string? value)
    {
        try
        {
            if (value is not null)
                Db.Run("INSERT INTO settings(key, value) VALUES(?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value", key, value);
            else
                Db.Run("DELETE FROM settings WHERE key = ?", key);
        }
        catch (DatabaseException) { }
    }

    public SortRules LoadSortRules()
    {
        var rules = Setting("sort_rules") is string json ? SortRules.FromJson(json) ?? new SortRules() : new SortRules();
        rules.ArtistOverrides = new();
        try
        {
            foreach (var r in Db.Query("SELECT artist, sort_name FROM artist_sort_overrides"))
                if (r.Text("artist") is string a && r.Text("sort_name") is string s) rules.ArtistOverrides[a] = s;
        }
        catch (DatabaseException) { }
        return rules;
    }

    public void SaveSortRules(SortRules rules)
    {
        SetSetting("sort_rules", rules.ToJson());
        Db.Transaction(() =>
        {
            Db.Run("DELETE FROM artist_sort_overrides");
            foreach (var (a, s) in rules.ArtistOverrides)
                if (TextFold.TrimSpaces(s).Length > 0)
                    Db.Run("INSERT INTO artist_sort_overrides(artist, sort_name) VALUES(?, ?)", a, s);
        });
    }

    // MARK: Historik

    public void Log(HistoryKind kind, long? copyId, string summary, (long LocationId, int Position)? from = null, (long LocationId, int Position)? to = null)
    {
        Db.Run("""
            INSERT INTO history(at, copy_id, kind, summary, from_location_id, from_position, to_location_id, to_position)
            VALUES(?, ?, ?, ?, ?, ?, ?, ?)
            """, Unix(DateTimeOffset.Now), copyId, kind.RawValue(), summary,
            from?.LocationId, from?.Position, to?.LocationId, to?.Position);
    }

    public List<HistoryEntry> History(int limit = 500) =>
        Db.Query("SELECT * FROM history ORDER BY id DESC LIMIT ?", limit).Select(r => new HistoryEntry(
            r.Long("id")!.Value, FromUnix(r.Double("at") ?? 0), r.Long("copy_id"),
            HistoryKindExtensions.FromRaw(r.Text("kind") ?? "") ?? HistoryKind.Moved,
            r.Text("summary") ?? "",
            r.Long("from_location_id"), r.Int("from_position"),
            r.Long("to_location_id"), r.Int("to_position"))).ToList();

    // MARK: Fysisk struktur

    private List<long> SectionIds(long locationId) =>
        Db.Query("SELECT copy_id FROM placements WHERE location_id = ? ORDER BY position", locationId).Select(r => r.Long("copy_id")!.Value).ToList();

    private void WriteSection(long locationId, IReadOnlyList<long> ids)
    {
        for (int i = 0; i < ids.Count; i++)
            Db.Run("INSERT INTO placements(copy_id, location_id, position) VALUES(?, ?, ?) ON CONFLICT(copy_id) DO UPDATE SET location_id = excluded.location_id, position = excluded.position", ids[i], locationId, i + 1);
    }

    private (long LocationId, int Position)? CurrentPlacement(long copyId)
    {
        var r = Db.Query("SELECT location_id, position FROM placements WHERE copy_id = ?", copyId).FirstOrDefault();
        return r is null ? null : (r.Long("location_id")!.Value, r.Int("position") ?? 0);
    }

    private string LocationName(long? id)
    {
        if (id is null) return "ukendt sektion";
        SqlRow? r;
        try { r = Db.Query("SELECT shelf, section, medium FROM locations WHERE id = ?", id).FirstOrDefault(); }
        catch (DatabaseException) { r = null; }
        if (r is null) return "ukendt sektion";
        var medium = MediumExtensions.FromRaw(r.Text("medium")) ?? Medium.Vinyl;
        return $"{medium.ShelfWord()} {r.Long("shelf") ?? 0} · Sektion {r.Text("section") ?? ""}";
    }

    /// Placering til historikken: "Reol 1 · Sektion A, plads 16".
    private string PlaceText(long locationId, int position) => $"{LocationName(locationId)}, plads {position}";

    private string RecordName(long copyId)
    {
        SqlRow? r;
        try { r = Db.Query("SELECT r.artist, r.title FROM copies c JOIN releases r ON r.discogs_release_id = c.release_id WHERE c.id = ?", copyId).FirstOrDefault(); }
        catch (DatabaseException) { r = null; }
        return $"{r?.Text("artist") ?? "?"} – {r?.Text("title") ?? "?"}";
    }

    /// Flytter (eller placerer) en kopi til `index` (0-baseret) i en sektion.
    /// Alle positioner i berørte sektioner omnummereres – naboer opdateres dermed automatisk.
    public void Move(long copyId, long locationId, int index, HistoryKind kind = HistoryKind.Moved)
    {
        Db.Transaction(() =>
        {
            var from = CurrentPlacement(copyId);
            if (from is { } f)
            {
                var old = SectionIds(f.LocationId);
                old.RemoveAll(x => x == copyId);
                Db.Run("DELETE FROM placements WHERE copy_id = ?", copyId);
                WriteSection(f.LocationId, old);
            }
            var target = SectionIds(locationId);
            target.RemoveAll(x => x == copyId);
            int i = Math.Max(0, Math.Min(index, target.Count));
            target.Insert(i, copyId);
            WriteSection(locationId, target);

            var toText = PlaceText(locationId, i + 1);
            var summary = from is { } ff
                ? $"{RecordName(copyId)} flyttet fra {PlaceText(ff.LocationId, ff.Position)} til {toText}"
                : $"{RecordName(copyId)} placeret på {toText}";
            Log(from is null ? HistoryKind.Placed : kind, copyId, summary, from, (locationId, i + 1));
        });
    }

    /// Fjerner fysisk placering (kræver brugerens bekræftelse i UI).
    public void Unplace(long copyId)
    {
        Db.Transaction(() =>
        {
            if (CurrentPlacement(copyId) is not { } from) return;
            var ids = SectionIds(from.LocationId);
            ids.RemoveAll(x => x == copyId);
            Db.Run("DELETE FROM placements WHERE copy_id = ?", copyId);
            WriteSection(from.LocationId, ids);
            Log(HistoryKind.Unplaced, copyId, $"{RecordName(copyId)} fjernet fra {PlaceText(from.LocationId, from.Position)}", from);
        });
    }

    /// Sletter en kopi helt (kun for plader fjernet fra Discogs, efter bekræftelse).
    public void DeleteCopy(long copyId)
    {
        Db.Transaction(() =>
        {
            var name = RecordName(copyId);
            var from = CurrentPlacement(copyId);
            if (from is { } f)
            {
                var ids = SectionIds(f.LocationId);
                ids.RemoveAll(x => x == copyId);
                Db.Run("DELETE FROM placements WHERE copy_id = ?", copyId);
                WriteSection(f.LocationId, ids);
            }
            Db.Run("DELETE FROM copies WHERE id = ?", copyId);
            Db.Run("DELETE FROM releases WHERE discogs_release_id NOT IN (SELECT release_id FROM copies)");
            Log(HistoryKind.Deleted, copyId, $"{name} slettet fra appen", from);
        });
    }

    public void SetStatus(long copyId, CopyStatus status, string? note)
    {
        var n = note is null ? null : TextFold.TrimSpaces(note);
        Db.Run("UPDATE copies SET status = ?, status_note = ? WHERE id = ?", status.RawValue(), string.IsNullOrEmpty(n) ? null : n, copyId);
        // Ord, ikke emoji – historikken skal kunne læses som almindelig tekst.
        var summary = $"{RecordName(copyId)}: status ændret til “{status.Label()}”";
        if (!string.IsNullOrEmpty(n)) summary += $" ({n})";
        Log(HistoryKind.StatusChanged, copyId, summary);
    }

    public void SetSortOverrides(long copyId, string? artist, string? title)
    {
        static string? Clean(string? s) => s is not null && TextFold.TrimSpaces(s) is { Length: > 0 } t ? t : null;
        Db.Run("UPDATE copies SET sort_artist_override = ?, sort_title_override = ? WHERE id = ?", Clean(artist), Clean(title), copyId);
    }

    /// Opretter reol-strukturen fra onboarding. `layout` er sektioner i rækkefølge med
    /// kopier i fysisk rækkefølge. Erstatter eksisterende struktur for samme slags hylde
    /// (kun efter bekræftelse): pladernes reoler røres ikke, når cd-reolerne oprettes, og omvendt.
    public void CreateLayout(IReadOnlyList<(int Shelf, string Section, IReadOnlyList<long> Copies)> layout, Medium medium = Medium.Vinyl)
    {
        Db.Transaction(() =>
        {
            Db.Run("DELETE FROM placements WHERE location_id IN (SELECT id FROM locations WHERE medium = ?)", medium.RawValue());
            Db.Run("DELETE FROM locations WHERE medium = ?", medium.RawValue());
            long offset = Db.Query("SELECT COALESCE(MAX(sort_index) + 1, 0) AS n FROM locations").FirstOrDefault()?.Long("n") ?? 0;
            for (int i = 0; i < layout.Count; i++)
            {
                var s = layout[i];
                var locId = Db.Run("INSERT INTO locations(shelf, section, sort_index, medium) VALUES(?, ?, ?, ?)", s.Shelf, s.Section, offset + i, medium.RawValue());
                WriteSection(locId, s.Copies);
            }
            int total = layout.Sum(s => s.Copies.Count);
            var what = medium == Medium.Vinyl ? "Reolerne" : "Cd-reolerne";
            Log(HistoryKind.LayoutCreated, null,
                $"{what} er oprettet: {(layout.Count == 1 ? "1 sektion" : $"{layout.Count} sektioner")}, {(total == 1 ? $"1 {medium.Singular()}" : $"{total} {medium.Plural()}")}");
        });
    }

    /// "Flyt til cd-hylden" / "Flyt til pladehylden" (null: følg Discogs' format). Står kopien på en
    /// reol af den gamle slags, fjernes den derfra og venter som ny på den anden hylde.
    public void SetMedium(long copyId, Medium? medium)
    {
        // Unplace kører sin egen transaktion (og skriver i historikken), derfor ingen ydre transaktion her.
        if (CurrentPlacement(copyId) is { } p
            && Db.Query("SELECT medium FROM locations WHERE id = ?", p.LocationId).FirstOrDefault() is { } loc)
        {
            var fmt = Db.Query("SELECT r.format FROM copies c JOIN releases r ON r.discogs_release_id = c.release_id WHERE c.id = ?", copyId)
                .FirstOrDefault()?.Text("format");
            // null = ingen hylde (en digital fil tilbage til "Følg Discogs"): pladsen fjernes også.
            var now = MediumExtensions.ShelfOf(medium, fmt);
            if (now is null || loc.Text("medium") != now.Value.RawValue()) Unplace(copyId);
        }
        Db.Run("UPDATE copies SET medium_override = ? WHERE id = ?", medium?.RawValue(), copyId);
    }

    /// Tilføjer en ny tom sektion sidst i en reol (eller i en ny reol).
    public long AddSection(int shelf, string section, Medium medium = Medium.Vinyl) => Db.Transaction(() =>
    {
        var existing = Db.Query("SELECT id, shelf, sort_index FROM locations WHERE medium = ? ORDER BY sort_index", medium.RawValue());
        // Indsæt efter den sidste sektion i samme (eller lavere) reol.
        var insertAfter = existing.LastOrDefault(r => (r.Long("shelf") ?? 0) <= shelf);
        long newIndex = insertAfter is null ? 0 : (insertAfter.Long("sort_index") ?? 0) + 1;
        Db.Run("UPDATE locations SET sort_index = sort_index + 1 WHERE sort_index >= ?", newIndex);
        return Db.Run("INSERT INTO locations(shelf, section, sort_index, medium) VALUES(?, ?, ?, ?)", shelf, section, newIndex, medium.RawValue());
    });

    public void DeleteEmptySection(long locationId)
    {
        if (SectionIds(locationId).Count > 0)
            throw new DatabaseException("Sektionen er ikke tom. Flyt pladerne ud af den først.", userFacing: true);
        Db.Run("DELETE FROM locations WHERE id = ?", locationId);
    }

    // MARK: Discogs-sync

    /// Anvender en fuld Discogs Collection. Rører ALDRIG placements eller locations:
    /// - kendt instance → behold kopi og placering, opdatér metadata
    /// - ny instance → ny, uplaceret kopi
    /// - forsvundet instance → markeres "ikke længere i Discogs" (slettes ikke)
    public SyncReport ApplyCollection(IEnumerable<DiscogsCollectionItem> collection)
    {
        // Discogs kan levere samme instance to gange (fx hvis samlingen ændres, mens siderne
        // hentes). Den første forekomst vinder; ellers fejler hele syncen på UNIQUE(discogs_instance_id).
        var firstSeen = new HashSet<long>();
        var items = collection.Where(i => firstSeen.Add(i.InstanceId)).ToList();
        var report = new SyncReport { Total = items.Count };
        Db.Transaction(() =>
        {
            var now = Unix(DateTimeOffset.Now);
            var existingReleases = new Dictionary<int, Release>();
            foreach (var r in Db.Query("SELECT * FROM releases")) { var rel = ReleaseFrom(r); existingReleases[rel.Id] = rel; }

            foreach (var it in items)
            {
                var r = it.Release;
                if (existingReleases.TryGetValue(r.Id, out var old))
                {
                    if (old != r)
                    {
                        Db.Run("""
                            UPDATE releases SET artist=?, title=?, year=?, label=?, catalog_number=?, format=?,
                                cover_url=?, thumb_url=?, genres=?, updated_at=? WHERE discogs_release_id=?
                            """, r.Artist, r.Title, r.Year, r.Label, r.CatalogNumber, r.Format,
                            r.CoverUrl, r.ThumbUrl, r.Genres, now, r.Id);
                        report.UpdatedReleases++;
                        existingReleases[r.Id] = r;
                    }
                }
                else
                {
                    Db.Run("""
                        INSERT INTO releases(discogs_release_id, artist, title, year, label, catalog_number, format,
                            cover_url, thumb_url, genres, updated_at) VALUES(?,?,?,?,?,?,?,?,?,?,?)
                        """, r.Id, r.Artist, r.Title, r.Year, r.Label, r.CatalogNumber, r.Format,
                        r.CoverUrl, r.ThumbUrl, r.Genres, now);
                    // Husk de indsatte værdier, så flere kopier af samme nye release
                    // ikke tælles som "opdateret metadata".
                    existingReleases[r.Id] = r;
                }
            }

            var copyByInstance = new Dictionary<long, SqlRow>();
            foreach (var c in Db.Query("SELECT id, discogs_instance_id, in_discogs, release_id FROM copies WHERE discogs_instance_id IS NOT NULL"))
                copyByInstance[c.Long("discogs_instance_id")!.Value] = c;

            // Discogs' egen rækkefølge gemmes, så "Præcis som Discogs" kan bruge den.
            Db.Run("UPDATE copies SET discogs_rank = NULL");
            var seen = new HashSet<long>();
            for (int rank = 0; rank < items.Count; rank++)
            {
                var it = items[rank];
                seen.Add(it.InstanceId);
                if (copyByInstance.TryGetValue(it.InstanceId, out var c))
                {
                    var id = c.Long("id")!.Value;
                    Db.Run("UPDATE copies SET discogs_rank = ? WHERE id = ?", rank, id);
                    if (c.Int("release_id") != it.Release.Id)
                        Db.Run("UPDATE copies SET release_id = ? WHERE id = ?", it.Release.Id, id);
                    if (c.Long("in_discogs") == 0)
                    {
                        Db.Run("UPDATE copies SET in_discogs = 1, removed_from_discogs_at = NULL WHERE id = ?", id);
                        report.ReturnedCopies.Add(id);
                    }
                }
                else
                {
                    var id = Db.Run("""
                        INSERT INTO copies(discogs_instance_id, release_id, status, in_discogs, date_added, created_at, discogs_rank)
                        VALUES(?, ?, 'home', 1, ?, ?, ?)
                        """, it.InstanceId, it.Release.Id, it.DateAdded, now, rank);
                    // Digitale filer gemmes (så de ikke ser "fjernet" ud), men meldes ikke som nye plader.
                    if (!MediumExtensions.IsDigital(it.Release.Format)) report.NewCopies.Add(id);
                    Log(HistoryKind.AddedFromDiscogs, id, $"Ny i Discogs: {it.Release.Artist} – {it.Release.Title}");
                }
            }

            foreach (var (instance, c) in copyByInstance)
            {
                if (seen.Contains(instance) || c.Long("in_discogs") == 0) continue;
                var id = c.Long("id")!.Value;
                Db.Run("UPDATE copies SET in_discogs = 0, removed_from_discogs_at = ? WHERE id = ?", now, id);
                var releaseId = (int)(c.Long("release_id") ?? 0);
                if (!MediumExtensions.IsDigital(existingReleases.TryGetValue(releaseId, out var rel) ? rel.Format : null))
                    report.RemovedCopies.Add(id);
                Log(HistoryKind.RemovedFromDiscogs, id, $"{RecordName(id)} er ikke længere i din Discogs-samling. Pladsen i reolen er bevaret.");
            }
            if (report.UpdatedReleases > 0)
            {
                int n = report.UpdatedReleases;
                Log(HistoryKind.MetadataUpdated, null, $"Oplysninger fra Discogs opdateret for {(n == 1 ? "1 plade" : $"{n} plader")}");
            }
        });
        SetSetting("last_sync", Unix(DateTimeOffset.Now).ToString("R", CultureInfo.InvariantCulture));
        return report;
    }

    /// Brugeren har bekræftet at en plade fjernet fra Discogs stadig står i reolen.
    public void KeepLocalOnly(long copyId) =>
        Db.Run("UPDATE copies SET removed_from_discogs_at = NULL WHERE id = ?", copyId);

    // MARK: Markedsdata (fra Market.swift)

    public void SaveMarket(int releaseId, MarketInfo m)
    {
        Db.Run("""
            INSERT INTO release_market(release_id, lowest_price, currency, num_for_sale, have, want, fetched_at)
            VALUES(?,?,?,?,?,?,?)
            ON CONFLICT(release_id) DO UPDATE SET lowest_price=excluded.lowest_price, currency=excluded.currency,
                num_for_sale=excluded.num_for_sale, have=excluded.have, want=excluded.want, fetched_at=excluded.fetched_at
            """, releaseId, m.LowestPrice, m.Currency, m.NumForSale, m.Have, m.Want, Unix(m.FetchedAt));
    }

    /// Sletter alle gemte markedspriser (bruges én gang efter valutarettelsen).
    public void ClearMarket() => Db.Run("DELETE FROM release_market");

    public Dictionary<int, MarketInfo> LoadMarket()
    {
        var output = new Dictionary<int, MarketInfo>();
        foreach (var r in Db.Query("SELECT * FROM release_market"))
        {
            output[(int)r.Long("release_id")!.Value] = new MarketInfo(
                r.Double("lowest_price"), r.Text("currency") ?? "EUR",
                r.Int("num_for_sale"), r.Int("have"), r.Int("want"),
                FromUnix(r.Double("fetched_at") ?? 0));
        }
        return output;
    }

    /// Swifts JSONEncoder gemmer en dato som sekunder siden 1. jan. 2001 (UTC).
    private static readonly DateTimeOffset SwiftReferenceDate = new(2001, 1, 1, 0, 0, 0, TimeSpan.Zero);

    /// Gemmes som JSON i settings["collection_value"], i samme format som på Mac.
    public void SaveCollectionValue(CollectionValue v)
    {
        var o = new JsonObject
        {
            ["minimum"] = v.Minimum,
            ["median"] = v.Median,
            ["maximum"] = v.Maximum,
            ["fetchedAt"] = (v.FetchedAt - SwiftReferenceDate).TotalSeconds,
        };
        SetSetting("collection_value", o.ToJsonString());
    }

    public CollectionValue? LoadCollectionValue() =>
        Setting("collection_value") is string s ? CollectionValueFromJson(s) : null;

    internal static CollectionValue? CollectionValueFromJson(string json)
    {
        try
        {
            if (JsonNode.Parse(json) is not JsonObject o) return null;
            var min = o["minimum"]?.GetValue<string>();
            var med = o["median"]?.GetValue<string>();
            var max = o["maximum"]?.GetValue<string>();
            var at = o["fetchedAt"]?.GetValue<double>();
            if (min is null || med is null || max is null || at is null) return null;
            return new CollectionValue(min, med, max, SwiftReferenceDate.AddMilliseconds(Math.Round(at.Value * 1000)));
        }
        catch (Exception e) when (e is System.Text.Json.JsonException or InvalidOperationException or FormatException) { return null; }
    }
}
