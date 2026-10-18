using System.Globalization;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace VinylShelfFinder.Core;

// Port af Sources/VinylCore/Sorting.swift.

public enum VariousPlacement { Alphabetical, First, Last }
public enum WithinArtist { Title, Year }

public static class SortRuleLabels
{
    public static string Label(this VariousPlacement v) => v switch
    {
        VariousPlacement.Alphabetical => "Alfabetisk under “Various”",
        VariousPlacement.First => "Først i samlingen",
        _ => "Sidst i samlingen",
    };

    public static string Label(this WithinArtist w) => w == WithinArtist.Title ? "Titel (alfabetisk)" : "Udgivelsesår (kronologisk)";

    public static string RawValue(this VariousPlacement v) => v switch
    {
        VariousPlacement.Alphabetical => "alphabetical",
        VariousPlacement.First => "first",
        _ => "last",
    };

    public static string RawValue(this WithinArtist w) => w == WithinArtist.Title ? "title" : "year";
}

/// Maskin-nøgle til sammenligning (se SortRules.KeyFor).
public readonly record struct SortKey(
    int NumberGroup,   // 1 = kunstneren starter med et tal og skal stå sidst (NumbersLast), ellers 0
    int DiscogsRank,   // int.MaxValue hvis ukendt eller ikke i brug
    int Group,         // 0 = først, 1 = normal, 2 = sidst
    string Artist,
    string Primary,    // titel
    int Year,
    string Catalog,
    int ReleaseId,
    long CopyId);

/// Konfigurerbare sorteringsregler. Ændrer aldrig det originale Discogs-navn –
/// de producerer kun en separat sorteringsværdi.
public sealed class SortRules : IEquatable<SortRules>
{
    /// Brug præcis den rækkefølge Discogs selv sorterer samlingen i (artist A–Z).
    /// De øvrige regler bruges så kun til plader uden Discogs-rækkefølge.
    public bool UseDiscogsOrder { get; set; } = true;
    /// Artikler der ignoreres forrest i kunstnernavne ("The Beatles" → "Beatles").
    public List<string> ArtistArticles { get; set; } = new() { "The" };
    /// Artikler der ignoreres forrest i titler. Tom som standard.
    public List<string> TitleArticles { get; set; } = new();
    /// "AC/DC" → "ACDC", "A-ha" → "Aha".
    public bool IgnorePunctuation { get; set; } = true;
    /// Æ, Ø, Å sorteres efter Z (ellers Æ=AE, Ø=O, Å=A).
    public bool DanishAlphabet { get; set; } = true;
    /// Kunstnere, der starter med et tal (10cc, 2Pac, The 1975), står sidst – efter Z og Æ Ø Å.
    /// Gælder også med Discogs' rækkefølge, hvor tallene ellers står først; indbyrdes beholder de rækkefølgen.
    public bool NumbersLast { get; set; } = true;
    public VariousPlacement Various { get; set; } = VariousPlacement.Alphabetical;
    public WithinArtist WithinArtist { get; set; } = WithinArtist.Title;
    /// Kunstner (som vist) → sorteringsnavn, fx "Bob Dylan" → "Dylan, Bob".
    public Dictionary<string, string> ArtistOverrides { get; set; } = new();

    /// En selvstændig kopi (lister og ordbog kopieres også), som Swift-structen.
    public SortRules Clone() => new()
    {
        UseDiscogsOrder = UseDiscogsOrder,
        ArtistArticles = new(ArtistArticles),
        TitleArticles = new(TitleArticles),
        IgnorePunctuation = IgnorePunctuation,
        DanishAlphabet = DanishAlphabet,
        NumbersLast = NumbersLast,
        Various = Various,
        WithinArtist = WithinArtist,
        ArtistOverrides = new(ArtistOverrides),
    };

    public bool Equals(SortRules? o) => o is not null && UseDiscogsOrder == o.UseDiscogsOrder
        && ArtistArticles.SequenceEqual(o.ArtistArticles) && TitleArticles.SequenceEqual(o.TitleArticles)
        && IgnorePunctuation == o.IgnorePunctuation && DanishAlphabet == o.DanishAlphabet
        && NumbersLast == o.NumbersLast && Various == o.Various && WithinArtist == o.WithinArtist
        && ArtistOverrides.Count == o.ArtistOverrides.Count
        && ArtistOverrides.All(kv => o.ArtistOverrides.TryGetValue(kv.Key, out var v) && v == kv.Value);
    public override bool Equals(object? obj) => Equals(obj as SortRules);
    public override int GetHashCode() => HashCode.Combine(UseDiscogsOrder, IgnorePunctuation, DanishAlphabet, Various, WithinArtist, ArtistArticles.Count);

