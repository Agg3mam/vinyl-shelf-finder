namespace VinylShelfFinder.Core;

// Port af Sources/VinylCore/Demo.swift.

/// Eksempeldata til --demo, så appen kan afprøves uden Discogs-konto.
public static class DemoData
{
    internal static readonly (string Artist, string Title, int Year, string Label, string Catalog)[] Records =
    {
        ("ABBA", "Arrival", 1976, "Polar", "POLS 272"),
        ("AC/DC", "Highway To Hell", 1979, "Atlantic", "K 50628"),
        ("Aerosmith", "Toys In The Attic", 1975, "Columbia", "PC 33479"),
        ("Al Green", "Call Me", 1973, "Hi Records", "SHL 32077"),
        ("A-ha", "Hunting High And Low", 1985, "Warner Bros.", "925 300-1"),
        ("The Beatles", "Abbey Road", 1969, "Apple Records", "PCS 7088"),
        ("The Beatles", "Revolver", 1966, "Parlophone", "PMC 7009"),
        ("Bob Dylan", "Bringing It All Back Home", 1965, "CBS", "BPG 62515"),
        ("Bob Dylan", "John Wesley Harding", 1967, "CBS", "SBPG 63252"),
        ("David Bowie", "Hunky Dory", 1971, "RCA Victor", "SF 8244"),
        ("David Bowie", "Young Americans", 1975, "RCA Victor", "RS 1006"),
        ("David Bowie", "Station To Station", 1976, "RCA Victor", "APL1-1327"),
        ("David Bowie", "Low", 1977, "RCA Victor", "PL 12030"),
        ("David Bowie", "\"Heroes\"", 1977, "RCA Victor", "PL 12522"),
        ("Dire Straits", "Brothers In Arms", 1985, "Vertigo", "824 499-1"),
        ("Gasolin'", "Gas 5", 1975, "CBS", "CBS 69183"),
        ("Genesis", "Nursery Cryme", 1971, "Charisma", "CAS 1052"),
        ("Genesis", "Foxtrot", 1972, "Charisma", "CAS 1058"),
        ("Genesis", "Selling England By The Pound", 1973, "Charisma", "CAS 1074"),
        ("Genesis", "The Lamb Lies Down On Broadway", 1974, "Charisma", "CGS 101"),
        ("Genesis", "A Trick Of The Tail", 1976, "Charisma", "CDS 4001"),
        ("Genesis", "Wind & Wuthering", 1976, "Charisma", "CDS 4005"),
        ("George Harrison", "All Things Must Pass", 1970, "Apple Records", "STCH 639"),
        ("Jimi Hendrix", "Electric Ladyland", 1968, "Track Record", "613 008/9"),
        ("Kim Larsen", "Værsgo", 1973, "Polydor", "2380 026"),
        ("Led Zeppelin", "Led Zeppelin IV", 1971, "Atlantic", "K 50008"),
        ("Lou Reed", "Transformer", 1972, "RCA Victor", "LSP-4807"),
        ("Nirvana", "Nevermind", 1991, "DGC", "DGC-24425"),
        ("Oasis", "(What's The Story) Morning Glory?", 1995, "Creation Records", "CRE LP 189"),
        ("Pink Floyd", "Meddle", 1971, "Harvest", "SHVL 795"),
        ("Pink Floyd", "The Dark Side Of The Moon", 1973, "Harvest", "SHVL 804"),
        ("Pink Floyd", "The Dark Side Of The Moon", 1973, "Capitol Records", "SMAS-11163"),
        ("Pink Floyd", "Wish You Were Here", 1975, "Harvest", "SHVL 814"),
        ("Pink Floyd", "Animals", 1977, "Harvest", "SHVL 815"),
        ("Pink Floyd", "The Wall", 1979, "Harvest", "SHDW 411"),
        ("Queen", "A Night At The Opera", 1975, "EMI", "EMTC 103"),
        ("Queen", "News Of The World", 1977, "EMI", "EMA 784"),
        ("The Rolling Stones", "Sticky Fingers", 1971, "Rolling Stones Records", "COC 59100"),
        ("Sort Sol", "Everything That Rises Must Converge", 1987, "Medley Records", "MdLP 6167"),
        ("Talking Heads", "Remain In Light", 1980, "Sire", "SRK 6095"),
        ("Various", "Nuggets: Original Artyfacts", 1972, "Elektra", "7E-2006"),
        ("Aurora", "All My Demons Greeting Me As A Friend", 2016, "Decca", "4760796"),
        ("Åge Aleksandersen", "Levva Livet", 1984, "Mercury", "818 413-1"),
    };

    internal static string DemoGenre(string artist) => artist switch
    {
        "ABBA" or "A-ha" or "Aurora" => "Pop",
        "Al Green" => "Funk / Soul",
        "Talking Heads" => "Rock, Pop",
        _ => "Rock",
    };

    public static List<DiscogsCollectionItem> Collection =>
        Records.Select((r, i) => new DiscogsCollectionItem(9_000 + i, null,
            new Release(100_000 + i, r.Artist, r.Title, r.Year, r.Label, r.Catalog, "Vinyl, LP, Album", Genres: DemoGenre(r.Artist)))).ToList();

    /// Fylder en tom database med eksempeldata og en reol med 3 sektioner.
    public static void SeedIfEmpty(ShelfStore store)
    {
        if (store.LoadLibrary().Copies.Count > 0) return;
        store.ApplyCollection(Collection);
        // Demo-listen er ikke i Discogs' rækkefølge, så demoen bruger appens egne regler.
        var rules = store.LoadSortRules();
        rules.UseDiscogsOrder = false;
        store.SaveSortRules(rules);
        var sorted = rules.Sorted(store.LoadLibrary().AllItems).Select(i => i.Id).ToList();
        var plan = LayoutPlanner.EvenPlan(sorted.Count, new[] { 2, 1 });
        var parts = LayoutPlanner.Split(sorted, plan);
        store.CreateLayout(plan.Zip(parts, (p, ids) => (p.Shelf, p.Section, (IReadOnlyList<long>)ids)).ToList());
    }
}
