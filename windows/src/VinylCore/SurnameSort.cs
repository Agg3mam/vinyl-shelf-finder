using System.Text.Json;

namespace VinylShelfFinder.Core;

/// Én kunstner i "Efternavn først": navnet, som det står i Discogs, det vendte sorteringsnavn
/// ("Bob Dylan" → "Dylan, Bob"), og appens gæt på, om det er en person.
public sealed record SurnameCandidate(string Artist, string Surname, bool LikelyPerson);

/// Sortering efter efternavn. Discogs siger ikke, om en kunstner er en person eller et band,
/// så appen gætter ud fra navnet, og brugeren krydser af. Valgene gemmes som almindelige
/// sorteringsnavne (SortRules.ArtistOverrides), så resten af sorteringen virker uændret.
public static class SurnameSort
{
    // Ord, der næsten altid betyder et band eller et ensemble, ikke en person.
    private static readonly HashSet<string> GroupWords = new(StringComparer.OrdinalIgnoreCase)
    {
        "band", "bands", "orchestra", "orkester", "orkestret", "quartet", "quintet", "trio", "kvartet", "ensemble",
        "brothers", "sisters", "brødre", "group", "gruppe", "experience", "project", "collective", "boys", "girls",
        "choir", "kor", "club", "society", "gang", "crew", "sound", "sounds", "system", "machine", "attack", "army",
        "family", "allstars", "all-stars", "singers", "players", "kids", "orchestre", "orquesta", "symphony",
        "philharmonic", "filharmoniske", "unit", "posse", "connection", "revival", "company", "jazzmen", "combo",
        "duo", "dolls", "stones", "heads", "beat", "beats", "riders", "rangers", "brigade", "foundation", "syndicate",
        "crue", "crüe", "floyd", "zeppelin", "maiden", "priest", "purple", "sabbath", "tull", "theory",
        "of", "airplane", "stompers", "senior",
    };

    // Første ord, der næsten altid betyder et band ("Black Sabbath", "Blue Cheer", "Deep Purple", "Atomic Swing").
    private static readonly HashSet<string> GroupFirstWords = new(StringComparer.OrdinalIgnoreCase)
    {
        "black", "blue", "big", "red", "white", "green", "deep", "atomic", "blind", "golden", "iron", "electric",
        "silver", "dead", "dire", "new", "pink", "rolling", "soft", "sonic", "talking", "velvet", "grateful",
        "steely", "thin", "def", "daft", "massive", "simple", "primal", "king", "blast", "heavy", "hot", "cold",
        "dark", "wild", "lucky", "dream", "magic", "mad", "crazy", "young", "savage", "spirit", "flying", "cream",
    };

    private static readonly HashSet<string> Suffixes = new(StringComparer.OrdinalIgnoreCase)
        { "jr", "jr.", "sr", "sr.", "ii", "iii", "iv" };

    /// Det vendte navn, eller null hvis navnet ikke kan være en person (ét ord, "The …", "&", tal …).
    public static string? Reverse(string artist)
    {
        var name = TextFold.TrimSpaces(artist);
        if (name.Length == 0 || SortRules.IsVarious(name)) return null;
        if (name.StartsWith("The ", StringComparison.OrdinalIgnoreCase) || name.StartsWith("A ", StringComparison.Ordinal)) return null;
        if (name.Contains(" - ", StringComparison.Ordinal)) return null; // "Beethoven - Schubert"
        if (name.IndexOfAny(new[] { '&', '+', ',', '/', '(', ')' }) >= 0 || name.Any(char.IsDigit)) return null;
        var words = name.Split(' ', StringSplitOptions.RemoveEmptyEntries).ToList();
        if (words.Any(w => w.Equals("and", StringComparison.OrdinalIgnoreCase) || w.Equals("og", StringComparison.OrdinalIgnoreCase)
                           || w.Equals("feat.", StringComparison.OrdinalIgnoreCase) || w.Equals("with", StringComparison.OrdinalIgnoreCase)))
            return null;

        string suffix = "";
        if (words.Count >= 3 && Suffixes.Contains(words[^1])) { suffix = " " + words[^1]; words.RemoveAt(words.Count - 1); }
        if (words.Count < 2 || words.Count > 3) return null;

        var last = words[^1];
        var first = words.Take(words.Count - 1).ToList();
        // "Ludwig van Beethoven": partiklen bliver hos fornavnene, som i biblioteker.
        return $"{last}, {string.Join(" ", first)}{suffix}";
    }

    /// Gættet: ser navnet ud som en person? (Ingen ord, der typisk betyder et band.)
    public static bool LooksLikePerson(string artist)
    {
        if (Reverse(artist) is null) return false;
        var words = artist.Split(' ', StringSplitOptions.RemoveEmptyEntries);
        return !GroupFirstWords.Contains(words[0]) && !words.Any(w => GroupWords.Contains(w.Trim('.', '!', '?')));
    }

    /// Alle kunstnere i samlingen, der kan vendes, sorteret efter navn. Hver kunstner én gang.
    /// Navnet beholdes præcis som i Discogs, for sorteringsnavnene slås op på det.
    public static List<SurnameCandidate> Candidates(IEnumerable<string> artists) =>
        artists.Distinct(StringComparer.Ordinal)
               .Select(a => Reverse(a) is string r ? new SurnameCandidate(a, r, LooksLikePerson(a)) : null)
               .OfType<SurnameCandidate>()
               .OrderBy(c => c.Artist, StringComparer.CurrentCulture)
               .ToList();

    /// Gemmer brugerens valg i reglerne: afkrydsede får efternavn først (et eget sorteringsnavn,
    /// som brugeren har skrevet, beholdes), de andre mister et vendt navn. Efternavn kræver appens
    /// egne regler, så Discogs' rækkefølge slås fra, når mindst én person er valgt.
    public static SortRules Apply(SortRules rules, IEnumerable<SurnameCandidate> candidates, IReadOnlySet<string> persons)
    {
        var r = rules.Clone();
        foreach (var c in candidates)
        {
            if (persons.Contains(c.Artist))
            {
                if (!r.ArtistOverrides.TryGetValue(c.Artist, out var own) || string.IsNullOrWhiteSpace(own)) r.ArtistOverrides[c.Artist] = c.Surname;
            }
            else if (r.ArtistOverrides.TryGetValue(c.Artist, out var cur) && cur == c.Surname)
            {
                r.ArtistOverrides.Remove(c.Artist);
            }
        }
        if (persons.Count > 0) r.UseDiscogsOrder = false;
        return r;
    }

    /// Er kunstneren allerede sat til efternavn først (et eget sorteringsnavn tæller også)?
    public static bool IsChosen(SortRules rules, SurnameCandidate c) => rules.ArtistOverrides.ContainsKey(c.Artist);
}

public sealed partial class ShelfStore
{
    private const string NotPersonsKey = "surname_not_persons";

    /// Kunstnere, brugeren har sagt ikke er personer (så de ikke foreslås som nye igen).
    public HashSet<string> SurnameNotPersons()
    {
        try { return JsonSerializer.Deserialize<List<string>>(Setting(NotPersonsKey) ?? "[]")?.ToHashSet(StringComparer.Ordinal) ?? new(StringComparer.Ordinal); }
        catch (JsonException) { return new(StringComparer.Ordinal); }
    }

    public void SaveSurnameNotPersons(IEnumerable<string> artists) =>
        SetSetting(NotPersonsKey, JsonSerializer.Serialize(artists.Distinct().OrderBy(a => a, StringComparer.Ordinal).ToList()));
}