    // MARK: JSON (samme format som Mac-appens Codable, så "sort_rules" kan deles)

    /// Kunstner-overrides gemmes ikke her, men i tabellen artist_sort_overrides.
    public string ToJson()
    {
        var o = new JsonObject
        {
            ["useDiscogsOrder"] = UseDiscogsOrder,
            ["artistArticles"] = new JsonArray(ArtistArticles.Select(a => (JsonNode?)JsonValue.Create(a)).ToArray()),
            ["titleArticles"] = new JsonArray(TitleArticles.Select(a => (JsonNode?)JsonValue.Create(a)).ToArray()),
            ["ignorePunctuation"] = IgnorePunctuation,
            ["danishAlphabet"] = DanishAlphabet,
            ["numbersLast"] = NumbersLast,
            ["various"] = Various.RawValue(),
            ["withinArtist"] = WithinArtist.RawValue(),
        };
        return o.ToJsonString();
    }

    /// Tolerant dekodning, så gemte regler fra ældre versioner ikke går tabt.
    /// Ugyldig JSON → null (så bruges standardreglerne).
    public static SortRules? FromJson(string json)
    {
        try
        {
            if (JsonNode.Parse(json) is not JsonObject o) return null;
            var r = new SortRules();
            if (o["useDiscogsOrder"] is JsonValue a && a.TryGetValue<bool>(out var b1)) r.UseDiscogsOrder = b1;
            if (o["artistArticles"] is JsonArray aa) r.ArtistArticles = aa.Select(x => x?.GetValue<string>() ?? "").ToList();
            if (o["titleArticles"] is JsonArray ta) r.TitleArticles = ta.Select(x => x?.GetValue<string>() ?? "").ToList();
            if (o["ignorePunctuation"] is JsonValue ip && ip.TryGetValue<bool>(out var b2)) r.IgnorePunctuation = b2;
            if (o["danishAlphabet"] is JsonValue da && da.TryGetValue<bool>(out var b3)) r.DanishAlphabet = b3;
            if (o["numbersLast"] is JsonValue nl && nl.TryGetValue<bool>(out var b4)) r.NumbersLast = b4;
            if (o["various"] is JsonValue v && v.TryGetValue<string>(out var vs))
            {
                r.Various = vs switch
                {
                    "alphabetical" => VariousPlacement.Alphabetical,
                    "first" => VariousPlacement.First,
                    "last" => VariousPlacement.Last,
                    _ => throw new JsonException("various"),
                };
            }
            if (o["withinArtist"] is JsonValue w && w.TryGetValue<string>(out var ws))
            {
                r.WithinArtist = ws switch
                {
                    "title" => WithinArtist.Title,
                    "year" => WithinArtist.Year,
                    _ => throw new JsonException("withinArtist"),
                };
            }
            return r;
        }
        catch (Exception e) when (e is JsonException or InvalidOperationException or FormatException) { return null; }
    }

    // MARK: Sorteringsværdier

    public static bool IsVarious(string artist)
    {
        var a = TextFold.TrimSpaces(artist.ToLowerInvariant());
        return a == "various" || a == "various artists" || a.StartsWith("various ", StringComparison.Ordinal);
    }

    /// Den menneskeligt læsbare sorteringsværdi for en kunstner, fx "Beatles".
    public string SortArtist(string artist, string? @override = null)
    {
        if (@override is not null && TextFold.TrimSpaces(@override) is { Length: > 0 } o) return o;
        if (ArtistOverrides.TryGetValue(artist, out var ov) && ov.Length > 0) return ov;
        var s = TextFold.TrimSpaces(artist);
        s = StripArticles(s, ArtistArticles);
        if (IgnorePunctuation) s = RemovePunctuation(s);
        return s;
    }

