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
    /// Sanglisten fra Discogs (tom, indtil den er hentet).
    public IReadOnlyList<Track> Tracks { get; init; } = Array.Empty<Track>();
}

/// Én sang på en udgivelse, som Discogs skriver den, fx position "B1" (side B, nummer 1) eller "3" på en cd.
public sealed record Track(string Position, string Title, string? Duration = null);

// MARK: Plader og cd'er

/// Hvilken slags hylde en kopi hører til. Plader og cd'er har hver deres reoler, sektioner og
/// nummerering, men samme Discogs-samling. Gemmes som tekst (RawValue), som på Mac.
public enum Medium { Vinyl, Cd }

public static class MediumExtensions
{
    public static readonly Medium[] All = { Medium.Vinyl, Medium.Cd };

    public static string RawValue(this Medium m) => m == Medium.Cd ? "cd" : "vinyl";

    public static Medium? FromRaw(string? raw) => raw switch { "vinyl" => Medium.Vinyl, "cd" => Medium.Cd, _ => null };

    private static readonly HashSet<string> CdFormats = new() { "CD", "CDR", "SACD", "HDCD" };

    /// Ud fra Discogs' format, fx "Vinyl, LP" eller "2×CD, Album". Kun det første format tæller.
    /// Alt, der ikke er en cd (vinyl, kassetter, bokse …), hører til pladerne, som før.
    public static Medium Of(string? format) =>
        CdFormats.Contains(FirstFormat(format)) ? Medium.Cd : Medium.Vinyl;

    /// Første format uden antal: "2×CD, Album" → "CD", "8×File, MP3" → "FILE".
    private static string FirstFormat(string? format)
    {
        var first = format?.Split(',')[0].Trim().ToUpperInvariant() ?? "";
        int x = first.IndexOf('×');
        return x >= 0 ? first[(x + 1)..] : first;
    }

    /// Kun digitale filer (Discogs-formatet "File"). De står ikke fysisk nogen steder.
    public static bool IsDigital(string? format) => FirstFormat(format) == "FILE";

    /// Hylden, en kopi hører til: brugerens valg, ellers ud fra formatet.
    /// null = ingen hylde (digitale filer), medmindre brugeren selv har flyttet kopien.
    public static Medium? ShelfOf(Medium? mediumOverride, string? format) =>
        mediumOverride ?? (IsDigital(format) ? null : Of(format));

    /// "Plader" / "Cd'er"
    public static string Title(this Medium m) => m == Medium.Cd ? "Cd'er" : "Plader";
    /// "plade" / "cd"
    public static string Singular(this Medium m) => m == Medium.Cd ? "cd" : "plade";
    /// "plader" / "cd'er"
    public static string Plural(this Medium m) => m == Medium.Cd ? "cd'er" : "plader";
    /// "1 plade", "5 plader", "1 cd", "5 cd'er"
    public static string Count(this Medium m, int n) => n == 1 ? $"1 {m.Singular()}" : $"{n} {m.Plural()}";
    /// "Reol" / "Cd-reol"
    public static string ShelfWord(this Medium m) => m == Medium.Cd ? "Cd-reol" : "Reol";
}

// MARK: Kategorier (Jazz, Underholdning, Klassisk)

/// Musik, der kan stå for sig: til sidst på reolerne eller på egne reoler. Rækkefølgen her er også rækkefølgen
/// til sidst på reolerne, og passer en plade i flere kategorier, vinder den første. Gemmes som tekst (RawValue).
public enum Category { Jazz, Entertainment, Classical }

public static class CategoryExtensions
{
    public static readonly Category[] All = { Category.Jazz, Category.Entertainment, Category.Classical };

    public static string RawValue(this Category c) => c switch
    {
        Category.Jazz => "jazz",
        Category.Entertainment => "entertainment",
        _ => "classical",
    };

    public static Category? FromRaw(string? raw) => raw switch
    {
        "jazz" => Category.Jazz,
        "entertainment" => Category.Entertainment,
        "classical" => Category.Classical,
        _ => null,
    };

    /// "Jazz" / "Underholdning" / "Klassisk"
    public static string Title(this Category c) => c switch
    {
        Category.Jazz => "Jazz",
        Category.Entertainment => "Underholdning",
        _ => "Klassisk",
    };

