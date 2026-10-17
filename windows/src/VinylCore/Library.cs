namespace VinylShelfFinder.Core;

// Port af Sources/VinylCore/Library.swift.

/// Naboer til en plade i reolen (se Library.NeighborsOf).
public sealed record Neighbors(
    RecordItem Target,
    Location? Location,
    /// Fysisk plads i sektionen (1-baseret), talt blandt de plader, der står i reolen.
    /// Er målpladen selv ude, er det den plads, den får, når den sættes tilbage.
    int? Position,
    /// Antal plader i sektionen, der står i reolen – plus målpladen selv, hvis den er ude.
    int SectionCount,
    /// Nærmeste først. Kun plader der faktisk står i reolen.
    IReadOnlyList<RecordItem> Before,
    IReadOnlyList<RecordItem> After,
    /// Plader mellem target og referencerne, som midlertidigt er væk (udlånt osv.).
    IReadOnlyList<RecordItem> AbsentBetweenBefore,
    IReadOnlyList<RecordItem> AbsentBetweenAfter,
    /// true hvis der ikke er flere plader før/efter i sektionen.
    bool ReachedSectionStart,
    bool ReachedSectionEnd,
    /// Ved sektionsstart: forrige sektion og dens sidste plade.
    (Location Location, RecordItem? Last)? PreviousSection,
    /// Ved sektionsslut: næste sektion og dens første plade.
    (Location Location, RecordItem? First)? NextSection)
{
    public bool IsPlaced => Location is not null;
}

public enum ReferenceSide { Before, After, SectionStart, SectionEnd }

public sealed record Reference(ReferenceSide Side, RecordItem? Item, string Reason);

public sealed record ReferenceAdvice(
    Reference Primary,
    Reference? Secondary,
    /// Pladens plads i en række af samme kunstner, når den står yderst i rækken,
    /// fx "Der står 3 Genesis-plader i træk, og din plade er den længst til venstre."
    /// null når pladen står midt i rækken – så står tælleinstruktionen i Primary.Reason,
    /// så positionen ikke gentages.
    string? ArtistBlockHint,
    /// Kort: "Plade 14 af 15 fra venstre" (Find) eller "Plads 14 af 15 fra venstre"
    /// (sæt tilbage). Fysiske tal: kun plader i reolen tælles, plus pladen selv.
    string PlacementHint,
    /// Ved sektionens kant: hvad der står på den anden side af kanten, fx
    /// "Næste sektion (1B) begynder med Dire Straits – Brothers In Arms." Ellers null.
    string? SectionEdgeHint);

public sealed record PlacementSuggestion(
    long LocationId,
    /// 0-baseret indeks i sektionen, hvor pladen skal indsættes.
    int Index,
    long? Before,
    long? After);

/// Et uforanderligt øjebliksbillede af hele samlingen, bygget fra databasen.
/// Al navigation (naboer, forslag, sektioner) beregnes herfra – previous/next
/// gemmes aldrig, de udledes af den fysiske rækkefølge.
public sealed class Library
{
    public IReadOnlyDictionary<int, Release> Releases { get; }
    public IReadOnlyDictionary<long, Copy> Copies { get; }
    /// Sektioner i fysisk rækkefølge.
    public IReadOnlyList<Location> Locations { get; }
    /// Sektion → kopier i fysisk rækkefølge (venstre mod højre).
    public IReadOnlyDictionary<long, IReadOnlyList<long>> Sections { get; }
    /// Alle placerede kopier i global fysisk rækkefølge.
    public IReadOnlyList<long> GlobalOrder { get; }
    public IReadOnlyDictionary<long, int> GlobalIndex { get; }
    public IReadOnlyDictionary<long, long> LocationOfCopy { get; }
    public IReadOnlyDictionary<long, int> IndexInSection { get; }
    /// Kopier uden fysisk placering (typisk nye fra Discogs).
    public IReadOnlyList<long> Unplaced { get; }

