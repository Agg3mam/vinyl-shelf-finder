using System.Globalization;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace VinylShelfFinder.Core;

// Port af Sources/VinylCore/SyncDocs.swift: synkronisering mellem enheder via en konto i skyen
// (se supabase/schema.sql). Felterne i Data skal være ens på alle platforme.
//
// Appen sammenligner ved hver synkronisering sine data med det, der sidst blev synkroniseret
// (tabellen sync_state). Kun det ændrede sendes op. Poster fra skyen lægges ind i den lokale
// database. Ved samtidig ændring af samme post vinder den, der allerede ligger i skyen.

public enum SyncKind { Release, Copy, Location, Section, Play, Setting }

public static class SyncKindExtensions
{
    public static string RawValue(this SyncKind k) => k switch
    {
        SyncKind.Release => "release",
        SyncKind.Copy => "copy",
        SyncKind.Location => "location",
        SyncKind.Section => "section",
        SyncKind.Play => "play",
        _ => "setting",
    };

    public static SyncKind? FromRaw(string? s) => s switch
    {
        "release" => SyncKind.Release,
        "copy" => SyncKind.Copy,
        "location" => SyncKind.Location,
        "section" => SyncKind.Section,
        "play" => SyncKind.Play,
        "setting" => SyncKind.Setting,
        _ => null,
    };
}

/// Én post: én ting fra den lokale database. Data == null betyder slettet.
public sealed record SyncDoc(SyncKind Kind, string Key, JsonObject? Data)
{
    public string Id => $"{Kind.RawValue()}|{Key}";

    /// Fast JSON-tekst (sorterede nøgler), så to ens poster altid giver samme tekst.
    public string? Canonical => Data is null ? null : Sorted(Data).ToJsonString();

    private static JsonNode? Sorted(JsonNode? n) => n switch
    {
        JsonObject o => new JsonObject(o.OrderBy(kv => kv.Key, StringComparer.Ordinal)
                                        .Select(kv => KeyValuePair.Create(kv.Key, Sorted(kv.Value)))),
        JsonArray a => new JsonArray(a.Select(Sorted).ToArray()),
        null => null,
        _ => JsonNode.Parse(n.ToJsonString()),
    };

    internal static JsonNode? From(object? v) => v switch
    {
        null => null,
        long l => JsonValue.Create(l),
        int i => JsonValue.Create((long)i),
        double d => JsonValue.Create(d),
        string s => JsonValue.Create(s),
        bool b => JsonValue.Create(b),
        _ => JsonValue.Create(Convert.ToString(v, CultureInfo.InvariantCulture)),
    };
}

public sealed partial class ShelfStore
{
    /// Indstillinger, der følger kontoen. Valg, der hører til den enkelte enhed (fx viste hylde og valuta), synkroniseres ikke.
    internal static readonly string[] SyncedSettings = { "sort_rules", "neighbor_count", "surname_not_persons" };

    // MARK: Fælles ID'er

    /// Giver alle kopier, reoler og afspilninger et fælles ID. Plader fra Discogs bruger Discogs' kopinummer.
    public void EnsureSyncIds() => Db.Transaction(() =>
    {
        Db.Run("UPDATE copies SET uid = 'i' || discogs_instance_id WHERE uid IS NULL AND discogs_instance_id IS NOT NULL");
        foreach (var table in new[] { "copies", "locations", "plays" })
            foreach (var r in Db.Query($"SELECT id FROM {table} WHERE uid IS NULL"))
                Db.Run($"UPDATE {table} SET uid = ? WHERE id = ?", Guid.NewGuid().ToString().ToLowerInvariant(), r.Long("id"));
    });

    // MARK: Lokale data som poster

