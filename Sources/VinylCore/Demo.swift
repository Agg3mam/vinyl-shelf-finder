import Foundation

/// Eksempeldata til `--demo`, så appen kan afprøves uden Discogs-konto.
public enum DemoData {
    static let records: [(String, String, Int, String, String)] = [
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
    ]

    /// Cd'er til den anden hylde (samme Discogs-samling, format "CD").
    static let cds: [(String, String, Int, String, String)] = [
        ("Björk", "Debut", 1993, "One Little Indian", "TPLP 31 CD"),
        ("Blur", "Parklife", 1994, "Food", "FOODCD 10"),
        ("The Cardigans", "First Band On The Moon", 1996, "Stockholm Records", "533 117-2"),
        ("D-A-D", "No Fuel Left For The Pilgrims", 1989, "Medley Records", "MdCD 6176"),
        ("Massive Attack", "Mezzanine", 1998, "Virgin", "WBRCD4"),
        ("Portishead", "Dummy", 1994, "Go! Beat", "828 553-2"),
        ("Radiohead", "OK Computer", 1997, "Parlophone", "7243 8 55229 2 5"),
        ("Radiohead", "Kid A", 2000, "Parlophone", "7243 5 27753 2 3"),
        ("TV-2", "Nærmest Lykkelig", 1985, "Medley Records", "MdCD 6050"),
        ("The Verve", "Urban Hymns", 1997, "Hut Recordings", "CDHUT45"),
    ]

    static func demoGenre(_ artist: String) -> String {
        switch artist {
        case "ABBA", "A-ha", "Aurora": return "Pop"
        case "Al Green": return "Funk / Soul"
        case "Talking Heads": return "Rock, Pop"
        default: return "Rock"
        }
    }

    public static var collection: [DiscogsCollectionItem] {
        records.enumerated().map { i, r in
            DiscogsCollectionItem(instanceID: 9_000 + i, dateAdded: nil,
                                  release: Release(id: 100_000 + i, artist: r.0, title: r.1, year: r.2,
                                                   label: r.3, catalogNumber: r.4, format: "Vinyl, LP, Album",
                                                   genres: demoGenre(r.0)))
        } + cds.enumerated().map { i, r in
            DiscogsCollectionItem(instanceID: 9_500 + i, dateAdded: nil,
                                  release: Release(id: 150_000 + i, artist: r.0, title: r.1, year: r.2,
                                                   label: r.3, catalogNumber: r.4, format: "CD, Album",
                                                   genres: demoGenre(r.0)))
        }
    }

    /// Fylder en tom database med eksempeldata: en pladereol med 3 sektioner og en cd-reol med 2.
    public static func seedIfEmpty(_ store: ShelfStore) throws {
        guard try store.mediumCounts().isEmpty else { return }
        _ = try store.applyCollection(collection)
        // Demo-listen er ikke i Discogs' rækkefølge, så demoen bruger appens egne regler.
        var rules = store.loadSortRules()
        rules.useDiscogsOrder = false
        try store.saveSortRules(rules)
        let sorted = rules.sorted(try store.loadLibrary().allItems).map(\.id)
        let plan = LayoutPlanner.evenPlan(total: sorted.count, sectionsPerShelf: [2, 1])
        let parts = LayoutPlanner.split(sorted, plan: plan)
        try store.createLayout(zip(plan, parts).map { (shelf: $0.shelf, section: $0.section, copies: $1) })

        let cdSorted = rules.sorted(try store.loadLibrary(medium: .cd).allItems).map(\.id)
        let cdPlan = LayoutPlanner.evenPlan(total: cdSorted.count, sectionsPerShelf: [2])
        let cdParts = LayoutPlanner.split(cdSorted, plan: cdPlan)
        try store.createLayout(zip(cdPlan, cdParts).map { (shelf: $0.shelf, section: $0.section, copies: $1) }, medium: .cd)
    }
}