    public string SortTitle(string title, string? @override = null)
    {
        if (@override is not null && TextFold.TrimSpaces(@override) is { Length: > 0 } o) return o;
        var s = StripArticles(TextFold.TrimSpaces(title), TitleArticles);
        if (IgnorePunctuation) s = RemovePunctuation(s);
        return s;
    }

    internal static string StripArticles(string input, IEnumerable<string> articles)
    {
        var s = input;
        foreach (var art in articles)
        {
            if (art.Length == 0) continue;
            // "Beatles, The" → "Beatles"
            var suffix = ", " + art;
            if (s.ToLowerInvariant().EndsWith(suffix.ToLowerInvariant(), StringComparison.Ordinal))
            {
                s = s[..^suffix.Length];
                break;
            }
            // "The Beatles" → "Beatles" (men ikke "The" alene eller "Theatre")
            var prefix = art + " ";
            if (s.ToLowerInvariant().StartsWith(prefix.ToLowerInvariant(), StringComparison.Ordinal) && s.Length > prefix.Length)
            {
                s = s[prefix.Length..];
                break;
            }
        }
        return s;
    }

    internal static string RemovePunctuation(string s)
    {
        var kept = new StringBuilder(s.Length);
        foreach (var r in s.EnumerateRunes())
            if (TextFold.IsAlphanumeric(r) || TextFold.IsSpace(r)) kept.Append(r.ToString());
        var collapsed = string.Join(" ", kept.ToString().Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries));
        return collapsed.Length == 0 ? s : collapsed;
    }

    /// Maskin-nøgle til sammenligning: små bogstaver, diakritika foldet,
    /// og (i dansk tilstand) æ/ø/å placeret efter z.
    public string CollationKey(string s)
    {
        var t = s.ToLowerInvariant();
        if (DanishAlphabet)
        {
            t = t.Replace("ä", "æ").Replace("ö", "ø")
                 .Replace("æ", "{").Replace("ø", "|").Replace("å", "}");
        }
        else
        {
            t = t.Replace("æ", "ae").Replace("ø", "o").Replace("ß", "ss");
        }
        return TextFold.Fold(t);
    }

    // MARK: Sammenligning

    public SortKey KeyFor(RecordItem item)
    {
        var artist = item.Release.Artist;
        int group = 1;
        if (IsVarious(artist))
            group = Various switch { VariousPlacement.First => 0, VariousPlacement.Last => 2, _ => 1 };
        var sortArtist = SortArtist(artist, item.Copy.SortArtistOverride);
        return new SortKey(
            NumberGroup: NumbersLast && StartsWithDigit(sortArtist) ? 1 : 0,
            DiscogsRank: UseDiscogsOrder ? (item.Copy.DiscogsRank ?? int.MaxValue) : int.MaxValue,
            Group: group,
            Artist: CollationKey(sortArtist),
            Primary: CollationKey(SortTitle(item.Release.Title, item.Copy.SortTitleOverride)),
            Year: item.Release.Year is int y && y > 0 ? y : 9999,
            Catalog: CollationKey(item.Release.CatalogNumber ?? ""),
            ReleaseId: item.Release.Id,
            CopyId: item.Copy.Id);
    }

    /// "10cc", "2Pac", "1975" (efter "The" er fjernet).
    public static bool StartsWithDigit(string sortArtist) =>
        sortArtist.EnumerateRunes().FirstOrDefault() is var r && Rune.IsDigit(r);

    public bool AreInIncreasingOrder(SortKey a, SortKey b)
    {
        if (a.NumberGroup != b.NumberGroup) return a.NumberGroup < b.NumberGroup;
        if (a.DiscogsRank != b.DiscogsRank) return a.DiscogsRank < b.DiscogsRank;
        if (a.Group != b.Group) return a.Group < b.Group;
        int c = NaturalCompare(a.Artist, b.Artist);
        if (c != 0) return c < 0;
        if (WithinArtist == WithinArtist.Year && a.Year != b.Year) return a.Year < b.Year;
        int t = NaturalCompare(a.Primary, b.Primary);
        if (t != 0) return t < 0;
        if (a.Year != b.Year) return a.Year < b.Year;
        int k = NaturalCompare(a.Catalog, b.Catalog);
        if (k != 0) return k < 0;
        if (a.ReleaseId != b.ReleaseId) return a.ReleaseId < b.ReleaseId;
        return a.CopyId < b.CopyId;
    }

    public List<RecordItem> Sorted(IEnumerable<RecordItem> items)
    {
        var keyed = items.Select(i => (Item: i, Key: KeyFor(i))).ToList();
        keyed.Sort((x, y) => AreInIncreasingOrder(x.Key, y.Key) ? -1 : AreInIncreasingOrder(y.Key, x.Key) ? 1 : 0);
        return keyed.Select(k => k.Item).ToList();
    }

    /// Ordinal sammenligning hvor tal-sekvenser sammenlignes numerisk ("2Pac" < "10cc").
    /// Mellemrum sorterer før bogstaver, så "Bob Dylan" < "Bobby".
    public static int NaturalCompare(string a, string b)
    {
        var x = a.EnumerateRunes().ToArray();
        var y = b.EnumerateRunes().ToArray();
        int i = 0, j = 0;
        while (i < x.Length && j < y.Length)
        {
            if (Rune.IsDigit(x[i]) && Rune.IsDigit(y[j]))
            {
                int ei = i; while (ei < x.Length && Rune.IsDigit(x[ei])) ei++;
                int ej = j; while (ej < y.Length && Rune.IsDigit(y[ej])) ej++;
                var na = string.Concat(x[i..ei].Select(r => r.ToString())).TrimStart('0');
                var nb = string.Concat(y[j..ej].Select(r => r.ToString())).TrimStart('0');
                if (na.Length != nb.Length) return na.Length < nb.Length ? -1 : 1;
                int c = string.CompareOrdinal(na, nb);
                if (c != 0) return c < 0 ? -1 : 1;
                i = ei; j = ej;
                continue;
            }
            if (x[i] != y[j]) return x[i].Value < y[j].Value ? -1 : 1;
            i++; j++;
        }
        if (x.Length - i == y.Length - j) return 0;
        return (x.Length - i) < (y.Length - j) ? -1 : 1;
    }
}