    /// Hele det lokale system som poster.
    public List<SyncDoc> ExportSyncDocs()
    {
        EnsureSyncIds();
        var docs = new List<SyncDoc>();
        static JsonNode? V(SqlRow r, string c) => SyncDoc.From(r[c]);

        foreach (var r in Db.Query("SELECT * FROM releases"))
            docs.Add(new SyncDoc(SyncKind.Release, r.Long("discogs_release_id")!.Value.ToString(CultureInfo.InvariantCulture), new JsonObject
            {
                ["artist"] = V(r, "artist"), ["title"] = V(r, "title"), ["year"] = V(r, "year"),
                ["label"] = V(r, "label"), ["catalog"] = V(r, "catalog_number"), ["format"] = V(r, "format"),
                ["cover"] = V(r, "cover_url"), ["thumb"] = V(r, "thumb_url"), ["genres"] = V(r, "genres"),
            }));

        var uidOfCopy = new Dictionary<long, string>();
        foreach (var r in Db.Query("SELECT * FROM copies"))
        {
            var uid = r.Text("uid")!;
            uidOfCopy[r.Long("id")!.Value] = uid;
            docs.Add(new SyncDoc(SyncKind.Copy, uid, new JsonObject
            {
                ["instance"] = V(r, "discogs_instance_id"), ["release"] = V(r, "release_id"),
                ["status"] = V(r, "status"), ["note"] = V(r, "status_note"),
                ["inDiscogs"] = JsonValue.Create((r.Long("in_discogs") ?? 1) != 0), ["removedAt"] = V(r, "removed_from_discogs_at"),
                ["sortArtist"] = V(r, "sort_artist_override"), ["sortTitle"] = V(r, "sort_title_override"),
                ["dateAdded"] = V(r, "date_added"), ["rank"] = V(r, "discogs_rank"), ["medium"] = V(r, "medium_override"),
            }));
        }

        var uidOfLocation = new Dictionary<long, string>();
        foreach (var r in Db.Query("SELECT * FROM locations"))
        {
            var uid = r.Text("uid")!;
            uidOfLocation[r.Long("id")!.Value] = uid;
            docs.Add(new SyncDoc(SyncKind.Location, uid, new JsonObject
            {
                ["shelf"] = V(r, "shelf"), ["section"] = V(r, "section"), ["sortIndex"] = V(r, "sort_index"), ["medium"] = V(r, "medium"),
                ["code"] = V(r, "scan_code"),
            }));
        }

        var sections = new Dictionary<long, List<string>>();
        foreach (var r in Db.Query("SELECT copy_id, location_id FROM placements ORDER BY location_id, position"))
        {
            if (!uidOfCopy.TryGetValue(r.Long("copy_id")!.Value, out var c)) continue;
            var loc = r.Long("location_id")!.Value;
            if (!sections.TryGetValue(loc, out var list)) sections[loc] = list = new();
            list.Add(c);
        }
        foreach (var (locId, uid) in uidOfLocation)
        {
            var arr = new JsonArray((sections.TryGetValue(locId, out var l) ? l : new()).Select(c => (JsonNode?)JsonValue.Create(c)).ToArray());
            docs.Add(new SyncDoc(SyncKind.Section, uid, new JsonObject { ["copies"] = arr }));
        }

        foreach (var r in Db.Query("SELECT uid, copy_id, played_at FROM plays"))
        {
            if (!uidOfCopy.TryGetValue(r.Long("copy_id")!.Value, out var c)) continue;
            docs.Add(new SyncDoc(SyncKind.Play, r.Text("uid")!, new JsonObject { ["copy"] = c, ["at"] = V(r, "played_at") }));
        }

        foreach (var key in SyncedSettings)
            if (Setting(key) is string v) docs.Add(new SyncDoc(SyncKind.Setting, key, new JsonObject { ["value"] = v }));
        var overrides = new JsonObject();
        foreach (var r in Db.Query("SELECT artist, sort_name FROM artist_sort_overrides"))
            if (r.Text("artist") is string a && r.Text("sort_name") is string n) overrides[a] = n;
        docs.Add(new SyncDoc(SyncKind.Setting, "artist_overrides", new JsonObject { ["value"] = overrides }));
        foreach (var m in MediumExtensions.All)
        {
            var uids = SortChecked(m).Where(uidOfCopy.ContainsKey).Select(id => uidOfCopy[id]).OrderBy(x => x, StringComparer.Ordinal);
            docs.Add(new SyncDoc(SyncKind.Setting, $"sort_checked_{m.RawValue()}",
                new JsonObject { ["value"] = new JsonArray(uids.Select(u => (JsonNode?)JsonValue.Create(u)).ToArray()) }));
        }
        return docs;
    }