    /// Plader eller cd'er. Styrer ordene i Find-teksterne ("din plade" / "din cd").
    public Medium Medium { get; }

    public Library(IReadOnlyDictionary<int, Release> releases, IReadOnlyDictionary<long, Copy> copies,
                   IEnumerable<Location> locations, IEnumerable<(long CopyId, long LocationId, int Position)> placements,
                   Medium medium = Medium.Vinyl)
    {
        Medium = medium;
        Releases = releases;
        Copies = copies;
        var locs = locations.OrderBy(l => l.SortIndex).ThenBy(l => l.Id).ToList();
        Locations = locs;

        var bySection = new Dictionary<long, List<(int Position, long CopyId)>>();
        foreach (var p in placements)
        {
            if (!bySection.TryGetValue(p.LocationId, out var list)) bySection[p.LocationId] = list = new();
            list.Add((p.Position, p.CopyId));
        }
        var sections = new Dictionary<long, IReadOnlyList<long>>();
        var locOf = new Dictionary<long, long>();
        var idxIn = new Dictionary<long, int>();
        var global = new List<long>();
        foreach (var loc in locs)
        {
            var ids = (bySection.TryGetValue(loc.Id, out var l) ? l : new()).OrderBy(x => x.Position).Select(x => x.CopyId).ToList();
            sections[loc.Id] = ids;
            for (int i = 0; i < ids.Count; i++) { locOf[ids[i]] = loc.Id; idxIn[ids[i]] = i; }
            global.AddRange(ids);
        }
        Sections = sections;
        LocationOfCopy = locOf;
        IndexInSection = idxIn;
        GlobalOrder = global;
        var gi = new Dictionary<long, int>();
        for (int i = 0; i < global.Count; i++) gi[global[i]] = i;
        GlobalIndex = gi;
        Unplaced = copies.Keys.Where(k => !locOf.ContainsKey(k)).OrderBy(k => k).ToList();
    }

    public static Library Empty { get; } = new(new Dictionary<int, Release>(), new Dictionary<long, Copy>(),
                                                Array.Empty<Location>(), Array.Empty<(long, long, int)>());

    public RecordItem? Item(long copyId) =>
        Copies.TryGetValue(copyId, out var c) && Releases.TryGetValue(c.ReleaseId, out var r) ? new RecordItem(c, r) : null;

    public List<RecordItem> AllItems => Copies.Keys.Select(Item).OfType<RecordItem>().ToList();

    public Location? LocationById(long? id) => id is long i ? Locations.FirstOrDefault(l => l.Id == i) : null;

    public Location? LocationOf(long copyId) => LocationOfCopy.TryGetValue(copyId, out var l) ? LocationById(l) : null;

    public List<RecordItem> ItemsIn(long locationId) => SectionIds(locationId).Select(Item).OfType<RecordItem>().ToList();

    public List<int> Shelves => Locations.Select(l => l.Shelf).Distinct().OrderBy(s => s).ToList();

    private IReadOnlyList<long> SectionIds(long locationId) =>
        Sections.TryGetValue(locationId, out var ids) ? ids : Array.Empty<long>();

    // MARK: Fysisk nummerering

    // En plade, der er ude af reolen (på væggen, udlånt, opbevaret, mangler), beholder sin
    // plads i placements, men tæller ikke med, når reolen nummereres. Numrene beregnes
    // derfor altid her ud fra de plader, der står i reolen – placements flyttes aldrig.

    /// Står kopien i reolen lige nu?
    internal bool IsOnShelf(long copyId) =>
        Copies.TryGetValue(copyId, out var c) && Releases.ContainsKey(c.ReleaseId) && c.Status.IsOnShelf();

    /// Sektionens plader, som de står fysisk (venstre mod højre): dem i reolen,
    /// plus `including`, hvis den er angivet (fx en plade, der skal sættes tilbage).
    internal List<long> PhysicalOrder(long locationId, long? including = null) =>
        SectionIds(locationId).Where(id => id == including || IsOnShelf(id)).ToList();

