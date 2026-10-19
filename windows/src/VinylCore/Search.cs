using System.Globalization;
using System.Text;

namespace VinylShelfFinder.Core;

// Port af Sources/VinylCore/Search.swift.

/// Lokal, hurtig søgning i hele samlingen. Tolererer små stavefejl.
public sealed class SearchIndex
{
    private sealed record Entry(
        long Id,
        string[] ArtistWords,
        string[] TitleWords,
        string[] OtherWords,      // label, format, år
        string[] CatalogWords,
        string CompactCatalog,    // "shvl804"
        string CompactArtist,     // "acdc"
        string ReleaseId,
        string Full,
        /// Plads i reolens rækkefølge (sektion, position). Uplacerede plader får int.MaxValue.
        int ShelfOrder,
        /// Sangene på udgivelsen (tom, indtil sanglisten er hentet).
        (Track Track, string[] Words, string Full)[] Tracks);

    /// Et søgeresultat. Track er sat, når det er en sang på pladen, der passer (ikke pladen selv).
    public sealed record Hit(long Id, Track? Track);

    private readonly List<Entry> _entries;

    public SearchIndex(Library library)
    {
        _entries = library.AllItems.Select(it =>
        {
            var r = it.Release;
            var cat = Normalize(r.CatalogNumber ?? "");
            return new Entry(
                it.Id,
                Words(r.Artist),
                Words(r.Title),
                Words(string.Join(" ", r.Label ?? "", r.Year?.ToString(CultureInfo.InvariantCulture) ?? "", r.Format ?? "")),
                Words(cat),
                cat.Replace(" ", ""),
                Normalize(r.Artist).Replace(" ", ""),
                r.Id.ToString(CultureInfo.InvariantCulture),
                Normalize($"{r.Artist} {r.Title} {r.Label ?? ""} {r.CatalogNumber ?? ""}"),
                library.GlobalIndex.TryGetValue(it.Id, out var g) ? g : int.MaxValue,
                r.Tracks.Select(t => (t, Words(t.Title), Normalize(t.Title))).ToArray());
        }).ToList();
    }

    /// Små bogstaver, æ→ae, ø→o, ß→ss, &→and, accenter fjernet; alt andet end bogstaver og tal
    /// bliver til ét mellemrum. Bruges også af iMusic-matcheren.
    public static string Normalize(string s)
    {
        var folded = TextFold.Fold(s.ToLowerInvariant()
            .Replace("æ", "ae")
            .Replace("ø", "o")
            .Replace("ß", "ss")
            .Replace("&", " and "));
        var mapped = new StringBuilder(folded.Length);
        foreach (var r in folded.EnumerateRunes())
            mapped.Append(TextFold.IsAlphanumeric(r) ? r.ToString() : " ");
        return string.Join(" ", mapped.ToString().Split(' ', StringSplitOptions.RemoveEmptyEntries));
    }

    public static string[] Words(string s) => Normalize(s).Split(' ', StringSplitOptions.RemoveEmptyEntries);

    /// Returnerer kopi-id'er sorteret efter relevans. Ved samme relevans kommer pladerne i
    /// reolens rækkefølge (sektion, derefter position), og uplacerede plader til sidst.
    public List<long> Search(string query, int limit = 60) => Hits(query, limit).Select(h => h.Id).ToList();

    /// Som Search, men fortæller også, hvilken sang der passede, når det er en sang og ikke pladen.
    /// En sang findes på sin titel, evt. sammen med kunstneren ("floyd wish you were here").
    public List<Hit> Hits(string query, int limit = 60)
    {
        var tokens = Words(query).Where(t => t.Length > 0).ToArray();
        if (tokens.Length == 0) return new();
        var phrase = string.Join(" ", tokens);
        var compactQuery = string.Concat(tokens);

        var scored = new List<(long Id, int Score, int Order, Track? Track)>();
        foreach (var e in _entries)
        {
            var song = BestTrack(tokens, phrase, e);
            int total = 0;
            bool allMatched = true;
            foreach (var t in tokens)
            {
                int s = Score(t, e);
                if (s == 0) { allMatched = false; break; }
                total += s;
            }
            if (!allMatched)
            {
                // Katalognummer skrevet med/uden mellemrum: "shvl 804" / "shvl804".
                if (compactQuery.Length >= 3 && e.CompactCatalog.Contains(compactQuery, StringComparison.Ordinal))
                    scored.Add((e.Id, 25, e.ShelfOrder, null));
                else if (tokens.Length == 1 && tokens[0] == e.ReleaseId)
                    scored.Add((e.Id, 100, e.ShelfOrder, null));
                else if (song is var (st, ss))
                    scored.Add((e.Id, ss - SongPenalty, e.ShelfOrder, st));
                continue;
            }
            if (e.Full.Contains(phrase, StringComparison.Ordinal)) total += 6;
            // Et album, der hedder præcis det, man søger på ("blue" → Joni Mitchell – Blue), kommer først.
            if (string.Join(" ", e.TitleWords) == phrase) total += 4;
            if (tokens.Length == 1 && tokens[0] == e.ReleaseId) total += 100;
            // Passer en sang bedre end pladen (fx en sang med samme navn som en kunstner), vises sangen.
            if (song is var (t2, s2) && s2 - SongPenalty > total) scored.Add((e.Id, s2 - SongPenalty, e.ShelfOrder, t2));
            else scored.Add((e.Id, total, e.ShelfOrder, null));
        }
        return scored.OrderByDescending(x => x.Score).ThenBy(x => x.Order).ThenBy(x => x.Id)
                     .Take(Math.Max(0, limit)).Select(x => new Hit(x.Id, x.Track)).ToList();
    }