    // MARK: Hvad er ændret siden sidst

    private Dictionary<string, string?> SyncState() =>
        Db.Query("SELECT kind, key, data FROM sync_state").ToDictionary(r => $"{r.Text("kind")}|{r.Text("key")}", r => r.Text("data"));

    /// Poster, der er ændret, nye eller slettet siden sidste synkronisering.
    public List<SyncDoc> PendingSyncDocs()
    {
        var current = ExportSyncDocs();
        var state = SyncState();
        var pending = new List<SyncDoc>();
        var seen = new HashSet<string>();
        foreach (var d in current)
        {
            seen.Add(d.Id);
            if ((state.TryGetValue(d.Id, out var s) ? s : null) != d.Canonical) pending.Add(d);
        }
        foreach (var (id, data) in state)
        {
            if (data is null || seen.Contains(id)) continue;
            var parts = id.Split('|', 2);
            if (SyncKindExtensions.FromRaw(parts[0]) is SyncKind k) pending.Add(new SyncDoc(k, parts[1], null));
        }
        return pending;
    }

    /// Husker, at posterne nu er ens lokalt og i skyen.
    public void MarkSynced(IEnumerable<SyncDoc> docs) => Db.Transaction(() =>
    {
        foreach (var d in docs)
            Db.Run("INSERT INTO sync_state(kind, key, data) VALUES(?, ?, ?) ON CONFLICT(kind, key) DO UPDATE SET data = excluded.data",
                   d.Kind.RawValue(), d.Key, d.Canonical);
    });

    // MARK: Poster fra skyen ind i den lokale database

    /// Lægger poster fra skyen ind. Rækkefølgen sikrer, at pladen findes, før den placeres.
    /// Poster, der ikke kunne lægges ind (fx en afspilning af en ukendt plade), huskes ikke som synkroniseret,
    /// så næste synkronisering ikke sender en sletning af dem op. Returnerer antallet af ændrede poster.
    public int ApplySyncDocs(IReadOnlyList<SyncDoc> remote)
    {
        EnsureSyncIds();
        var state = SyncState();
        // Egne ændringer, der kommer tilbage fra skyen, springes over.
        var fresh = remote.Where(d => (state.TryGetValue(d.Id, out var s) ? s : null) != d.Canonical).ToList();
        var order = new[] { SyncKind.Release, SyncKind.Copy, SyncKind.Location, SyncKind.Section, SyncKind.Play, SyncKind.Setting };
        var skipped = new HashSet<string>();
        Db.Transaction(() =>
        {
            foreach (var kind in order)
                foreach (var d in fresh.Where(d => d.Kind == kind))
                    if (!Apply(d)) skipped.Add(d.Id);
            // Slettede reoler fjernes til sidst, når deres plader er flyttet.
            foreach (var d in fresh.Where(d => d.Kind == SyncKind.Location && d.Data is null))
                if (LocalId("locations", d.Key) is long id)
                {
                    Db.Run("DELETE FROM placements WHERE location_id = ?", id);
                    Db.Run("DELETE FROM locations WHERE id = ?", id);
                }
        });
        MarkSynced(remote.Where(d => !skipped.Contains(d.Id)));
        return fresh.Count;
    }

    private long? LocalId(string table, string uid) => Db.Query($"SELECT id FROM {table} WHERE uid = ?", uid).FirstOrDefault()?.Long("id");

    private long? CopyIdOf(string uid)
    {
        if (LocalId("copies", uid) is long id) return id;
        // En kopi fra Discogs, som denne enhed kender, men endnu uden fælles ID.
        if (uid.StartsWith('i') && long.TryParse(uid[1..], NumberStyles.Integer, CultureInfo.InvariantCulture, out var inst))
            return Db.Query("SELECT id FROM copies WHERE discogs_instance_id = ?", inst).FirstOrDefault()?.Long("id");
        return null;
    }