    /// Underholdning er brugerens egen mappe i Discogs-samlingen med dette navn.
    public const string EntertainmentFolder = "Underholdning";

    /// Jazz og Klassisk er Discogs-genrer ("Jazz, Rock" tæller som jazz). Underholdning er Discogs-mappen.
    public static bool Matches(this Category c, string? genres, string? folder) => c switch
    {
        Category.Jazz => HasGenre(genres, "jazz"),
        Category.Classical => HasGenre(genres, "classical"),
        _ => string.Equals(folder?.Trim(), EntertainmentFolder, StringComparison.OrdinalIgnoreCase),
    };

    /// Skillekortets farve (lys og mørk tilstand), som RGB-hex. Hvid tekst ovenpå. Samme farver som på Mac og i webappen.
    public static (uint Light, uint Dark) ColorHex(this Category c) => c switch
    {
        Category.Jazz => (0x1F4F8F, 0x3A6DB5),
        Category.Entertainment => (0x85621A, 0xA67C24),
        _ => (0x6E2433, 0x93394B),
    };

    private static bool HasGenre(string? genres, string name) =>
        (genres ?? "").Split(',').Any(g => g.Trim().Equals(name, StringComparison.OrdinalIgnoreCase));
}

/// Hvor en kategori står. Off = sammen med alt det andet (som før).
public enum CategoryMode { Off, End, Own }

public static class CategoryModeExtensions
{
    public static readonly CategoryMode[] All = { CategoryMode.Off, CategoryMode.End, CategoryMode.Own };
    public static string RawValue(this CategoryMode m) => m switch { CategoryMode.End => "end", CategoryMode.Own => "own", _ => "off" };
    public static CategoryMode? FromRaw(string? raw) => raw switch
    {
        "off" => CategoryMode.Off,
        "end" => CategoryMode.End,
        "own" => CategoryMode.Own,
        _ => null,
    };
    public static string Label(this CategoryMode m) => m switch
    {
        CategoryMode.End => "Sidst på reolerne",
        CategoryMode.Own => "Egne reoler",
        _ => "Fra",
    };
}

/// En slags hylde med egne reoler, sektioner og nummerering: plader eller cd'er, og evt. en kategori med
/// egne reoler (fx jazz-cd'er). Gemmes som tekst: "vinyl", "cd", "vinyl.jazz", "cd.classical" osv. (som på Mac).
public readonly record struct ShelfKind(Medium Medium, Category? Category = null)
{
    public static readonly ShelfKind Vinyl = new(Medium.Vinyl);
    public static readonly ShelfKind Cd = new(Medium.Cd);

    public string RawValue => Category is Category c ? $"{Medium.RawValue()}.{c.RawValue()}" : Medium.RawValue();

    public static ShelfKind? FromRaw(string? raw)
    {
        if (raw is null) return null;
        var parts = raw.Split('.');
        if (parts.Length > 2 || MediumExtensions.FromRaw(parts[0]) is not Medium m) return null;
        if (parts.Length == 1) return new ShelfKind(m);
        return CategoryExtensions.FromRaw(parts[1]) is Category c ? new ShelfKind(m, c) : null;
    }

    /// Alle slags hylder i fast rækkefølge: plader, cd'er, og så kategorierne (plader før cd'er).
    public static IReadOnlyList<ShelfKind> All { get; } =
        MediumExtensions.All.Select(m => new ShelfKind(m))
            .Concat(CategoryExtensions.All.SelectMany(c => MediumExtensions.All.Select(m => new ShelfKind(m, c)))).ToArray();

    /// "Plader" / "Cd'er" / "Jazz (plader)" / "Klassisk (cd'er)"
    public string Title => Category is Category c ? $"{c.Title()} ({Medium.Plural()})" : Medium.Title();
    /// "Reol" / "Cd-reol" / "Jazz-reol" / "Klassisk-cd-reol"
    public string ShelfWord => Category is Category c ? (Medium == Medium.Vinyl ? $"{c.Title()}-reol" : $"{c.Title()}-cd-reol") : Medium.ShelfWord();
    /// "Reolerne" / "Cd-reolerne" / "Jazz-reolerne" – til historikken.
    public string ShelvesWord => ShelfWord + "erne";
    public string Singular => Medium.Singular();
    public string Plural => Medium.Plural();
    public string Count(int n) => Medium.Count(n);
}