    /// copyId → fysisk nummer (1…n) for de plader i sektionen, der står i reolen.
    /// Plader, der er ude, er ikke med.
    public Dictionary<long, int> ShelfNumbers(long locationId)
    {
        var numbers = new Dictionary<long, int>();
        var order = PhysicalOrder(locationId);
        for (int i = 0; i < order.Count; i++) numbers[order[i]] = i + 1;
        return numbers;
    }

    /// Antal plader, der står i sektionen nu.
    public int OnShelfCount(long locationId) => PhysicalOrder(locationId).Count;

    // MARK: Naboer

    public Neighbors? NeighborsOf(long copyId, int count = 1)
    {
        if (Item(copyId) is not RecordItem target) return null;
        if (!LocationOfCopy.TryGetValue(copyId, out var locId) || LocationById(locId) is not Location loc
            || !Sections.TryGetValue(locId, out var ids) || !IndexInSection.TryGetValue(copyId, out var idx))
        {
            return new Neighbors(target, null, null, 0, Array.Empty<RecordItem>(), Array.Empty<RecordItem>(),
                                 Array.Empty<RecordItem>(), Array.Empty<RecordItem>(), false, false, null, null);
        }

        (List<RecordItem> Present, List<RecordItem> AbsentBetween, bool ReachedEnd) Collect(IEnumerable<int> range)
        {
            var present = new List<RecordItem>();
            var absent = new List<RecordItem>();
            foreach (var i in range)
            {
                if (Item(ids[i]) is not RecordItem it) continue;
                if (it.Copy.Status.IsOnShelf())
                {
                    present.Add(it);
                    if (present.Count == count) return (present, absent, false);
                }
                else if (present.Count == 0)
                {
                    absent.Add(it);
                }
            }
            return (present, absent, true);
        }

        var b = Collect(Enumerable.Range(0, idx).Reverse());
        var a = Collect(Enumerable.Range(idx + 1, ids.Count - idx - 1));

        int locIdx = Locations.ToList().FindIndex(l => l.Id == locId);
        (Location, RecordItem?)? prevSec = null;
        (Location, RecordItem?)? nextSec = null;
        if (b.ReachedEnd && locIdx > 0)
        {
            var pl = Locations[locIdx - 1];
            prevSec = (pl, SectionIds(pl.Id).Reverse().Select(Item).OfType<RecordItem>().FirstOrDefault(x => x.Copy.Status.IsOnShelf()));
        }
        if (a.ReachedEnd && locIdx + 1 < Locations.Count)
        {
            var nl = Locations[locIdx + 1];
            nextSec = (nl, SectionIds(nl.Id).Select(Item).OfType<RecordItem>().FirstOrDefault(x => x.Copy.Status.IsOnShelf()));
        }

        // Fysiske tal: plader i reolen ∪ målpladen, i placements-rækkefølge.
        var shelf = PhysicalOrder(locId, copyId);
        return new Neighbors(target, loc, shelf.IndexOf(copyId) + 1, shelf.Count,
                             b.Present, a.Present, b.AbsentBetween, a.AbsentBetween,
                             b.ReachedEnd, a.ReachedEnd, prevSec, nextSec);
    }

    // MARK: Reference-mode

    /// Vælger de bedste fysiske referencepunkter og forklarer hvorfor (bruges til Find).
    /// Alle tekster er skrevet set fra målpladen ("din plade") og bruger venstre/højre,
    /// aldrig "før"/"efter", så det er entydigt, hvilken vej man skal gå.
    public ReferenceAdvice? ReferenceAdviceFor(long copyId) => Advice(copyId, putBack: false);

    /// Som ReferenceAdviceFor, men til at SÆTTE pladen tilbage i reolen, fx
    /// "Sæt den lige til højre for Aurora – All My Demons Greeting Me as a Friend." Samme valg
    /// af referencer; kun plader, der står i reolen, nævnes. PlacementHint er fx
    /// "Plads 7 af 15 fra venstre", hvor pladen selv er talt med. null uden placering.
    public ReferenceAdvice? ReturnAdviceFor(long copyId) => Advice(copyId, putBack: true);