/// Tekstfoldning som Foundation på Mac (diacriticInsensitive, widthInsensitive, .whitespaces, .alphanumerics).
internal static class TextFold
{
    /// Fjerner accenter ("é" → "e", "å" → "a") og folder fuld bredde ("Ａ" → "A").
    public static string Fold(string s)
    {
        var d = s.Normalize(NormalizationForm.FormD);
        var sb = new StringBuilder(d.Length);
        foreach (var c in d)
        {
            var cat = CharUnicodeInfo.GetUnicodeCategory(c);
            if (cat == UnicodeCategory.NonSpacingMark) continue;
            if (c >= '！' && c <= '～') sb.Append((char)(c - 0xFEE0));
            else if (c == '　') sb.Append(' ');
            else sb.Append(c);
        }
        return sb.ToString().Normalize(NormalizationForm.FormC);
    }

    /// Som CharacterSet.alphanumerics: bogstaver, mærker og tal.
    public static bool IsAlphanumeric(Rune r) => Rune.GetUnicodeCategory(r) switch
    {
        UnicodeCategory.UppercaseLetter or UnicodeCategory.LowercaseLetter or UnicodeCategory.TitlecaseLetter
            or UnicodeCategory.ModifierLetter or UnicodeCategory.OtherLetter
            or UnicodeCategory.NonSpacingMark or UnicodeCategory.SpacingCombiningMark or UnicodeCategory.EnclosingMark
            or UnicodeCategory.DecimalDigitNumber or UnicodeCategory.LetterNumber or UnicodeCategory.OtherNumber => true,
        _ => false,
    };

    /// Som CharacterSet.whitespaces: mellemrum og tabulator (ikke linjeskift).
    public static bool IsSpace(Rune r) => r.Value == '\t' || Rune.GetUnicodeCategory(r) == UnicodeCategory.SpaceSeparator;
    public static bool IsSpace(char c) => c == '\t' || CharUnicodeInfo.GetUnicodeCategory(c) == UnicodeCategory.SpaceSeparator;

    public static string TrimSpaces(string s)
    {
        int a = 0, b = s.Length;
        while (a < b && IsSpace(s[a])) a++;
        while (b > a && IsSpace(s[b - 1])) b--;
        return s[a..b];
    }
}
