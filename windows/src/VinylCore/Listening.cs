namespace VinylShelfFinder.Core;

// Port af Sources/VinylCore/Listening.swift.

// MARK: Lyttelog

public sealed record Play(long Id, long CopyId, DateTimeOffset PlayedAt);

public sealed class ListeningStats
{
    /// Nyeste først.
    public IReadOnlyList<Play> Plays { get; }
    public IReadOnlyDictionary<long, int> Count { get; }
    public IReadOnlyDictionary<long, DateTimeOffset> LastPlayed { get; }

    public ListeningStats(IEnumerable<Play> plays)
    {
        var list = plays.ToList();
        Plays = list.OrderByDescending(p => p.PlayedAt).ToList();
        var c = new Dictionary<long, int>();
        var l = new Dictionary<long, DateTimeOffset>();
        foreach (var p in list)
        {
            c[p.CopyId] = c.GetValueOrDefault(p.CopyId) + 1;
            if (!l.TryGetValue(p.CopyId, out var last) || p.PlayedAt > last) l[p.CopyId] = p.PlayedAt;
        }
        Count = c;
        LastPlayed = l;
    }

    public static ListeningStats Empty { get; } = new(Array.Empty<Play>());

    public int PlaysSince(DateTimeOffset date) => Plays.Count(p => p.PlayedAt >= date);

    /// Mest spillede kopier, flest først.
    public List<(long CopyId, int Count)> MostPlayed(int limit = 10) =>
        Count.OrderByDescending(kv => kv.Value)
             .ThenByDescending(kv => LastPlayed.TryGetValue(kv.Key, out var d) ? d : DateTimeOffset.MinValue)
             .Take(limit).Select(kv => (kv.Key, kv.Value)).ToList();
}

public sealed partial class ShelfStore
{
    public long LogPlay(long copyId, DateTimeOffset? at = null) =>
        Db.Run("INSERT INTO plays(copy_id, played_at) VALUES(?, ?)", copyId, Unix(at ?? DateTimeOffset.Now));

    public void DeletePlay(long id) => Db.Run("DELETE FROM plays WHERE id = ?", id);

    public List<Play> LoadPlays() =>
        Db.Query("SELECT id, copy_id, played_at FROM plays").Select(r =>
            new Play(r.Long("id")!.Value, r.Long("copy_id")!.Value, FromUnix(r.Double("played_at") ?? 0))).ToList();

    public void SetScanCode(long locationId, string code)
    {
        Db.Run("UPDATE locations SET scan_code = ? WHERE id = ?", code, locationId);
        Db.Run("INSERT INTO scan_codes(code, kind, target_id) VALUES(?, 'location', ?) ON CONFLICT(code) DO UPDATE SET kind = 'location', target_id = excluded.target_id", code, locationId);
    }
}

// MARK: "Hvad skal jeg høre?"

public enum Freshness { Any, NeverPlayed, NotIn3Months, NotInYear }

public static class FreshnessExtensions
{
    public static string Label(this Freshness f) => f switch
    {
        Freshness.Any => "Alle plader",
        Freshness.NeverPlayed => "Aldrig spillet",
        Freshness.NotIn3Months => "Ikke hørt i 3 måneder",
        _ => "Ikke hørt i et år",
    };
}

/// Genre: fx "Rock". Decade: fx 1970 for 70'erne.
public sealed record ListenFilter(string? Genre = null, int? Decade = null, Freshness Freshness = Freshness.Any);

public static class ListenPicker
{
    private static IEnumerable<string> GenreList(Release r) =>
        (r.Genres ?? "").Split(',').Select(TextFold.TrimSpaces);

    public static List<string> Genres(IEnumerable<RecordItem> items) =>
        items.SelectMany(i => GenreList(i.Release)).Where(g => g.Length > 0).Distinct()
             .OrderBy(g => g, StringComparer.Ordinal).ToList();

    public static List<int> Decades(IEnumerable<RecordItem> items) =>
        items.Where(i => i.Release.Year is not null).Select(i => i.Release.Year!.Value / 10 * 10).Distinct().OrderBy(d => d).ToList();

