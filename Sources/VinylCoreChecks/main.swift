import Foundation
import VinylCore

// Selvtest af kernelogikken. Kør: swift run VinylCoreChecks

var failures = 0
var passes = 0
func check(_ cond: @autoclosure () -> Bool, _ msg: String, line: Int = #line) {
    if cond() { passes += 1 } else { failures += 1; print("✗ linje \(line): \(msg)") }
}

func item(_ inst: Int, _ rel: Int, _ artist: String, _ title: String, year: Int? = nil, label: String? = nil, cat: String? = nil) -> DiscogsCollectionItem {
    DiscogsCollectionItem(instanceID: inst, dateAdded: nil,
                          release: Release(id: rel, artist: artist, title: title, year: year, label: label, catalogNumber: cat, format: "Vinyl, LP"))
}

// MARK: Sortering
do {
    let r = SortRules()
    check(r.sortArtist("The Beatles") == "Beatles", "The Beatles → Beatles")
    check(r.sortArtist("Beatles, The") == "Beatles", "Beatles, The → Beatles")
    check(r.sortArtist("AC/DC") == "ACDC", "AC/DC → ACDC")
    check(r.sortArtist("A-ha") == "Aha", "A-ha → Aha")
    check(r.sortArtist("The The") == "The", "The The → The")
    var o = r; o.artistOverrides["Bob Dylan"] = "Dylan, Bob"
    check(o.sortArtist("Bob Dylan") == "Dylan, Bob", "override")
    check(SortRules.naturalCompare("2pac", "10cc") < 0, "2Pac før 10cc")
    check(SortRules.naturalCompare(r.collationKey("Zappa"), r.collationKey("Ølbutikken")) < 0, "Ø efter Z (dansk)")
    check(SortRules.naturalCompare(r.collationKey("Ølbutikken"), r.collationKey("Åge Aleksandersen")) < 0, "Å efter Ø")
    var nd = r; nd.danishAlphabet = false
    check(SortRules.naturalCompare(nd.collationKey("Ølbutikken"), nd.collationKey("Pink")) < 0, "Ø=O i international tilstand")
    check(SortRules.naturalCompare(r.collationKey("bob dylan"), r.collationKey("bobby")) < 0, "Bob Dylan før Bobby")
    check(DiscogsClient.cleanDiscogsName("Nirvana (2)") == "Nirvana", "Discogs (2)-suffiks")
}

// MARK: Store + naboer + sync
let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("vsf-check-\(UUID().uuidString).sqlite")
defer { try? FileManager.default.removeItem(at: tmp) }
let store = try ShelfStore(path: tmp.path)
var rules = SortRules()
rules.useDiscogsOrder = false

var collection = [
    item(1, 101, "ABBA", "Arrival", year: 1976),
    item(2, 102, "AC/DC", "Highway To Hell", year: 1979),
    item(3, 103, "David Bowie", "Low", year: 1977),
    item(4, 104, "David Bowie", "\"Heroes\"", year: 1977),
    item(5, 105, "Dire Straits", "Brothers In Arms", year: 1985),
    item(6, 106, "Pink Floyd", "The Dark Side Of The Moon", year: 1973, label: "Harvest", cat: "SHVL 804"),
    item(7, 107, "Pink Floyd", "The Dark Side Of The Moon", year: 1973, label: "Capitol", cat: "SMAS-11163"),
    item(8, 108, "Pink Floyd", "Wish You Were Here", year: 1975, label: "Harvest", cat: "SHVL 814"),
    item(9, 109, "Pink Floyd", "Animals", year: 1977),
    item(10, 110, "Queen", "A Night At The Opera", year: 1975),
    item(11, 111, "The Beatles", "Abbey Road", year: 1969),
    item(12, 112, "Led Zeppelin", "Led Zeppelin IV", year: 1971, label: "Atlantic", cat: "K 50014"),
    item(13, 106, "Pink Floyd", "The Dark Side Of The Moon", year: 1973, label: "Harvest", cat: "SHVL 804"), // dublet af samme release
]
var report = try store.applyCollection(collection)
check(report.newCopies.count == 13, "13 nye kopier (inkl. dublet af samme release)")

var lib = try store.loadLibrary()
check(lib.releases.count == 12, "12 unikke releases")
let sorted = rules.sorted(lib.allItems)
let names = sorted.map(\.fullName)
check(names.first == "ABBA – Arrival" && names[1] == "AC/DC – Highway To Hell", "ABBA, AC/DC først: \(names.prefix(3))")
check(names.firstIndex(of: "The Beatles – Abbey Road")! < names.firstIndex(of: "David Bowie – Low")!, "Beatles sorteres under B")

// Onboarding: to sektioner
let plan = LayoutPlanner.evenPlan(total: sorted.count, sectionsPerShelf: [2])
check(plan.map(\.count) == [7, 6], "jævn fordeling 7/6")
let parts = LayoutPlanner.split(sorted.map(\.id), plan: plan)
try store.createLayout(zip(plan, parts).map { (shelf: $0.shelf, section: $0.section, copies: $1) })
lib = try store.loadLibrary()
check(lib.unplaced.isEmpty, "alle placeret")
check(lib.globalOrder == sorted.map(\.id), "fysisk rækkefølge = sorteret")

func copyID(_ inst: Int) -> Int64 { lib.copies.values.first { $0.instanceID == inst }!.id }
func name(_ id: Int64?) -> String { id.flatMap { lib.item($0)?.fullName } ?? "∅" }

let heroes = copyID(4)
let n = lib.neighbors(of: heroes, count: 1)!
check(n.before.first?.title == "Low" || n.after.first?.title == "Low", "Heroes nabo til Low: før=\(name(n.before.first?.id)) efter=\(name(n.after.first?.id))")

// Første plade i samlingen: ingen før, start af sektion
let abba = copyID(1)
let na = lib.neighbors(of: abba)!
check(na.before.isEmpty && na.reachedSectionStart && na.previousSection == nil, "ABBA: starten af sektionen")

// Sektionsgrænse: sidste plade i sektion A skal pege på første i sektion B
let secA = lib.locations[0].id
let lastA = lib.sections[secA]!.last!
let nl = lib.neighbors(of: lastA)!
check(nl.after.isEmpty && nl.reachedSectionEnd && nl.nextSection?.first?.id == lib.sections[lib.locations[1].id]!.first, "sektionsslut peger på næste sektions første plade")

// 3 naboer
let wish = copyID(8)
let n3 = lib.neighbors(of: wish, count: 3)!
check(n3.before.count <= 3 && n3.after.count <= 3, "højst 3 naboer")

// Udlånt plade springes over som reference, men positionen bevares
let animals = copyID(9)
let afterAnimals = lib.globalOrder[lib.globalIndex[animals]! + 1]
let refPos = lib.globalIndex[animals]!
try store.setStatus(copyID: animals, .lent, note: "Peter")
lib = try store.loadLibrary()
check(lib.globalIndex[animals] == refPos, "status ændrer ikke position")
let nw = lib.neighbors(of: afterAnimals)!
check(nw.before.first?.id != animals && nw.absentBetweenBefore.first?.id == animals && nw.reachedSectionStart, "udlånt plade springes over som reference")
try store.setStatus(copyID: animals, .home, note: nil)
do {
    let h = try store.history(limit: 2)
    check(h.last?.summary == "Pink Floyd – Animals: status ændret til “Udlånt” (Peter)" && h.first?.summary == "Pink Floyd – Animals: status ændret til “På plads”",
          "historik: status med ord, ikke emoji: \(h.map(\.summary))")
}

// Flyt: naboer opdateres automatisk
lib = try store.loadLibrary()
let secB = lib.locations[1].id
try store.move(copyID: abba, to: secB, index: 0)
lib = try store.loadLibrary()
check(lib.sections[secB]!.first == abba, "ABBA flyttet først i sektion B")
check(lib.sections[secA]!.count == 6, "sektion A har nu 6")
let posA = try store.db.query("SELECT position FROM placements WHERE location_id = ? ORDER BY position", secA).map { Int($0["position"]!.int!) }
check(posA == Array(1...6), "positioner omnummereret: \(posA)")
check((try? store.history(limit: 1))?.first?.summary == "ABBA – Arrival flyttet fra Reol 1 · Sektion A, plads 1 til Reol 1 · Sektion B, plads 1",
      "historik: flyt med ens placeringsformat: \((try? store.history(limit: 1).first?.summary) ?? "")")
try store.move(copyID: abba, to: secA, index: 0)
lib = try store.loadLibrary()

// Sync: metadata ændres → placering bevares
let bowieLowPlacementBefore = (lib.locationOfCopy[copyID(3)], lib.indexInSection[copyID(3)])
collection[2].release.title = "Low (Remastered)"
collection[2].release.year = 1977
report = try store.applyCollection(collection)
lib = try store.loadLibrary()
check(report.updatedReleases == 1 && report.newCopies.isEmpty, "1 opdateret release, ingen nye")
check(lib.item(copyID(3))!.title == "Low (Remastered)", "metadata opdateret")
check((lib.locationOfCopy[copyID(3)], lib.indexInSection[copyID(3)]) == bowieLowPlacementBefore, "placering bevaret efter metadata-ændring")

// Sync: plade fjernet fra Discogs → markeres, placering bevares
let queen = copyID(10)
let queenLoc = lib.locationOfCopy[queen]
collection.removeAll { $0.instanceID == 10 }
report = try store.applyCollection(collection)
lib = try store.loadLibrary()
check(report.removedCopies == [queen], "Queen markeret som fjernet")
check(lib.copies[queen]?.inDiscogs == false && lib.locationOfCopy[queen] == queenLoc, "Queen stadig placeret fysisk")

// Sync: ny plade → uplaceret + forslag mellem de rigtige naboer
collection.append(item(20, 120, "David Bowie", "Hunky Dory", year: 1971))
report = try store.applyCollection(collection)
lib = try store.loadLibrary()
let hunky = report.newCopies.first!
check(lib.unplaced == [hunky], "ny plade er uplaceret")
let sug = lib.suggestPlacement(for: hunky, rules: rules)!
check(name(sug.before) == "David Bowie – \"Heroes\"" && name(sug.after) == "David Bowie – Low (Remastered)",
      "forslag: mellem Heroes og Low, fik \(name(sug.before)) / \(name(sug.after))")
try store.move(copyID: hunky, to: sug.locationID, index: sug.index)
lib = try store.loadLibrary()
let nh = lib.neighbors(of: hunky)!
check(nh.before.first?.id == sug.before && nh.after.first?.id == sug.after, "ny plade indsat – naboer opdateret")
check(lib.neighbors(of: sug.before!)!.after.first?.id == hunky, "forgængerens næste = ny plade")
check((try? store.history(limit: 1))?.first?.summary.hasPrefix("David Bowie – Hunky Dory placeret på Reol 1 · Sektion A, plads ") == true,
      "historik: placering af ny plade")

// Genkommer fra Discogs
collection.append(item(10, 110, "Queen", "A Night At The Opera", year: 1975))
report = try store.applyCollection(collection)
check(report.returnedCopies == [queen], "Queen tilbage i Discogs")

// Ude af rækkefølge
check(lib.outOfOrder(in: secA, rules: rules).isEmpty, "sektion A i orden")

// Reference-mode
let adv = lib.referenceAdvice(for: wish)
check(adv != nil, "reference-råd for Wish You Were Here")

// MARK: Søgning
let idx = SearchIndex(library: lib)
func top(_ q: String) -> String { name(idx.search(q).first) }
check(idx.search("pink floyd").count == 5, "5 Pink Floyd-kopier: \(idx.search("pink floyd").count)")
check(top("dark side").contains("Dark Side"), "dark side")
check(idx.search("shvl").count == 3, "shvl finder SHVL 804 ×2 og SHVL 814")
check(top("smas11163").contains("Dark Side"), "katalognummer uden bindestreg")
check(top("zepelin").contains("Led Zeppelin"), "stavefejl: zepelin")
check(top("led zeppelin iv").contains("Led Zeppelin IV"), "led zeppelin iv")
check(top("108") == "Pink Floyd – Wish You Were Here", "release ID")
check(top("beatles abbey") == "The Beatles – Abbey Road", "artist + titel")
check(top("acdc").hasPrefix("AC/DC"), "acdc finder AC/DC")

