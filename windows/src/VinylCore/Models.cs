namespace VinylShelfFinder.Core;

// Port af Sources/VinylCore/Models.swift. Navne og betydning er de samme som i Mac-appen,
// så databasen (vinyl.sqlite) har præcis samme skema på begge platforme.

// MARK: Discogs-data ("Jeg ejer denne release")

/// Metadata for én Discogs-release. Identificeres altid ved Id (Discogs release ID),
/// aldrig ved artist + titel.
public sealed record Release(
    int Id,
    string Artist,
    string Title,
    int? Year = null,
    string? Label = null,
    string? CatalogNumber = null,
    string? Format = null,
    string? CoverUrl = null,
    string? ThumbUrl = null,
    string? Genres = null)
{
    public Uri DiscogsUrl => new($"https://www.discogs.com/release/{Id}");
}

// MARK: Fysisk data ("Denne konkrete kopi står her")

/// Pladens fysiske status. Gemmes som tekst (RawValue) i copies.status, som på Mac.
/// Alle andre end Home er "ude af reolen": pladen beholder sin plads i placements,
/// men tæller ikke med i reolens fysiske nummerering, før den er sat tilbage.
public enum CopyStatus { Home, Wall, Lent, Stored, Missing }

public static class CopyStatusExtensions
{
    public static readonly CopyStatus[] All = { CopyStatus.Home, CopyStatus.Wall, CopyStatus.Lent, CopyStatus.Stored, CopyStatus.Missing };

    /// Teksten i databasen: "home", "wall", "lent", "stored", "missing".
    public static string RawValue(this CopyStatus s) => s switch
    {
        CopyStatus.Home => "home",
        CopyStatus.Wall => "wall",
        CopyStatus.Lent => "lent",
        CopyStatus.Stored => "stored",
        _ => "missing",
    };

    public static CopyStatus? FromRaw(string? raw) => raw switch
    {
        "home" => CopyStatus.Home,
        "wall" => CopyStatus.Wall,
        "lent" => CopyStatus.Lent,
        "stored" => CopyStatus.Stored,
        "missing" => CopyStatus.Missing,
        _ => null,
    };

    public static string Label(this CopyStatus s) => s switch
    {
        CopyStatus.Home => "På plads",
        CopyStatus.Wall => "På væggen",
        CopyStatus.Stored => "Opbevaret andet sted",
        CopyStatus.Lent => "Udlånt",
        _ => "Mangler",
    };

    /// Står pladen faktisk i reolen? Kun sådanne plader bruges som referencepunkter
    /// og tæller med i reolens fysiske nummerering ("Plade 13 af 14").
    public static bool IsOnShelf(this CopyStatus s) => s == CopyStatus.Home;
}

/// Én fysisk kopi. Svarer til en Discogs collection-"instance", så to kopier af samme
/// release (eller to pressings) altid er to forskellige rækker.
public sealed record Copy(
    long Id,
    int? InstanceId,
    int ReleaseId,
    CopyStatus Status = CopyStatus.Home,
    string? StatusNote = null,
    /// false når kopien er forsvundet fra Discogs Collection. Fysisk placering bevares.
    bool InDiscogs = true,
    DateTimeOffset? RemovedFromDiscogsAt = null,
    string? SortArtistOverride = null,
    string? SortTitleOverride = null,
    string? DateAdded = null,
    /// Pladens plads i Discogs' egen artist-sortering ved seneste sync (0-baseret).
    int? DiscogsRank = null);

/// En sektion i en reol, fx "Reol 3 · Sektion B".
public sealed record Location(long Id, int Shelf, string Section, int SortIndex, string? ScanCode = null)
{
    public string Name => $"Reol {Shelf} · Sektion {Section}";
    public string ShortName => $"{Shelf}{Section}";
}

public enum HistoryKind { Moved, Placed, StatusChanged, AddedFromDiscogs, RemovedFromDiscogs, MetadataUpdated, Unplaced, Deleted, LayoutCreated }

public static class HistoryKindExtensions
{
    /// Samme tekst som Swift-enummets rawValue ("moved", "statusChanged" …).
    public static string RawValue(this HistoryKind k)
    {
        var s = k.ToString();
        return char.ToLowerInvariant(s[0]) + s[1..];
    }

    public static HistoryKind? FromRaw(string? raw)
    {
        if (string.IsNullOrEmpty(raw)) return null;
        var pascal = char.ToUpperInvariant(raw[0]) + raw[1..];
        return Enum.TryParse<HistoryKind>(pascal, out var k) ? k : null;
    }
}

public sealed record HistoryEntry(
    long Id,
    DateTimeOffset At,
    long? CopyId,
    HistoryKind Kind,
    string Summary,
    long? FromLocationId,
    int? FromPosition,
    long? ToLocationId,
    int? ToPosition);

/// Kombinerer fysisk kopi og Discogs-metadata til visning.
public sealed record RecordItem(Copy Copy, Release Release)
{
    public long Id => Copy.Id;
    public string Artist => Release.Artist;
    public string Title => Release.Title;
    public string FullName => $"{Release.Artist} – {Release.Title}";

    /// "1973 • Harvest • SHVL 804 • Vinyl, LP" – bruges til at skelne pressings.
    public string DetailLine
    {
        get
        {
            var parts = new List<string>();
            if (Release.Year is int y && y > 0) parts.Add(y.ToString());
            if (!string.IsNullOrEmpty(Release.Label)) parts.Add(Release.Label!);
            if (!string.IsNullOrEmpty(Release.CatalogNumber) && !Release.CatalogNumber!.Equals("none", StringComparison.OrdinalIgnoreCase))
                parts.Add(Release.CatalogNumber!);
            if (!string.IsNullOrEmpty(Release.Format)) parts.Add(Release.Format!);
            return string.Join(" • ", parts);
        }
    }
}

/// Én post i Discogs Collection = én fysisk kopi (instance) af en release.
public sealed record DiscogsCollectionItem(int InstanceId, string? DateAdded, Release Release);