    private ReferenceAdvice? Advice(long copyId, bool putBack)
    {
        if (NeighborsOf(copyId, 1) is not Neighbors n || n.Location is not Location loc || n.Position is not int position) return null;
        var target = n.Target;
        var targetArtist = target.Artist;
        var before = n.Before.FirstOrDefault();
        var after = n.After.FirstOrDefault();
        string word = Medium.Singular(), words = Medium.Plural();
        string capWord = char.ToUpperInvariant(word[0]) + word[1..];

        // Kunstnerblok: hvor mange plader af samme kunstner står i træk omkring målet?
        // Der tælles kun plader, der fysisk står i reolen (plus målet selv), ellers bliver
        // "tæl N plader" forkert, når en plade i blokken er udlånt, og landmærket kan være væk.
        var shelf = PhysicalOrder(loc.Id, copyId);
        int sIdx = position - 1;
        int blockStart = sIdx, blockEnd = sIdx;
        while (blockStart > 0 && Item(shelf[blockStart - 1])?.Artist == targetArtist) blockStart--;
        while (blockEnd + 1 < shelf.Count && Item(shelf[blockEnd + 1])?.Artist == targetArtist) blockEnd++;
        int blockSize = blockEnd - blockStart + 1;

        static Reference Ref(ReferenceSide side, RecordItem? it, string why) => new(side, it, why);
        // Navnet på en nabo i en sætning. Et andet eksemplar af samme plade nævnes som sådan.
        // Når pladen skal sættes tilbage, nævnes en anden kunstner med fuldt navn, så den er
        // let at finde på ryggen i reolen.
        string Called(RecordItem it, bool first = false)
        {
            if (it.Artist == targetArtist && it.Title == target.Title)
                return $"{(first ? "Et" : "et")} andet eksemplar af {it.Title}";
            return putBack && it.Artist != targetArtist ? it.FullName : it.Title;
        }
        // LeftOf: pladen står til venstre for målet. RightOf: til højre for målet.
        string LeftOf(RecordItem it) => putBack
            ? $"Sæt den lige til højre for {SentenceEnd(Called(it))}"
            : $"{Called(it, first: true)} står lige til venstre for din {word}.";
        string RightOf(RecordItem it) => putBack
            ? $"Sæt den lige til venstre for {SentenceEnd(Called(it))}"
            : $"{Called(it, first: true)} står lige til højre for din {word}.";
        var atLeftEdge = putBack ? "Sæt den yderst til venstre i sektionen." : $"Din {word} står yderst til venstre i sektionen.";
        var atRightEdge = putBack ? "Sæt den yderst til højre i sektionen." : $"Din {word} står yderst til højre i sektionen.";
        const string otherArtist = "Det er en anden kunstner, så den er let at få øje på.";

        Reference primary;
        Reference? secondary;
        bool countsInPrimary = false;

        if (n.ReachedSectionStart && before is null)
        {
            primary = Ref(ReferenceSide.SectionStart, null, atLeftEdge);
            secondary = after is null ? null : Ref(ReferenceSide.After, after, RightOf(after));
        }
        else if (n.ReachedSectionEnd && after is null)
        {
            primary = Ref(ReferenceSide.SectionEnd, null, atRightEdge);
            secondary = before is null ? null : Ref(ReferenceSide.Before, before, LeftOf(before));
        }
        else if (before is RecordItem b && after is RecordItem a)
        {
            bool bDiff = b.Artist != targetArtist, aDiff = a.Artist != targetArtist;
            if (bDiff && !aDiff)
            {
                primary = Ref(ReferenceSide.Before, b, $"{LeftOf(b)} {otherArtist}");
                secondary = Ref(ReferenceSide.After, a, RightOf(a));
            }
            else if (aDiff && !bDiff)
            {
                primary = Ref(ReferenceSide.After, a, $"{RightOf(a)} {otherArtist}");
                secondary = Ref(ReferenceSide.Before, b, LeftOf(b));
            }
            else if (!bDiff && !aDiff && blockSize > 2)
            {
                // Midt i en stor blok af samme kunstner: tæl fra den nærmeste blokkant
                // (en anden kunstner eller sektionens kant). Det er den eneste tælleinstruktion.
                countsInPrimary = true;
                int fromStart = sIdx - blockStart, fromEnd = blockEnd - sIdx;
                var among = putBack ? $"Din {word} skal stå blandt {blockSize} {targetArtist}-{words} i træk."
                                    : $"Din {word} står blandt {blockSize} {targetArtist}-{words} i træk.";
                string Count(int nr, string side, RecordItem it) => putBack
                    ? $"din {word} skal stå som nr. {nr}, lige til {side} for {SentenceEnd(Called(it))}"
                    : $"din {word} er nr. {nr}, lige til {side} for {SentenceEnd(Called(it))}";
                if (fromStart <= fromEnd)
                {
                    var start = blockStart > 0 && Item(shelf[blockStart - 1]) is RecordItem s0
                        ? $"Find {s0.FullName}, som står lige til venstre for dem" : null;
                    primary = Ref(ReferenceSide.Before, b, $"{among} {start ?? "Start ved sektionens venstre kant"}, og tæl mod højre: {Count(fromStart + 1, "højre", b)}");
                    secondary = Ref(ReferenceSide.After, a, RightOf(a));
                }
                else
                {
                    var start = blockEnd + 1 < shelf.Count && Item(shelf[blockEnd + 1]) is RecordItem s1
                        ? $"Find {s1.FullName}, som står lige til højre for dem" : null;
                    primary = Ref(ReferenceSide.After, a, $"{among} {start ?? "Start ved sektionens højre kant"}, og tæl mod venstre: {Count(fromEnd + 1, "venstre", a)}");
                    secondary = Ref(ReferenceSide.Before, b, LeftOf(b));
                }
            }
            else
            {
                primary = Ref(ReferenceSide.Before, b, LeftOf(b));
                secondary = Ref(ReferenceSide.After, a, RightOf(a));
            }
        }
        else
        {
            primary = Ref(ReferenceSide.Before, before, before is null ? atLeftEdge : LeftOf(before));
            secondary = after is null ? null : Ref(ReferenceSide.After, after, RightOf(after));
        }

        // Kunstnerblokken nævnes kun, når pladen står yderst i den – står den midt i, er tællingen
        // allerede i Primary, og står den ved sektionens kant, siger Primary det.
        string? blockHint = null;
        bool atSectionEdge = primary.Side is ReferenceSide.SectionStart or ReferenceSide.SectionEnd;
        if (blockSize > 1 && !countsInPrimary && !atSectionEdge)
        {
            var side = sIdx == blockStart ? "venstre" : sIdx == blockEnd ? "højre" : null;
            if (side is not null)
            {
                blockHint = putBack
                    ? $"Din {word} skal stå længst til {side} blandt {blockSize} {targetArtist}-{words} i træk."
                    : $"Der står {blockSize} {targetArtist}-{words} i træk, og din {word} er den længst til {side}.";
            }
        }

        var edge = new List<string>();
        if (n.ReachedSectionStart && n.PreviousSection is { } prev && prev.Last is RecordItem last)
            edge.Add($"Forrige sektion ({prev.Location.ShortName}) slutter med {SentenceEnd(last.FullName)}");
        if (n.ReachedSectionEnd && n.NextSection is { } next && next.First is RecordItem first)
            edge.Add($"Næste sektion ({next.Location.ShortName}) begynder med {SentenceEnd(first.FullName)}");
        string? edgeHint = edge.Count == 0 ? null : string.Join(" ", edge);

        // Fysiske tal: talt blandt pladerne i reolen, med målpladen selv.
        var placementHint = $"{(putBack ? "Plads" : capWord)} {position} af {n.SectionCount} fra venstre";
        return new ReferenceAdvice(primary, secondary, blockHint, placementHint, edgeHint);
    }