    private static string? Text(JsonObject v, string k) => v[k] is JsonValue j && j.TryGetValue<string>(out var s) ? s : null;
    private static long? Long(JsonObject v, string k) =>
        v[k] is JsonValue j ? (j.TryGetValue<long>(out var l) ? l : j.TryGetValue<double>(out var d) && d == Math.Round(d) ? (long)d : null) : null;
    private static double? Dbl(JsonObject v, string k) =>
        v[k] is JsonValue j ? (j.TryGetValue<double>(out var d) ? d : j.TryGetValue<long>(out var l) ? l : null) : null;
    private static bool? Bool(JsonObject v, string k) => v[k] is JsonValue j && j.TryGetValue<bool>(out var b) ? b : null;
    private static IEnumerable<string> Strings(JsonNode? n) =>
        n is JsonArray a ? a.Select(x => x is JsonValue j && j.TryGetValue<string>(out var s) ? s : null).OfType<string>() : Enumerable.Empty<string>();

    /// Har denne enhed reolen med det fælles ID?
    public bool HasLocation(string uid) => LocalId("locations", uid) is not null;

    /// false: posten kunne ikke lægges ind (den mangler noget, den bygger på).
    private bool Apply(SyncDoc d)
    {
        var v = d.Data ?? new JsonObject();
        switch (d.Kind)
        {
            case SyncKind.Release:
                if (d.Data is null) return true;
                if (!long.TryParse(d.Key, NumberStyles.Integer, CultureInfo.InvariantCulture, out var rid)) return false;
                Db.Run("""
                    INSERT INTO releases(discogs_release_id, artist, title, year, label, catalog_number, format, cover_url, thumb_url, genres, updated_at)
                    VALUES(?,?,?,?,?,?,?,?,?,?,?)
                    ON CONFLICT(discogs_release_id) DO UPDATE SET artist = excluded.artist, title = excluded.title, year = excluded.year,
                        label = excluded.label, catalog_number = excluded.catalog_number, format = excluded.format,
                        cover_url = excluded.cover_url, thumb_url = excluded.thumb_url, genres = excluded.genres
                    """, rid, Text(v, "artist") ?? "", Text(v, "title") ?? "", Long(v, "year"), Text(v, "label"), Text(v, "catalog"),
                    Text(v, "format"), Text(v, "cover"), Text(v, "thumb"), Text(v, "genres"), Unix(DateTimeOffset.Now));
                break;

            case SyncKind.Copy:
            {
                var existing = CopyIdOf(d.Key);
                if (d.Data is null)
                {
                    // Slettet på en anden enhed (der er allerede en transaktion, så ikke DeleteCopy).
                    if (existing is long e)
                    {
                        Db.Run("DELETE FROM placements WHERE copy_id = ?", e);
                        Db.Run("DELETE FROM plays WHERE copy_id = ?", e);
                        Db.Run("DELETE FROM copies WHERE id = ?", e);
                    }
                    return true;
                }
                if (Long(v, "release") is not long release || !Db.Query("SELECT 1 FROM releases WHERE discogs_release_id = ?", release).Any()) return false;
                object?[] fields =
                {
                    Long(v, "instance"), release, Text(v, "status") ?? "home", Text(v, "note"),
                    (Bool(v, "inDiscogs") ?? true) ? 1L : 0L, Dbl(v, "removedAt"),
                    Text(v, "sortArtist"), Text(v, "sortTitle"), Text(v, "dateAdded"), Long(v, "rank"), Text(v, "medium"),
                };
                if (existing is long id)
                    Db.Run("""
                        UPDATE copies SET discogs_instance_id = ?, release_id = ?, status = ?, status_note = ?, in_discogs = ?,
                            removed_from_discogs_at = ?, sort_artist_override = ?, sort_title_override = ?, date_added = ?,
                            discogs_rank = ?, medium_override = ?, uid = ? WHERE id = ?
                        """, fields.Concat(new object?[] { d.Key, id }).ToArray());
                else
                    Db.Run("""
                        INSERT INTO copies(discogs_instance_id, release_id, status, status_note, in_discogs, removed_from_discogs_at,
                            sort_artist_override, sort_title_override, date_added, discogs_rank, medium_override, uid, created_at)
                        VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)
                        """, fields.Concat(new object?[] { d.Key, Unix(DateTimeOffset.Now) }).ToArray());
                break;
            }

            case SyncKind.Location:
            {
                if (d.Data is null) return true; // slettes til sidst (se ApplySyncDocs)
                // QR-koden på det trykte skilt følger sektionen, så skiltet virker på alle enheder.
                var code = Text(v, "code");
                if (code is not null) Db.Run("UPDATE locations SET scan_code = NULL WHERE scan_code = ? AND (uid IS NULL OR uid != ?)", code, d.Key);
                if (LocalId("locations", d.Key) is long lid)
                    Db.Run("UPDATE locations SET shelf = ?, section = ?, sort_index = ?, medium = ?, scan_code = ? WHERE id = ?",
                           Long(v, "shelf") ?? 1, Text(v, "section") ?? "A", Long(v, "sortIndex") ?? 0, Text(v, "medium") ?? "vinyl", code, lid);
                else
                    Db.Run("INSERT INTO locations(shelf, section, sort_index, medium, scan_code, uid) VALUES(?, ?, ?, ?, ?, ?)",
                           Long(v, "shelf") ?? 1, Text(v, "section") ?? "A", Long(v, "sortIndex") ?? 0, Text(v, "medium") ?? "vinyl", code, d.Key);
                break;
            }

            case SyncKind.Section:
            {
                if (LocalId("locations", d.Key) is not long loc) return d.Data is null;
                var ids = Strings(v["copies"]).Select(CopyIdOf).OfType<long>().ToList();
                Db.Run("DELETE FROM placements WHERE location_id = ?", loc);
                for (int i = 0; i < ids.Count; i++)
                    Db.Run("INSERT INTO placements(copy_id, location_id, position) VALUES(?, ?, ?) ON CONFLICT(copy_id) DO UPDATE SET location_id = excluded.location_id, position = excluded.position",
                           ids[i], loc, i + 1);
                break;
            }

            case SyncKind.Play:
            {
                var existing = LocalId("plays", d.Key);
                if (d.Data is null)
                {
                    if (existing is long e) Db.Run("DELETE FROM plays WHERE id = ?", e);
                    return true;
                }
                if (existing is not null) return true;
                if (Text(v, "copy") is not string c || CopyIdOf(c) is not long copy || Dbl(v, "at") is not double at) return false;
                Db.Run("INSERT INTO plays(copy_id, played_at, uid) VALUES(?, ?, ?)", copy, at, d.Key);
                break;
            }

            case SyncKind.Setting:
                if (d.Key == "artist_overrides")
                {
                    Db.Run("DELETE FROM artist_sort_overrides");
                    if (v["value"] is JsonObject o)
                        foreach (var (a, n) in o)
                            if (n is JsonValue j && j.TryGetValue<string>(out var name))
                                Db.Run("INSERT INTO artist_sort_overrides(artist, sort_name) VALUES(?, ?)", a, name);
                }
                else if (d.Key.StartsWith("sort_checked_", StringComparison.Ordinal) && MediumExtensions.FromRaw(d.Key["sort_checked_".Length..]) is Medium m)
                {
                    var ids = Strings(v["value"]).Select(CopyIdOf).OfType<long>().OrderBy(x => x);
                    SetSetting($"sort_checked_{m.RawValue()}", string.Join(",", ids.Select(x => x.ToString(CultureInfo.InvariantCulture))));
                }
                else if (SyncedSettings.Contains(d.Key))
                    SetSetting(d.Key, Text(v, "value"));
                break;
        }
        return true;
    }
}