// MARK: Fysisk data ("Denne konkrete kopi står her")

/// Pladens fysiske status. Gemmes som tekst (RawValue) i copies.status, som på Mac.
/// Alle andre end Home er "ude af reolen": pladen beholder sin plads i placements,
/// men tæller ikke med i reolens fysiske nummerering, før den er sat tilbage.
public enum CopyStatus { Home, Playing, Wall, Lent, Stored, Missing }

public static class CopyStatusExtensions
{
    public static readonly CopyStatus[] All = { CopyStatus.Home, CopyStatus.Playing, CopyStatus.Wall, CopyStatus.Lent, CopyStatus.Stored, CopyStatus.Missing };

    /// Teksten i databasen: "home", "playing", "wall", "lent", "stored", "missing".
    /// "playing" (på pladespilleren) læses som "home" af ældre versioner.
    public static string RawValue(this CopyStatus s) => s switch
    {
        CopyStatus.Home => "home",
        CopyStatus.Playing => "playing",
        CopyStatus.Wall => "wall",
        CopyStatus.Lent => "lent",
        CopyStatus.Stored => "stored",
        _ => "missing",
    };

    public static CopyStatus? FromRaw(string? raw) => raw switch
    {
        "home" => CopyStatus.Home,
        "playing" => CopyStatus.Playing,
        "wall" => CopyStatus.Wall,
        "lent" => CopyStatus.Lent,
        "stored" => CopyStatus.Stored,
        "missing" => CopyStatus.Missing,
        _ => null,
    };

    public static string Label(this CopyStatus s) => s switch
    {
        CopyStatus.Home => "På plads",
        CopyStatus.Playing => "På pladespilleren",
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
    long? InstanceId,
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
    int? DiscogsRank = null,
    /// Brugerens eget valg af hylde, når Discogs' format ikke passer.
    Medium? MediumOverride = null,
    /// Navnet på mappen i Discogs-samlingen (fx "Underholdning"). null, indtil den er hentet.
    string? DiscogsFolder = null);

/// En sektion i en reol, fx "Reol 3 · Sektion B".
/// Category er en kategori med egne reoler (fx jazz); null = de almindelige reoler.
public sealed record Location(long Id, int Shelf, string Section, int SortIndex, string? ScanCode = null, Medium Medium = Medium.Vinyl,
    Category? Category = null)
{
    public ShelfKind Kind => new(Medium, Category);
    /// "Reol 1 · Sektion A", "Cd-reol 1 · Sektion A" eller "Jazz-reol 1 · Sektion A".
    public string Name => $"{Kind.ShelfWord} {Shelf} · Sektion {Section}";
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
    /// Plade eller cd: brugerens valg, ellers Discogs' format.
    public Medium Medium => Copy.MediumOverride ?? MediumExtensions.Of(Release.Format);

    /// "Harvest SHVL 804 (1973)" – pladeselskab og katalognummer, som samlere skriver dem (som på Mac).
    public string PressingLine
    {
        get
        {
            var cat = string.IsNullOrEmpty(Release.CatalogNumber) || Release.CatalogNumber!.Equals("none", StringComparison.OrdinalIgnoreCase) ? null : Release.CatalogNumber;
            var name = string.Join(" ", new[] { string.IsNullOrEmpty(Release.Label) ? null : Release.Label, cat }.Where(x => x is not null));
            if (Release.Year is not int y || y <= 0) return name;
            return name.Length == 0 ? y.ToString() : $"{name} ({y})";
        }
    }

    /// "Harvest SHVL 804 (1973). Vinyl, LP" – bruges til at skelne pressings (som på Mac).
    public string DetailLine
    {
        get
        {
            var parts = new[] { PressingLine.Length == 0 ? null : PressingLine, string.IsNullOrEmpty(Release.Format) ? null : Release.Format };
            return string.Join(". ", parts.Where(x => x is not null));
        }
    }
}

/// Én post i Discogs Collection = én fysisk kopi (instance) af en release.
/// FolderId er mappen i Discogs-samlingen (fx 1 = "Uncategorized"); Folder er dens navn, når navnene er hentet.
public sealed record DiscogsCollectionItem(long InstanceId, string? DateAdded, Release Release, int? FolderId = null, string? Folder = null);