    /// Afslutter en sætning, der ender med et navn: "Low" → "Low.", men "Morning Glory?" forbliver uændret.
    internal static string SentenceEnd(string name)
    {
        if (name.Length == 0 || ".!?…".Contains(name[^1])) return name;
        return name + ".";
    }

    // MARK: Forslag til placering af nye plader

    /// Finder hvor en (uplaceret eller flyttet) plade burde stå ud fra sorteringsreglerne,
    /// relativt til den *faktiske* fysiske rækkefølge: pladen sættes lige efter den placerede
    /// plade med den største sorteringsnøgle ≤ pladens egen.
    public PlacementSuggestion? SuggestPlacement(long copyId, SortRules rules, long? restrictTo = null)
    {
        if (Item(copyId) is not RecordItem target || Locations.Count == 0) return null;
        var tk = rules.KeyFor(target);
        var candidates = restrictTo is long l
            ? SectionIds(l).Where(id => id != copyId).ToList()
            : GlobalOrder.Where(id => id != copyId).ToList();

        (long Id, SortKey Key)? bestPred = null;
        foreach (var id in candidates)
        {
            if (Item(id) is not RecordItem it) continue;
            var k = rules.KeyFor(it);
            if (!rules.AreInIncreasingOrder(tk, k))  // k <= tk
            {
                if (bestPred is null || rules.AreInIncreasingOrder(bestPred.Value.Key, k)) bestPred = (id, k);
            }
        }

        if (bestPred is { } pred)
        {
            var loc = LocationOfCopy[pred.Id];
            var ids = SectionIds(loc).Where(id => id != copyId).ToList();
            int pi = ids.IndexOf(pred.Id);
            long? next = pi + 1 < ids.Count ? ids[pi + 1] : null;
            return new PlacementSuggestion(loc, pi + 1, pred.Id, next);
        }
        // Ingen forgænger: først i den første (evt. valgte) sektion.
        var firstLoc = restrictTo ?? Locations[0].Id;
        var firstIds = SectionIds(firstLoc).Where(id => id != copyId).ToList();
        return new PlacementSuggestion(firstLoc, 0, null, firstIds.Count > 0 ? firstIds[0] : null);
    }