// MARK: Præcis Discogs-rækkefølge
do {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("vsf-rank-\(UUID().uuidString).sqlite")
    defer { try? FileManager.default.removeItem(at: url) }
    let s = try ShelfStore(path: url.path)
    // Discogs' rækkefølge afviger bevidst fra appens regler ("The" og titel-orden).
    let discogsOrder = [
        item(1, 1, "Pink Floyd", "Wish You Were Here"),
        item(2, 2, "Pink Floyd", "Animals"),
        item(3, 3, "The Beatles", "Abbey Road"),
    ]
    _ = try s.applyCollection(discogsOrder)
    var l = try s.loadLibrary()
    let d = SortRules()   // standard: useDiscogsOrder = true
    check(d.useDiscogsOrder, "Discogs-rækkefølge er standard")
    check(d.sorted(l.allItems).map(\.copy.instanceID!) == [1, 2, 3], "sorteret præcis som Discogs")
    // Ny plade midt i Discogs-listen → forslag efter dens forgænger i Discogs
    let sorted = d.sorted(l.allItems).map(\.id)
    let locID = try s.addSection(shelf: 1, section: "A")
    for (i, id) in sorted.enumerated() { try s.move(copyID: id, to: locID, index: i) }
    _ = try s.applyCollection([discogsOrder[0], item(4, 4, "Pink Floyd", "Meddle"), discogsOrder[1], discogsOrder[2]])
    l = try s.loadLibrary()
    let meddle = l.unplaced.first!
    let sug = l.suggestPlacement(for: meddle, rules: d)!
    check(l.item(sug.before!)?.title == "Wish You Were Here" && l.item(sug.after!)?.title == "Animals",
          "forslag følger Discogs-rækkefølgen")
    // Gamle gemte regler uden feltet dekodes stadig
    let old = try JSONDecoder().decode(SortRules.self, from: Data(#"{"danishAlphabet":false}"#.utf8))
    check(old.useDiscogsOrder && !old.danishAlphabet, "tolerant dekodning af gamle regler")
}

// MARK: Discogs JSON
do {
    let json = """
    {"pagination":{"page":1,"pages":3,"per_page":100,"items":250,"urls":{}},
     "releases":[{"id":1873013,"instance_id":45123,"date_added":"2024-01-02T10:00:00-08:00","rating":0,
       "basic_information":{"id":1873013,"master_id":10362,"title":"The Dark Side Of The Moon","year":1973,
         "resource_url":"https://api.discogs.com/releases/1873013",
         "thumb":"https://i.discogs.com/t.jpg","cover_image":"https://i.discogs.com/c.jpg",
         "formats":[{"name":"Vinyl","qty":"1","descriptions":["LP","Album"]}],
         "labels":[{"name":"Harvest","catno":"SHVL 804","entity_type":"1","id":1}],
         "artists":[{"name":"Pink Floyd","anv":"","join":"","role":"","tracks":"","id":45467}],
         "genres":["Rock"],"styles":["Psychedelic Rock"]}},
      {"id":2,"instance_id":2,"basic_information":{"id":2,"title":"Bookends","year":0,
         "thumb":"","cover_image":"https://s.discogs.com/images/spacer.gif",
         "formats":[{"name":"Vinyl","qty":"2","descriptions":[]}],
         "labels":[{"name":"CBS (2)","catno":"none"}],
         "artists":[{"name":"Simon (4)","anv":"Simon","join":"&"},{"name":"Garfunkel","anv":"","join":""}]}}]}
    """
    let parsed = try DiscogsClient.parseCollectionPage(Data(json.utf8))
    check(parsed.pages == 3 && parsed.total == 250 && parsed.items.count == 2, "pagination")
    let a = parsed.items[0], b = parsed.items[1]
    check(a.instanceID == 45123 && a.release.id == 1873013 && a.release.catalogNumber == "SHVL 804", "release/instance id + catno")
    check(a.release.format == "Vinyl, LP, Album", "format: \(a.release.format ?? "nil")")
    check(b.release.artist == "Simon & Garfunkel", "kunstner-join: \(b.release.artist)")
    check(b.release.year == nil && b.release.catalogNumber == nil && b.release.coverURL == nil && b.release.thumbURL == nil,
          "manglende år/katalognr./cover")
    check(b.release.label == "CBS" && b.release.format == "2×Vinyl", "label uden (2), 2×Vinyl: \(b.release.format ?? "")")
    do { _ = try DiscogsClient.parseCollectionValue(Data("ikke json".utf8)); check(false, "ugyldig værdi-JSON skal fejle") }
    catch { check(error.localizedDescription == "Svaret fra Discogs kunne ikke læses (samlingens værdi).", "Discogs-fejl på dansk: \(error.localizedDescription)") }
    check(DiscogsError.offline.localizedDescription.hasPrefix("Kunne ikke få forbindelse til Discogs"), "netværksfejl på dansk")
}

// MARK: Værdi
do {
    let rel = #"{"id":1,"title":"X","lowest_price":24.99,"num_for_sale":17,"community":{"have":5120,"want":1830,"rating":{"count":1}}}"#
    let m = try DiscogsClient.parseMarketInfo(Data(rel.utf8), currency: "EUR")
    check(m.lowestPrice == 24.99 && m.numForSale == 17 && m.have == 5120 && m.want == 1830, "markedsdata parses")
    let none = try DiscogsClient.parseMarketInfo(Data(#"{"id":2,"lowest_price":null,"num_for_sale":0}"#.utf8), currency: "EUR")
    check(none.lowestPrice == nil && none.numForSale == 0 && none.demand == nil, "ingen pris til salg")
    let v = try DiscogsClient.parseCollectionValue(Data(#"{"maximum":"€2,310.40","median":"€1,105.00","minimum":"€512.30"}"#.utf8))
    check(v.median == "€1,105.00", "samlingsværdi parses")
    try store.saveMarket(106, m)
    let loaded = try store.loadMarket()[106]
    check(loaded?.lowestPrice == 24.99 && loaded?.want == 1830 && loaded?.currency == "EUR", "markedsdata gemmes")
}

// MARK: Lyttelog + forslag + skilte
do {
    let l = try store.loadLibrary()
    let now = Date()
    let ids = l.globalOrder
    let pid = try store.logPlay(copyID: ids[0], at: now.addingTimeInterval(-400 * 86400))
    try store.logPlay(copyID: ids[0], at: now.addingTimeInterval(-10 * 86400))
    try store.logPlay(copyID: ids[1], at: now.addingTimeInterval(-200 * 86400))
    var stats = ListeningStats(plays: try store.loadPlays())
    check(stats.count[ids[0]] == 2 && stats.mostPlayed(limit: 1).first?.copyID == ids[0], "lyttelog tæller")
    check(stats.plays(since: now.addingTimeInterval(-30 * 86400)) == 1, "spillet sidste 30 dage")
    try store.deletePlay(pid)
    stats = ListeningStats(plays: try store.loadPlays())
    check(stats.count[ids[0]] == 1, "fortryd afspilning")

    let items = l.allItems
    let never = ListenPicker.candidates(items, library: l, filter: ListenFilter(freshness: .neverPlayed), stats: stats, now: now)
    check(!never.contains { $0.id == ids[0] || $0.id == ids[1] } && !never.isEmpty, "aldrig spillet-filter")
    let q3 = ListenPicker.candidates(items, library: l, filter: ListenFilter(freshness: .notIn3Months), stats: stats, now: now)
    check(q3.contains { $0.id == ids[1] } && !q3.contains { $0.id == ids[0] }, "ikke hørt i 3 måneder")
    let seventies = ListenPicker.candidates(items, library: l, filter: ListenFilter(decade: 1970), stats: stats, now: now)
    check(!seventies.isEmpty && seventies.allSatisfy { ($0.release.year ?? 0) / 10 == 197 }, "årti-filter")
    var rng = SystemRandomNumberGenerator()
    let recent = Array(never.dropFirst().map(\.id))
    check(ListenPicker.pick(from: never, stats: stats, avoiding: recent, now: now, using: &rng)?.id == never.first?.id,
          "undgår nylige forslag")

    let labels = ShelfLabel.labels(for: l)
    check(labels.count == l.locations.count && labels[0].firstArtist == "ABBA", "skilte: første kunstner")
    check(ShelfLabel.locationID(fromScanCode: labels[1].scanCode) == labels[1].location.id, "QR-kode kan læses tilbage")
    try store.setScanCode(locationID: labels[0].location.id, code: labels[0].scanCode)
    let reloaded = try store.loadLibrary()
    check(reloaded.locations[0].scanCode == labels[0].scanCode, "scan-kode gemt på sektion")
}

// MARK: Reference-mode på demo-data
do {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("vsf-demo-\(UUID().uuidString).sqlite")
    defer { try? FileManager.default.removeItem(at: url) }
    let demo = try ShelfStore(path: url.path)
    try DemoData.seedIfEmpty(demo)
    let dl = try demo.loadLibrary()
    check(dl.unplaced.isEmpty && dl.locations.count == 3, "demo: 3 sektioner, alt placeret")
    let station = dl.allItems.first { $0.title == "Station To Station" }!.id
    let adv = dl.referenceAdvice(for: station)!
    check(adv.primary.reason.contains("højre kant") && adv.primary.reason.contains("tæl mod venstre: din plade er nr. 2"),
          "blok ved sektionskant: \(adv.primary.reason)")
    let lamb = dl.allItems.first { $0.title == "The Lamb Lies Down On Broadway" }!.id
    let lambAdv = dl.referenceAdvice(for: lamb)!
    check(lambAdv.primary.reason.contains("blandt 6 Genesis-plader") && lambAdv.artistBlockHint == nil,
          "midt i Genesis-blokken: tællingen står kun ét sted: \(lambAdv.primary.reason) / \(lambAdv.artistBlockHint ?? "nil")")
    let genesis = dl.globalOrder.filter { dl.item($0)?.artist == "Genesis" }
    check(dl.referenceAdvice(for: genesis.first!)!.artistBlockHint == "Der står 6 Genesis-plader i træk, og din plade er den længst til venstre."
          && dl.referenceAdvice(for: genesis.last!)!.artistBlockHint == "Der står 6 Genesis-plader i træk, og din plade er den længst til højre.",
          "Genesis-blok hint ved blokkens kanter")

    // Teksterne er entydige: set fra din plade, venstre/højre, aldrig "før"/"efter".
    var ambiguous: [String] = [], wrongSide: [String] = [], badHint: [String] = [], tripled: [String] = []
    for id in dl.globalOrder {
        let a = dl.referenceAdvice(for: id)!
        let texts = [a.primary.reason, a.secondary?.reason, a.artistBlockHint, a.placementHint, a.sectionEdgeHint].compactMap { $0 }
        for t in texts where t.contains(" før") || t.contains(" efter") || t.hasPrefix("Står ") || t.hasPrefix("Pladen ") || t.contains("?.") {
            ambiguous.append(t)
        }
        for r in [a.primary, a.secondary].compactMap({ $0 }) {
            switch r.side {
            case .before: if !r.reason.contains("til venstre for din plade") && !r.reason.contains("lige til højre for") { wrongSide.append(r.reason) }
            case .after: if !r.reason.contains("til højre for din plade") && !r.reason.contains("lige til venstre for") { wrongSide.append(r.reason) }
            case .sectionStart: if r.reason != "Din plade står yderst til venstre i sektionen." { wrongSide.append(r.reason) }
            case .sectionEnd: if r.reason != "Din plade står yderst til højre i sektionen." { wrongSide.append(r.reason) }
            }
        }
        if let s = a.secondary, let it = s.item, it.title != dl.item(id)!.title {
            let expected = "\(it.title) står lige til \(s.side == .before ? "venstre" : "højre") for din plade."
            if s.reason != expected { wrongSide.append(s.reason) }
        }
        let n = dl.neighbors(of: id)!
        if a.placementHint != "Plade \(n.position!) af \(n.sectionCount) fra venstre" { badHint.append(a.placementHint) }
        if a.artistBlockHint != nil && a.primary.reason.contains("tæl") { tripled.append(a.primary.reason) }
    }
    check(ambiguous.isEmpty, "ingen tvetydige tekster: \(ambiguous.prefix(3))")
    check(wrongSide.isEmpty, "referencer siger venstre/højre set fra din plade: \(wrongSide.prefix(3))")
    check(badHint.isEmpty, "kort placeringstekst: \(badHint.prefix(3))")
    check(tripled.isEmpty, "tælleinstruktion og blok-hint gentager ikke hinanden: \(tripled.prefix(2))")
    let hunky = dl.allItems.first { $0.title == "Hunky Dory" }!.id
    check(dl.referenceAdvice(for: hunky)!.primary.reason ==
          "Din plade står blandt 5 David Bowie-plader i træk. Find Bob Dylan – John Wesley Harding, som står lige til venstre for dem, og tæl mod højre: din plade er nr. 2, lige til højre for \"Heroes\".",
          "tælleinstruktion fra venstre: \(dl.referenceAdvice(for: hunky)!.primary.reason)")
    let lastA = dl.sections[dl.locations[0].id]!.last!
    check(dl.referenceAdvice(for: lastA)!.sectionEdgeHint == "Næste sektion (1B) begynder med Dire Straits – Brothers In Arms.",
          "sektionskant: næste sektion nævnes: \(dl.referenceAdvice(for: lastA)!.sectionEdgeHint ?? "nil")")
    let lastB = dl.sections[dl.locations[1].id]!.last!
    check(dl.referenceAdvice(for: lastB)!.sectionEdgeHint?.hasSuffix("Morning Glory?") == true, "titel med ? får ikke ekstra punktum")
    let darkSides = dl.globalOrder.filter { dl.item($0)?.title == "The Dark Side Of The Moon" }
    check(dl.referenceAdvice(for: darkSides[0])!.secondary?.reason == "Et andet eksemplar af The Dark Side Of The Moon står lige til højre for din plade.",
          "andet eksemplar af samme plade nævnes som sådan")
    check(dl.referenceAdvice(for: dl.globalOrder[5])!.artistBlockHint == nil && dl.referenceAdvice(for: dl.globalOrder[5])!.sectionEdgeHint == nil,
          "ingen ekstra hints midt i sektionen mellem andre kunstnere")
    let aurora = dl.allItems.first { $0.artist == "Åge Aleksandersen" }!.id
    check(dl.globalOrder.last == aurora, "Åge Aleksandersen står sidst (Å efter Z)")
}

// MARK: Deep scan – ende-til-ende-flows og grænsetilfælde
func freshStore(_ tag: String) throws -> (ShelfStore, URL) {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("vsf-\(tag)-\(UUID().uuidString).sqlite")
    return (try ShelfStore(path: url.path), url)
}
func placementRows(_ s: ShelfStore) -> [String] {
    (try? s.db.query("SELECT copy_id, location_id, position FROM placements ORDER BY copy_id").map {
        "\($0["copy_id"]!.int!):\($0["location_id"]!.int!):\($0["position"]!.int!)"
    }) ?? ["fejl"]
}
func positions(_ s: ShelfStore, _ loc: Int64) -> [Int] {
    (try? s.db.query("SELECT position FROM placements WHERE location_id = ? ORDER BY position", loc).map { Int($0["position"]!.int!) }) ?? [-1]
}

// Sync: dubletter, metadata-tælling, genrer og placeringer
do {
    let (s, url) = try freshStore("sync")
    defer { try? FileManager.default.removeItem(at: url) }
    var c = [item(1, 1, "ABBA", "Arrival"), item(2, 2, "Bowie", "Low"), item(3, 2, "Bowie", "Low"), item(4, 3, "Queen", "Jazz")]
    var r = try s.applyCollection(c + [c[0]])   // instance 1 to gange (sideskift under sync)
    check(r.newCopies.count == 4 && r.total == 4, "sync: dublet-instance giver ikke fejl og kun én kopi")
    check(r.updatedReleases == 0, "sync: ny release med to kopier tælles ikke som opdateret (fik \(r.updatedReleases))")
    var l = try s.loadLibrary()
    let loc = try s.addSection(shelf: 1, section: "A")
    for (i, id) in SortRules().sorted(l.allItems).map(\.id).enumerated() { try s.move(copyID: id, to: loc, index: i) }
    let before = placementRows(s)
    r = try s.applyCollection(c)
    check(r.updatedReleases == 0 && r.newCopies.isEmpty && r.removedCopies.isEmpty, "sync: uændret samling giver tom rapport")
    c[1].release.genres = "Rock"; c[2].release.genres = "Rock"
    r = try s.applyCollection(c)
    l = try s.loadLibrary()
    check(r.updatedReleases == 1 && l.releases[2]?.genres == "Rock", "sync: ændrede genrer opdateres (én gang pr. release)")
    // Fjernet + ny + ændret metadata i samme sync: placeringer er uberørte.
    c.removeAll { $0.instanceID == 4 }
    c[0].release.title = "Arrival (Deluxe)"
    c.append(item(5, 9, "Zappa", "Hot Rats"))
    r = try s.applyCollection(c)
    check(placementRows(s) == before, "sync: placements uændret efter fjernet/ny/ændret")
    l = try s.loadLibrary()
    check(l.unplaced.count == 1 && l.copies[l.unplaced[0]]?.discogsRank == 3, "sync: ny plade uplaceret med discogs_rank")
    let queen = l.copies.values.first { $0.instanceID == 4 }!
    check(!queen.inDiscogs && queen.discogsRank == nil && l.locationOfCopy[queen.id] == loc, "sync: fjernet plade beholder placering, mister rank")
}

// Flyt, omnummerering, rollback og fortryd
do {
    let (s, url) = try freshStore("move")
    defer { try? FileManager.default.removeItem(at: url) }
    _ = try s.applyCollection((1...5).map { item($0, $0, "Artist \($0)", "T\($0)") })
    var l = try s.loadLibrary()
    let ids = SortRules().sorted(l.allItems).map(\.id)
    try s.createLayout([(shelf: 1, section: "A", copies: Array(ids[0..<4])), (shelf: 1, section: "B", copies: [ids[4]])])
    l = try s.loadLibrary()
    let a = l.locations[0].id, b = l.locations[1].id
    // Flyt ned i samme sektion
    try s.move(copyID: ids[0], to: a, index: 2)
    l = try s.loadLibrary()
    check(l.sections[a]! == [ids[1], ids[2], ids[0], ids[3]] && (positions(s, a)) == [1, 2, 3, 4], "flyt ned i samme sektion + omnummerering")
    // Fortryd (som appen gør det: tilbage til from-position)
    let e = try s.history().first { $0.kind == .moved }!
    try s.move(copyID: e.copyID!, to: e.fromLocationID!, index: e.fromPosition! - 1)
    l = try s.loadLibrary()
    check(l.sections[a]! == Array(ids[0..<4]), "fortryd flyt genskaber rækkefølgen")
    // Flyt til ikke-eksisterende sektion: fejler og rulles tilbage
    let snapshot = placementRows(s)
    var threw = false
    do { try s.move(copyID: ids[1], to: 9999, index: 0) } catch { threw = true }
    check(threw && (placementRows(s)) == snapshot, "flyt til ukendt sektion rulles tilbage")
    // Sidste plade ud af sektion B → tom sektion; grænser og naboer holder
    try s.move(copyID: ids[4], to: a, index: Int.max)
    l = try s.loadLibrary()
    check(l.sections[b]!.isEmpty && l.sections[a]!.last == ids[4] && (positions(s, a)) == [1, 2, 3, 4, 5], "sidste plade flyttet ud – tom sektion")
    let nLast = l.neighbors(of: ids[4])!
    check(nLast.reachedSectionEnd && nLast.nextSection?.location.id == b && nLast.nextSection?.first == nil, "naboer ved tom næste sektion")
    let lbl = ShelfLabel.labels(for: l).first { $0.location.id == b }!
    check(lbl.count == 0 && lbl.firstArtist == nil, "skilt for tom sektion")
    check(l.suggestPlacement(for: ids[0], rules: SortRules(), restrictTo: b)?.index == 0, "forslag i tom sektion = først")
    // Fjern fra reolen og læg tilbage
    try s.unplace(copyID: ids[2])
    l = try s.loadLibrary()
    check(l.unplaced == [ids[2]] && (positions(s, a)) == [1, 2, 3, 4], "unplace omnummererer")
    let sug = l.suggestPlacement(for: ids[2], rules: SortRules())!
    check(sug.locationID == a && sug.before == ids[1] && sug.after == ids[3], "forslag lægger pladen tilbage mellem sine naboer")
    try s.move(copyID: ids[2], to: sug.locationID, index: sug.index)
    l = try s.loadLibrary()
    check(l.sections[a]! == [ids[0], ids[1], ids[2], ids[3], ids[4]], "placering efter forslag")
    try s.deleteEmptySection(b)
    var refused = false
    do { try s.deleteEmptySection(a) } catch { refused = true }
    check(refused && ((try? s.loadLibrary())?.locations.count ?? 0) == 1, "kun tomme sektioner kan slettes")
    do { try s.deleteEmptySection(a) } catch {
        check(error.localizedDescription == "Sektionen er ikke tom. Flyt pladerne ud af den først.", "fejltekst på dansk: \(error.localizedDescription)")
    }
    do { _ = try s.db.query("SELECT nope FROM nowhere") } catch {
        check(error.localizedDescription == "Der opstod en fejl i databasen. Prøv igen." && "\(error)".contains("nowhere"),
              "databasefejl: dansk for brugeren, teknisk i log: \(error.localizedDescription)")
    }
    let hist = try s.history().map(\.summary)
    check(hist.contains { $0.hasSuffix("fjernet fra Reol 1 · Sektion A, plads 3") }, "historik: fjernet fra reolen")
    check(!hist.contains { $0.contains(" / ") || $0.unicodeScalars.contains { $0.properties.isEmojiPresentation } },
          "historik: ingen emoji og ens placeringsformat: \(hist.filter { $0.contains(" / ") })")
    // Gamle poster i databasen vises uændret.
    try s.db.run("INSERT INTO history(at, kind, summary) VALUES(?, 'statusChanged', ?)", 1.0, "X – Y: 👤 Udlånt")
    check((try? s.history(limit: 1))?.first?.summary == "X – Y: 👤 Udlånt", "eksisterende historik ændres ikke")
    // Én plade i sektionen
    let one = try s.addSection(shelf: 2, section: "A")
    try s.move(copyID: ids[0], to: one, index: 0)
    l = try s.loadLibrary()
    let adv1 = l.referenceAdvice(for: ids[0])!
    check(adv1.primary.side == .sectionStart && adv1.secondary == nil && adv1.placementHint == "Plade 1 af 1 fra venstre", "reference: eneste plade i sektionen")
}

// Reference: udlånte plader i en kunstnerblok tælles ikke med
do {
    let (s, url) = try freshStore("ref")
    defer { try? FileManager.default.removeItem(at: url) }
    var c = [item(1, 1, "Abba", "A")]
    for i in 2...7 { c.append(item(i, i, "Genesis", "G\(i)")) }
    c.append(item(8, 8, "Queen", "Q"))
    _ = try s.applyCollection(c)
    var l = try s.loadLibrary()
    let ids = l.copies.values.sorted { $0.instanceID! < $1.instanceID! }.map(\.id)
    try s.createLayout([(shelf: 1, section: "A", copies: ids)])
    // Abba, G2, G3(udlånt), G4 = mål, G5, G6, G7, Queen
    try s.setStatus(copyID: ids[2], .lent, note: nil)
    l = try s.loadLibrary()
    let adv = l.referenceAdvice(for: ids[3])!
    check(adv.primary.reason.contains("tæl mod højre: din plade er nr. 2") && adv.primary.reason.contains("Abba"),
          "udlånt plade i blok tælles ikke: \(adv.primary.reason)")
    check(adv.primary.reason.contains("blandt 5 Genesis-plader") && adv.artistBlockHint == nil,
          "blokken tæller kun plader i reolen: \(adv.primary.reason)")
    // Landmærket (Abba) udlånt → ingen plade at finde; brug sektionens kant
    try s.setStatus(copyID: ids[0], .lent, note: nil)
    l = try s.loadLibrary()
    check(l.referenceAdvice(for: ids[3])!.primary.reason.contains("venstre kant"), "udlånt landmærke bruges ikke")
}

// Lyttelog med fortryd, forslag og værdi
do {
    let (s, url) = try freshStore("listen")
    defer { try? FileManager.default.removeItem(at: url) }
    _ = try s.applyCollection([item(1, 1, "A", "a", year: 1975), item(2, 2, "B", "b", year: 1983)])
    var l = try s.loadLibrary()
    try s.createLayout([(shelf: 1, section: "A", copies: l.copies.keys.sorted())])
    l = try s.loadLibrary()
    let id = l.globalOrder[0]
    let now = Date()
    let p = try s.logPlay(copyID: id, at: now)
    let afterLog = ListeningStats(plays: try s.loadPlays())
    check(afterLog.count[id] == 1, "spillet registreret")
    try s.deletePlay(p)
    let afterUndo = ListeningStats(plays: try s.loadPlays())
    check(afterUndo.count[id] == nil, "fortryd spillet")
    // Afspilninger i fremtiden (forkert ur) må ikke crashe forslaget
    for cid in l.globalOrder { try s.logPlay(copyID: cid, at: now.addingTimeInterval(3 * 365 * 86400)) }
    let stats = ListeningStats(plays: try s.loadPlays())
    var rng = SystemRandomNumberGenerator()
    let cands = ListenPicker.candidates(l.allItems, library: l, filter: ListenFilter(), stats: stats, now: now)
    check(ListenPicker.pick(from: cands, stats: stats, avoiding: [], now: now, using: &rng) != nil, "forslag med fremtidige afspilninger")
    check(ListenPicker.pick(from: [], stats: stats, avoiding: [], now: now, using: &rng) == nil, "forslag uden kandidater = nil")
    check(ListenPicker.decades(in: l.allItems) == [1970, 1980], "årtier")
    // Værdi: gem/indlæs og valutaskift overskriver
    let v = try JSONDecoder().decode(CollectionValue.self, from: Data(#"{"minimum":"€1","median":"€2","maximum":"€3","fetchedAt":1000}"#.utf8))
    s.saveCollectionValue(v)
    check(s.loadCollectionValue() == v, "samlingsværdi gemmes")
    try s.saveMarket(1, MarketInfo(lowestPrice: 10, currency: "EUR", numForSale: 1, have: 0, want: 3))
    try s.saveMarket(1, MarketInfo(lowestPrice: 90, currency: "SEK", numForSale: nil, have: nil, want: nil))
    let m = try s.loadMarket()
    check(m.count == 1 && m[1]?.currency == "SEK" && m[1]?.lowestPrice == 90 && m[1]?.have == nil, "markedsdata overskrives ved valutaskift")
    check(MarketInfo(lowestPrice: nil, currency: "EUR", numForSale: nil, have: 0, want: 5).demand == nil, "efterspørgsel: ingen division med 0")
}

// SQLite-robusthed
do {
    var threw = false
    do { _ = try ShelfStore(path: FileManager.default.temporaryDirectory.path) } catch { threw = true }
    check(threw, "database-sti der er en mappe giver fejl (ikke crash)")
    check(SQLValue.double(.nan).int == nil && SQLValue.double(1e300).int == nil && SQLValue.double(3.9).int == 3, "REAL→Int crasher ikke")
    let (s, url) = try freshStore("schema")
    defer { try? FileManager.default.removeItem(at: url) }
    check(s.db.userVersion == 4, "skema v4")
    _ = try s.applyCollection([item(1, 1, "O'Brien", "Robert'); DROP TABLE copies;--")])
    let reopened = try ShelfStore(path: url.path)
    check((try? reopened.loadLibrary())?.allItems.first?.title == "Robert'); DROP TABLE copies;--", "genåbning + strenge bindes sikkert")
}

// Migration v3 → v4 bevarer data
do {
    let (s, url) = try freshStore("migr")
    defer { try? FileManager.default.removeItem(at: url) }
    _ = try s.applyCollection([item(1, 1, "A", "a")])
    try s.db.execute("DROP TABLE plays; PRAGMA user_version = 3;")
    let up = try ShelfStore(path: url.path)
    let cid = try up.loadLibrary().copies.keys.first!
    check(up.db.userVersion == 4 && (try? up.logPlay(copyID: cid)) != nil, "migration v3→v4 opretter plays og bevarer kopier")
}

// Søgning: Unicode og grænsetilfælde
do {
    let (s, url) = try freshStore("search")
    defer { try? FileManager.default.removeItem(at: url) }
    _ = try s.applyCollection([item(1, 1, "Kim Larsen", "Værsgo"), item(2, 2, "Åge Aleksandersen", "Levva Livet"),
                               item(3, 3, "Mötley Crüe", "Dr. Feelgood"), item(4, 4, "Simon & Garfunkel", "Bookends")])
    let ix = SearchIndex(library: try s.loadLibrary())
    check(ix.search("").isEmpty && ix.search("   ").isEmpty && ix.search("!!!").isEmpty, "tom søgning")
    check(ix.search("VÆRSGO").count == 1 && ix.search("vaersgo").count == 1, "Æ søges uafhængigt af store/små og ae")
    check(ix.search("åge").count == 1 && ix.search("motley crue").count == 1, "Å og diakritika")
    check(ix.search("simon and garfunkel").count == 1, "& = and")
    _ = ix.search("🎵"); _ = ix.search("a"); _ = ix.search("xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx")
    check(ix.search("varsgo").count == 1, "stavefejl uden crash")
}

// Søgning: samme relevans → reolens rækkefølge (sektion, position), uplacerede sidst
do {
    let (s, url) = try freshStore("searchorder")
    defer { try? FileManager.default.removeItem(at: url) }
    // Uplaceret plade får det laveste id, og sektionernes id'er er omvendt af reolens rækkefølge.
    _ = try s.applyCollection([item(1, 1, "Pink Floyd", "Ummagumma"), item(2, 2, "Pink Floyd", "The Wall"),
                               item(3, 3, "Pink Floyd", "Animals"), item(4, 4, "Pink Floyd", "Wish You Were Here"),
                               item(5, 5, "Pink Floyd", "Meddle"), item(6, 6, "Pink Floyd", "The Dark Side Of The Moon")])
    var l = try s.loadLibrary()
    func cid(_ title: String) -> Int64 { l.allItems.first { $0.title == title }!.id }
    let second = try s.addSection(shelf: 2, section: "A")
    let first = try s.addSection(shelf: 1, section: "A")
    for (i, t) in ["Meddle", "The Dark Side Of The Moon", "Wish You Were Here"].enumerated() { try s.move(copyID: cid(t), to: first, index: i) }
    for (i, t) in ["Animals", "The Wall"].enumerated() { try s.move(copyID: cid(t), to: second, index: i) }
    l = try s.loadLibrary()
    let ix = SearchIndex(library: l)
    let expected = ["Meddle", "The Dark Side Of The Moon", "Wish You Were Here", "Animals", "The Wall", "Ummagumma"]
    let got = ix.search("pink floid").map { l.item($0)!.title }
    check(got == expected, "samme relevans i reolens rækkefølge, uplacerede sidst: \(got)")
    check(ix.search("pink floyd").map { l.item($0)!.title } == expected, "også uden stavefejl")
    check(ix.search("pink floyd wall").first.map { l.item($0)!.title } == "The Wall", "bedre match kommer stadig først")
}

// Mobilside: parsing, routing og escaping
do {
    func req(_ raw: String) -> MobileSite.Request? { MobileSite.Request.parse(Data(raw.utf8)) }
    check(req("GET /?q=AC%2BDC+live HTTP/1.1\r\nHost: x\r\n\r\n")?.query["q"] == "AC+DC live", "query: + er mellemrum, %2B er plus")
    check(req("GET /?q=%C3%A6%C3%B8%C3%A5 HTTP/1.1\r\n\r\n")?.query["q"] == "æøå", "query: procent-dekodet UTF-8")
    check(req("GET /?q=%zz HTTP/1.1\r\n\r\n")?.query["q"] == "%zz", "query: ugyldig procent-kode crasher ikke")
    check(req("") == nil && req("GARBAGE") == nil && req("\r\n\r\n") == nil, "ugyldig request = nil")
    var bad = Data("GET /section/3 HTTP/1.1\r\nX: ".utf8); bad.append(contentsOf: [0xFF, 0xFE]); bad.append(Data("\r\n\r\n".utf8))
    check(MobileSite.Request.parse(bad)?.path == "/section/3", "ugyldig UTF-8 i header afviser ikke requesten")
    check(req("POST /record/5/play HTTP/1.1\n\n")?.method == "POST", "linjeskift uden \\r")

    let (s, url) = try freshStore("mobile")
    defer { try? FileManager.default.removeItem(at: url) }
    _ = try s.applyCollection([item(1, 77, "<script>alert(1)</script>", "\"><img src=x onerror=alert(1)>"), item(2, 78, "Bob", "Plain")])
    var l = try s.loadLibrary()
    let ids = l.copies.keys.sorted()
    try s.createLayout([(shelf: 1, section: "<b>X", copies: ids)])
    l = try s.loadLibrary()
    let loc = l.locations[0].id
    func route(_ m: String, _ path: String, _ q: [String: String] = [:]) -> MobileSite.Reply {
        MobileSite.route(MobileSite.Request(method: m, path: path, query: q), library: l, stats: .empty)
    }
    func html(_ r: MobileSite.Reply) -> String { if case .html(let h) = r { return h } else { return "" } }
    let pages = [html(route("GET", "/")), html(route("GET", "/", ["q": "bob"])), html(route("GET", "/", ["q": "script"])),
                 html(route("GET", "/section/\(loc)", ["mark": "\(ids[0])"])), html(route("GET", "/record/\(ids[0])")),
                 html(route("GET", "/record/\(ids[1])"))]
    check(pages.allSatisfy { !$0.isEmpty }, "mobilside: alle sider renderes")
    check(pages.allSatisfy { !$0.contains("<script>alert") && !$0.contains("<img src=x") && !$0.contains("<b>X") }, "mobilside: titler, kunstnere og sektionsnavne escapes")
    check(route("GET", "/section/999") == .notFound && route("GET", "/section/abc") == .notFound && route("GET", "/record/999") == .notFound, "mobilside: ukendte id'er = 404")
    check(route("POST", "/record/\(ids[0])/play") == .logPlay(copyID: ids[0], then: "/record/\(ids[0])?played=1"), "mobilside: Spillet-knap")
    check(route("GET", "/record/\(ids[0])/play") == .notFound && route("POST", "/") == .notFound, "mobilside: forkert metode = 404")
    check(route("GET", "/cover/77", ["s": "l"]) == .cover(releaseID: 77, large: true) && route("GET", "/cover/1") == .notFound, "mobilside: cover-route")
    check(html(route("GET", "/record/\(ids[0])", ["played": "1"])).contains("Registreret"), "mobilside: bekræftelse efter Spillet")
    let resp = MobileSite.response(status: 200, contentType: "text/html; charset=utf-8", body: Data("æ".utf8))
    check(String(decoding: resp, as: UTF8.self).contains("Content-Length: 2\r\n"), "Content-Length tæller bytes")
}

// MARK: Ude af reolen (fx På væggen): fysisk nummerering og "sæt tilbage"

/// Kontrollerer reglerne for fysisk nummerering og `returnAdvice` for alle plader,
/// mens pladerne i `out` er ude af reolen. Returnerer en liste over fejl (tom = alt i orden).
func physicalSweep(_ base: Library, out: [Int64]) -> [String] {
    var copies = base.copies
    for id in out { copies[id]!.status = .wall }
    let placements = base.locations.flatMap { loc in
        base.sections[loc.id]!.enumerated().map { (copyID: $0.element, locationID: loc.id, position: $0.offset + 1) }
    }
    let lib = Library(releases: base.releases, copies: copies, locations: base.locations, placements: placements)
    let outSet = Set(out)
    var problems: [String] = []
    for loc in lib.locations {
        let onShelf = lib.sections[loc.id]!.filter { !outSet.contains($0) }
        let expected = Dictionary(uniqueKeysWithValues: onShelf.enumerated().map { ($0.element, $0.offset + 1) })
        if lib.shelfNumbers(in: loc.id) != expected { problems.append("shelfNumbers i \(loc.shortName)") }
        if lib.onShelfCount(in: loc.id) != onShelf.count { problems.append("onShelfCount i \(loc.shortName)") }
    }
    for target in lib.globalOrder {
        let title = lib.item(target)!.title
        let loc = lib.locationOfCopy[target]!
        let physical = lib.sections[loc]!.filter { $0 == target || !outSet.contains($0) }
        let t = physical.firstIndex(of: target)!
        let n = lib.neighbors(of: target)!
        if n.position != t + 1 || n.sectionCount != physical.count { problems.append("position/antal for \(title): \(n.position ?? -1)/\(n.sectionCount)") }
        if !outSet.contains(target) && lib.shelfNumbers(in: loc)[target] != n.position { problems.append("shelfNumbers ≠ position for \(title)") }
        // Når en ude-plade sættes tilbage, får den præcis det nummer, der blev sagt.
        if outSet.contains(target) {
            var back = copies; back[target]!.status = .home
            let after = Library(releases: lib.releases, copies: back, locations: lib.locations, placements: placements)
            if after.shelfNumbers(in: loc)[target] != t + 1 || after.onShelfCount(in: loc) != physical.count {
                problems.append("tilbage på en anden plads end sagt: \(title)")
            }
        }
        if lib.referenceAdvice(for: target)!.placementHint != "Plade \(t + 1) af \(physical.count) fra venstre" { problems.append("Find-placementHint for \(title)") }

        let r = lib.returnAdvice(for: target)!
        let texts = [r.primary.reason, r.secondary?.reason, r.artistBlockHint, r.placementHint, r.sectionEdgeHint].compactMap { $0 }
        if r.placementHint != "Plads \(t + 1) af \(physical.count) fra venstre" { problems.append("placementHint: \(r.placementHint)") }
        for txt in texts where txt.contains(" før") || txt.contains(" efter") || txt.contains("?.") || txt.contains("din plade er") || txt.contains("står lige til venstre for din") || txt.contains("står lige til højre for din") {
            problems.append("tekst set fra reolen, ikke fra pladen: \(txt)")
        }
        for txt in [r.primary.reason, r.secondary?.reason, r.artistBlockHint].compactMap({ $0 })
            where !txt.hasPrefix("Sæt den ") && !txt.hasPrefix("Din plade skal stå ") {
            problems.append("tekst siger ikke 'sæt den'/'skal stå': \(txt)")
        }
        for txt in texts where txt.contains("tæl") && !txt.contains("skal stå") { problems.append("tælleinstruktion uden 'skal stå': \(txt)") }
        // Nævner aldrig en plade, der selv er ude. Navne på plader i reolen fjernes først, så fx
        // "Hunting High And Low" ikke forveksles med "Low", og et andet eksemplar ikke tæller.
        let shelfNames = lib.globalOrder.filter { !outSet.contains($0) }
            .flatMap { [lib.item($0)!.fullName, lib.item($0)!.title] }.sorted { $0.count > $1.count }
        var rest = texts.joined(separator: " | ")
        for name in shelfNames { rest = rest.replacingOccurrences(of: name, with: "#") }
        for id in outSet where id != target {
            let other = lib.item(id)!
            if rest.contains(other.title) || [r.primary.item?.id, r.secondary?.item?.id].contains(id) {
                problems.append("\(title): nævner \(other.title), som er ude: \(texts)")
            }
        }
        for it in [r.primary.item, r.secondary?.item].compactMap({ $0 }) where outSet.contains(it.id) {
            problems.append("\(title): reference til en plade, der er ude")
        }
        // Venstre/højre: en plade til venstre for pladen → "sæt den lige til højre for" den, og omvendt.
        for ref in [r.primary, r.secondary].compactMap({ $0 }) {
            let core = ref.reason.replacingOccurrences(of: "som står lige til venstre for dem", with: "")
                .replacingOccurrences(of: "som står lige til højre for dem", with: "")
            switch ref.side {
            case .before:
                if ref.item?.id != (t > 0 ? physical[t - 1] : nil) || !core.contains("lige til højre for") || core.contains("lige til venstre for") {
                    problems.append("venstre nabo forkert for \(title): \(ref.reason)")
                }
            case .after:
                if ref.item?.id != (t + 1 < physical.count ? physical[t + 1] : nil) || !core.contains("lige til venstre for") || core.contains("lige til højre for") {
                    problems.append("højre nabo forkert for \(title): \(ref.reason)")
                }
            case .sectionStart:
                if t != 0 || ref.reason != "Sæt den yderst til venstre i sektionen." { problems.append("venstre kant for \(title): \(ref.reason)") }
            case .sectionEnd:
                if t != physical.count - 1 || ref.reason != "Sæt den yderst til højre i sektionen." { problems.append("højre kant for \(title): \(ref.reason)") }
            }
        }
    }
    return problems
}

do {
    check(CopyStatus.wall.rawValue == "wall" && CopyStatus.wall.label == "På væggen" && !CopyStatus.wall.isOnShelf && CopyStatus.wall.emoji == "🖼",
          "På væggen: rawValue, label, emoji og står ikke i reolen")
    check(CopyStatus.allCases == [.home, .wall, .lent, .stored, .missing], "rækkefølge af statusser: \(CopyStatus.allCases.map(\.rawValue))")
    check(CopyStatus.allCases.filter(\.isOnShelf) == [.home], "kun På plads tæller som i reolen")

    let (s, url) = try freshStore("wall")
    defer { try? FileManager.default.removeItem(at: url) }
    let records = [("ABBA", "Arrival"), ("Aurora", "All My Demons Greeting Me as a Friend"), ("The Beatles", "Abbey Road"),
                   ("The Beatles", "Help!"), ("The Beatles", "Revolver"), ("Bob Dylan", "Blonde On Blonde"),
                   ("Genesis", "Trespass"), ("Genesis", "Nursery Cryme"), ("Genesis", "Foxtrot"),
                   ("Genesis", "Selling England By The Pound"), ("Queen", "Jazz"), ("Frank Zappa", "Hot Rats")]
    _ = try s.applyCollection(records.enumerated().map { item($0.offset + 1, 500 + $0.offset, $0.element.0, $0.element.1) })
    var l = try s.loadLibrary()
    let ids = l.copies.values.sorted { $0.instanceID! < $1.instanceID! }.map(\.id)
    try s.createLayout([(shelf: 1, section: "A", copies: Array(ids[0..<6])), (shelf: 1, section: "B", copies: Array(ids[6..<11])),
                        (shelf: 2, section: "A", copies: [ids[11]])])
    l = try s.loadLibrary()
    let a = l.locations[0].id, b = l.locations[1].id, c = l.locations[2].id
    let (abba, aurora, abbey, help, revolver, dylan) = (ids[0], ids[1], ids[2], ids[3], ids[4], ids[5])
    let (trespass, nursery, foxtrot, selling, queen, zappa) = (ids[6], ids[7], ids[8], ids[9], ids[10], ids[11])
    let original = placementRows(s)
    func pos(_ id: Int64) -> String { l.neighbors(of: id).map { "\($0.position ?? -1)/\($0.sectionCount)" } ?? "nil" }
    func set(_ id: Int64, _ st: CopyStatus) throws { try s.setStatus(copyID: id, st, note: nil); l = try s.loadLibrary() }
    func texts(_ r: Library.ReferenceAdvice) -> [String] {
        [r.primary.reason, r.secondary?.reason, r.artistBlockHint, r.placementHint, r.sectionEdgeHint].compactMap { $0 }
    }

    // Før: alle står i reolen.
    check(pos(revolver) == "5/6" && l.referenceAdvice(for: revolver)?.placementHint == "Plade 5 af 6 fra venstre", "før: Plade 5 af 6")
    check(l.shelfNumbers(in: a) == [abba: 1, aurora: 2, abbey: 3, help: 4, revolver: 5, dylan: 6] && l.onShelfCount(in: a) == 6,
          "før: shelfNumbers 1…6 og onShelfCount 6")

    // Aurora hænges på væggen.
    try set(aurora, .wall)
    check(placementRows(s) == original, "På væggen flytter ikke placements")
    let storedStatus = try s.db.query("SELECT status FROM copies WHERE id = ?", aurora).first?["status"]?.text
    check(storedStatus == "wall" && l.copies[aurora]?.status == .wall,
          "status gemmes som teksten 'wall' og læses tilbage")
    check(l.sections[a]?.count == 6 && l.indexInSection[aurora] == 1 && l.locationOfCopy[aurora] == a, "pladen på væggen beholder sin plads i databasen")
    check(pos(revolver) == "4/5" && l.referenceAdvice(for: revolver)?.placementHint == "Plade 4 af 5 fra venstre",
          "plader til højre rykker sammen: Plade 5 af 6 → 4 af 5 (fik \(pos(revolver)))")
    check(pos(abba) == "1/5", "plade til venstre beholder sit nummer: \(pos(abba))")
    check(pos(aurora) == "2/6", "ude-plade: nummeret når den sættes tilbage, talt med sig selv: \(pos(aurora))")
    check(l.shelfNumbers(in: a) == [abba: 1, abbey: 2, help: 3, revolver: 4, dylan: 5], "shelfNumbers springer pladen på væggen over")
    check(l.onShelfCount(in: a) == 5 && l.onShelfCount(in: b) == 5 && l.onShelfCount(in: c) == 1, "onShelfCount")
    let ra = l.returnAdvice(for: aurora)!
    check(ra.primary.side == .before && ra.primary.item?.id == abba && ra.primary.reason == "Sæt den lige til højre for ABBA – Arrival.",
          "sæt tilbage: til højre for pladen til venstre: \(ra.primary.reason)")
    check(ra.secondary?.side == .after && ra.secondary?.item?.id == abbey && ra.secondary?.reason == "Sæt den lige til venstre for The Beatles – Abbey Road.",
          "sæt tilbage: til venstre for pladen til højre: \(ra.secondary?.reason ?? "nil")")
    check(ra.placementHint == "Plads 2 af 6 fra venstre" && ra.artistBlockHint == nil && ra.sectionEdgeHint == nil,
          "sæt tilbage: Plads 2 af 6 (tæller sig selv med): \(ra.placementHint)")
    let findAbbey = l.referenceAdvice(for: abbey)!
    check(findAbbey.primary.item?.id == abba && findAbbey.primary.reason == "Arrival står lige til venstre for din plade. Det er en anden kunstner, så den er let at få øje på."
          && !texts(findAbbey).contains { $0.contains("Aurora") } && findAbbey.placementHint == "Plade 2 af 5 fra venstre",
          "Find: naboen springer pladen på væggen over: \(texts(findAbbey))")

    // Sat tilbage: samme plads som sagt, og numrene rykker igen.
    let saidPosition = pos(aurora)
    try set(aurora, .home)
    check(placementRows(s) == original && pos(aurora) == saidPosition && pos(revolver) == "5/6" && l.onShelfCount(in: a) == 6,
          "sat tilbage: står hvor returnAdvice sagde, og numrene rykker tilbage")

    // Revolver på væggen: anden kunstner til højre, blok-hint og titel med "!".
    try set(revolver, .wall)
    let rr = l.returnAdvice(for: revolver)!
    check(rr.primary.side == .after && rr.primary.item?.id == dylan
          && rr.primary.reason == "Sæt den lige til venstre for Bob Dylan – Blonde On Blonde. Det er en anden kunstner, så den er let at få øje på.",
          "sæt tilbage: anden kunstner til højre: \(rr.primary.reason)")
    check(rr.secondary?.item?.id == help && rr.secondary?.reason == "Sæt den lige til højre for Help!", "samme kunstner nævnes med titel, ingen ekstra punktum: \(rr.secondary?.reason ?? "nil")")
    check(rr.artistBlockHint == "Din plade skal stå længst til højre blandt 3 The Beatles-plader i træk." && rr.placementHint == "Plads 5 af 6 fra venstre",
          "blok-hint ved sæt tilbage: \(rr.artistBlockHint ?? "nil")")
    try set(revolver, .home)

    // Help! på væggen og Aurora udlånt: tælleinstruktion, og landmærket er ikke Aurora.
    try set(help, .wall); try set(aurora, .lent)
    let rh = l.returnAdvice(for: help)!
    check(rh.primary.reason == "Din plade skal stå blandt 3 The Beatles-plader i træk. Find ABBA – Arrival, som står lige til venstre for dem, og tæl mod højre: din plade skal stå som nr. 2, lige til højre for Abbey Road.",
          "tælleinstruktion med 'skal stå': \(rh.primary.reason)")
    check(rh.secondary?.reason == "Sæt den lige til venstre for Revolver." && rh.placementHint == "Plads 3 af 5 fra venstre" && rh.artistBlockHint == nil,
          "sæt tilbage midt i blok: \(rh.secondary?.reason ?? "nil") / \(rh.placementHint)")
    check(!texts(rh).contains { $0.contains("Aurora") } && !texts(l.returnAdvice(for: aurora)!).contains { $0.contains("Help!") },
          "returnAdvice nævner aldrig en plade, der selv er ude")
    try set(help, .home); try set(aurora, .home)

    // Kant: første plade.
    try set(abba, .wall)
    let rf = l.returnAdvice(for: abba)!
    check(rf.primary.side == .sectionStart && rf.primary.item == nil && rf.primary.reason == "Sæt den yderst til venstre i sektionen."
          && rf.secondary?.reason == "Sæt den lige til venstre for Aurora – All My Demons Greeting Me as a Friend." && rf.placementHint == "Plads 1 af 6 fra venstre",
          "første plade: \(texts(rf))")
    var lbl = ShelfLabel.labels(for: l)[0]
    check(lbl.firstArtist == "Aurora" && lbl.lastArtist == "Bob Dylan" && lbl.count == 5, "skilt: første kunstner og antal tæller kun plader i reolen: \(lbl)")
    try set(abba, .home)

    // Kant: sidste plade.
    try set(dylan, .wall)
    let rl = l.returnAdvice(for: dylan)!
    check(rl.primary.side == .sectionEnd && rl.primary.reason == "Sæt den yderst til højre i sektionen."
          && rl.secondary?.reason == "Sæt den lige til højre for The Beatles – Revolver." && rl.placementHint == "Plads 6 af 6 fra venstre"
          && rl.sectionEdgeHint == "Næste sektion (1B) begynder med Genesis – Trespass.",
          "sidste plade: \(texts(rl))")
    lbl = ShelfLabel.labels(for: l)[0]
    check(lbl.firstArtist == "ABBA" && lbl.lastArtist == "The Beatles" && lbl.count == 5, "skilt: sidste kunstner tæller kun plader i reolen: \(lbl)")
    try set(dylan, .home)

    // Sektion, hvor alle andre er ude.
    for (id, st) in [(trespass, CopyStatus.lent), (nursery, .stored), (foxtrot, .missing), (queen, .wall), (selling, .wall)] { try set(id, st) }
    check(placementRows(s) == original, "flere statusskift flytter ikke placements")
    let rb = l.returnAdvice(for: selling)!
    check(rb.primary.side == .sectionStart && rb.secondary == nil && rb.placementHint == "Plads 1 af 1 fra venstre" && pos(selling) == "1/1",
          "alle andre ude: \(texts(rb))")
    check(rb.sectionEdgeHint == "Forrige sektion (1A) slutter med Bob Dylan – Blonde On Blonde. Næste sektion (2A) begynder med Frank Zappa – Hot Rats.",
          "alle andre ude: nabosektioner nævnes: \(rb.sectionEdgeHint ?? "nil")")
    check(l.onShelfCount(in: b) == 0 && l.shelfNumbers(in: b).isEmpty, "alle ude: onShelfCount 0 og ingen numre")
    lbl = ShelfLabel.labels(for: l)[1]
    check(lbl.count == 0 && lbl.firstArtist == nil && lbl.lastArtist == nil, "skilt: sektion hvor alle er ude")
    check(l.neighbors(of: dylan)!.nextSection?.first == nil && l.returnAdvice(for: dylan)!.sectionEdgeHint == nil,
          "næste sektion uden plader i reolen nævnes ikke med en ude-plade")
    do {
        let home = { if case .html(let h) = MobileSite.route(MobileSite.Request(method: "GET", path: "/"), library: l, stats: .empty) { return h }; return "" }()
        check(home.contains("(alle plader er ude)") && home.contains("ABBA → Bob Dylan"), "mobil forside: sektion hvor alle er ude")
    }
    try set(foxtrot, .home)
    let rb2 = l.returnAdvice(for: selling)!
    check(pos(foxtrot) == "1/1" && l.referenceAdvice(for: foxtrot)?.placementHint == "Plade 1 af 1 fra venstre"
          && rb2.primary.side == .sectionEnd && rb2.secondary?.reason == "Sæt den lige til højre for Foxtrot." && rb2.placementHint == "Plads 2 af 2 fra venstre",
          "én plade tilbage i sektionen: \(texts(rb2))")
    for id in [trespass, nursery, queen, selling] { try set(id, .home) }

    // Sektion med én plade.
    try set(zappa, .wall)
    let rz = l.returnAdvice(for: zappa)!
    check(rz.primary.side == .sectionStart && rz.secondary == nil && rz.placementHint == "Plads 1 af 1 fra venstre" && l.onShelfCount(in: c) == 0
          && rz.sectionEdgeHint == "Forrige sektion (1B) slutter med Queen – Jazz.",
          "sektion med én plade: \(texts(rz))")
    check(ShelfLabel.labels(for: l)[2].count == 0 && ShelfLabel.labels(for: l)[2].firstArtist == nil, "skilt: eneste plade på væggen")
    try set(zappa, .home)
    check(l.referenceAdvice(for: zappa)?.placementHint == "Plade 1 af 1 fra venstre" && l.onShelfCount(in: c) == 1, "sektion med én plade tilbage")

    // Statusskift ændrer aldrig placements – heller ikke frem og tilbage gennem alle statusser.
    var moved: [String] = []
    for st in CopyStatus.allCases + [.home] { try set(help, st); if placementRows(s) != original { moved.append(st.rawValue) } }
    check(moved.isEmpty && placementRows(s) == original, "statusskift (alle statusser) ændrer aldrig placements: \(moved)")
    check(l.unplaced.isEmpty && l.shelfNumbers(in: a).count == 6, "alt er tilbage")

    // Mobilside: kun plader i reolen nummereres; ude-plader nedtonet uden nummer og med status.
    try set(aurora, .wall)
    func html(_ path: String, _ q: [String: String] = [:]) -> String {
        if case .html(let h) = MobileSite.route(MobileSite.Request(method: "GET", path: path, query: q), library: l, stats: .empty) { return h }
        return ""
    }
    func rowNumbers(_ h: String) -> [Int64: String] {
        let re = try! NSRegularExpression(pattern: #"<li id="c(\d+)" class="[^"]*"><a class="row" href="/record/\d+"><span class="num">([^<]*)</span>"#)
        var out: [Int64: String] = [:]
        for m in re.matches(in: h, range: NSRange(h.startIndex..., in: h)) {
            out[Int64(h[Range(m.range(at: 1), in: h)!])!] = String(h[Range(m.range(at: 2), in: h)!])
        }
        return out
    }
    let sec = html("/section/\(a)")
    check(rowNumbers(sec) == [abba: "1", aurora: "", abbey: "2", help: "3", revolver: "4", dylan: "5"], "mobil sektion: fysiske numre, intet nummer på væggen: \(rowNumbers(sec))")
    check(sec.contains("<li id=\"c\(aurora)\" class=\"away\">") && sec.contains("<span class=\"sub\">På væggen</span>") && sec.contains("5 plader (+1 ude)"),
          "mobil sektion: pladen på væggen er nedtonet med status, og antallet tæller kun plader i reolen")
    check(rowNumbers(html("/section/\(a)", ["mark": "\(aurora)"]))[aurora] == "" && html("/section/\(a)", ["mark": "\(aurora)"]).contains("class=\"away mark\""),
          "mobil sektion: markeret ude-plade")
    let recRev = html("/record/\(revolver)")
    check(recRev.contains("Plade 4 af 5 fra venstre") && recRev.contains("Gå til") && !recRev.contains("Aurora"), "mobil plade: fysiske tal for plade i reolen")
    let recAur = html("/record/\(aurora)")
    check(recAur.contains("Plads 2 af 6 fra venstre") && recAur.contains("Hører til") && recAur.contains("Sæt tilbage")
          && recAur.contains("Sæt den lige til højre for ABBA – Arrival.") && recAur.contains("“På væggen”"),
          "mobil plade: ude-plade viser, hvor den skal sættes tilbage")
    let home = html("/")
    check(home.contains("ABBA → Bob Dylan") && home.contains("5 plader") && !home.contains("6 plader"), "mobil forside: antal tæller kun plader i reolen")
    check(html("/", ["q": "revolver"]).contains("1A · plads 4") && html("/", ["q": "aurora"]).contains("1A · på væggen")
          && !html("/", ["q": "aurora"]).contains("plads 2"), "mobil søgning: fysisk plads, intet nummer for ude-plade")
    try set(aurora, .home)
    check(rowNumbers(html("/section/\(a)"))[aurora] == "2" && rowNumbers(html("/section/\(a)"))[revolver] == "5", "mobil sektion: numrene rykker igen efter tilbagesætning")

    // Uplaceret plade har intet "sæt tilbage"-råd.
    _ = try s.applyCollection(records.enumerated().map { item($0.offset + 1, 500 + $0.offset, $0.element.0, $0.element.1) } + [item(99, 999, "Ny", "Plade")])
    l = try s.loadLibrary()
    check(l.unplaced.count == 1 && l.returnAdvice(for: l.unplaced[0]) == nil && l.referenceAdvice(for: l.unplaced[0]) == nil, "returnAdvice = nil uden placering")
    check(placementRows(s) == original, "sync flytter ikke placeringer")

    // Gennemløb af alle plader med forskellige mønstre af plader, der er ude.
    let patterns: [[Int64]] = [[], [aurora], [abbey, revolver], [help, dylan, foxtrot], [trespass, nursery, foxtrot, queen], [zappa, abba],
                               ids.enumerated().filter { $0.offset % 2 == 0 }.map(\.element),
                               ids.enumerated().filter { $0.offset % 3 == 1 }.map(\.element)]
    let sweep = patterns.flatMap { physicalSweep(l, out: $0) }
    check(sweep.isEmpty, "fysisk nummerering og returnAdvice for alle plader: \(sweep.prefix(4))")

    let (d, durl) = try freshStore("wall-demo")
    defer { try? FileManager.default.removeItem(at: durl) }
    try DemoData.seedIfEmpty(d)
    let dl = try d.loadLibrary()
    let genesis = dl.globalOrder.filter { dl.item($0)?.artist == "Genesis" }
    let demoPatterns: [[Int64]] = [[], Array(genesis.prefix(2)), [genesis[2]], dl.globalOrder.enumerated().filter { $0.offset % 4 == 0 }.map(\.element),
                                   dl.globalOrder.enumerated().filter { $0.offset % 5 == 2 }.map(\.element)]
    let demoSweep = demoPatterns.flatMap { physicalSweep(dl, out: $0) }
    check(demoSweep.isEmpty, "demo: fysisk nummerering og returnAdvice for alle plader: \(demoSweep.prefix(4))")
}

// Demo-data kan seedes igen uden at ændre noget
do {
    let (d, url) = try freshStore("demo2")
    defer { try? FileManager.default.removeItem(at: url) }
    try DemoData.seedIfEmpty(d)
    let first = placementRows(d)
    try DemoData.seedIfEmpty(d)
    check(placementRows(d) == first && !first.isEmpty, "demo: seedIfEmpty er idempotent")
}

// MARK: Discogs-katalog: søg, udgaver, ønskeliste (offline)
// Testdata: versions-siderne og releasen er rigtige, forkortede svar hentet uden login fra
// api.discogs.com (/masters/10362/versions?per_page=5&page=1 og &page=309, /releases/249504?curr_abbr=EUR).
// /database/search kræver login, så søgesvarene er bygget efter Discogs' dokumenterede format.
let fxVersionsP1 = #"{"pagination":{"page":1,"pages":309,"per_page":5,"items":1542,"urls":{"last":"https://api.discogs.com/masters/10362/versions?per_page=5&page=309","next":"https://api.discogs.com/masters/10362/versions?per_page=5&page=2"}},"filters":{"applied":{},"available":{}},"versions":[{"id":10255816,"label":"Harvest","country":"Netherlands","title":"The Dark Side Of The Moon","major_formats":["Vinyl"],"format":"LP, Album, Stereo","catno":"5C062-05 249, 5C 062-05249","released":"1973","status":"Accepted","resource_url":"https://api.discogs.com/releases/10255816","thumb":"https://i.discogs.com/ltUm8Ofo-qRZ4W8FuGsF-fpCDZGKk2ARV58degIaY-8/rs:fit/g:sm/q:40/h:150/w:150/czM6Ly9kaXNjb2dz/LWRhdGFiYXNlLWlt/YWdlcy9SLTEwMjU1/ODE2LTE1NTI0OTUy/NzctNjI1Ni5qcGVn.jpeg","stats":{"community":{"in_wantlist":1703,"in_collection":1421}}},{"id":24571544,"label":"Harvest","country":"UK","title":"The Dark Side Of The Moon","major_formats":["Vinyl"],"format":"LP, Album, Misprint, Repress","catno":"SHVL 804","released":"1973","status":"Accepted","resource_url":"https://api.discogs.com/releases/24571544","thumb":"https://i.discogs.com/goIH_cO9e581t1wyAuf3qcXU2YrK1uQvVu4ip3H3zvs/rs:fit/g:sm/q:40/h:150/w:150/czM6Ly9kaXNjb2dz/LWRhdGFiYXNlLWlt/YWdlcy9SLTI0NTcx/NTQ0LTE2NjM4NDM4/MjgtNzkzMC5qcGVn.jpeg","stats":{"community":{"in_wantlist":908,"in_collection":1188}}},{"id":13655729,"label":"EMI","country":"Peru","title":"El Lado Oscuro De La Luna","major_formats":["Vinyl"],"format":"LP, Album, Stereo","catno":"ELD 02.21.257","released":"1973","status":"Accepted","resource_url":"https://api.discogs.com/releases/13655729","thumb":"https://i.discogs.com/b4sU_wDut_xdcXKCd3RDSMwwvTbYC6QuG5Gyf6yWmds/rs:fit/g:sm/q:40/h:150/w:150/czM6Ly9kaXNjb2dz/LWRhdGFiYXNlLWlt/YWdlcy9SLTEzNjU1/NzI5LTE2MDIwNzA5/MDktNDM5NS5qcGVn.jpeg","stats":{"community":{"in_wantlist":1127,"in_collection":122}}},{"id":3422671,"label":"Harvest","country":"New Zealand","title":"The Dark Side Of The Moon","major_formats":["Cassette"],"format":"Album","catno":"TC-SHVL.804","released":"1973","status":"Accepted","resource_url":"https://api.discogs.com/releases/3422671","thumb":"https://i.discogs.com/oLk77L77ChTuwzLRN0F0HoqfUdsWHNINhxaM9QHOjL4/rs:fit/g:sm/q:40/h:150/w:150/czM6Ly9kaXNjb2dz/LWRhdGFiYXNlLWlt/YWdlcy9SLTM0MjI2/NzEtMTM2MDY0ODE0/Ni05NTQxLmpwZWc.jpeg","stats":{"community":{"in_wantlist":1293,"in_collection":66}}},{"id":23773439,"label":"Harvest","country":"US","title":"The Dark Side Of The Moon","major_formats":["8-Track Cartridge"],"format":"Album","catno":"8XW-11163, 8XW 11163","released":"1973","status":"Accepted","resource_url":"https://api.discogs.com/releases/23773439","thumb":"https://i.discogs.com/o3v_psko0B87ic-VLJzLqzlvEAF67uFwtk7dhofu1L0/rs:fit/g:sm/q:40/h:150/w:150/czM6Ly9kaXNjb2dz/LWRhdGFiYXNlLWlt/YWdlcy9SLTIzNzcz/NDM5LTE2NTY4Nzk5/NjAtMTgwNi5qcGVn.jpeg","stats":{"community":{"in_wantlist":256,"in_collection":44}}}]}"#
let fxVersionsP309 = #"{"pagination":{"page":309,"pages":309,"per_page":5,"items":1542,"urls":{"first":"https://api.discogs.com/masters/10362/versions?per_page=5&page=1","prev":"https://api.discogs.com/masters/10362/versions?per_page=5&page=308"}},"filters":{"applied":{},"available":{}},"versions":[{"id":36479455,"label":"Harvest (2)","country":"Philippines","title":"The Dark Side Of The Moon","major_formats":["Vinyl"],"format":"LP, Album, Limited Edition, Repress, Unofficial Release, Stereo","catno":"SHVL 804","released":"0","status":"Accepted","resource_url":"https://api.discogs.com/releases/36479455","thumb":"https://i.discogs.com/spw4RItF4Km09JdtExjEvTVbpJuqyXOjXLWOlnjFUgk/rs:fit/g:sm/q:40/h:150/w:150/czM6Ly9kaXNjb2dz/LWRhdGFiYXNlLWlt/YWdlcy9SLTM2NDc5/NDU1LTE3NzA4ODM0/NTYtMzY5MC5qcGVn.jpeg","stats":{"community":{"in_wantlist":121,"in_collection":2}}},{"id":37007961,"label":"Jugoton","country":"Yugoslavia","title":"The Dark Side Of The Moon","major_formats":["Vinyl"],"format":"LP, Album, Quadraphonic","catno":"LQEMI 73009, Q4SHVL 804","released":"0","status":"Accepted","resource_url":"https://api.discogs.com/releases/37007961","thumb":"https://i.discogs.com/X8TPmgKG-8JP6q7E5aDs08RQ81Oaayn00XFKebcCMoY/rs:fit/g:sm/q:40/h:150/w:150/czM6Ly9kaXNjb2dz/LWRhdGFiYXNlLWlt/YWdlcy9SLTM3MDA3/OTYxLTE3NzU2NDIx/NzktNzE0MC5qcGVn.jpeg","stats":{"community":{"in_wantlist":94,"in_collection":3}}}]}"#
let fxRelease249504 = #"{"id":249504,"status":"Accepted","year":1987,"title":"Never Gonna Give You Up","country":"UK","released":"1987-07-00","released_formatted":"Jul 1987","master_id":96559,"labels":[{"name":"RCA","catno":"PB 41447","entity_type":"1","id":895}],"formats":[{"name":"Vinyl","qty":"1","descriptions":["7\"","45 RPM","Single","Stereo"]}],"thumb":"https://i.discogs.com/HG2xChKN-rIHHSfgL53W9z2vJWeFknfevpOMwSHtIaM/rs:fit/g:sm/q:40/h:150/w:150/czM6Ly9kaXNjb2dz/LWRhdGFiYXNlLWlt/YWdlcy9SLTI0OTUw/NC0xMzM0NTkyMjEy/LmpwZWc.jpeg","lowest_price":0.67,"num_for_sale":118,"community":{"have":4126,"want":589}}"#

/// Falsk netværk til checks: svarer ud fra metode + sti (+ type=) og husker forespørgslerne.
final class StubDiscogs: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var routes: [String: (status: Int, body: String)] = [:]
    nonisolated(unsafe) static var seen: [URLRequest] = []
    static let lock = NSLock()
    static func key(_ r: URLRequest) -> String {
        let type = URLComponents(url: r.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "type" }?.value
        return "\(r.httpMethod ?? "GET") \(r.url!.path)" + (type.map { "?type=\($0)" } ?? "")
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); Self.seen.append(request); let route = Self.routes[Self.key(request)]; Self.lock.unlock()
        let (status, body) = route ?? (404, "{}")
        if status == 0 { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)); return }
        let resp = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class ResultBox<T>: @unchecked Sendable { var value: Result<T, Error>? }
/// Kører async kode færdig fra top-level (uden at gøre hele main.swift asynkron).
func blocking<T>(_ op: @escaping @Sendable () async throws -> T) -> Result<T, Error> {
    let box = ResultBox<T>(), sem = DispatchSemaphore(value: 0)
    Task.detached { do { box.value = .success(try await op()) } catch { box.value = .failure(error) }; sem.signal() }
    sem.wait()
    return box.value!
}
/// Checks må ikke vente på den rigtige grænse (45 kald/min); denne kø er praktisk talt ubegrænset.
let fastLimiter = DiscogsRateLimiter(capacity: 100_000, perMinute: 6_000_000)

func errorText<T>(_ r: Result<T, Error>) -> String? {
    if case .failure(let e) = r { return e.localizedDescription }
    return nil
}

do {
    // parseSearch: masters + releases uden master, dubletter, split af kunstner/titel, user_data
    let search = #"""
    {"pagination":{"page":1,"pages":4,"per_page":50,"items":180,"urls":{"last":"https://api.discogs.com/database/search?q=x&page=4","next":"https://api.discogs.com/database/search?q=x&page=2"}},
     "results":[
      {"id":45467,"type":"artist","title":"Pink Floyd","thumb":"","cover_image":"","uri":"/artist/45467-Pink-Floyd","resource_url":"https://api.discogs.com/artists/45467","user_data":{"in_wantlist":false,"in_collection":false}},
      {"id":10362,"type":"master","master_id":10362,"master_url":"https://api.discogs.com/masters/10362","uri":"/master/10362-Pink-Floyd-The-Dark-Side-Of-The-Moon",
       "title":"Pink Floyd - The Dark Side Of The Moon","country":"UK","year":"1973","format":["Vinyl","LP","Album","Vinyl","LP"],"label":["Harvest"],
       "genre":["Electronic","Rock"],"style":["Prog Rock"],"catno":"SHVL 804","barcode":[],"community":{"want":1,"have":2},
       "thumb":"https://i.discogs.com/t10362.jpeg","cover_image":"https://i.discogs.com/c10362.jpeg",
       "user_data":{"in_wantlist":false,"in_collection":true},"resource_url":"https://api.discogs.com/masters/10362"},
      {"id":1873013,"type":"release","master_id":10362,"title":"Pink Floyd - The Dark Side Of The Moon","year":"1973","format":["Vinyl","LP","Album"],"user_data":{"in_wantlist":true,"in_collection":false}},
      {"id":10362,"type":"master","master_id":10362,"title":"Pink Floyd - The Dark Side Of The Moon","year":"1973"},
      {"id":5555001,"type":"release","master_id":0,"master_url":null,"title":"Nirvana (2) - Live At The Paramount","year":"2019","format":["Vinyl","LP"],
       "thumb":"","cover_image":"https://s.discogs.com/images/spacer.gif","user_data":{"in_wantlist":true,"in_collection":false}},
      {"id":5555002,"type":"release","master_id":null,"title":"Simon* & Garfunkel - Bookends - Live 1969","year":1969},
      {"id":5555003,"type":"release","title":"Kim Larsen – Midt Om Natten","format":["Vinyl","LP","Album"],"user_data":{"in_wantlist":false,"in_collection":false}},
      {"type":"release","title":"Uden id - springes over"},
      {"id":5555004,"type":"label","title":"Harvest"},
      {"id":5555005,"type":"release","master_id":0,"year":"","user_data":{"in_collection":1}}
     ]}
    """#
    let s = try DiscogsClient.parseSearch(Data(search.utf8))
    check(s.hasMore, "søgning: side 1 af 4 → hasMore")
    check(s.albums.map(\.id) == [10362, 5555001, 5555002, 5555003, 5555005],
          "søgning: artist/label/uden id droppes, release med master vises via masteren, ingen dubletter: \(s.albums.map(\.id))")
    let m = s.albums[0]
    check(m.isMaster && m.artist == "Pink Floyd" && m.title == "The Dark Side Of The Moon" && m.year == 1973,
          "søgning: master + split af kunstner/titel: \(m.artist) / \(m.title)")
    check(m.inCollection && !m.inWantlist, "søgning: user_data på masteren (ikke releasens)")
    check(m.formats == ["Vinyl", "LP", "Album"] && m.thumbURL?.absoluteString == "https://i.discogs.com/t10362.jpeg"
          && m.coverURL?.absoluteString == "https://i.discogs.com/c10362.jpeg", "søgning: formater uden gentagelser + billeder")
    let nirvana = s.albums[1]
    check(!nirvana.isMaster && nirvana.artist == "Nirvana" && nirvana.title == "Live At The Paramount" && nirvana.inWantlist
          && nirvana.thumbURL == nil && nirvana.coverURL == nil, "søgning: release uden master, (2) fjernet, tomme billeder → nil")
    let bookends = s.albums[2]
    check(bookends.artist == "Simon & Garfunkel" && bookends.title == "Bookends - Live 1969" && bookends.year == 1969
          && !bookends.inCollection && !bookends.inWantlist && bookends.formats.isEmpty,
          "søgning: deles ved første \" - \", år som tal, manglende user_data → false: \(bookends.artist) / \(bookends.title)")
    check(s.albums[3].artist == "Kim Larsen" && s.albums[3].title == "Midt Om Natten" && s.albums[3].year == nil,
          "søgning: \" – \" accepteres, manglende år → nil")
    let bare = s.albums[4]
    check(bare.artist == "" && bare.title == "" && bare.year == nil && bare.inCollection && bare.thumbURL == nil,
          "søgning: manglende titel/år giver tomme felter, in_collection som tal")

    let empty = try DiscogsClient.parseSearch(Data(#"{"pagination":{"page":1,"pages":0,"per_page":50,"items":0,"urls":{}},"results":[]}"#.utf8))
    check(empty.albums.isEmpty && !empty.hasMore, "søgning: tom liste")
    let last = try DiscogsClient.parseSearch(Data(#"{"pagination":{"page":4,"pages":4,"items":180},"results":[]}"#.utf8))
    check(!last.hasMore, "søgning: sidste side → ingen flere")
    let noPagination = try DiscogsClient.parseSearch(Data(#"{"results":[{"id":7,"type":"master","title":"A - B"}]}"#.utf8))
    check(noPagination.albums.count == 1 && !noPagination.hasMore, "søgning: manglende pagination → ingen flere")
    do { _ = try DiscogsClient.parseSearch(Data("ikke json".utf8)); check(false, "ugyldig søge-JSON skal fejle") }
    catch { check(error.localizedDescription == "Svaret fra Discogs kunne ikke læses (søgeresultaterne).", "søgning: fejl på dansk: \(error.localizedDescription)") }

    // combineSearch: to opslag (type=master + type=release) til én side
    let mastersJSON = #"{"pagination":{"page":1,"pages":1,"items":1},"results":[{"id":10362,"type":"master","title":"Pink Floyd - The Dark Side Of The Moon","year":"1973"}]}"#
    let releasesJSON = #"{"pagination":{"page":1,"pages":3,"items":150},"results":[{"id":1873013,"type":"release","master_id":10362,"title":"Pink Floyd - The Dark Side Of The Moon"},{"id":777,"type":"release","master_id":0,"title":"Pink Floyd - Rare Acetate"}]}"#
    let c = try DiscogsClient.combineSearch(masters: Data(mastersJSON.utf8), releases: Data(releasesJSON.utf8))
    check(c.albums.map(\.id) == [10362, 777] && c.albums.map(\.isMaster) == [true, false] && c.hasMore,
          "søgning: masters først, så releases uden master; hasMore hvis en af delene har flere")
    let noMasters = #"{"pagination":{"page":1,"pages":0,"items":0},"results":[]}"#
    let catno = try DiscogsClient.combineSearch(masters: Data(noMasters.utf8), releases: Data(releasesJSON.utf8))
    check(catno.albums.map(\.id) == [1873013, 777] && catno.albums.allSatisfy { !$0.isMaster },
          "søgning: ingen masters (fx katalognr.) → de fundne udgaver vises som enkelte releases")

    // parseVersions: rigtige data
    let p1 = try DiscogsClient.parseVersions(Data(fxVersionsP1.utf8))
    check(p1.versions.count == 5 && p1.hasMore, "udgaver: 5 på side 1 af 309")
    let nl = p1.versions[0]
    check(nl.id == 10255816 && nl.title == "The Dark Side Of The Moon" && nl.format == "Vinyl, LP, Album, Stereo"
          && nl.label == "Harvest" && nl.catno == "5C062-05 249, 5C 062-05249" && nl.country == "Netherlands" && nl.year == 1973,
          "udgaver: år/land/label/format/katalognr.: \(nl.format)")
    check(nl.thumbURL != nil && !nl.inCollection && !nl.inWantlist, "udgaver: billede, ingen brugerdata uden login → false")
    check(p1.versions[3].format == "Cassette, Album" && p1.versions[4].format == "8-Track Cartridge, Album", "udgaver: andre formater end vinyl")
    let p309 = try DiscogsClient.parseVersions(Data(fxVersionsP309.utf8))
    check(p309.versions.count == 2 && !p309.hasMore, "udgaver: sidste side → ingen flere")
    check(p309.versions[0].label == "Harvest" && p309.versions[0].year == nil, "udgaver: \"Harvest (2)\" → Harvest, released \"0\" → intet år")

    // parseVersions: brugerdata og manglende felter
    let versionsJSON = #"""
    {"pagination":{"page":2,"pages":2,"per_page":50,"items":52},"versions":[
     {"id":1,"status":"Accepted","stats":{"user":{"in_collection":1,"in_wantlist":0},"community":{"in_collection":2,"in_wantlist":1}},
      "thumb":"https://i.discogs.com/t1.jpeg","format":"Vinyl, 12\", 33 ⅓ RPM","country":"Belgium","title":"Stardiver",
      "label":"Bonzai Records (2)","released":"1969-09-26","major_formats":["Vinyl"],"catno":"BR-1234","resource_url":"https://api.discogs.com/releases/1"},
     {"id":2,"stats":{"user":{"in_collection":false,"in_wantlist":true}},"catno":"none","released":null},
     {"title":"uden id"}
    ]}
    """#
    let v = try DiscogsClient.parseVersions(Data(versionsJSON.utf8))
    check(v.versions.map(\.id) == [1, 2] && !v.hasMore, "udgaver: element uden id springes over")
    let v1 = v.versions[0]
    check(v1.format == "Vinyl, 12\", 33 ⅓ RPM" && v1.label == "Bonzai Records" && v1.year == 1969 && v1.catno == "BR-1234",
          "udgaver: \"1969-09-26\" → 1969, Vinyl gentages ikke: \(v1.format)")
    check(v1.inCollection && !v1.inWantlist, "udgaver: stats.user.in_collection (tal)")
    let v2 = v.versions[1]
    check(v2.title == "" && v2.format == "" && v2.label == "" && v2.catno == "" && v2.country == "" && v2.year == nil
          && v2.thumbURL == nil && !v2.inCollection && v2.inWantlist, "udgaver: manglende felter → tomme/nil, in_wantlist som bool")
    do { _ = try DiscogsClient.parseVersions(Data(#"{"pagination":{}}"#.utf8)); check(false, "udgaver uden versions skal fejle") }
    catch { check(error.localizedDescription == "Svaret fra Discogs kunne ikke læses (udgaverne).", "udgaver: fejl på dansk") }

    // Release uden master → én udgave (rigtige data), og prisen fra samme svar
    let rel = try DiscogsClient.parseReleaseVersion(Data(fxRelease249504.utf8), inCollection: false, inWantlist: true)
    check(rel.id == 249504 && rel.title == "Never Gonna Give You Up" && rel.format == "Vinyl, 7\", 45 RPM, Single, Stereo"
          && rel.label == "RCA" && rel.catno == "PB 41447" && rel.country == "UK" && rel.year == 1987 && rel.thumbURL != nil && rel.inWantlist,
          "release → udgave: \(rel.format)")
    let price = try DiscogsClient.parseMarketInfo(Data(fxRelease249504.utf8), currency: "EUR")
    check(price.lowestPrice == 0.67 && price.numForSale == 118, "pris pr. udgave via parseMarketInfo")
    let multi = #"{"id":9,"title":"X","year":0,"released":"1975-03-00","labels":[{"name":"Atlantic (3)","catno":"none"}],"thumb":"","images":[{"uri150":"https://i.discogs.com/150.jpeg"}],"formats":[{"name":"Vinyl","qty":"2","descriptions":["LP","Album"],"text":"Gatefold"},{"name":"CD","qty":"1"}]}"#
    let mv = try DiscogsClient.parseReleaseVersion(Data(multi.utf8), inCollection: false, inWantlist: false)
    check(mv.format == "2×Vinyl, LP, Album, Gatefold + CD" && mv.label == "Atlantic" && mv.catno == "" && mv.year == 1975
          && mv.thumbURL?.absoluteString == "https://i.discogs.com/150.jpeg", "release: flere formater, år fra released, billede fra images: \(mv.format)")

    // URL'er til Discogs' hjemmeside
    check(DiscogsClient.marketplaceURL(releaseID: 249504).absoluteString == "https://www.discogs.com/sell/release/249504", "marketplaceURL")
    check(DiscogsClient.releasePageURL(releaseID: 249504).absoluteString == "https://www.discogs.com/release/249504", "releasePageURL")

    // PUT-forespørgsel bygges uden netværk; tokenet sendes, men vises aldrig
    let fakeToken = "TEST-token-ikke-rigtig-123"
    let client = DiscogsClient(token: fakeToken)
    let put = client.wantlistRequest(username: "holger", releaseID: 249504)
    check(put.httpMethod == "PUT" && put.url?.absoluteString == "https://api.discogs.com/users/holger/wants/249504", "PUT: metode og sti: \(put.url?.absoluteString ?? "")")
    check(put.value(forHTTPHeaderField: "Authorization") == "Discogs token=\(fakeToken)"
          && put.value(forHTTPHeaderField: "User-Agent") == DiscogsClient.userAgent, "PUT: Authorization og User-Agent sættes")
    var dumped = ""
    dump(client, to: &dumped)
    let shown = [put.url!.absoluteString, "\(put)", put.debugDescription, "\(client)", String(reflecting: client), dumped,
                 DiscogsError.unauthorized.localizedDescription]
    check(!shown.contains { $0.contains(fakeToken) }, "tokenet optræder aldrig i URL, beskrivelser, dump eller fejltekst")
    let get = client.makeRequest(path: "/masters/10362/versions", query: [URLQueryItem(name: "page", value: "2")])
    check(get.httpMethod == "GET" && get.url?.absoluteString == "https://api.discogs.com/masters/10362/versions?page=2", "GET-forespørgsel")

    // Danske fejltekster
    check(DiscogsError.unauthorized.localizedDescription.hasPrefix("Discogs-tokenet blev afvist"), "401: dansk fejltekst")
    check(DiscogsError.http(404).localizedDescription == "Pladen findes ikke længere på Discogs.", "404: dansk fejltekst")
    check(DiscogsError.http(500).localizedDescription.contains("kode 500"), "andre koder: generel tekst")
    check(DiscogsError.offline.localizedDescription.hasPrefix("Kunne ikke få forbindelse til Discogs"), "offline: dansk fejltekst")

    // Ende-til-ende mod et falsk netværk (ingen rigtige kald)
    let cfg = URLSessionConfiguration.ephemeral
    cfg.protocolClasses = [StubDiscogs.self]
    let stub = DiscogsClient(token: fakeToken, session: URLSession(configuration: cfg), limiter: fastLimiter)
    StubDiscogs.routes = [
        "PUT /users/holger/wants/249504": (201, #"{"id":249504,"rating":0}"#),
        "PUT /users/holger/wants/1": (404, #"{"message":"Release not found."}"#),
        "PUT /users/andre/wants/249504": (401, #"{"message":"You must authenticate to access this resource."}"#),
        "GET /database/search?type=master": (200, mastersJSON),
        "GET /database/search?type=release": (200, releasesJSON),
        "GET /masters/10362/versions": (200, fxVersionsP1),
        "GET /releases/249504": (200, fxRelease249504),
        "GET /masters/999/versions": (0, ""),
    ]
    let added = blocking { try await stub.addToWantlist(username: "holger", releaseID: 249504) }
    let sentPut = StubDiscogs.seen.last
    check(errorText(added) == nil && sentPut?.httpMethod == "PUT" && sentPut?.url?.path == "/users/holger/wants/249504"
          && sentPut?.value(forHTTPHeaderField: "Authorization") == "Discogs token=\(fakeToken)", "addToWantlist sender PUT med token")
    check(errorText(blocking { try await stub.addToWantlist(username: "holger", releaseID: 1) }) == "Pladen findes ikke længere på Discogs.", "PUT 404 → dansk tekst")
    check(errorText(blocking { try await stub.addToWantlist(username: "andre", releaseID: 249504) })?.hasPrefix("Discogs-tokenet blev afvist") == true, "PUT 401 → dansk tekst")
    check(errorText(blocking { try await stub.versions(of: DiscogsAlbum(id: 999, isMaster: true, title: "", artist: "", year: nil, thumbURL: nil, coverURL: nil, formats: [], inCollection: false, inWantlist: false)) })?
            .hasPrefix("Kunne ikke få forbindelse til Discogs") == true, "ingen forbindelse → offline på dansk")

    StubDiscogs.seen = []
    let found = blocking { try await stub.searchAlbums("  pink floyd  ") }
    let searchQueries = StubDiscogs.seen.map { URLComponents(url: $0.url!, resolvingAgainstBaseURL: false)!.queryItems ?? [] }
    check((try? found.get().albums.map(\.id)) == [10362, 777] && (try? found.get().hasMore) == true, "searchAlbums samler masters og releases")
    check(searchQueries.count == 2 && searchQueries.allSatisfy { $0.contains(URLQueryItem(name: "q", value: "pink floyd")) && $0.contains(URLQueryItem(name: "page", value: "1")) }
          && Set(searchQueries.compactMap { $0.first { $0.name == "type" }?.value }) == ["master", "release"], "searchAlbums: to opslag, trimmet søgning")
    StubDiscogs.seen = []
    let none = blocking { try await stub.searchAlbums("   ") }
    check((try? none.get().albums.isEmpty) == true && StubDiscogs.seen.isEmpty, "tom søgning → intet kald")
    check(errorText(blocking { try await DiscogsClient(token: "", session: URLSession(configuration: cfg), limiter: fastLimiter).searchAlbums("abba") }) == DiscogsError.missingToken.localizedDescription,
          "søgning uden token → missingToken")

    let master = DiscogsAlbum(id: 10362, isMaster: true, title: "The Dark Side Of The Moon", artist: "Pink Floyd", year: 1973, thumbURL: nil, coverURL: nil, formats: [], inCollection: false, inWantlist: false)
    let mvers = blocking { try await stub.versions(of: master, page: 2) }
    let versionsQuery = StubDiscogs.seen.last.flatMap { URLComponents(url: $0.url!, resolvingAgainstBaseURL: false)?.queryItems } ?? []
    check((try? mvers.get().versions.count) == 5 && versionsQuery.contains(URLQueryItem(name: "page", value: "2")), "versions(of: master) henter /masters/{id}/versions med side")
    let single = DiscogsAlbum(id: 249504, isMaster: false, title: "Never Gonna Give You Up", artist: "Rick Astley", year: 1987, thumbURL: nil, coverURL: nil, formats: ["Vinyl"], inCollection: true, inWantlist: false)
    let svers = blocking { try await stub.versions(of: single) }
    check((try? svers.get().versions.map(\.id)) == [249504] && (try? svers.get().hasMore) == false && (try? svers.get().versions[0].inCollection) == true,
          "versions(of: release) → én udgave med albummets brugerdata")
    StubDiscogs.seen = []
    let page2 = blocking { try await stub.versions(of: single, page: 2) }
    check((try? page2.get().versions.isEmpty) == true && StubDiscogs.seen.isEmpty, "release uden master har kun én side")

    // Formatfilter: Discogs' eget `format`-filter sendes med både til søgning og udgaver.
    func queryItems(_ r: URLRequest) -> [URLQueryItem] {
        r.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems } ?? []
    }
    StubDiscogs.seen = []
    _ = blocking { try await stub.searchAlbums("dark side", format: "CD") }
    check(StubDiscogs.seen.count == 2 && StubDiscogs.seen.allSatisfy { queryItems($0).contains(URLQueryItem(name: "format", value: "CD")) },
          "searchAlbums(format:) sender format=CD i begge søgeopslag")
    StubDiscogs.seen = []
    _ = blocking { try await stub.searchAlbums("dark side") }
    check(StubDiscogs.seen.allSatisfy { !queryItems($0).contains { $0.name == "format" } }, "uden format: intet formatfilter (alle formater)")
    StubDiscogs.seen = []
    _ = blocking { try await stub.versions(of: master, page: 1, format: "Vinyl") }
    check(StubDiscogs.seen.last.map { queryItems($0).contains(URLQueryItem(name: "format", value: "Vinyl")) } == true,
          "versions(format:) sender format=Vinyl til /masters/{id}/versions")
}

// MARK: Danske kroner (omregnet fra euro)
do {
    let eur = MarketInfo(lowestPrice: 10, currency: "EUR", numForSale: 3, have: 5, want: 7)
    let dkk = MarketCurrency.converted(eur, to: "DKK")
    check(dkk.currency == "DKK" && dkk.lowestPrice == 74.6 && dkk.numForSale == 3 && dkk.have == 5,
          "10 € → 74,60 kr. (kurs \(MarketCurrency.dkkPerEur)); antal til salg uændret")
    let back = MarketCurrency.converted(MarketInfo(lowestPrice: 3.36, currency: "DKK", numForSale: 1, have: nil, want: nil), to: "EUR")
    check(back.currency == "EUR" && back.lowestPrice == 0.45, "3,36 kr. → 0,45 € (samme kurs baglæns)")
    check(MarketCurrency.converted(MarketInfo(lowestPrice: 3.36, currency: "DKK", numForSale: 1, have: nil, want: nil), to: "DKK").lowestPrice == 3.36,
          "kroner til kroner regnes aldrig om (fejlen fra før 1. okt: ×7,46)")
    check(MarketCurrency.converted(eur, to: "EUR") == eur, "EUR omregnes ikke")
    check(MarketCurrency.converted(MarketInfo(lowestPrice: nil, currency: "EUR", numForSale: 0, have: nil, want: nil), to: "DKK").lowestPrice == nil,
          "ingen pris → stadig ingen pris")
    check(MarketCurrency.allCases.first == .DKK, "DKK står først i valutavalget")
}

// MARK: Priser med oplyst valuta (/marketplace/stats) – rettelse 1. okt 2026
// Målt mod det rigtige Discogs for en bruger med DKK som valuta, release 6496:
// /marketplace/stats?curr_abbr=EUR → 0.45 EUR, ?curr_abbr=DKK → 3.36 DKK,
// /releases/6496 med curr_abbr=EUR, USD eller uden → altid 3.36 (brugerens valuta).
let fxStats6496DKK = #"{"lowest_price":{"currency":"DKK","value":3.36},"num_for_sale":36,"blocked_from_sale":false}"#
do {
    let m = try DiscogsClient.parseMarketStats(Data(fxStats6496DKK.utf8), fallbackCurrency: "DKK")
    check(m.lowestPrice == 3.36 && m.currency == "DKK" && m.numForSale == 36, "stats: pris og valuta læses fra svaret")
    let str = try DiscogsClient.parseMarketStats(Data(#"{"lowest_price":{"currency":"eur","value":"0.45"},"num_for_sale":"36"}"#.utf8), fallbackCurrency: "DKK")
    check(str.lowestPrice == 0.45 && str.currency == "EUR" && str.numForSale == 36, "stats: beløb og antal som tekst")
    let none = try DiscogsClient.parseMarketStats(Data(#"{"lowest_price":null,"num_for_sale":0,"blocked_from_sale":false}"#.utf8), fallbackCurrency: "DKK")
    check(none.lowestPrice == nil && none.numForSale == 0, "stats: intet til salg → ingen pris")
    let noCur = try DiscogsClient.parseMarketStats(Data(#"{"lowest_price":{"value":3.36},"num_for_sale":2}"#.utf8), fallbackCurrency: "DKK")
    check(noCur.lowestPrice == nil && noCur.numForSale == 2, "stats: pris uden valuta → ingen pris (aldrig gættet)")

    let cfg = URLSessionConfiguration.ephemeral
    cfg.protocolClasses = [StubDiscogs.self]
    let stub = DiscogsClient(token: "TEST-ikke-rigtig", session: URLSession(configuration: cfg), limiter: fastLimiter)
    StubDiscogs.routes = [
        "GET /marketplace/stats/6496": (200, fxStats6496DKK),
        "GET /releases/6496": (200, #"{"id":6496,"lowest_price":3.36,"num_for_sale":36,"community":{"have":900,"want":40}}"#),
    ]
    StubDiscogs.seen = []
    let price = try blocking { try await stub.marketInfo(releaseID: 6496, currency: "DKK") }.get()
    let q = StubDiscogs.seen.last.flatMap { URLComponents(url: $0.url!, resolvingAgainstBaseURL: false) }
    check(price.lowestPrice == 3.36 && price.currency == "DKK" && q?.path == "/marketplace/stats/6496"
          && q?.queryItems == [URLQueryItem(name: "curr_abbr", value: "DKK")], "marketInfo: ét kald til /marketplace/stats med curr_abbr=DKK; 3,36 kr. forbliver 3,36 kr.")

    StubDiscogs.seen = []
    let v = try blocking { try await stub.releaseMarketInfo(releaseID: 6496, discogsCurrency: "DKK", appCurrency: "DKK") }.get()
    check(v.lowestPrice == 3.36 && v.currency == "DKK" && v.have == 900 && v.want == 40 && StubDiscogs.seen.count == 1,
          "Værdi: /releases-pris i brugerens Discogs-valuta (DKK) bruges uomregnet; ét kald")
    let ve = try blocking { try await stub.releaseMarketInfo(releaseID: 6496, discogsCurrency: "DKK", appCurrency: "EUR") }.get()
    check(ve.lowestPrice == 0.45 && ve.currency == "EUR", "Værdi: kroner fra Discogs vises som 0,45 € i en euroapp")
    StubDiscogs.seen = []
    let vs = try blocking { try await stub.releaseMarketInfo(releaseID: 6496, discogsCurrency: "DKK", appCurrency: "SEK") }.get()
    check(vs.currency == "DKK" && StubDiscogs.seen.last?.url?.path == "/marketplace/stats/6496" && vs.have == 900,
          "Værdi: kan valutaen ikke regnes om, hentes prisen fra stats (her svarer stubben i DKK)")
    StubDiscogs.seen = []
    let vu = try blocking { try await stub.releaseMarketInfo(releaseID: 6496, discogsCurrency: nil, appCurrency: "DKK") }.get()
    check(vu.lowestPrice == 3.36 && vu.currency == "DKK" && StubDiscogs.seen.count == 2, "Værdi: ukendt Discogs-valuta → pris fra stats")

    let s = try ShelfStore(path: FileManager.default.temporaryDirectory.appendingPathComponent("prisfix-\(UUID().uuidString).sqlite").path)
    try s.saveMarket(6496, price)
    try s.clearMarket()
    let left = try s.loadMarket()
    check(left.isEmpty, "clearMarket sletter gemte priser")
} catch { check(false, "priser med oplyst valuta: \(error)") }

// MARK: Billigste køb: udbredte udgaver først, søgning der rammer flere ord
do {
    let page = try DiscogsClient.parseVersions(Data(fxVersionsP1.utf8)).versions
    check(page.map(\.popularity) == [3124, 2096, 1249, 1359, 300], "udgaver: udbredelse = har + ønsker (stats.community)")
    check(DiscogsVersion.mostPopularFirst(page).map(\.id) == [10255816, 24571544, 3422671, 13655729, 23773439],
          "mostPopularFirst sorterer de mest udbredte først")
    let tie = [DiscogsVersion(id: 1, title: "", format: "", label: "", catno: "", country: "", year: nil, thumbURL: nil, inCollection: false, inWantlist: false, popularity: 5),
               DiscogsVersion(id: 2, title: "", format: "", label: "", catno: "", country: "", year: nil, thumbURL: nil, inCollection: false, inWantlist: false, popularity: 5)]
    check(DiscogsVersion.mostPopularFirst(tie).map(\.id) == [1, 2], "lige udbredte beholder Discogs' rækkefølge")

    func al(_ id: Int, _ artist: String, _ title: String) -> DiscogsAlbum {
        DiscogsAlbum(id: id, isMaster: true, title: title, artist: artist, year: nil, thumbURL: nil, coverURL: nil, formats: [], inCollection: false, inWantlist: false)
    }
    // Målt 1. okt 2026: Discogs gav "LaTour – LaTour" før "LaTour – Blue" for "blue latour".
    let found = [al(133599, "LaTour", "LaTour"), al(133594, "LaTour", "Blue"), al(133592, "LaTour", "E")]
    check(DiscogsAlbum.rankedForQuery(found, query: "blue latour").map(\.id) == [133594, 133599, 133592], "\"blue latour\" → LaTour – Blue først")
    check(DiscogsAlbum.rankedForQuery(found, query: "latour").map(\.id) == [133599, 133594, 133592], "ét søgeord: Discogs' rækkefølge bevares")
    check(DiscogsAlbum.rankedForQuery([al(1, "Björk", "Post"), al(2, "Bjork Tribute", "Debut")], query: "bjork debut").map(\.id) == [2, 1],
          "rangering ser bort fra store bogstaver og accenter")
} catch { check(false, "billigste køb: \(error)") }

// MARK: Albumkortet: pris for hele albummet (master), brugerens valuta og markedsplads
// Testdata: forkortede, rigtige svar hentet uden login fra api.discogs.com:
// /masters/10362 (har lowest_price, num_for_sale og main_release, men ingen curr_abbr) og
// /users/susan.salkeld (curr_abbr er tom uden login).
let fxMaster10362 = #"{"id":10362,"main_release":1873013,"most_recent_release":38452401,"resource_url":"https://api.discogs.com/masters/10362","uri":"https://www.discogs.com/master/10362-_-The-Dark-Side-Of-The-Moon","versions_url":"https://api.discogs.com/masters/10362/versions","main_release_url":"https://api.discogs.com/releases/1873013","most_recent_release_url":"https://api.discogs.com/releases/38452401","num_for_sale":8395,"lowest_price":0.01,"genres":["Electronic","Rock"],"year":1973,"title":"The Dark Side Of The Moon","data_quality":"Correct"}"#
let fxUserNoCurrency = #"{"id":2443307,"username":"susan.salkeld","resource_url":"https://api.discogs.com/users/susan.salkeld","curr_abbr":"","num_for_sale":0,"activated":true,"marketplace_suspended":false}"#
do {
    let m = try DiscogsClient.parseMasterOffer(Data(fxMaster10362.utf8))
    check(m.lowestPrice == 0.01 && m.numForSale == 8395 && m.mainRelease == 1873013 && m.currency == nil,
          "master: lowest_price, num_for_sale og main_release læses; ingen curr_abbr → nil")
    let withCur = try DiscogsClient.parseMasterOffer(Data(#"{"id":1,"lowest_price":12.5,"num_for_sale":"3","main_release":7,"curr_abbr":"eur"}"#.utf8))
    check(withCur.currency == "EUR" && withCur.numForSale == 3 && withCur.mainRelease == 7, "master: curr_abbr læses, hvis Discogs sender den")
    let bare = try DiscogsClient.parseMasterOffer(Data(#"{"id":2,"lowest_price":null,"main_release":0}"#.utf8))
    check(bare.lowestPrice == nil && bare.numForSale == nil && bare.mainRelease == nil, "master uden pris/antal/hovedudgave → nil")
    do { _ = try DiscogsClient.parseMasterOffer(Data("{}".utf8)); check(false, "master uden id skal fejle") }
    catch { check(error.localizedDescription == "Svaret fra Discogs kunne ikke læses (albummets priser).", "master: fejl på dansk") }

    let uc1 = try DiscogsClient.parseUserCurrency(Data(fxUserNoCurrency.utf8))
    check(uc1 == nil, "brugerens valuta: tom curr_abbr → nil (ukendt)")
    let uc2 = try DiscogsClient.parseUserCurrency(Data(#"{"username":"holger","curr_abbr":"EUR"}"#.utf8))
    check(uc2 == "EUR", "brugerens valuta: EUR")
    let uc3 = try DiscogsClient.parseUserCurrency(Data(#"{"username":"holger","curr_abbr":" usd"}"#.utf8))
    check(uc3 == "USD", "brugerens valuta: renses til USD")
    let uc4 = try DiscogsClient.parseUserCurrency(Data(#"{"username":"holger"}"#.utf8))
    check(uc4 == nil, "brugerens valuta: mangler → nil")
    let uc5 = try DiscogsClient.parseUserCurrency(Data(#"{"username":"holger","curr_abbr":"€"}"#.utf8))
    check(uc5 == nil, "brugerens valuta: ugyldig kode → nil")

    check(DiscogsClient.marketplaceURL(masterID: 10362, format: "Vinyl").absoluteString == "https://www.discogs.com/sell/list?master_id=10362&format=Vinyl",
          "markedsplads for hele albummet i Vinyl")
    check(DiscogsClient.marketplaceURL(masterID: 10362, format: "Cassette").absoluteString == "https://www.discogs.com/sell/list?master_id=10362&format=Cassette",
          "markedsplads for hele albummet på kassette")
    check(DiscogsClient.marketplaceURL(masterID: 10362, format: nil).absoluteString == "https://www.discogs.com/sell/list?master_id=10362"
          && DiscogsClient.marketplaceURL(masterID: 10362, format: "").absoluteString == "https://www.discogs.com/sell/list?master_id=10362",
          "markedsplads uden format = alle formater")

    // Valuta: kun EUR → DKK regnes om; ellers vises Discogs' egen valuta. Ingen opfundne kurser.
    let offer = MasterOffer(lowestPrice: 10, currency: nil, numForSale: 37, mainRelease: 5)
    let eurToDkk = offer.market(userCurrency: "EUR", appCurrency: "DKK")
    check(eurToDkk.currency == "DKK" && eurToDkk.lowestPrice == 74.6 && eurToDkk.numForSale == 37, "master: EUR-pris vises i kr. (omregnet)")
    let same = offer.market(userCurrency: "SEK", appCurrency: "SEK")
    check(same.currency == "SEK" && same.lowestPrice == 10, "master: samme valuta som appen → vises direkte")
    let usdInDkkApp = offer.market(userCurrency: "USD", appCurrency: "DKK")
    check(usdInDkkApp.currency == "USD" && usdInDkkApp.lowestPrice == 10, "master: USD i en kroneapp vises i USD (ingen opfundet kurs)")
    let gbpInEurApp = offer.market(userCurrency: "GBP", appCurrency: "EUR")
    check(gbpInEurApp.currency == "GBP" && gbpInEurApp.lowestPrice == 10, "master: GBP i en euroapp vises i GBP")
    let unknown = offer.market(userCurrency: nil, appCurrency: "DKK")
    check(unknown.lowestPrice == nil && unknown.numForSale == 37, "master: ukendt valuta → ingen pris, kun antal til salg")
    let own = MasterOffer(lowestPrice: 10, currency: "EUR", numForSale: 1, mainRelease: nil).market(userCurrency: "USD", appCurrency: "DKK")
    check(own.currency == "DKK" && own.lowestPrice == 74.6, "master: svarets egen valuta går forud for brugerens")
    check(MarketCurrency.converted(MarketInfo(lowestPrice: 10, currency: "USD", numForSale: 1, have: nil, want: nil), to: "DKK").currency == "USD"
          && MarketCurrency.converted(MarketInfo(lowestPrice: 10, currency: "SEK", numForSale: 1, have: nil, want: nil), to: "DKK").lowestPrice == 10,
          "converted: kun mellem EUR og DKK, aldrig USD/SEK → DKK")

    // Ende-til-ende mod falsk netværk
    let cfg = URLSessionConfiguration.ephemeral
    cfg.protocolClasses = [StubDiscogs.self]
    let stub = DiscogsClient(token: "TEST-token", session: URLSession(configuration: cfg), limiter: fastLimiter)
    StubDiscogs.routes = [
        "GET /masters/10362": (200, fxMaster10362),
        "GET /users/holger": (200, #"{"username":"holger","curr_abbr":"EUR"}"#),
        "GET /masters/10362/versions": (200, fxVersionsP1),
    ]
    StubDiscogs.seen = []
    let mo = blocking { try await stub.masterOffer(id: 10362) }
    check((try? mo.get().mainRelease) == 1873013 && StubDiscogs.seen.last?.url?.path == "/masters/10362" && StubDiscogs.seen.last?.httpMethod == "GET",
          "masterOffer henter GET /masters/{id}")
    let uc = blocking { try await stub.userCurrency(username: "holger") }
    check((try? uc.get()) == "EUR" && StubDiscogs.seen.last?.url?.path == "/users/holger", "userCurrency henter GET /users/{username}")
    let master = DiscogsAlbum(id: 10362, isMaster: true, title: "", artist: "", year: nil, thumbURL: nil, coverURL: nil, formats: [], inCollection: false, inWantlist: false)
    check((try? blocking { try await stub.versions(of: master) }.get().total) == 1542, "versions: samlet antal udgaver fra pagination.items")
}

// MARK: Fælles kø (rate limit) og cache for Discogs
final class FakeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var t: TimeInterval = 1000
    var now: TimeInterval { lock.lock(); defer { lock.unlock() }; return t }
    func advance(_ s: TimeInterval) { lock.lock(); t += s; lock.unlock() }
}
final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
    func bump() { lock.lock(); n += 1; lock.unlock() }
}
do {
    // Token-bucket: 15 kald i et hug, derefter 45 i minuttet (højst 60 i ét minut).
    var b = TokenBucket(capacity: 15, perMinute: 45, now: 0)
    var taken = 0
    while b.take(now: 0) == 0 { taken += 1 }
    check(taken == 15, "token-bucket: 15 kald i et hug (\(taken))")
    let wait = b.take(now: 0)
    check(abs(wait - 60.0 / 45) < 0.001, "token-bucket: derefter ét kald pr. 1,33 s (\(wait))")
    check(b.take(now: 1.4) == 0 && b.take(now: 1.4) > 0, "token-bucket: efter ventetiden må ét kald sendes")
    var perMinute = 0
    var t = 0.0
    var fresh = TokenBucket(capacity: 15, perMinute: 45, now: 0)
    while t < 60 { if fresh.take(now: t) == 0 { perMinute += 1 } else { t += 0.01 } }
    check(perMinute <= 60, "token-bucket: højst 60 kald i det første minut (\(perMinute))")
    var p = TokenBucket(capacity: 15, perMinute: 45, now: 0)
    p.pause(3, now: 10)
    check(abs(p.take(now: 11) - 2) < 0.001, "pause: ingen kald i 3 sekunder")
    check(p.take(now: 13) > 0, "pause: spanden starter tom efter pausen")
    check(p.take(now: 13 + 1.4) == 0, "pause: derefter normalt tempo")

    let fastQueue = blocking { () -> Bool in
        let q = DiscogsRateLimiter(capacity: 3, perMinute: 60_000)
        for _ in 0..<10 { try await q.acquire(.interactive) }
        return true
    }
    check((try? fastQueue.get()) == true, "køen slipper kald igennem")
    let cancelled = blocking { () -> Bool in
        let q = DiscogsRateLimiter(capacity: 1, perMinute: 1)
        try await q.acquire(.background)
        let waiting = Task { try await q.acquire(.background) }
        waiting.cancel()
        do { try await waiting.value; return false } catch { return error is CancellationError }
    }
    check((try? cancelled.get()) == true, "en annulleret ventende opgave kaster CancellationError")

    // Cache: samme nøgle hentes kun én gang, også når to kald kører samtidig.
    let clock = FakeClock()
    let cache = DiscogsResponseCache(maxEntries: 2, maxAge: 600, clock: { clock.now })
    let calls = CallCounter()
    let load: @Sendable () async throws -> Data = {
        calls.bump()
        try await Task.sleep(nanoseconds: 50_000_000)
        return Data("svar".utf8)
    }
    let together = blocking { () -> [Data] in
        async let a = cache.data(for: "a", load: load)
        async let b = cache.data(for: "a", load: load)
        return try await [a, b]
    }
    check((try? together.get()) == [Data("svar".utf8), Data("svar".utf8)] && calls.value == 1, "cache: to samtidige ens kald → ét kald (\(calls.value))")
    _ = blocking { try await cache.data(for: "a", load: load) }
    check(calls.value == 1, "cache: gentaget kald tages fra cachen")
    clock.advance(601)
    _ = blocking { try await cache.data(for: "a", load: load) }
    check(calls.value == 2, "cache: efter 10 minutter hentes svaret igen")
    _ = blocking { try await cache.data(for: "b", load: load) }
    _ = blocking { try await cache.data(for: "a", load: load) }   // a er nu senest brugt
    _ = blocking { try await cache.data(for: "c", load: load) }   // b smides ud
    let size = blocking { await cache.count }
    check((try? size.get()) == 2, "cache: højst maxEntries svar")
    let before = calls.value
    _ = blocking { try await cache.data(for: "a", load: load) }
    check(calls.value == before, "cache: det senest brugte svar bliver liggende")
    _ = blocking { try await cache.data(for: "b", load: load) }
    check(calls.value == before + 1, "cache: det ældst brugte svar er smidt ud")
    let failing = blocking { try await cache.data(for: "fejl", load: { calls.bump(); throw DiscogsError.offline }) }
    let afterFail = calls.value
    _ = blocking { try await cache.data(for: "fejl", load: { calls.bump(); throw DiscogsError.offline }) }
    check(errorText(failing) != nil && calls.value == afterFail + 1, "cache: fejl gemmes ikke")

    // Søgning: mange masters → ét kald; få masters → også releases (album uden master).
    let manyMasters = #"{"pagination":{"page":1,"pages":2,"items":60},"results":[{"id":10362,"type":"master","title":"Pink Floyd - The Dark Side Of The Moon","year":"1973"},{"id":1,"type":"release","title":"X - Y"}]}"#
    let only = try DiscogsClient.mastersOnly(Data(manyMasters.utf8))
    check(only?.albums.map(\.id) == [10362] && only?.hasMore == true, "mastersOnly: nok masters → kun masters")
    let few = try DiscogsClient.mastersOnly(Data(#"{"pagination":{"page":1,"pages":1,"items":3},"results":[]}"#.utf8))
    check(few == nil, "mastersOnly: få masters → søg også releases")

    let cfg = URLSessionConfiguration.ephemeral
    cfg.protocolClasses = [StubDiscogs.self]
    StubDiscogs.routes = [
        "GET /database/search?type=master": (200, manyMasters),
        "GET /database/search?type=release": (200, #"{"pagination":{"page":1,"pages":1,"items":0},"results":[]}"#),
        "GET /masters/10362/versions": (200, fxVersionsP1),
        "GET /marketplace/stats/6496": (200, fxStats6496DKK),
    ]
    let plain = DiscogsClient(token: "TEST-token", session: URLSession(configuration: cfg), limiter: fastLimiter)
    StubDiscogs.seen = []
    let one = blocking { try await plain.searchAlbums("pink floyd") }
    check((try? one.get().albums.map(\.id)) == [10362] && StubDiscogs.seen.count == 1, "searchAlbums: mange masters → kun ét kald (\(StubDiscogs.seen.count))")

    let cached = DiscogsClient(token: "TEST-token", session: URLSession(configuration: cfg), limiter: fastLimiter,
                               cache: DiscogsResponseCache())
    let master = DiscogsAlbum(id: 10362, isMaster: true, title: "", artist: "", year: nil, thumbURL: nil, coverURL: nil, formats: [], inCollection: false, inWantlist: false)
    StubDiscogs.seen = []
    _ = blocking { try await cached.searchAlbums("pink floyd") }
    _ = blocking { try await cached.searchAlbums("pink floyd") }
    _ = blocking { try await cached.versions(of: master) }
    _ = blocking { try await cached.versions(of: master) }
    check(StubDiscogs.seen.count == 2, "cache: samme søgning og samme udgaver hentes kun én gang (\(StubDiscogs.seen.count) kald)")
    _ = blocking { try await cached.searchAlbums("pink floyd", format: "Vinyl") }
    check(StubDiscogs.seen.count == 3, "cache: et andet format er en ny søgning")
    StubDiscogs.seen = []
    _ = blocking { try await cached.marketInfo(releaseID: 6496, currency: "DKK") }
    _ = blocking { try await cached.marketInfo(releaseID: 6496, currency: "DKK") }
    check(StubDiscogs.seen.count == 2, "cache: priser hentes altid frisk")
} catch { check(false, "kø og cache: \(error)") }

// MARK: Sikkerhedskopi af databasen
do {
    let cal = Calendar.current
    let day = cal.date(from: DateComponents(year: 2026, month: 10, day: 1, hour: 14))!
    check(DatabaseBackup.fileName(for: day) == "vinyl-2026-10-01.sqlite", "backup: filnavn med dato")
    check(DatabaseBackup.date(fromFileName: "vinyl-2026-10-01.sqlite").map { cal.isDate($0, inSameDayAs: day) } == true, "backup: dato læses fra filnavnet")
    check(DatabaseBackup.date(fromFileName: "vinyl.sqlite") == nil && DatabaseBackup.date(fromFileName: "noter-2026-10-01.sqlite") == nil
          && DatabaseBackup.date(fromFileName: "vinyl-2026-10-01.sqlite-wal") == nil, "backup: andre filer genkendes ikke")
    check(DatabaseBackup.isDue(latest: nil, now: day), "backup: ingen kopi → tag en")
    check(!DatabaseBackup.isDue(latest: day.addingTimeInterval(-3600), now: day), "backup: allerede taget i dag → ikke igen")
    check(DatabaseBackup.isDue(latest: day.addingTimeInterval(-24 * 3600), now: day), "backup: sidste kopi er fra i går → tag en")

    let names = (1...20).map { String(format: "vinyl-2026-09-%02d.sqlite", $0) } + ["vinyl.sqlite", "egne noter.txt"]
    let delete = DatabaseBackup.namesToDelete(names.shuffled(), keep: 14)
    check(Set(delete) == Set((1...6).map { String(format: "vinyl-2026-09-%02d.sqlite", $0) }), "backup: de 6 ældste af 20 slettes: \(delete.sorted())")
    check(DatabaseBackup.namesToDelete(names, keep: 30).isEmpty, "backup: færre end keep → intet slettes")

    // Ende-til-ende: kopi af en rigtig database, oprydning, og kopien kan åbnes.
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("backup-check-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let folder = dir.appendingPathComponent("Vinyl Shelf Finder's backup", isDirectory: true)   // mellemrum og apostrof
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let src = try ShelfStore(path: dir.appendingPathComponent("kilde.sqlite").path)
    _ = try src.applyCollection([item(1, 101, "ABBA", "Arrival"), item(2, 102, "Queen", "Jazz")])
    for d in 1...3 {
        try Data().write(to: folder.appendingPathComponent(String(format: "vinyl-2026-09-%02d.sqlite", d)))
    }
    try Data("mine".utf8).write(to: folder.appendingPathComponent("noter.txt"))
    let made = try DatabaseBackup.run(store: src, to: folder, now: day, keep: 2)
    let copy = try ShelfStore(path: made.path).loadLibrary()
    check(copy.copies.count == 2 && copy.releases.count == 2, "backup: kopien kan åbnes og indeholder pladerne")
    let left = Set(try FileManager.default.contentsOfDirectory(atPath: folder.path))
    check(left == ["vinyl-2026-10-01.sqlite", "vinyl-2026-09-03.sqlite", "noter.txt", "vinyl-2026-10-01.sqlite-wal", "vinyl-2026-10-01.sqlite-shm"]
          || left == ["vinyl-2026-10-01.sqlite", "vinyl-2026-09-03.sqlite", "noter.txt"],
          "backup: de 2 nyeste kopier beholdes, andre filer røres ikke: \(left.sorted())")
    check(DatabaseBackup.latest(in: folder).map { cal.isDate($0, inSameDayAs: day) } == true, "backup: nyeste kopi findes ud fra filnavnet")
    _ = try src.applyCollection([item(1, 101, "ABBA", "Arrival"), item(2, 102, "Queen", "Jazz"), item(3, 103, "Bowie", "Low")])
    let again = try DatabaseBackup.run(store: src, to: folder, now: day, keep: 2)
    let newer = try ShelfStore(path: again.path).loadLibrary()
    check(newer.copies.count == 3, "backup: en ny kopi samme dag erstatter dagens kopi")
    check(DatabaseBackup.isInICloud(URL(fileURLWithPath: "/Users/x/Library/Mobile Documents/com~apple~CloudDocs/Vinyl Shelf Finder backup"))
          && !DatabaseBackup.isInICloud(folder), "backup: iCloud-mappen genkendes")
} catch { check(false, "sikkerhedskopi: \(error)") }

// MARK: Cover Flow
do {
    typealias G = CoverFlowGeometry
    // Coverets størrelse
    check(G.side(width: 100, height: 50) == 80, "cover flow: siden er aldrig under 80")
    check(G.side(width: 10_000, height: 10_000) == 360, "cover flow: siden er aldrig over 360")
    check(abs(G.side(width: 500, height: 1000) - 180) < 0.0001, "cover flow: siden begrænses af bredden (36 %)")
    check(abs(G.side(width: 2000, height: 300) - 240) < 0.0001, "cover flow: siden begrænses af højden (80 %)")
    var sizesOK = true
    for w in stride(from: 0.0, through: 3000.0, by: 137.0) {
        for h in stride(from: 0.0, through: 2000.0, by: 91.0) {
            let s = G.side(width: w, height: h)
            if s < 80 || s > 360 { sizesOK = false }
        }
    }
    check(sizesOK, "cover flow: siden ligger altid mellem 80 og 360")

    // Vandret placering
    let side = 200.0
    check(G.x(0, side: side) == 0, "cover flow: midtercoveret står i midten")
    check(abs(G.x(1, side: side) - 0.62 * side) < 0.0001, "cover flow: første sidecover står 0,62 × siden fra midten")
    var symmetric = true, increasing = true
    for d in 1...10 {
        if abs(G.x(-d, side: side) + G.x(d, side: side)) > 0.0001 { symmetric = false }
        if !(G.x(d + 1, side: side) > G.x(d, side: side)) { increasing = false }
        if !(G.x(-(d + 1), side: side) < G.x(-d, side: side)) { increasing = false }
    }
    check(symmetric, "cover flow: x er symmetrisk om midten")
    check(increasing, "cover flow: afstanden fra midten vokser med |d|")
    check(G.x(1, side: side) > 0 && G.x(-1, side: side) < 0, "cover flow: højre er positiv, venstre negativ")

    // Drejning, skala og lag
    check(G.angle(0) == 0, "cover flow: midtercoveret vender lige frem")
    check(G.angle(1) == -G.tilt && G.angle(5) == -G.tilt, "cover flow: covers til højre drejes -tilt (yderkanten nærmest)")
    check(G.angle(-1) == G.tilt && G.angle(-5) == G.tilt, "cover flow: covers til venstre drejes +tilt (yderkanten nærmest)")
    check(G.scale(0) == 1, "cover flow: midtercoveret har fuld størrelse")
    check(G.scale(1) < 1 && G.scale(-1) < 1 && G.scale(4) < 1, "cover flow: sidecovers er mindre")
    var layersOK = true
    for d in 0...G.visible {
        if !(G.zIndex(d) > G.zIndex(d + 1)) || !(G.zIndex(-d) > G.zIndex(-(d + 1))) { layersOK = false }
        if G.zIndex(d) != G.zIndex(-d) { layersOK = false }
    }
    check(layersOK, "cover flow: nærmere covers ligger øverst")
    check(G.zIndex(0) > G.zIndex(1) && G.zIndex(0) > G.zIndex(-1), "cover flow: midtercoveret ligger øverst")

    // Synlige plader
    check(G.visibleRange(center: 0, count: 0).isEmpty, "cover flow: ingen plader → intet at tegne")
    check(G.visibleRange(center: 3, count: 0).isEmpty, "cover flow: ingen plader → intet at tegne, uanset midte")
    check(G.visibleRange(center: 0, count: 100) == 0..<(G.visible + 1), "cover flow: klemmes i starten")
    check(G.visibleRange(center: 99, count: 100) == (99 - G.visible)..<100, "cover flow: klemmes i slutningen")
    check(G.visibleRange(center: 50, count: 100) == (50 - G.visible)..<(51 + G.visible), "cover flow: midt i samlingen")
    check(G.visibleRange(center: 1, count: 3) == 0..<3, "cover flow: lille samling vises helt")
    check(G.visibleRange(center: -5, count: 10) == G.visibleRange(center: 0, count: 10), "cover flow: negativ midte klemmes til 0")
    check(G.visibleRange(center: 20, count: 10) == G.visibleRange(center: 9, count: 10), "cover flow: midte efter sidste plade klemmes")
    check(G.visibleRange(center: 10, count: 10).contains(9), "cover flow: midte == antal klemmes til sidste plade")
    var rangeOK = true
    for count in 1...30 {
        for center in -3...(count + 3) {
            let r = G.visibleRange(center: center, count: count)
            let c = min(max(center, 0), count - 1)
            if r.count > 2 * G.visible + 1 || !r.contains(c) || r.lowerBound < 0 || r.upperBound > count { rangeOK = false }
        }
    }
    check(rangeOK, "cover flow: højst 2×visible+1 plader, altid med midten, aldrig uden for samlingen")

    // Rulning
    var st = ScrollStepper()
    let a1 = st.add(10, precise: true), a2 = st.add(10, precise: true), a3 = st.add(10, precise: true)
    check(a1 == 0 && a2 == 0 && a3 == 1, "rulning: små trackpad-bevægelser lægges sammen (10+10+10 → 1 trin)")
    let a4 = st.add(26, precise: true)
    check(a4 == 1, "rulning: resten (2) gemmes til næste trin")
    st.reset()
    let n1 = st.add(-10, precise: true), n2 = st.add(-20, precise: true)
    check(n1 == 0 && n2 == -1, "rulning: negativ retning giver negative trin")
    st.reset()
    let big = st.add(100, precise: true)
    check(big == 3, "rulning: stor bevægelse giver flere trin på én gang")
    let bigNeg = st.add(-100, precise: true)
    check(bigNeg == -3, "rulning: stor negativ bevægelse giver flere trin baglæns")
    st.reset()
    let w1 = st.add(1, precise: false), w2 = st.add(-1, precise: false), w3 = st.add(3, precise: false)
    check(w1 == 1 && w2 == -1 && w3 == 3, "rulning: musehjul giver ét trin pr. hak")
    st.reset()
    _ = st.add(20, precise: true)
    st.reset()
    let afterReset = st.add(20, precise: true)
    check(afterReset == 0, "rulning: reset() nulstiller resten")
    st.reset()
    let d1 = st.add(20, precise: true), d2 = st.add(-20, precise: true), d3 = st.add(20, precise: true)
    check(d1 == 0 && d2 == 0 && d3 == 0, "rulning: retningsskift ophæver hinanden")
}

print(failures == 0 ? "✓ Alle \(passes) checks bestået" : "✗ \(failures) fejl, \(passes) bestået")
exit(failures == 0 ? 0 : 1)
