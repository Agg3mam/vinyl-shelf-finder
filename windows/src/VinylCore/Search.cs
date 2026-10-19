using System.Globalization;
using System.Text;

namespace VinylShelfFinder.Core;

// Port af Sources/VinylCore/Search.swift (læs reglerne øverst dér). De to skal give præcis samme rækkefølge;
// fælles checks i VinylCoreChecks og VinylCore.Checks. Længder tælles i Unicode-tegn (runes) som skalarer i Swift.

/// Lokal, hurtig søgning i hele samlingen (plader og sange). Tolererer stavefejl.
/// Sorterer efter en fast rækkefølge af regler (som Algolia/Meilisearch/Typesense), ikke efter en sum af point.
public sealed class SearchIndex
{
    /// Ét felt, klar til søgning: ordene som numre i ordlisten, sammentrukne ord ("acdc") og hele feltet.
    private sealed class Field
    {
        public readonly int[] WordIds;
        /// "AC/DC" → "acdc", "A-ha" → "aha", "R.E.M." → "rem", og hele feltet i ét ord ("okcomputer").
        public readonly int[] Joined;
        public readonly string Full;
        /// Uden en artikel forrest ("The Beatles" → "beatles").
        public readonly string Bare;

        public Field(string text, Vocabulary vocab)
        {
            var w = Words(SpellSymbols(text));
            WordIds = w.Select(vocab.Id).ToArray();
            Full = string.Join(" ", w);
            Bare = w.Length > 1 && Articles.Contains(w[0]) ? string.Join(" ", w.Skip(1)) : Full;
            var j = new List<int>();
            // Kun ord med et skilletegn inde i sig ("AC/DC"); for ren ASCII tjekkes det hurtigt.
            bool ascii = text.All(c => c < 128);
            bool hasInnerMark = !ascii || text.Any(c => !(c == ' ' || (c >= '0' && c <= '9') || (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z')));
            if (hasInnerMark)
                foreach (var part in text.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries))
                {
                    if (part.EnumerateRunes().All(r => Rune.IsLetter(r) || Rune.IsNumber(r))) continue;
                    var pw = Words(part);
                    if (pw.Length > 1) j.Add(vocab.Id(string.Concat(pw)));
                }
            if (w.Length > 1) j.Add(vocab.Id(string.Concat(w)));
            Joined = j.ToArray();
        }
    }

    /// Alle forskellige ord i samlingen.
    private sealed class Vocabulary
    {
        public readonly List<string> Words = new();
        private readonly Dictionary<string, int> _ids = new(StringComparer.Ordinal);
        public int Id(string w)
        {
            if (_ids.TryGetValue(w, out var i)) return i;
            i = Words.Count;
            Words.Add(w); _ids[w] = i;
            return i;
        }
    }

    private sealed record Entry(long Id, Field Artist, Field Title, Field Catalog, Field Label, Field Other,
                                string CompactCatalog, string ReleaseId, long ShelfOrder, (Track Track, Field Field)[] Tracks);

    /// Et søgeresultat. Track er sat, når det er en sang på pladen, der passer (ikke pladen selv).
    public sealed record Hit(long Id, Track? Track);

    private readonly List<Entry> _entries;
    private readonly string[] _vocab;
    private readonly int[][] _vocabChars;
    private readonly bool[] _vocabHasDigit;

    public SearchIndex(Library library)
    {
        var v = new Vocabulary();
        _entries = library.AllItems.Select(it =>
        {
            var r = it.Release;
            return new Entry(
                it.Id,
                new Field(r.Artist, v),
                new Field(r.Title, v),
                new Field(r.CatalogNumber ?? "", v),
                new Field(r.Label ?? "", v),
                new Field(string.Join(" ", r.Year?.ToString(CultureInfo.InvariantCulture) ?? "", r.Format ?? ""), v),
                Normalize(r.CatalogNumber ?? "").Replace(" ", ""),
                r.Id.ToString(CultureInfo.InvariantCulture),
                library.GlobalIndex.TryGetValue(it.Id, out var g) ? g : long.MaxValue,
                r.Tracks.Select(t => (t, new Field(t.Title, v))).ToArray());
        }).ToList();
        _vocab = v.Words.ToArray();
        _vocabChars = _vocab.Select(Runes).ToArray();
        _vocabHasDigit = _vocab.Select(HasDigit).ToArray();
    }

    // MARK: Normalisering (bruges også af iMusic-matcheren – må ikke ændres uden at tjekke den)

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

    private static int[] Runes(string s) => s.EnumerateRunes().Select(r => r.Value).ToArray();

    /// Et tal 0-9 (samme regel på Mac).
    private static bool HasDigit(string s) => s.Any(c => c >= '0' && c <= '9');

    /// Titler af bare tegn ("÷", "★") kan ellers ikke findes: tegnet skrives også som ord.
    private static string SpellSymbols(string s)
    {
        if (!s.Any(SymbolNames.ContainsKey)) return s;
        return s + " " + string.Join(" ", s.Where(SymbolNames.ContainsKey).Select(c => SymbolNames[c]));
    }
    private static readonly Dictionary<char, string> SymbolNames = new()
    {
        ['÷'] = "divide", ['×'] = "multiply", ['+'] = "plus", ['★'] = "blackstar", ['='] = "equals", ['−'] = "minus",
    };

    /// Artikler, der ikke behøver at stå i søgningen ("beatles" finder "The Beatles", og omvendt).
    private static readonly HashSet<string> Articles = new(StringComparer.Ordinal)
        { "the", "a", "an", "de", "det", "den", "en", "et", "le", "la", "les", "die", "der", "das" };

    private static readonly string[] Romans =
        { "i", "ii", "iii", "iv", "v", "vi", "vii", "viii", "ix", "x", "xi", "xii", "xiii", "xiv", "xv", "xvi", "xvii", "xviii", "xix", "xx" };

    /// Ord, der betyder det samme: romertal og tal, forkortelser, "og"/"and" og "aa"/"oe"/"ue" for å/ø/ü.
    private static List<string> Synonyms(string t)
    {
        if (t.All(char.IsAsciiDigit) && int.TryParse(t, NumberStyles.None, CultureInfo.InvariantCulture, out var n) && n >= 1 && n <= Romans.Length)
            return new() { Romans[n - 1] };
        int ri = Array.IndexOf(Romans, t);
        if (ri >= 0) return new() { (ri + 1).ToString(CultureInfo.InvariantCulture) };
        switch (t)
        {
            case "pt": return new() { "part" };
            case "part": return new() { "pt" };
            case "vol": return new() { "volume" };
            case "volume": return new() { "vol" };
            case "st": return new() { "saint" };
            case "saint": return new() { "st" };
            case "og": return new() { "and" };
            case "and": return new() { "og" };
        }
        var alt = new List<string>();
        foreach (var (from, to) in new[] { ("aa", "a"), ("oe", "o"), ("ue", "u") })
            if (t.Contains(from, StringComparison.Ordinal)) alt.Add(t.Replace(from, to, StringComparison.Ordinal));
        return alt;
    }

    // MARK: Søgning

    public List<long> Search(string query, int limit = 60) => Hits(query, limit).Select(h => h.Id).ToList();

    /// Som Search, men fortæller også, hvilken sang der passede, når det er en sang og ikke pladen.
    public List<Hit> Hits(string query, int limit = 60)
    {
        // Højst 10 ord: en lang indsat tekst må ikke få appen til at hænge.
        var tokens = Words(SpellSymbols(query)).Take(10).ToArray();
        if (tokens.Length == 0) return new();
        var found = Rank(tokens, false, 0);
        // Intet fundet: prøv igen, hvor alle ord må være påbegyndte, og ellers hvor ét (eller to) ord må mangle.
        if (found.Count == 0 && tokens.Length > 1) found = Rank(tokens, true, 0);
        if (found.Count == 0 && tokens.Length > 1) found = Rank(tokens, true, tokens.Length >= 5 ? 2 : 1);
        return found.Take(Math.Max(0, limit)).Select(f => new Hit(f.Id, f.Track)).ToList();
    }

    private static int Compare(long[] a, long[] b)
    {
        for (int i = 0; i < a.Length; i++)
            if (a[i] != b[i]) return a[i] < b[i] ? -1 : 1;
        return 0;
    }

    private List<(long Id, Track? Track, long[] Key)> Rank(string[] tokens, bool allPrefix, int mayMiss)
    {
        var q = new Query(tokens, allPrefix, mayMiss, _vocab, _vocabChars, _vocabHasDigit);
        var outList = new List<(long Id, Track? Track, long[] Key)>();
        foreach (var e in _entries)
        {
            (Track? Track, long[] Key)? best = null;
            // Kunstneren regnes ud én gang og bruges både til pladen og alle dens sange.
            var artist = q.Bests(e.Artist);
            if (q.AlbumKey(e, artist) is long[] k) best = (null, k);
            foreach (var (track, field) in e.Tracks)
            {
                var song = q.Bests(field);
                if (song.All(b => b is null)) continue; // ingen af ordene i sangens titel
                if (q.SongKey(e, field, artist, song) is long[] sk && (best is null || Compare(sk, best.Value.Key) < 0)) best = (track, sk);
            }
            if (best is { } b2) outList.Add((e.Id, b2.Track, b2.Key));
        }
        outList.Sort((a, b) => Compare(a.Key, b.Key));
        return outList;
    }

    /// Én søgning: ordene og en hukommelse for ord, der allerede er sammenlignet.
    private sealed class Query
    {
        private readonly string[] _tokens;
        private readonly string _phrase, _barePhrase, _compact;
        private readonly bool _allPrefix;
        private readonly int _mayMiss;
        private readonly bool[] _optional;
        private readonly string[] _vocab;
        private readonly int[][] _vocabChars, _tokenChars;
        private readonly bool[] _vocabHasDigit;
        private readonly List<string>[] _tokenSynonyms;
        private readonly int[] _tokenBudget;
        private readonly EditDistanceBuffer _dist = new();
        /// Pr. søgeord og ord i ordlisten: -2 ikke regnet ud, -1 passer ikke, ellers kodet Match.
        private readonly short[][] _cache;

        public readonly record struct Match(int Cost, bool Prefix, bool Synonym = false, bool FirstLetter = false);
        public readonly record struct Best(Match Match, int Position);

        public Query(string[] tokens, bool allPrefix, int mayMiss, string[] vocab, int[][] vocabChars, bool[] vocabHasDigit)
        {
            _vocab = vocab; _vocabChars = vocabChars; _vocabHasDigit = vocabHasDigit;
            _tokenSynonyms = tokens.Select(Synonyms).ToArray();
            _tokenBudget = tokens.Select(Budget).ToArray();
            _tokenChars = tokens.Select(Runes).ToArray();
            _tokens = tokens; _allPrefix = allPrefix; _mayMiss = mayMiss;
            _phrase = string.Join(" ", tokens);
            _barePhrase = tokens.Length > 1 && Articles.Contains(tokens[0]) ? string.Join(" ", tokens.Skip(1)) : _phrase;
            _compact = string.Concat(tokens);
            _optional = tokens.Select((t, i) => tokens.Length > 1 && i < tokens.Length - 1 && Articles.Contains(t)).ToArray();
            _cache = tokens.Select(_ => Enumerable.Repeat((short)-2, vocab.Length).ToArray()).ToArray();
        }

        private static bool ContainsRun(int[] hay, int[] needle)
        {
            if (needle.Length == 0 || needle.Length > hay.Length) return false;
            for (int start = 0; start <= hay.Length - needle.Length; start++)
            {
                if (hay[start] != needle[0]) continue;
                bool ok = true;
                for (int k = 1; k < needle.Length; k++) if (hay[start + k] != needle[k]) { ok = false; break; }
                if (ok) return true;
            }
            return false;
        }

        /// Hvor mange stavefejl et ord må have (længder i Unicode-tegn).
        private static int Budget(string t)
        {
            if (HasDigit(t)) return 0;
            int n = t.EnumerateRunes().Count();
            return n >= 6 ? 2 : n >= 4 ? 1 : 0;
        }

        private Match? MatchOf(int i, int id)
        {
            short c = _cache[i][id];
            if (c == -2)
            {
                var m = ComputeMatch(i, id);
                c = m is Match x ? (short)(x.Cost * 8 + (x.Prefix ? 4 : 0) + (x.Synonym ? 2 : 0) + (x.FirstLetter ? 1 : 0)) : (short)-1;
                _cache[i][id] = c;
            }
            return c < 0 ? null : new Match(c / 8, (c & 4) != 0, (c & 2) != 0, (c & 1) != 0);
        }

        private Match? ComputeMatch(int i, int id)
        {
            string t = _tokens[i], w = _vocab[id];
            int[] tc = _tokenChars[i], wc = _vocabChars[id];
            bool last = _allPrefix || i == _tokens.Length - 1;
            if (w == t) return new Match(0, false);
            // Et enkelt bogstav, der stadig skrives, er ikke et romertal ("back i" → Back In Black, ikke "1").
            if (!(last && tc.Length == 1 && !HasDigit(t)) && _tokenSynonyms[i].Contains(w)) return new Match(0, false, Synonym: true);
            if (last && wc.Length > tc.Length && wc.AsSpan(0, tc.Length).SequenceEqual(tc)) return new Match(0, true);
            int budget = _tokenBudget[i];
            if (budget > 0 && !_vocabHasDigit[id])
            {
                int first = tc.Length > 0 && wc.Length > 0 && tc[0] == wc[0] ? 0 : 1;
                if (Math.Abs(wc.Length - tc.Length) <= budget)
                {
                    int d = _dist.Distance(tc, tc.Length, wc, wc.Length, budget) + first;
                    if (d <= budget) return new Match(d - first, false, FirstLetter: first == 1);
                }
                if (last && wc.Length > tc.Length)
                {
                    int d = _dist.Distance(tc, tc.Length, wc, tc.Length, budget) + first;
                    if (d <= budget) return new Match(d - first, true, FirstLetter: first == 1);
                }
            }
            // Sidste udvej: ordet står inde i et længere ord (danske sammensatte ord).
            if (tc.Length >= 4 && wc.Length > tc.Length && ContainsRun(wc, tc)) return new Match(2, true);
            return null;
        }

        /// Bedste træf i feltet for hvert søgeord (null = ordet står ikke i feltet).
        public Best?[] Bests(Field f, bool synonyms = true)
        {
            var result = new Best?[_tokens.Length];
            for (int i = 0; i < _tokens.Length; i++)
            {
                Best? best = null;
                void Consider(Match? mm, int pos)
                {
                    if (mm is not Match m || (!synonyms && m.Synonym)) return;
                    if (best is Best b && Cmp((b.Match.Cost, b.Match.Prefix ? 1 : 0, b.Position), (m.Cost, m.Prefix ? 1 : 0, pos)) <= 0) return;
                    best = new Best(m, pos);
                }
                for (int p = 0; p < f.WordIds.Length; p++) Consider(MatchOf(i, f.WordIds[p]), p);
                // Sammentrukne ord kun helt eller påbegyndt – ikke med stavefejl ("imagine" ≠ "imemine").
                foreach (var w in f.Joined) if (MatchOf(i, w) is Match m && m.Cost == 0) Consider(m, 0);
                result[i] = best;
            }
            return result;
        }

        private static int Cmp((int, int, int) a, (int, int, int) b) =>
            a.Item1 != b.Item1 ? a.Item1.CompareTo(b.Item1) : a.Item2 != b.Item2 ? a.Item2.CompareTo(b.Item2) : a.Item3.CompareTo(b.Item3);

        /// Fælles for plader og sange. exactness regnes kun ud, når pladen/sangen faktisk passer.
        private long[]? Key((Best?[] Bests, int Rank)[] fields, int entity, Func<(int Level, int Length)> exactness,
                            int? requireRank, long shelf, long id)
        {
            bool allInArtist = true, hitRequired = requireRank is null;
            int realMatched = 0, matched = 0, typos = 0, firstLetters = 0, lastPrefix = 0, bestRank = int.MaxValue, worstRank = 0, firstPos = int.MaxValue, missing = 0;
            var placed = new (int Field, int Pos)?[_tokens.Length];
            for (int i = 0; i < _tokens.Length; i++)
            {
                (Match Match, int Position, int Field, int Rank)? best = null;
                for (int fi = 0; fi < fields.Length; fi++)
                {
                    if (fields[fi].Bests[i] is not Best b) continue;
                    if (best is { } cur)
                    {
                        var a = (cur.Match.Cost, cur.Match.Prefix ? 1 : 0, cur.Rank, cur.Position);
                        var bb = (b.Match.Cost, b.Match.Prefix ? 1 : 0, fields[fi].Rank, b.Position);
                        if (a.CompareTo(bb) <= 0) continue;
                    }
                    best = (b.Match, b.Position, fi, fields[fi].Rank);
                }
                if (best is not { } bt)
                {
                    if (_optional[i]) continue;
                    if (++missing > _mayMiss) return null;
                    continue;
                }
                matched++;
                if (!_optional[i]) realMatched++;
                typos += bt.Match.Cost;
                if (bt.Match.FirstLetter) firstLetters++;
                if (bt.Match.Prefix) lastPrefix = 1;
                bestRank = Math.Min(bestRank, bt.Rank);
                worstRank = Math.Max(worstRank, bt.Rank);
                if (bt.Field != 0) allInArtist = false;
                firstPos = Math.Min(firstPos, bt.Position);
                if (bt.Rank == requireRank) hitRequired = true;
                placed[i] = (bt.Field, bt.Position);
            }
            // Mindst ét rigtigt ord (ikke kun en artikel som "the") skal passe.
            if (!hitRequired || realMatched == 0) return null;
            int adjacent = 0;
            for (int i = 1; i < placed.Length; i++)
            {
                if (placed[i - 1] is not { } a || placed[i] is not { } b) continue;
                if (a.Field == b.Field ? b.Pos == a.Pos + 1 : (a.Field == 0 && b.Field == 1)) adjacent++;
            }
            var ex = exactness();
            int tier = entity == 0 ? (worstRank > 0 ? 5 : lastPrefix == 0 ? 0 : 2) : (ex.Level == 0 ? 1 : lastPrefix == 0 ? 3 : 4);
            int position = entity == 0 && (ex.Level <= 1 || allInArtist) ? 0 : firstPos;
            return new long[] { -matched, typos, tier, firstLetters, lastPrefix, ex.Level, ex.Length, -adjacent, bestRank, position, shelf, id };
        }

        private bool EqualsField(Field f) => f.Full == _phrase || f.Bare == _barePhrase || f.Full == _barePhrase;
        private bool Starts(Field f) => f.Full.StartsWith(_phrase, StringComparison.Ordinal) || f.Bare.StartsWith(_barePhrase, StringComparison.Ordinal);
        private bool ContainsPhrase(Field f) => $" {f.Full} ".Contains($" {_barePhrase}", StringComparison.Ordinal);
        private bool OneLetter => _phrase.EnumerateRunes().Count() == 1;

        public long[]? AlbumKey(Entry e, Best?[] artist)
        {
            // Katalognummer med eller uden mellemrum – kun når søgningen ligner et katalognummer (har et tal).
            if (_compact.EnumerateRunes().Count() >= 3 && HasDigit(_compact) && e.CompactCatalog.Length > 0
                && e.CompactCatalog.StartsWith(_compact, StringComparison.Ordinal))
            {
                int exact = e.CompactCatalog == _compact ? 0 : 1;
                return new long[] { -_tokens.Length, 0, exact == 0 ? 0 : 2, 0, exact, exact, 0, 0, 2, 0, e.ShelfOrder, e.Id };
            }
            if (_tokens.Length == 1 && _tokens[0] == e.ReleaseId)
                return new long[] { -1, 0, 0, 0, 0, 0, 0, 0, 0, 0, e.ShelfOrder, e.Id };
            (int, int) Exactness()
            {
                if (EqualsField(e.Title) || $"{e.Artist.Bare} {e.Title.Bare}" == _barePhrase || $"{e.Artist.Full} {e.Title.Full}" == _phrase) return (0, 0);
                if (EqualsField(e.Artist)) return (1, 0);
                if (Starts(e.Title)) return (2, 0);
                if (Starts(e.Artist)) return (3, e.Artist.WordIds.Length);
                if (ContainsPhrase(e.Title) || ContainsPhrase(e.Artist)) return (4, 0);
                return (5, 0);
            }
            // Ét bogstav: kun når kunstner eller titel begynder med det (ikke katalognummer eller pladeselskab).
            if (OneLetter)
            {
                if (!Starts(e.Artist) && !Starts(e.Title)) return null;
                return Key(new[] { (artist, 0), (Bests(e.Title), 0) }, 0, Exactness, null, e.ShelfOrder, e.Id);
            }
            return Key(new[] { (artist, 0), (Bests(e.Title), 0), (Bests(e.Catalog, false), 2), (Bests(e.Label, false), 3), (Bests(e.Other, false), 4) },
                       0, Exactness, null, e.ShelfOrder, e.Id);
        }

        /// En sang: alle ord i sangens titel eller kunstneren, og mindst ét i sangens titel.
        public long[]? SongKey(Entry e, Field song, Best?[] artist, Best?[] songBests)
        {
            if (OneLetter && !(song.Full.StartsWith(_phrase, StringComparison.Ordinal) || song.Bare.StartsWith(_barePhrase, StringComparison.Ordinal))) return null;
            (int, int) Exactness() =>
                song.Full == _phrase || song.Bare == _barePhrase ? (0, 0)
                : song.Full.StartsWith(_phrase, StringComparison.Ordinal) ? (2, 0)
                : $" {song.Full} ".Contains($" {_barePhrase}", StringComparison.Ordinal) ? (4, 0) : (5, 0);
            return Key(new[] { (artist, 0), (songBests, 1) }, 1, Exactness, 1, e.ShelfOrder, e.Id);
        }
    }

    /// Damerau-Levenshtein (optimal string alignment) med tidlig afbrydelse. Bruges også af iMusic-matcheren.
    /// Returnerer max + 1, så snart afstanden er større end max.
    public static int EditDistance(string a, string b, int max)
    {
        var x = Runes(a); var y = Runes(b);
        return new EditDistanceBuffer().Distance(x, x.Length, y, y.Length, max);
    }

    /// Genbruger sine rækker, så en søgning ikke laver nye lister for hvert ord.
    private sealed class EditDistanceBuffer
    {
        private int[] _prev2 = Array.Empty<int>(), _prev = Array.Empty<int>(), _cur = Array.Empty<int>();

        /// Afstanden mellem de første xn tegn i x og de første yn tegn i y.
        public int Distance(int[] x, int xn, int[] y, int yn, int limit)
        {
            if (Math.Abs(xn - yn) > limit) return limit + 1;
            if (xn == 0) return yn;
            if (yn == 0) return xn;
            int n = yn + 1;
            if (_prev.Length < n) { _prev2 = new int[n]; _prev = new int[n]; _cur = new int[n]; }
            for (int j = 0; j < n; j++) { _prev[j] = j; _prev2[j] = 0; }
            for (int i = 1; i <= xn; i++)
            {
                _cur[0] = i;
                int rowMin = _cur[0];
                for (int j = 1; j <= yn; j++)
                {
                    int cost = x[i - 1] == y[j - 1] ? 0 : 1;
                    _cur[j] = Math.Min(Math.Min(_prev[j] + 1, _cur[j - 1] + 1), _prev[j - 1] + cost);
                    if (i > 1 && j > 1 && x[i - 1] == y[j - 2] && x[i - 2] == y[j - 1])
                        _cur[j] = Math.Min(_cur[j], _prev2[j - 2] + 1);
                    rowMin = Math.Min(rowMin, _cur[j]);
                }
                if (rowMin > limit) return limit + 1;
                (_prev2, _prev, _cur) = (_prev, _cur, _prev2);
            }
            return _prev[yn];
        }
    }
}