    // MARK: Sortering vs. virkelighed

    /// Kopier i en sektion, der ikke står i forventet rækkefølge (uden for den længste
    /// korrekt sorterede delsekvens). Bruges til at markere mulige fejlplaceringer.
    public HashSet<long> OutOfOrder(long locationId, SortRules rules)
    {
        var ids = SectionIds(locationId);
        var keys = ids.Select(Item).OfType<RecordItem>().Select(rules.KeyFor).ToList();
        if (keys.Count != ids.Count || ids.Count <= 1) return new();
        // Længste ikke-faldende delsekvens, O(n log n).
        var tailsIdx = new List<int>();
        var prev = Enumerable.Repeat(-1, ids.Count).ToArray();
        for (int i = 0; i < ids.Count; i++)
        {
            int lo = 0, hi = tailsIdx.Count;
            while (lo < hi)
            {
                int mid = (lo + hi) / 2;
                if (!rules.AreInIncreasingOrder(keys[i], keys[tailsIdx[mid]])) lo = mid + 1; else hi = mid;
            }
            if (lo > 0) prev[i] = tailsIdx[lo - 1];
            if (lo == tailsIdx.Count) tailsIdx.Add(i); else tailsIdx[lo] = i;
        }
        var keep = new HashSet<int>();
        int k = tailsIdx.Count > 0 ? tailsIdx[^1] : -1;
        while (k >= 0) { keep.Add(k); k = prev[k]; }
        return Enumerable.Range(0, ids.Count).Where(i => !keep.Contains(i)).Select(i => ids[i]).ToHashSet();
    }
}