    /// Et træf på en sang tæller mindre end samme træf på pladen, så albummer kommer før sange
    /// ("blue": albummet Blue og Kind of Blue før alle sangene med "blue" i titlen).
    private const int SongPenalty = 10;

    /// Den sang på pladen, der passer bedst: hvert ord i søgningen skal stå i sangens titel eller kunstneren,
    /// og mindst ét i sangens titel. Lidt lavere vægt end pladens egen titel, så albummet vinder ved lighed.
    private static (Track Track, int Score)? BestTrack(string[] tokens, string phrase, Entry e)
    {
        (Track Track, int Score)? best = null;
        foreach (var t in e.Tracks)
        {
            int total = 0;
            bool inTitle = false;
            foreach (var tok in tokens)
            {
                int inTrack = WordScore(tok, t.Words, 3);
                int s = Math.Max(inTrack, WordScore(tok, e.ArtistWords, 2));
                if (s == 0) { total = 0; break; }
                if (inTrack > 0) inTitle = true;
                total += s;
            }
            if (total == 0 || !inTitle) continue;
            if (t.Full.Contains(phrase, StringComparison.Ordinal)) total += 6;
            if (t.Full == phrase) total += 4;
            if (best is null || total > best.Value.Score) best = (t.Track, total);
        }
        return best;
    }

    /// Ordets bedste træf blandt words (også med én-to stavefejl, som ellers i søgningen).
    private static int WordScore(string t, string[] words, int weight)
    {
        int best = 0;
        foreach (var w in words)
        {
            if (w == t) best = Math.Max(best, 10 * weight);
            else if (w.StartsWith(t, StringComparison.Ordinal)) best = Math.Max(best, 7 * weight);
            else if (t.Length >= 3 && w.Contains(t, StringComparison.Ordinal)) best = Math.Max(best, 4 * weight);
        }
        if (best > 0 || t.Length < 4) return best;
        int maxDist = t.Length >= 7 ? 2 : 1;
        foreach (var w in words)
        {
            if (Math.Abs(w.Length - t.Length) <= maxDist && EditDistance(t, w, maxDist) <= maxDist) return 5;
            if (w.Length > t.Length && EditDistance(t, w[..t.Length], maxDist) <= maxDist) return 3;
        }
        return 0;
    }

    private static int Score(string t, Entry e)
    {
        int best = 0;
        void Consider(string[] words, int weight)
        {
            foreach (var w in words)
            {
                if (w == t) best = Math.Max(best, 10 * weight);
                else if (w.StartsWith(t, StringComparison.Ordinal)) best = Math.Max(best, 7 * weight);
                else if (t.Length >= 3 && w.Contains(t, StringComparison.Ordinal)) best = Math.Max(best, 4 * weight);
            }
        }
        Consider(e.ArtistWords, 3);
        Consider(e.TitleWords, 3);
        Consider(e.CatalogWords, 2);
        Consider(e.OtherWords, 1);
        if (t == e.ReleaseId) best = Math.Max(best, 30);
        if (best > 0) return best;
        if (t.Length >= 3 && e.CompactCatalog.Contains(t, StringComparison.Ordinal)) return 6;
        // "acdc" → "AC/DC", "aha" → "A-ha"
        if (t.Length >= 3 && e.CompactArtist.StartsWith(t, StringComparison.Ordinal)) return 18;

        // Stavefejl: tillad 1 fejl (≥4 tegn) eller 2 fejl (≥7 tegn), også mod ord-præfikser.
        if (t.Length < 4) return 0;
        int maxDist = t.Length >= 7 ? 2 : 1;
        foreach (var w in e.ArtistWords.Concat(e.TitleWords).Concat(e.CatalogWords).Concat(e.OtherWords))
        {
            if (Math.Abs(w.Length - t.Length) <= maxDist && EditDistance(t, w, maxDist) <= maxDist) return 5;
            if (w.Length > t.Length && EditDistance(t, w[..t.Length], maxDist) <= maxDist) return 3;
        }
        return 0;
    }

    /// Damerau-Levenshtein (optimal string alignment) med tidlig afbrydelse.
    /// Returnerer max + 1, så snart afstanden er større end max.
    public static int EditDistance(string a, string b, int max)
    {
        int limit = max;
        if (Math.Abs(a.Length - b.Length) > limit) return limit + 1;
        if (a.Length == 0) return b.Length;
        if (b.Length == 0) return a.Length;
        var prev2 = new int[b.Length + 1];
        var prev = new int[b.Length + 1];
        var cur = new int[b.Length + 1];
        for (int j = 0; j <= b.Length; j++) prev[j] = j;
        for (int i = 1; i <= a.Length; i++)
        {
            cur[0] = i;
            int rowMin = cur[0];
            for (int j = 1; j <= b.Length; j++)
            {
                int cost = a[i - 1] == b[j - 1] ? 0 : 1;
                cur[j] = Math.Min(Math.Min(prev[j] + 1, cur[j - 1] + 1), prev[j - 1] + cost);
                if (i > 1 && j > 1 && a[i - 1] == b[j - 2] && a[i - 2] == b[j - 1])
                    cur[j] = Math.Min(cur[j], prev2[j - 2] + 1);
                rowMin = Math.Min(rowMin, cur[j]);
            }
            if (rowMin > limit) return limit + 1;
            (prev2, prev, cur) = (prev, cur, prev2);
        }
        return prev[b.Length];
    }
}