    /// Plader der opfylder filteret og står i reolen.
    public static List<RecordItem> Candidates(IEnumerable<RecordItem> items, Library library, ListenFilter filter,
                                              ListeningStats stats, DateTimeOffset? now = null)
    {
        var t = now ?? DateTimeOffset.Now;
        return items.Where(it =>
        {
            if (!it.Copy.Status.IsOnShelf() || !library.LocationOfCopy.ContainsKey(it.Id)) return false;
            if (filter.Genre is string g && !GenreList(it.Release).Contains(g)) return false;
            if (filter.Decade is int d && (it.Release.Year is int y ? y / 10 * 10 : (int?)null) != d) return false;
            DateTimeOffset? last = stats.LastPlayed.TryGetValue(it.Id, out var l) ? l : null;
            return filter.Freshness switch
            {
                Freshness.NeverPlayed => last is null,
                Freshness.NotIn3Months => last is null || (t - last.Value).TotalSeconds > 90 * 86400,
                Freshness.NotInYear => last is null || (t - last.Value).TotalSeconds > 365 * 86400,
                _ => true,
            };
        }).ToList();
    }

    /// Vælger tilfældigt, vægtet mod plader der ikke er hørt længe. Undgår nylige forslag.
    public static RecordItem? Pick(IReadOnlyList<RecordItem> candidates, ListeningStats stats, IEnumerable<long> avoiding,
                                   DateTimeOffset? now = null, Random? rng = null)
    {
        var t = now ?? DateTimeOffset.Now;
        var recent = avoiding.ToHashSet();
        var pool = candidates.Where(c => !recent.Contains(c.Id)).ToList();
        if (pool.Count == 0) pool = candidates.ToList();
        if (pool.Count == 0) return null;
        // Vægt: aldrig spillet = 4, ellers 1 + år siden sidst (max 4).
        var weights = pool.Select(it =>
        {
            if (!stats.LastPlayed.TryGetValue(it.Id, out var last)) return 4.0;
            // Afspilninger med dato i fremtiden (fx ændret ur) må ikke give vægt ≤ 0.
            return Math.Min(4, 1 + Math.Max(0, (t - last).TotalSeconds) / (365 * 86400));
        }).ToList();
        var r = (rng ?? Random.Shared).NextDouble() * weights.Sum();
        for (int i = 0; i < weights.Count; i++)
        {
            if (r < weights[i]) return pool[i];
            r -= weights[i];
        }
        return pool[^1];
    }
}

// MARK: Reolskilte

public sealed record ShelfLabel(Location Location, string? FirstArtist, string? LastArtist, int Count)
{
    public long Id => Location.Id;

    /// Kode på QR-skiltet. Appen åbner sektionen, når koden scannes eller klikkes.
    public string ScanCode => $"vinylshelf://section/{Location.Id}";

    /// Ét skilt pr. sektion. Antal og første/sidste kunstner tæller kun plader, der står
    /// i reolen – en plade på væggen eller udlånt er ikke med.
    public static List<ShelfLabel> Labels(Library library) =>
        library.Locations.Select(loc =>
        {
            var onShelf = library.ItemsIn(loc.Id).Where(i => i.Copy.Status.IsOnShelf()).ToList();
            return new ShelfLabel(loc, onShelf.FirstOrDefault()?.Artist, onShelf.LastOrDefault()?.Artist, library.OnShelfCount(loc.Id));
        }).ToList();

    /// Fortolker "vinylshelf://section/<id>".
    public static long? LocationIdFromScanCode(string code)
    {
        if (!Uri.TryCreate(code, UriKind.Absolute, out var url) || url.Scheme != "vinylshelf" || url.Host != "section") return null;
        var last = url.AbsolutePath.TrimEnd('/').Split('/').LastOrDefault() ?? "";
        return long.TryParse(last, System.Globalization.NumberStyles.Integer, System.Globalization.CultureInfo.InvariantCulture, out var id) ? id : null;
    }
}
