import Foundation
import VinylCore

// Selvtest af kernelogikken. Kør: swift run VinylCoreChecks

var failures = 0
var passes = 0
/// En fejl undervejs tæller som et fejlet check (i stedet for at stoppe afsnittet).
func check(_ cond: @autoclosure () throws -> Bool, _ msg: @autoclosure () -> String, line: Int = #line) {
    let ok: Bool
    do { ok = try cond() } catch { failures += 1; print("✗ linje \(line): \(msg()) – fejl: \(error)"); return }
    if ok { passes += 1 } else { failures += 1; print("✗ linje \(line): \(msg())") }
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

// MARK: instance_id over 32 bit (Discogs har passeret 2.147.483.647; Windows-versionen fejlede på det)
do {
    let big = 2_400_000_123
    let page = #"{"pagination":{"page":1,"pages":1,"items":1},"releases":[{"id":7,"instance_id":2400000123,"basic_information":{"id":7,"title":"Værsgo","artists":[{"name":"Kim Larsen"}]}}]}"#
    let parsed = try DiscogsClient.parseCollectionPage(Data(page.utf8))
    check(parsed.items.first?.instanceID == big, "instance_id over Int32.max læses fra Discogs' svar")

    let url = FileManager.default.temporaryDirectory.appendingPathComponent("vsf-big-\(UUID().uuidString).sqlite")
    defer { try? FileManager.default.removeItem(at: url) }
    let s = try ShelfStore(path: url.path)
    let bigItem = item(big, 7, "Kim Larsen", "Værsgo")
    _ = try s.applyCollection([bigItem])
    let again = try s.applyCollection([bigItem])
    let copies = Array(try s.loadLibrary().copies.values)
    check(copies.count == 1 && copies.first?.instanceID == big && again.newCopies.isEmpty,
          "instance_id over Int32.max overlever databasen og to syncs")
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
    check(s.db.userVersion == 8, "skema v8")
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
    check(up.db.userVersion == 8 && (try? up.logPlay(copyID: cid)) != nil, "migration v3→v8 opretter plays og bevarer kopier")
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
    check(CopyStatus.allCases == [.home, .playing, .wall, .lent, .stored, .missing], "rækkefølge af statusser: \(CopyStatus.allCases.map(\.rawValue))")
    check(CopyStatus(rawValue: "playing") == .playing && CopyStatus.playing.label == "På pladespilleren" && !CopyStatus.playing.isOnShelf,
          "På pladespilleren: rawValue, label og står ikke i reolen")
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
    let put = client.wantlistRequest(username: "testbruger", releaseID: 249504)
    check(put.httpMethod == "PUT" && put.url?.absoluteString == "https://api.discogs.com/users/testbruger/wants/249504", "PUT: metode og sti: \(put.url?.absoluteString ?? "")")
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
        "PUT /users/testbruger/wants/249504": (201, #"{"id":249504,"rating":0}"#),
        "PUT /users/testbruger/wants/1": (404, #"{"message":"Release not found."}"#),
        "PUT /users/andre/wants/249504": (401, #"{"message":"You must authenticate to access this resource."}"#),
        "GET /database/search?type=master": (200, mastersJSON),
        "GET /database/search?type=release": (200, releasesJSON),
        "GET /masters/10362/versions": (200, fxVersionsP1),
        "GET /releases/249504": (200, fxRelease249504),
        "GET /masters/999/versions": (0, ""),
    ]
    let added = blocking { try await stub.addToWantlist(username: "testbruger", releaseID: 249504) }
    let sentPut = StubDiscogs.seen.last
    check(errorText(added) == nil && sentPut?.httpMethod == "PUT" && sentPut?.url?.path == "/users/testbruger/wants/249504"
          && sentPut?.value(forHTTPHeaderField: "Authorization") == "Discogs token=\(fakeToken)", "addToWantlist sender PUT med token")
    check(errorText(blocking { try await stub.addToWantlist(username: "testbruger", releaseID: 1) }) == "Pladen findes ikke længere på Discogs.", "PUT 404 → dansk tekst")
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
    let uc2 = try DiscogsClient.parseUserCurrency(Data(#"{"username":"testbruger","curr_abbr":"EUR"}"#.utf8))
    check(uc2 == "EUR", "brugerens valuta: EUR")
    let uc3 = try DiscogsClient.parseUserCurrency(Data(#"{"username":"testbruger","curr_abbr":" usd"}"#.utf8))
    check(uc3 == "USD", "brugerens valuta: renses til USD")
    let uc4 = try DiscogsClient.parseUserCurrency(Data(#"{"username":"testbruger"}"#.utf8))
    check(uc4 == nil, "brugerens valuta: mangler → nil")
    let uc5 = try DiscogsClient.parseUserCurrency(Data(#"{"username":"testbruger","curr_abbr":"€"}"#.utf8))
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
        "GET /users/testbruger": (200, #"{"username":"testbruger","curr_abbr":"EUR"}"#),
        "GET /masters/10362/versions": (200, fxVersionsP1),
    ]
    StubDiscogs.seen = []
    let mo = blocking { try await stub.masterOffer(id: 10362) }
    check((try? mo.get().mainRelease) == 1873013 && StubDiscogs.seen.last?.url?.path == "/masters/10362" && StubDiscogs.seen.last?.httpMethod == "GET",
          "masterOffer henter GET /masters/{id}")
    let uc = blocking { try await stub.userCurrency(username: "testbruger") }
    check((try? uc.get()) == "EUR" && StubDiscogs.seen.last?.url?.path == "/users/testbruger", "userCurrency henter GET /users/{username}")
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
    check(abs(G.side(width: 2000, height: 300) - 186) < 0.0001, "cover flow: siden begrænses af højden (62 %, plads til spejling)")
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

    // Glidende position (kommatal) og glid under trackpad
    check(abs(G.x(0.5, side: side) - 0.31 * side) < 0.0001 && abs(G.angle(0.5) + G.tilt / 2) < 0.0001,
          "cover flow: halvvejs mellem to pladser står coveret halvvejs og halvt drejet")
    check(abs(G.x(2.0, side: side) - G.x(2, side: side)) < 0.0001 && G.angle(3.7) == -G.tilt, "cover flow: kommatal og heltal giver det samme")
    var smooth = true
    for k in -40...40 {
        let o = Double(k) / 10
        if !(G.x(o + 0.1, side: side) > G.x(o, side: side)) { smooth = false }
    }
    check(smooth, "cover flow: coverne glider jævnt (x vokser hele vejen)")
    let g1 = G.glide(center: 5, shift: 0.4, count: 10)
    check(g1.center == 5 && abs(g1.shift - 0.4) < 0.0001, "glid: under en halv plade bliver midten")
    let g2 = G.glide(center: 5, shift: 0.7, count: 10)
    check(g2.center == 6 && abs(g2.shift + 0.3) < 0.0001, "glid: over en halv plade skifter midten uden hop")
    let g3 = G.glide(center: 5, shift: -2.6, count: 10)
    check(g3.center == 2 && abs(g3.shift - 0.4) < 0.0001, "glid: flere plader baglæns")
    let g4 = G.glide(center: 0, shift: -3, count: 10)
    check(g4.center == 0 && abs(g4.shift + 0.3) < 0.0001, "glid: i starten kan man kun skubbe lidt (gummibånd)")
    let g5 = G.glide(center: 9, shift: 5, count: 10)
    check(g5.center == 9 && abs(g5.shift - 0.3) < 0.0001, "glid: i slutningen kan man kun skubbe lidt")
    let g6 = G.glide(center: 3, shift: 1, count: 0)
    check(g6.center == 0 && g6.shift == 0, "glid: tom sektion")
    check(G.fling(from: 5, velocity: 2, count: 50) == nil, "fart: et langsomt stryg falder bare på plads")
    let f1 = G.fling(from: 5, velocity: 20, count: 50)
    check(f1?.target == 14 && abs((f1?.duration ?? 0) - 1.8) < 0.0001, "fart: et kraftigt stryg fortsætter 9 plader og bremser op på 1,8 s")
    check(G.fling(from: 5, velocity: -20, count: 50)?.target == 0, "fart: baglæns stopper ved den første plade")
    check(G.fling(from: 40, velocity: 1000, count: 50)?.target == 49, "fart: stopper ved den sidste plade")
    check(G.fling(from: 0, velocity: 1000, count: 100)?.target == 27, "fart: meget hurtige stryg begrænses (højst 60 plader/s)")
    check(G.fling(from: 49, velocity: 20, count: 50) == nil, "fart: allerede ved enden – intet glid")
    check(abs(G.spinDuration(distance: 0) - 1.3) < 0.0001 && abs(G.spinDuration(distance: 1000) - 2.7) < 0.0001,
          "lykkehjul: mindst 1,3 s og højst 2,7 s")
    check(G.easeOut(0) == 0 && G.easeOut(1) == 1 && abs(G.easeOut(0.5) - 0.9375) < 0.0001 && G.easeOut(2) == 1,
          "lykkehjul: kurven starter hurtigt og bremser op")
    // Procent inde i sektionen (samme tal på Windows og i webappen).
    check([(1, 1), (1, 15), (7, 15), (15, 15), (2, 4), (1, 200), (0, 3), (5, 0)].map { Library.percentFromLeft(position: $0.0, count: $0.1) }
          == [50, 5, 45, 95, 40, 5, 15, 50] && Library.percentHint(position: 7, count: 15) == "ca. 45 % inde",
          "procent inde: midten af pladen, rundet til 5, mellem 5 og 95")
    // Udseende: samme stile og farver som webappen (web/app.css).
    check(LookStyle.allCases.map(\.rawValue) == ["", "kasse", "cover", "fokus"] && LookTheme.allCases.map(\.rawValue) == ["", "light", "dark"],
          "udseende: samme stile og temaer som webappen")
    check(LookStyle.standard.palette == nil && !LookStyle.standard.condensedTitles && LookStyle.kasse.condensedTitles && LookStyle.kasse.name == "Hi-fi" && LookStyle.fokus.bigCovers && !LookStyle.cover.bigCovers,
          "udseende: Standard bruger systemets farver; kun Covers i fokus har store covers")
    if let css = try? String(contentsOfFile: "web/app.css", encoding: .utf8) {
        for style in LookStyle.allCases {
            guard let p = style.palette else { continue }
            let colors = [p.light, p.dark].flatMap { [$0.background, $0.cell, $0.label, $0.accent, $0.accentInk] }
            let missing = colors.map { String(format: "#%06X", $0) }.filter { !css.contains($0) }
            check(css.contains("data-style=\"\(style.rawValue)\"") && missing.isEmpty,
                  "udseende: \(style.name) har samme farver som webappen \(missing.isEmpty ? "" : "(mangler \(missing.joined(separator: ", ")))")")
        }
    }
}

// MARK: iMusic (Daisycon-feed, separat cache)
// Små lokale eksempel-feeds i Daisycons struktur (datafeed › programs › products › product_info / update_info).
// Det rigtige feed og imusic.dk hentes aldrig i checks.
let fxIMusicJSON = #"""
{"datafeed":{"info_array":{"generated":"2026-10-02"},"programs":[{"program_info":{"id":19392,"name":"iMusic DK","url":"https://imusic.dk"},
 "products":[
  {"product_info":{"title":"Pink Floyd - Animals (LP)","link":"https://lt45.net/c/?si=19392&li=1&wi=1&ws=&dl=animals","price":"249.00","ean":"5099902987613","category_path":"Musik > Vinyl","in_stock":true,"delivery_time":"1-2 hverdage","images":[{"location":"https://img/1.jpg","size":"large","tag":"","type":"front"}]},
   "update_info":{"daisycon_unique_id":"a1","status":"active"}},
  {"product_info":{"title":"Pink Floyd - Animals","brand":"Pink Floyd","link":"https://lt45.net/c/?si=19392&li=1&wi=1&ws=&dl=animals-cd","price":"99,95","ean":"0 77774 64612 5","category":"CD","in_stock":"false","delivery_description":"Bestillingsvare"},
   "update_info":{"daisycon_unique_id":"a2","status":"active"}},
  {"product_info":{"title":"Alien (DVD)","link":"https://lt45.net/c/?dl=alien","price":"59","category_path":"Film > DVD","in_stock":true},
   "update_info":{"status":"active"}},
  {"product_info":{"title":"David Bowie - Low (LP)","link":"https://lt45.net/c/?dl=low","price":"229","category_path":"Musik > Vinyl","in_stock":true},
   "update_info":{"status":"deleted"}},
  {"product_info":{"title":"Kim Larsen - Værsgo \"Remastered\" {LP}","link":"https://lt45.net/c/?dl=vaersgo","price":"1.249,95","keywords":"vinyl dansk rock","in_stock_amount":"3"},
   "update_info":{"status":"active"}}
 ]}]}}
"""#
let fxIMusicXML = #"""
<?xml version="1.0" encoding="UTF-8"?>
<datafeed><programs><program><program_info><id>19392</id><name>iMusic DK</name></program_info>
<products>
 <product><product_info><title>Pink Floyd - Animals (LP)</title><link>https://lt45.net/c/?si=19392&amp;dl=animals</link><price>249.00</price><ean>5099902987613</ean><category_path>Musik &gt; Vinyl</category_path><in_stock>true</in_stock><images><image><location>https://img/1.jpg</location></image></images></product_info><update_info><status>active</status></update_info></product>
 <product><product_info><title><![CDATA[Alien (DVD)]]></title><link>https://lt45.net/c/?dl=alien</link><price>59</price><category_path>Film</category_path></product_info></product>
 <product><product_info><title>Genesis - Foxtrot</title><brand>Genesis</brand><link>https://lt45.net/c/?dl=foxtrot</link><price>199</price><category>Vinyl</category><in_stock>0</in_stock><delivery_description>Bestillingsvare</delivery_description></product_info><update_info><status>active</status></update_info></product>
</products></program></programs></datafeed>
"""#
do {
    // Stregkoder
    check(Barcode.normalize("5 099902 987613") == "5099902987613", "EAN-13 med mellemrum → kun cifre")
    check(Barcode.normalize("0 77774 64612 5") == "0077774646125" && Barcode.normalize("077774646125") == "0077774646125",
          "UPC-A (12 cifre) → EAN-13 med foranstillet 0")
    check(Barcode.normalize("00077774646125") == "0077774646125", "GTIN-14 med foranstillet 0 → EAN-13")
    check(Barcode.normalize("1234-5678") == "12345678", "EAN-8")
    check(Barcode.normalize("SHVL 804") == nil && Barcode.normalize("") == nil && Barcode.normalize("12345") == nil,
          "katalognumre og korte tal er ikke stregkoder")

    // Priser og lager
    check(IMusicFields.parsePrice("249.00") == 249 && IMusicFields.parsePrice("99,95") == 99.95
          && IMusicFields.parsePrice("1.249,95") == 1249.95 && IMusicFields.parsePrice("DKK 1,249.50") == 1249.5
          && IMusicFields.parsePrice("gratis") == nil && IMusicFields.parsePrice("0") == nil, "priser i begge talformater")
    check(IMusicFields.parseStock("true") == true && IMusicFields.parseStock("0") == false && IMusicFields.parseStock("3") == true
          && IMusicFields.parseStock("Out of stock") == false && IMusicFields.parseStock("måske") == nil, "lagerstatus")

    // JSON (læst i bidder på 7 byte)
    let fromJSON = try IMusicFeedParser.parse(data: Data(fxIMusicJSON.utf8))
    check(fromJSON.map(\.title) == ["Animals (LP)", "Pink Floyd - Animals", "Værsgo \"Remastered\" {LP}"],
          "JSON: kun aktive musikvarer (ikke film, ikke slettede): \(fromJSON.map(\.title))")
    let animalsLP = fromJSON.first
    check(animalsLP?.artist == "Pink Floyd" && animalsLP?.ean == "5099902987613" && animalsLP?.price == 249
          && animalsLP?.currency == "DKK" && animalsLP?.inStock == true && animalsLP?.isVinyl == true
          && animalsLP?.link.absoluteString == "https://lt45.net/c/?si=19392&li=1&wi=1&ws=&dl=animals",
          "JSON: kunstner fra titlen, EAN, pris, lager og affiliate-link")
    let animalsCD = fromJSON.dropFirst().first
    check(animalsCD?.artist == "Pink Floyd" && animalsCD?.ean == "0077774646125" && animalsCD?.price == 99.95
          && animalsCD?.inStock == false && animalsCD?.availabilityText == "bestillingsvare" && animalsCD?.isVinyl == false,
          "JSON: brand som kunstner, UPC → EAN, bestillingsvare")
    check(fromJSON.last?.price == 1249.95 && fromJSON.last?.inStock == true, "JSON: anførselstegn og tuborgklammer i tekst, lager som antal")
    check(animalsLP?.availabilityText == "på lager", "på lager-tekst")

    // XML (streamet)
    let fromXML = try IMusicFeedParser.parse(data: Data(fxIMusicXML.utf8))
    check(fromXML.map(\.title) == ["Animals (LP)", "Genesis - Foxtrot"], "XML: kun musikvarer: \(fromXML.map(\.title))")
    check(fromXML.first?.link.absoluteString == "https://lt45.net/c/?si=19392&dl=animals" && fromXML.first?.ean == "5099902987613",
          "XML: &amp; i linket og EAN")
    check(fromXML.last?.artist == "Genesis" && fromXML.last?.inStock == false && fromXML.last?.availabilityText == "bestillingsvare",
          "XML: brand som kunstner og bestillingsvare")
    check(IMusicFeedParser.detectFormat(Data("  \n{".utf8)) == .json && IMusicFeedParser.detectFormat(Data("\u{FEFF}<?xml".utf8)) == .xml
          && IMusicFeedParser.detectFormat(Data("title;link".utf8)) == nil, "formatet genkendes (også med BOM)")

    // Søge-URL (virker uden feed)
    check(IMusicLink.searchURL(artist: "Pink Floyd", title: "Animals").absoluteString == "https://imusic.dk/page/search?query=Pink%20Floyd%20Animals",
          "søge-URL på imusic.dk")
    check(IMusicLink.searchURL(artist: " Kim Larsen ", title: "Værsgo", vinylOnly: true).absoluteString
          == "https://imusic.dk/vinyl/search?query=Kim%20Larsen%20V%C3%A6rsgo", "søge-URL kun i vinyl, med æøå")
    check(IMusicLink.searchURL(artist: "AC/DC", title: "Back In Black & More").query?.contains("%26") == true, "& kodes i søgningen")

    // Feed-URL'en
    check(IMusicFeedUpdater.validate(" https://daisycon.io/datafeed/?media_id=1&program_id[]=19392&type=JSON ") != nil, "Daisycon-feed-URL godtages")
    check(IMusicFeedUpdater.validate("http://daisycon.io/datafeed/") == nil && IMusicFeedUpdater.validate("https://example.com/feed") == nil
          && IMusicFeedUpdater.validate("hej") == nil, "kun https hos Daisycon")

    // Cache: separat fil under Caches, aldrig vinyl.sqlite
    let defaultCache = IMusicCache.defaultURL
    check(defaultCache.lastPathComponent == "imusic.sqlite" && defaultCache.path.contains("/Caches/VinylShelfFinder/")
          && defaultCache != ShelfStore.defaultURL && defaultCache.deletingLastPathComponent() != ShelfStore.defaultURL.deletingLastPathComponent(),
          "iMusic-cachen ligger i Caches, ikke ved vinyl.sqlite")
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("imusic-check-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let feedFile = dir.appendingPathComponent("feed.json")
    try Data(fxIMusicJSON.utf8).write(to: feedFile)
    let cache = try IMusicCache(url: dir.appendingPathComponent("imusic.sqlite"))
    check(IMusicCache.needsRefresh(lastFetched: nil) && cache.lastFetched == nil, "tom cache skal hentes")
    let day = Date(timeIntervalSince1970: 1_790_000_000)
    let stored = try cache.replace(withFeedAt: feedFile, now: day)
    check(stored == 3 && cache.count == 3, "cachen får de 3 musikvarer fra feedet (\(stored))")
    check(cache.lastFetched == day && !IMusicCache.needsRefresh(lastFetched: day, now: day.addingTimeInterval(3600))
          && IMusicCache.needsRefresh(lastFetched: day, now: day.addingTimeInterval(25 * 3600)), "feedet hentes højst én gang i døgnet")
    let files = Set(try FileManager.default.contentsOfDirectory(atPath: dir.path))
    check(!files.contains("vinyl.sqlite") && files.isSubset(of: ["feed.json", "imusic.sqlite", "imusic.sqlite-wal", "imusic.sqlite-shm"]),
          "cachen opretter ingen vinyl.sqlite: \(files.sorted())")
    let xmlFile = dir.appendingPathComponent("feed.xml")
    try Data(fxIMusicXML.utf8).write(to: xmlFile)
    let fromXMLFile = try cache.replace(withFeedAt: xmlFile, now: day)
    check(fromXMLFile == 2 && cache.count == 2, "ny hentning erstatter hele cachen (XML)")
    _ = try cache.replace(withFeedAt: feedFile, now: day)

    // Matching
    check(cache.match(barcodes: ["5 099902 987613"], artist: "", title: "")?.price == 249, "match på stregkode")
    check(cache.match(barcodes: ["077774646125"], artist: "Noget", title: "Andet")?.price == 99.95, "match på UPC mod EAN i feedet")
    check(cache.match(barcodes: [], artist: "Pink Floyd", title: "Animals")?.isVinyl == true, "kunstner + titel: vinyl foretrækkes")
    check(cache.match(barcodes: [], artist: "Pink Floyd", title: "Animals", preferVinyl: false)?.isVinyl == false,
          "uden vinyl-ønske vinder den udgave, der passer bedst (her cd'en uden ekstra ord)")
    check(cache.match(barcodes: [], artist: "Pink Floid", title: "Animals")?.price == 249, "tåler en stavefejl i kunstnernavnet")
    check(cache.match(barcodes: [], artist: "Kim Larsen", title: "Værsgo")?.price == 1249.95, "æøå i titlen")
    check(cache.match(barcodes: [], artist: "Pink Floyd", title: "The Wall") == nil, "intet match, når et ord mangler")
    check(cache.match(barcodes: ["1234567890128"], artist: "", title: "") == nil, "ukendt stregkode og ingen tekst → intet match")
} catch { check(false, "iMusic: \(error)") }

// MARK: Cd'er: egen hylde i samme samling
do {
    check(Medium.of(format: "CD, Album") == .cd && Medium.of(format: "2×CD, Compilation") == .cd
          && Medium.of(format: "CDr, Album") == .cd && Medium.of(format: "SACD, Hybrid") == .cd, "cd-formater genkendes")
    check(Medium.of(format: "Vinyl, LP, Album") == .vinyl && Medium.of(format: "2×Vinyl, LP") == .vinyl
          && Medium.of(format: "Cassette, Album") == .vinyl && Medium.of(format: nil) == .vinyl
          && Medium.of(format: "Box Set, CD") == .vinyl, "alt andet hører til pladerne (kun første format tæller)")

    let (s, url) = try freshStore("cd")
    defer { try? FileManager.default.removeItem(at: url) }
    func item(_ i: Int, _ artist: String, _ title: String, _ format: String) -> DiscogsCollectionItem {
        DiscogsCollectionItem(instanceID: 70_000 + i, dateAdded: nil,
                              release: Release(id: 700_000 + i, artist: artist, title: title, format: format))
    }
    _ = try s.applyCollection([item(0, "ABBA", "Arrival", "Vinyl, LP"), item(1, "Blur", "Parklife", "CD, Album"),
                               item(2, "Bowie", "Low", "Vinyl, LP"), item(3, "Radiohead", "Kid A", "CD, Album"),
                               item(4, "Radiohead", "OK Computer", "CD, Album")])
    let counts = try s.mediumCounts()
    check(counts[.vinyl] == 2 && counts[.cd] == 3, "antal pr. hylde: \(counts)")
    let vinyl = try s.loadLibrary(), cds = try s.loadLibrary(medium: .cd)
    check(vinyl.copies.count == 2 && cds.copies.count == 3 && cds.medium == .cd, "samlingen deles op i plader og cd'er")

    let rules = SortRules()
    try s.createLayout([(shelf: 1, section: "A", copies: rules.sorted(vinyl.allItems).map(\.id))])
    try s.createLayout([(shelf: 1, section: "A", copies: rules.sorted(cds.allItems).map(\.id))], medium: .cd)
    var v = try s.loadLibrary(), c = try s.loadLibrary(medium: .cd)
    check(v.locations.count == 1 && c.locations.count == 1 && v.locations[0].id != c.locations[0].id
          && v.unplaced.isEmpty && c.unplaced.isEmpty, "egne reoler pr. hylde")
    check(c.locations[0].name == "Cd-reol 1 · Sektion A" && v.locations[0].name == "Reol 1 · Sektion A", "cd-reolens navn")

    // Cd-reolen kan oprettes igen uden at røre pladernes placeringer.
    let vinylBefore = placementRows(s)
    try s.createLayout([(shelf: 1, section: "A", copies: Array(rules.sorted(cds.allItems).map(\.id).prefix(1))),
                        (shelf: 1, section: "B", copies: Array(rules.sorted(cds.allItems).map(\.id).dropFirst()))], medium: .cd)
    v = try s.loadLibrary(); c = try s.loadLibrary(medium: .cd)
    check(v.locations.count == 1 && v.globalOrder.count == 2 && c.locations.count == 2 && c.globalOrder.count == 3,
          "ny cd-opdeling rører ikke pladereolen")
    check(placementRows(s).count == vinylBefore.count, "samme antal placeringer i alt")

    // Find-teksterne siger "cd".
    let kidA = c.allItems.first { $0.title == "Kid A" }!.id
    let adv = c.referenceAdvice(for: kidA)!
    check(adv.placementHint.hasPrefix("Cd ") && !adv.placementHint.contains("Plade"), "Find på cd: \(adv.placementHint)")
    check(adv.primary.reason.contains("cd") && !adv.primary.reason.contains("plade"), "Find på cd: \(adv.primary.reason)")
    let low = v.allItems.first { $0.title == "Low" }!.id
    check(v.referenceAdvice(for: low)!.placementHint.hasPrefix("Plade "), "pladerne siger stadig plade")

    // En ny sektion lander på den rigtige hylde.
    let newCD = try s.addSection(shelf: 2, section: "A", medium: .cd)
    c = try s.loadLibrary(medium: .cd); v = try s.loadLibrary()
    check(c.location(newCD)?.name == "Cd-reol 2 · Sektion A" && v.location(newCD) == nil && c.locations.last?.id == newCD,
          "ny cd-sektion står sidst på cd-hylden")

    // "Det er en plade": kopien flyttes til den anden hylde og mister sin cd-plads.
    try s.setMedium(copyID: kidA, .vinyl)
    v = try s.loadLibrary(); c = try s.loadLibrary(medium: .cd)
    check(v.unplaced.contains(kidA) && c.copies[kidA] == nil && v.item(kidA)?.medium == .vinyl, "skift til plader: uplaceret blandt pladerne")
    let lastKind = try s.history().first?.kind
    check(lastKind == .unplaced, "skiftet står i historikken")
    try s.setMedium(copyID: kidA, nil)
    c = try s.loadLibrary(medium: .cd)
    check(c.unplaced.contains(kidA), "tilbage til Discogs' format: cd igen (uden plads)")

    // En sync ændrer ikke brugerens valg.
    try s.setMedium(copyID: kidA, .vinyl)
    _ = try s.applyCollection([item(0, "ABBA", "Arrival", "Vinyl, LP"), item(1, "Blur", "Parklife", "CD, Album"),
                               item(2, "Bowie", "Low", "Vinyl, LP"), item(3, "Radiohead", "Kid A", "CD, Album"),
                               item(4, "Radiohead", "OK Computer", "CD, Album")])
    let kept = try s.loadLibrary().copies[kidA]?.mediumOverride
    check(kept == .vinyl, "sync bevarer valget af hylde")

    // Demo har begge hylder.
    let (d, durl) = try freshStore("cd-demo")
    defer { try? FileManager.default.removeItem(at: durl) }
    try DemoData.seedIfEmpty(d)
    let dcd = try d.loadLibrary(medium: .cd)
    check(dcd.copies.count == 10 && dcd.locations.count == 2 && dcd.unplaced.isEmpty, "demo: cd-reol med 2 sektioner")
    let demoVinyl = try d.loadLibrary().copies.count
    check(demoVinyl == 43, "demo: pladerne er uændrede")
} catch { check(false, "cd'er: \(error)") }

// MARK: Sorteringsliste (samme checks som på Windows)
do {
    let (s, url) = try freshStore("sortlist")
    defer { try? FileManager.default.removeItem(at: url) }
    func it(_ i: Int, _ artist: String, _ title: String, _ format: String) -> DiscogsCollectionItem {
        DiscogsCollectionItem(instanceID: 80_000 + i, dateAdded: nil,
                              release: Release(id: 800_000 + i, artist: artist, title: title, format: format))
    }
    let first = [it(0, "ABBA", "Arrival", "Vinyl, LP"), it(1, "Blur", "Parklife", "CD, Album"),
                 it(2, "Bowie", "Low", "Vinyl, LP"), it(3, "Radiohead", "Kid A", "CD, Album")]
    _ = try s.applyCollection(first)
    let rules = SortRules()
    let vinyl = SortList.build(try s.loadLibrary(), rules: rules)
    let cds = SortList.build(try s.loadLibrary(medium: .cd), rules: rules)
    check(vinyl.map(\.item.title) == ["Arrival", "Low"] && vinyl.map(\.number) == [1, 2],
          "sorteringsliste uden reoler: pladerne nummereret 1, 2 uden cd'er imellem")
    check(cds.map(\.item.title) == ["Parklife", "Kid A"] && cds.allSatisfy { $0.location == nil }, "cd'erne har deres egen sorteringsliste")

    // Med reoler: fysisk rækkefølge sektion for sektion, nye til sidst.
    var lib = try s.loadLibrary()
    let ids = rules.sorted(lib.allItems).map(\.id)
    try s.createLayout([(shelf: 1, section: "A", copies: Array(ids.prefix(1))), (shelf: 1, section: "B", copies: Array(ids.dropFirst()))])
    _ = try s.applyCollection(first + [it(4, "Air", "Moon Safari", "Vinyl, LP")])
    lib = try s.loadLibrary()
    let low = lib.allItems.first { $0.title == "Low" }!.id
    try s.setStatus(copyID: low, .lent, note: "Mads")
    let list = SortList.build(try s.loadLibrary(), rules: rules)
    check(list.map(\.item.title) == ["Arrival", "Low", "Moon Safari"]
          && list[0].location?.section == "A" && list[1].location?.section == "B" && list[2].location == nil,
          "sorteringsliste med reoler: sektion A, sektion B, og ny plade uden plads til sidst")
    check(list[1].number == nil && list[2].number == 2 && SortList.countable(list) == 2, "udlånt plade har intet nummer og tæller ikke med")

    // Flueben gemmes pr. hylde.
    let arrival = list[0].item.id
    s.setSortChecked(.vinyl, copyID: arrival, checked: true)
    s.setSortChecked(.vinyl, copyID: arrival, checked: true)
    check(s.sortChecked(.vinyl) == [arrival] && s.sortChecked(.cd).isEmpty, "flueben gemmes pr. hylde")
    check(SortList.nextUnchecked(list, done: s.sortChecked(.vinyl))?.item.title == "Moon Safari", "næste uden flueben springer udlånte over")
    s.setSortChecked(.vinyl, copyID: arrival, checked: false)
    check(s.sortChecked(.vinyl).isEmpty, "flueben kan fjernes")
    s.setSortChecked(.cd, copyID: cds[0].item.id, checked: true)
    s.clearSortChecked(.cd)
    check(s.sortChecked(.cd).isEmpty, "start forfra rydder fluebenene")
} catch { check(false, "sorteringsliste: \(error)") }

// MARK: Tal sidst (som på Windows, men slået fra som standard på Mac)
do {
    let d = SortRules()
    check(!d.numbersLast, "tal sidst er slået fra som standard på Mac (sorteringen må ikke ændre sig ved opdatering)")
    check(SortRules.startsWithDigit(d.sortArtist("The 1975")) && SortRules.startsWithDigit("10cc")
          && !SortRules.startsWithDigit(d.sortArtist("Blur")) && !SortRules.startsWithDigit(""), "tal genkendes (efter “The”)")
    func rec(_ id: Int64, _ artist: String, _ rank: Int?) -> RecordItem {
        RecordItem(copy: Copy(id: id, instanceID: Int(id), releaseID: Int(id), discogsRank: rank),
                   release: Release(id: Int(id), artist: artist, title: "T"))
    }
    let discogs = [rec(1, "10cc", 0), rec(2, "2Pac", 1), rec(3, "ABBA", 2), rec(4, "Zappa", 3), rec(5, "Åge Aleksandersen", 4)]
    check(d.sorted(discogs).first?.artist == "10cc", "slået fra: tal først som i Discogs (uændret sortering)")
    var on = d; on.numbersLast = true
    check(on.sorted(discogs).map(\.artist) == ["ABBA", "Zappa", "Åge Aleksandersen", "10cc", "2Pac"],
          "Discogs-rækkefølge: tal flyttes sidst og beholder deres indbyrdes orden")
    var own = on; own.useDiscogsOrder = false
    check(own.sorted(discogs).map(\.artist) == ["ABBA", "Zappa", "Åge Aleksandersen", "2Pac", "10cc"],
          "egne regler: bogstaver, Æ Ø Å, og så tal i talorden")
    let json = String(data: try JSONEncoder().encode(on), encoding: .utf8)!
    let decodedOn = try JSONDecoder().decode(SortRules.self, from: Data(json.utf8))
    check(json.contains("\"numbersLast\":true") && decodedOn.numbersLast,
          "tal-reglen gemmes og læses (samme nøgle som Windows)")
    let old = try JSONDecoder().decode(SortRules.self, from: Data(#"{"danishAlphabet":true}"#.utf8))
    check(!old.numbersLast, "gemte regler fra før tal-reglen: forbliver slået fra")
} catch { check(false, "tal sidst: \(error)") }

// MARK: Detaljelinjen (samme tekst som Windows og webappen)
do {
    let it = RecordItem(copy: Copy(id: 1, instanceID: 1, releaseID: 106),
                        release: Release(id: 106, artist: "Pink Floyd", title: "The Dark Side Of The Moon", year: 1973, label: "Harvest", catalogNumber: "SHVL 804", format: "Vinyl, LP"))
    check(it.detailLine == "Harvest SHVL 804 (1973). Vinyl, LP" && it.pressingLine == "Harvest SHVL 804 (1973)", "detaljelinjen: selskab, katalognr. (år). Format")
    let bare = RecordItem(copy: Copy(id: 2, instanceID: 2, releaseID: 2), release: Release(id: 2, artist: "A", title: "B", year: 1980, catalogNumber: "none"))
    check(bare.detailLine == "1980" && RecordItem(copy: bare.copy, release: Release(id: 2, artist: "A", title: "B")).detailLine.isEmpty, "detaljelinjen uden selskab og format")
}

// MARK: Kategorier: Jazz, Underholdning, Klassisk (samme checks som på Windows)
do {
    let d = SortRules()
    check(d.categories.isEmpty && Category.allCases.allSatisfy { d.mode($0) == .off },
          "kategorierne er slået fra som standard (sorteringen må ikke ændre sig ved opdatering)")
    check(Category.jazz.matches(genres: "Jazz, Rock", folder: nil) && !Category.jazz.matches(genres: "Rock", folder: nil)
          && Category.classical.matches(genres: "Stage & Screen, Classical", folder: nil) && !Category.classical.matches(genres: "Neoclassical", folder: nil)
          && Category.entertainment.matches(genres: "Pop", folder: " underholdning ") && !Category.entertainment.matches(genres: "Pop", folder: "Uncategorized")
          && !Category.entertainment.matches(genres: nil, folder: nil), "jazz og klassisk ud fra genren, underholdning ud fra Discogs-mappen")
    check(ShelfKind(rawValue: "cd.jazz") == ShelfKind(.cd, .jazz) && ShelfKind(rawValue: "vinyl") == .vinyl
          && ShelfKind(rawValue: "vinyl.x") == nil && ShelfKind(rawValue: "kassette") == nil && ShelfKind(.vinyl, .classical).rawValue == "vinyl.classical"
          && ShelfKind.all.count == 8 && ShelfKind.all.prefix(2) == [.vinyl, .cd], "hylderne har faste navne")
    check(ShelfKind(.vinyl, .jazz).shelfWord == "Jazz-reol" && ShelfKind(.cd, .classical).shelfWord == "Klassisk-cd-reol"
          && ShelfKind(.cd, .entertainment).title == "Underholdning (cd'er)" && ShelfKind.cd.shelfWord == "Cd-reol", "navne på kategori-reoler")
    func rec(_ id: Int64, _ artist: String, _ genres: String?, _ folder: String? = nil, _ rank: Int?) -> RecordItem {
        RecordItem(copy: Copy(id: id, instanceID: Int(id), releaseID: Int(id), discogsRank: rank, discogsFolder: folder),
                   release: Release(id: Int(id), artist: artist, title: "T", format: "Vinyl, LP", genres: genres))
    }
    let items = [rec(1, "Bach", "Classical", nil, 0), rec(2, "Beatles", "Rock", nil, 1), rec(3, "Coltrane", "Jazz", nil, 2),
                 rec(4, "Kim Larsen", "Pop", "Underholdning", 3), rec(5, "Miles Davis", "Jazz, Classical", nil, 4), rec(6, "Zappa", "Rock", nil, 5)]
    check(d.sorted(items).map(\.artist) == ["Bach", "Beatles", "Coltrane", "Kim Larsen", "Miles Davis", "Zappa"], "slået fra: uændret rækkefølge")
    var end = d
    for c in Category.allCases { end.categories[c] = .end }
    check(end.sorted(items).map(\.artist) == ["Beatles", "Zappa", "Coltrane", "Miles Davis", "Kim Larsen", "Bach"],
          "sidst på reolerne: Jazz, så Underholdning, så Klassisk; jazz vinder over klassisk")
    var onlyClassical = d; onlyClassical.categories[.classical] = .end
    check(onlyClassical.sorted(items).map(\.artist) == ["Beatles", "Coltrane", "Kim Larsen", "Zappa", "Bach", "Miles Davis"],
          "kun klassisk slået til: også jazz med genren Classical står blandt klassisk")
    var own = d; own.categories[.jazz] = .own
    check(own.shelfKind(of: items[2].copy, release: items[2].release) == ShelfKind(.vinyl, .jazz)
          && own.shelfKind(of: items[1].copy, release: items[1].release) == .vinyl
          && end.shelfKind(of: items[2].copy, release: items[2].release) == .vinyl, "egne reoler: jazz får sin egen hylde, sidst på reolerne gør ikke")
    let cdCopy = Copy(id: 9, instanceID: 9, releaseID: 9)
    check(own.shelfKind(of: cdCopy, release: Release(id: 9, artist: "A", title: "T", format: "CD, Album", genres: "Jazz")) == ShelfKind(.cd, .jazz)
          && own.shelfKind(of: cdCopy, release: Release(id: 9, artist: "A", title: "T", format: "File, MP3", genres: "Jazz")) == nil,
          "jazz-cd'er står på jazz-cd-reolerne, digitale filer ingen steder")
    let json = String(data: try JSONEncoder().encode(own), encoding: .utf8)!
    check(try json.contains(#""categories":{"jazz":"own"}"#) && (try JSONDecoder().decode(SortRules.self, from: Data(json.utf8))).mode(.jazz) == .own,
          "kategorierne gemmes og læses (samme nøgle som Windows)")
    check(try !String(data: try JSONEncoder().encode(d), encoding: .utf8)!.contains("categories"), "uden kategorier gemmes reglerne som før")
    let odd = try JSONDecoder().decode(SortRules.self, from: Data(#"{"categories":{"jazz":"end","polka":"own","classical":"?","entertainment":"off"}}"#.utf8))
    check(odd.categories == [.jazz: .end], "ukendte kategorier og valg springes over")
    check(try (try JSONDecoder().decode(SortRules.self, from: Data(#"{"numbersLast":true}"#.utf8))).categories.isEmpty,
          "gemte regler fra før kategorierne: forbliver slået fra")
} catch { check(false, "kategorier: \(error)") }

// MARK: Kategorier i databasen: Discogs-mappe, egne reoler og synkronisering (samme checks som på Windows)
do {
    let (s, url) = try freshStore("kategorier")
    defer { try? FileManager.default.removeItem(at: url) }
    check(s.db.userVersion == 8, "skema v8")
    func it(_ i: Int, _ artist: String, _ format: String, _ genres: String, folder: String?) -> DiscogsCollectionItem {
        DiscogsCollectionItem(instanceID: 60_000 + i, dateAdded: nil,
                              release: Release(id: 6_000 + i, artist: artist, title: "T\(i)", format: format, genres: genres), folderID: 1, folder: folder)
    }
    _ = try s.applyCollection([it(1, "Beatles", "Vinyl, LP", "Rock", folder: "Uncategorized"), it(2, "Coltrane", "Vinyl, LP", "Jazz", folder: "Uncategorized"),
                               it(3, "Kim Larsen", "Vinyl, LP", "Pop", folder: "Underholdning"), it(4, "Monk", "CD, Album", "Jazz", folder: nil)])
    let all = try s.loadLibrary(medium: .vinyl)
    check(all.copies.count == 3 && all.allItems.first { $0.artist == "Kim Larsen" }?.copy.discogsFolder == "Underholdning",
          "mappen fra Discogs gemmes pr. kopi")
    _ = try s.applyCollection([it(1, "Beatles", "Vinyl, LP", "Rock", folder: "Underholdning"), it(2, "Coltrane", "Vinyl, LP", "Jazz", folder: nil),
                               it(3, "Kim Larsen", "Vinyl, LP", "Pop", folder: "Underholdning"), it(4, "Monk", "CD, Album", "Jazz", folder: nil)])
    let again = try s.loadLibrary(medium: .vinyl)
    check(again.allItems.first { $0.artist == "Beatles" }?.copy.discogsFolder == "Underholdning"
          && again.allItems.first { $0.artist == "Coltrane" }?.copy.discogsFolder == "Uncategorized",
          "flyttet mappe opdateres; ukendt mappe (navnene ikke hentet) bevarer den gamle")
    try s.createLayout([(shelf: 1, section: "A", copies: again.globalOrder.isEmpty ? again.allItems.map(\.id).sorted() : again.globalOrder)], medium: .vinyl)
    let before = placementRows(s)
    var rules = s.loadSortRules(); rules.categories[.jazz] = .own
    try s.saveSortRules(rules)
    let main = try s.loadLibrary(kind: .vinyl), jazz = try s.loadLibrary(kind: ShelfKind(.vinyl, .jazz)), jazzCD = try s.loadLibrary(kind: ShelfKind(.cd, .jazz))
    check(try main.copies.count == 2 && jazz.copies.count == 1 && jazz.unplaced.count == 1 && jazzCD.copies.count == 1 && (try s.loadLibrary(kind: .cd)).copies.isEmpty,
          "egne reoler: jazz-pladen og jazz-cd'en flytter til deres egne hylder og venter på en plads")
    check(placementRows(s) == before && main.globalOrder.count == 2, "at slå egne reoler til flytter ingen placeringer i databasen")
    let counts = try s.shelfCounts()
    check(counts[.vinyl] == 2 && counts[ShelfKind(.vinyl, .jazz)] == 1 && counts[ShelfKind(.cd, .jazz)] == 1 && counts[.cd] == nil, "antal pr. hylde")
    try s.createLayout([(shelf: 1, section: "A", copies: Array(jazz.copies.keys))], kind: ShelfKind(.vinyl, .jazz))
    let jazz2 = try s.loadLibrary(kind: ShelfKind(.vinyl, .jazz)), main2 = try s.loadLibrary(kind: .vinyl)
    check(jazz2.locations.count == 1 && jazz2.unplaced.isEmpty && jazz2.locations[0].name == "Jazz-reol 1 · Sektion A" && main2.locations.count == 1
          && main2.locations[0].category == nil, "jazz-reolen oprettes uden at røre de almindelige reoler")
    check(try (try s.history(limit: 1)).first?.summary.hasPrefix("Jazz-reolerne er oprettet") == true, "historikken nævner jazz-reolerne")
    try s.addSection(shelf: 1, section: "B", kind: ShelfKind(.vinyl, .jazz))
    check(try (try s.loadLibrary(kind: ShelfKind(.vinyl, .jazz))).locations.map(\.shortName) == ["1A", "1B"] && (try s.loadLibrary(kind: .vinyl)).locations.count == 1,
          "ny sektion på jazz-reolen")
    // Synkronisering: mappe og kategori følger med, og en ældre version uden felterne sletter dem ikke.
    let docs = try s.exportSyncDocs()
    let coltrane = jazz2.allItems[0].copy
    let copyDoc = docs.first { $0.kind == .copy && $0.data?["instance"] == .int(Int64(coltrane.instanceID!)) }
    let jazzLoc = docs.first { $0.kind == .location && $0.data?["category"] != nil }
    check(copyDoc?.data?["folder"] == .string("Uncategorized") && jazzLoc?.data?["category"] == .string("jazz")
          && docs.filter { $0.kind == .location && $0.data?["category"] == nil }.count == 1, "mappe og kategori sendes med (kun når de findes)")
    let (b, burl) = try freshStore("kategorier-b")
    defer { try? FileManager.default.removeItem(at: burl) }
    _ = try b.applySyncDocs(docs)
    try b.saveSortRules(rules)
    let bj = try b.loadLibrary(kind: ShelfKind(.vinyl, .jazz))
    check(bj.locations.count == 2 && bj.copies.count == 1 && bj.unplaced.isEmpty && bj.locations.allSatisfy { $0.category == .jazz },
          "en anden enhed får jazz-reolen med pladen på")
    let oldCopy = SyncDoc(kind: .copy, key: copyDoc!.key, data: copyDoc!.data!.filter { $0.key != "folder" })
    let oldLoc = SyncDoc(kind: .location, key: jazzLoc!.key, data: jazzLoc!.data!.filter { $0.key != "category" })
    _ = try b.applySyncDocs([oldCopy, oldLoc])
    check(try (try b.loadLibrary(kind: ShelfKind(.vinyl, .jazz))).locations.count == 2
          && (try b.db.query("SELECT discogs_folder FROM copies WHERE discogs_instance_id = ?", coltrane.instanceID!)).first?["discogs_folder"]?.text == "Uncategorized",
          "poster fra en ældre version uden mappe/kategori sletter dem ikke")
    s.setSortChecked(ShelfKind(.vinyl, .jazz), copyID: coltrane.id, checked: true)
    check(try s.sortChecked(ShelfKind(.vinyl, .jazz)) == [coltrane.id] && s.sortChecked(.vinyl).isEmpty
          && (try s.exportSyncDocs()).contains { $0.kind == .setting && $0.key == "sort_checked_vinyl.jazz" }
          && !(try s.exportSyncDocs()).contains { $0.key == "sort_checked_cd.jazz" }, "flueben pr. kategori-hylde (og kun brugte sendes)")
    // Plader → cd: en jazz-plade, der markeres som cd, fjernes fra jazz-pladereolen.
    try s.setMedium(copyID: coltrane.id, .cd)
    check(try (try s.loadLibrary(kind: ShelfKind(.cd, .jazz))).unplaced.contains(coltrane.id) && (try s.loadLibrary(kind: ShelfKind(.vinyl, .jazz))).copies.isEmpty,
          "\"Det er en cd\" flytter jazz-pladen til jazz-cd'erne")
    check(try try DiscogsClient.parseFolders(Data(#"{"folders":[{"id":0,"name":"All","count":3},{"id":7,"name":"Underholdning","count":1}]}"#.utf8)) == [0: "All", 7: "Underholdning"],
          "mappernes navne fra Discogs læses")
} catch { check(false, "kategorier i databasen: \(error)") }

// MARK: Efternavn først (samme checks som på Windows)
do {
    check(SurnameSort.reverse("Bob Dylan") == "Dylan, Bob" && SurnameSort.reverse("Kim Larsen") == "Larsen, Kim", "for- og efternavn vendes")
    check(SurnameSort.reverse("Ludwig van Beethoven") == "Beethoven, Ludwig van" && SurnameSort.reverse("Sammy Davis Jr.") == "Davis, Sammy Jr.",
          "partikel bliver hos fornavnet, Jr. bliver bagerst")
    check(SurnameSort.reverse("Gasolin'") == nil && SurnameSort.reverse("The Beatles") == nil && SurnameSort.reverse("Simon & Garfunkel") == nil
          && SurnameSort.reverse("Various") == nil && SurnameSort.reverse("UB40") == nil && SurnameSort.reverse("Earth Wind and Fire") == nil
          && SurnameSort.reverse("Crosby Stills Nash Young") == nil, "ét ord, The, &, tal, and og fire ord vendes ikke")
    check(SurnameSort.looksLikePerson("Leonard Cohen") && !SurnameSort.looksLikePerson("Pink Floyd") && !SurnameSort.looksLikePerson("Massive Attack")
          && !SurnameSort.looksLikePerson("The Allman Brothers Band"), "gættet: person eller band")
    check(!SurnameSort.looksLikePerson("Black Stone Cherry") && !SurnameSort.looksLikePerson("Blue Cheer") && SurnameSort.reverse("A Perfect Circle") == nil
          && SurnameSort.reverse("Beethoven - Schubert") == nil && SurnameSort.looksLikePerson("B.B. King") && SurnameSort.looksLikePerson("Alice Cooper")
          && !SurnameSort.looksLikePerson("Sort Sol"),
          "typiske bandnavne gættes som bands; B.B. King er stadig en person")

    let cands = SurnameSort.candidates(["Bob Dylan", "Pink Floyd", "Bob Dylan", "Kim Larsen", "ABBA"])
    check(cands.map(\.artist) == ["Bob Dylan", "Kim Larsen", "Pink Floyd"], "hver kunstner én gang, kun dem der kan vendes")

    var rules = SortRules()
    rules.artistOverrides["Kim Larsen"] = "Larsen, Kim (Gasolin')"
    let applied = SurnameSort.apply(rules, candidates: cands, persons: ["Bob Dylan", "Kim Larsen"])
    check(applied.artistOverrides["Bob Dylan"] == "Dylan, Bob" && applied.artistOverrides["Kim Larsen"] == "Larsen, Kim (Gasolin')"
          && applied.artistOverrides["Pink Floyd"] == nil && !applied.useDiscogsOrder && rules.useDiscogsOrder,
          "valgte får efternavn (eget navn beholdes), Discogs-rækkefølge slås fra, originalen røres ikke")
    let undone = SurnameSort.apply(applied, candidates: cands, persons: ["Kim Larsen"])
    check(undone.artistOverrides["Bob Dylan"] == nil && undone.artistOverrides["Kim Larsen"] != nil, "fravalgt: det vendte navn fjernes igen")

    func rec(_ id: Int64, _ artist: String) -> RecordItem {
        RecordItem(copy: Copy(id: id, instanceID: Int(id), releaseID: Int(id)), release: Release(id: Int(id), artist: artist, title: "T"))
    }
    let withCohen = SurnameSort.apply(applied, candidates: SurnameSort.candidates(["Leonard Cohen"]), persons: ["Leonard Cohen"])
    check(withCohen.sorted([rec(1, "Kim Larsen"), rec(2, "Bob Dylan"), rec(3, "Leonard Cohen")]).map(\.artist)
          == ["Leonard Cohen", "Bob Dylan", "Kim Larsen"], "sorteres efter efternavn")

    let (s, url) = try freshStore("surname")
    defer { try? FileManager.default.removeItem(at: url) }
    s.saveSurnameNotPersons(["Pink Floyd", "Daft Punk", "Pink Floyd"])
    check(s.surnameNotPersons() == ["Daft Punk", "Pink Floyd"], "ikke-personer huskes")
    s.setSetting("surname_not_persons", "ødelagt")
    check(s.surnameNotPersons().isEmpty, "ødelagt gemt liste → tom, ingen fejl")
} catch { check(false, "efternavn først: \(error)") }

// MARK: Digitale filer (samme checks som på Windows)
do {
    check(Medium.isDigital(format: "File, MP3, Album") && Medium.isDigital(format: "8×File, FLAC")
          && !Medium.isDigital(format: "Vinyl, LP") && !Medium.isDigital(format: "Box Set, CD") && !Medium.isDigital(format: nil),
          "digitale filer genkendes (kun første format)")
    func it(_ i: Int, _ artist: String, _ title: String, _ format: String) -> DiscogsCollectionItem {
        DiscogsCollectionItem(instanceID: 90_000 + i, dateAdded: nil,
                              release: Release(id: 900_000 + i, artist: artist, title: title, format: format))
    }
    let (f, url) = try freshStore("digital")
    defer { try? FileManager.default.removeItem(at: url) }
    let withFile = [it(0, "ABBA", "Arrival", "Vinyl, LP"), it(1, "Blur", "Parklife", "CD, Album"),
                    it(5, "Moby", "Play", "File, MP3, Album"), it(6, "Björk", "Vespertine", "2×DVD, Album")]
    let fr = try f.applyCollection(withFile)
    let fc = try f.mediumCounts()
    check(fc[.vinyl] == 2 && fc[.cd] == 1 && fr.newCopies.count == 3, "fil tælles ikke med; dvd bliver på pladehylden")
    let vLib = try f.loadLibrary(), cLib = try f.loadLibrary(medium: .cd)
    check(vLib.allItems.allSatisfy { $0.title != "Play" } && cLib.allItems.allSatisfy { $0.title != "Play" },
          "filen står hverken blandt plader eller cd'er")
    let again = try f.applyCollection(withFile)
    check(again.newCopies.isEmpty && again.removedCopies.isEmpty, "filen gemmes og ses ikke som ny eller fjernet ved næste sync")
    let playID = try f.db.query("SELECT id FROM copies WHERE release_id = 900005").first!["id"]!.int!
    try f.setMedium(copyID: playID, .cd)
    let cdNow = try f.loadLibrary(medium: .cd)
    check(cdNow.unplaced.contains(playID), "brugeren kan selv sætte en fil på en hylde")
    let cdLoc = try f.addSection(shelf: 1, section: "A", medium: .cd)
    try f.move(copyID: playID, to: cdLoc, index: 0)
    try f.setMedium(copyID: playID, nil)
    let left = try f.db.query("SELECT copy_id FROM placements WHERE copy_id = ?", playID)
    check(left.isEmpty,
          "fil tilbage til Discogs' format: pladsen fjernes (ingen skjult placering)")
    let gone = try f.applyCollection(withFile.filter { $0.release.title != "Play" })
    check(gone.removedCopies.isEmpty, "en fil, der forsvinder fra Discogs, meldes ikke som fjernet plade")

    // En fil, der allerede står i reolen (fra før appen kendte forskel), bliver stående med samme nummer.
    let (k, kurl) = try freshStore("digital-keep")
    defer { try? FileManager.default.removeItem(at: kurl) }
    _ = try k.applyCollection([it(10, "ABBA", "Arrival", "Vinyl, LP"), it(11, "Moby", "Play", "File, MP3"), it(12, "Zappa", "Hot Rats", "Vinyl, LP")])
    let fileID = try k.db.query("SELECT id FROM copies WHERE release_id = 900011").first!["id"]!.int!
    try k.setMedium(copyID: fileID, .vinyl)          // som en gammel version, der regnede filen for en plade
    let all = try k.loadLibrary().allItems.map(\.id).sorted()
    try k.createLayout([(shelf: 1, section: "A", copies: all)])
    try k.db.run("UPDATE copies SET medium_override = NULL WHERE id = ?", fileID)   // gammel database: intet valg gemt
    let before = placementRows(k)
    let reopened = try ShelfStore(path: kurl.path)
    let lib = try reopened.loadLibrary()
    check(placementRows(reopened) == before && lib.copies[fileID]?.mediumOverride == .vinyl && lib.sections.values.first?.count == 3,
          "en fil med en plads bliver stående efter opdateringen (ingen numre flytter sig)")
} catch { check(false, "digitale filer: \(error)") }

// MARK: Eksport, import og nulstilling (samme checks som på Windows)
do {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vsf-transfer-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let dbPath = dir.appendingPathComponent("vinyl.sqlite").path
    var comps = DateComponents(); comps.year = 2026; comps.month = 10; comps.day = 17; comps.hour = 21; comps.minute = 5
    let when = Calendar.current.date(from: comps)!
    let export = dir.appendingPathComponent("ud").appendingPathComponent(DataTransfer.exportFileName(when)).path
    check(URL(fileURLWithPath: export).lastPathComponent == "Vinyl Shelf Finder 2026-10-17.sqlite", "eksportens filnavn (samme som Windows)")
    check(DataTransfer.safetyFileName("nulstilling", when).hasPrefix("før-nulstilling-2026-10-17-")
          && DatabaseBackup.date(fromFileName: "før-nulstilling-2026-10-17-2105.sqlite") == nil,
          "sikkerhedskopien før nulstilling ryddes ikke væk som en daglig kopi")

    do {
        let s = try ShelfStore(path: dbPath)
        _ = try s.applyCollection([item(1, 1, "ABBA", "Arrival"), item(2, 2, "Bowie", "Low")])
        let ids = try s.loadLibrary().allItems.map(\.id)
        try s.createLayout([(shelf: 1, section: "A", copies: ids)])
        s.setSortChecked(.vinyl, copyID: ids[0], checked: true)
        try DataTransfer.export(s, to: export)
        try DataTransfer.export(s, to: export)   // en eksisterende fil erstattes
    }
    let outFiles = try FileManager.default.contentsOfDirectory(atPath: (export as NSString).deletingLastPathComponent)
    check(FileManager.default.fileExists(atPath: export) && !outFiles.contains { $0.hasSuffix(".partial") }, "eksport gemmes som én fil")

    // Nulstilling: tom database ved næste start.
    try DataTransfer.requestReset(dbPath: dbPath)
    check((try? DataTransfer.applyPending(dbPath: dbPath)) == .reset && !FileManager.default.fileExists(atPath: dbPath), "nulstilling sletter databasen før start")
    check((try? DataTransfer.applyPending(dbPath: dbPath)) == .unchanged, "intet at gøre bagefter")
    do {
        let s = try ShelfStore(path: dbPath)
        let lib = try s.loadLibrary()
        check(lib.copies.isEmpty && lib.locations.isEmpty && s.sortChecked(.vinyl).isEmpty, "appen starter helt forfra")
    }

    // Import: det gamle system kommer tilbage.
    let summary = try DataTransfer.requestImport(dbPath: dbPath, source: export)
    check(summary == ImportSummary(vinyl: 2, cds: 0, sections: 1), "import viser indholdet først: \(summary)")
    check(FileManager.default.fileExists(atPath: export), "den valgte fil røres ikke")
    check((try? DataTransfer.applyPending(dbPath: dbPath)) == .unchanged && !FileManager.default.fileExists(atPath: DataTransfer.stagedImport(dbPath)),
          "en import uden bekræftelse bruges ikke og ryddes væk")
    do { let s = try ShelfStore(path: dbPath); check((try? s.loadLibrary().copies.isEmpty) == true, "databasen er urørt uden bekræftelse") }
    _ = try DataTransfer.requestImport(dbPath: dbPath, source: export)
    try DataTransfer.commitImport(dbPath: dbPath)
    check((try? DataTransfer.applyPending(dbPath: dbPath)) == .imported, "bekræftet import udføres ved start")
    do {
        let s = try ShelfStore(path: dbPath)
        let lib = try s.loadLibrary()
        check(lib.copies.count == 2 && lib.locations.count == 1 && lib.unplaced.isEmpty && s.sortChecked(.vinyl).count == 1,
              "reoler, placeringer og flueben er tilbage")
    }

    // Forkerte filer afvises, og intet bestilles.
    let junk = dir.appendingPathComponent("noter.sqlite").path
    try Data("ikke en database".utf8).write(to: URL(fileURLWithPath: junk))
    var refused = false
    do { _ = try DataTransfer.requestImport(dbPath: dbPath, source: junk) }
    catch let e as DataTransfer.TransferError { refused = e.message.contains("ikke en eksport") }
    check(refused && !FileManager.default.fileExists(atPath: DataTransfer.importFile(dbPath)), "en fil, der ikke er en eksport, afvises")
    let empty = dir.appendingPathComponent("tom.sqlite").path
    _ = try ShelfStore(path: empty)
    var emptyRefused = false
    do { _ = try DataTransfer.requestImport(dbPath: dbPath, source: empty) }
    catch let e as DataTransfer.TransferError { emptyRefused = e.message.contains("ingen plader") }
    check(emptyRefused && !FileManager.default.fileExists(atPath: DataTransfer.stagedImport(dbPath)), "en tom database afvises")
    var own = false
    do { _ = try DataTransfer.requestImport(dbPath: dbPath, source: dbPath) } catch is DataTransfer.TransferError { own = true }
    check(own, "appens egen database kan ikke importeres")

    // Fortryd: en bestilt nulstilling kan aflyses.
    try DataTransfer.requestReset(dbPath: dbPath)
    DataTransfer.cancelPending(dbPath: dbPath)
    check((try? DataTransfer.applyPending(dbPath: dbPath)) == .unchanged && FileManager.default.fileExists(atPath: dbPath), "bestilt nulstilling kan fortrydes")
} catch { check(false, "eksport/import: \(error)") }

// MARK: Synkronisering mellem enheder (poster, uden net)
do {
    func it(_ i: Int, _ artist: String, _ title: String) -> DiscogsCollectionItem {
        DiscogsCollectionItem(instanceID: 2_400_000_000 + i, dateAdded: nil,
                              release: Release(id: 950_000 + i, artist: artist, title: title, format: "Vinyl, LP"))
    }
    var cloud: [String: SyncDoc] = [:]
    func push(_ s: ShelfStore) throws -> Int {
        let p = try s.pendingSyncDocs()
        for d in p { cloud["\(d.kind.rawValue)|\(d.key)"] = d }
        try s.markSynced(p)
        return p.count
    }
    let items = [it(1, "ABBA", "Arrival"), it(2, "Bowie", "Low"), it(3, "Cohen", "Songs")]

    // A har hele systemet: reol, placeringer, en afspilning, et flueben og et sorteringsnavn.
    let (a, aurl) = try freshStore("sync-a"); defer { try? FileManager.default.removeItem(at: aurl) }
    _ = try a.applyCollection(items)
    let aIDs = SortRules().sorted(try a.loadLibrary().allItems).map(\.id)
    try a.createLayout([(shelf: 1, section: "A", copies: Array(aIDs.prefix(2))), (shelf: 1, section: "B", copies: Array(aIDs.dropFirst(2)))])
    _ = try a.logPlay(copyID: aIDs[0])
    a.setSortChecked(.vinyl, copyID: aIDs[1], checked: true)
    var r = a.loadSortRules(); r.artistOverrides["Cohen"] = "Cohen, Leonard"; try a.saveSortRules(r)
    let first = try push(a)
    let afterFirst = try a.pendingSyncDocs()
    check(first > 0 && afterFirst.isEmpty, "første synkronisering sender alt, derefter intet")

    // B er en ny enhed: henter alt.
    let (b, burl) = try freshStore("sync-b"); defer { try? FileManager.default.removeItem(at: burl) }
    try b.applySyncDocs(Array(cloud.values))
    let la = try a.loadLibrary(), lb = try b.loadLibrary()
    func order(_ l: Library) -> [[String]] { l.locations.map { loc in (l.sections[loc.id] ?? []).compactMap { l.item($0)?.title } } }
    check(order(lb) == order(la) && lb.copies.count == 3, "ny enhed får samme reoler og rækkefølge: \(order(lb))")
    check(try b.loadPlays().count == 1 && b.sortChecked(.vinyl).count == 1 && b.loadSortRules().artistOverrides["Cohen"] == "Cohen, Leonard",
          "afspilning, flueben og sorteringsnavne følger med")
    check((try b.pendingSyncDocs()).isEmpty, "det hentede sendes ikke tilbage igen")
    check(try b.applySyncDocs(Array(cloud.values)) == 0, "samme poster igen ændrer intet")

    // B flytter en plade; A får flytningen.
    let low = lb.allItems.first { $0.title == "Low" }!.id
    let secB = lb.locations[1].id
    try b.move(copyID: low, to: secB, index: 0)
    let moved = try b.pendingSyncDocs()
    check(moved.allSatisfy { $0.kind == .section }, "en flytning sendes som sektionernes rækkefølge: \(moved.map(\.kind.rawValue))")
    _ = try push(b)
    try a.applySyncDocs(Array(cloud.values))
    let oa = order(try a.loadLibrary()), ob = order(try b.loadLibrary())
    check(oa == ob, "flytningen er nået frem: \(oa)")

    // QR-koden fra et trykt skilt på A virker også på B, hvor sektionen har et andet nummer.
    let printed = try a.loadLibrary().locations[1]
    try a.setScanCode(locationID: printed.id, code: "vinylshelf://section/999")
    _ = try push(a)
    try b.applySyncDocs(Array(cloud.values))
    let lbq = try b.loadLibrary()
    let hit = lbq.location(forScanCode: "vinylshelf://section/999")
    check(hit?.shortName == printed.shortName && ShelfLabel.labels(for: lbq).first { $0.location.id == hit?.id }?.scanCode == "vinylshelf://section/999",
          "QR-koden på et trykt skilt følger sektionen til en anden enhed")

    // C har selv hentet samlingen fra Discogs, før den logger ind: ingen dubletter.
    let (c, curl) = try freshStore("sync-c"); defer { try? FileManager.default.removeItem(at: curl) }
    _ = try c.applyCollection(items)
    try c.applySyncDocs(Array(cloud.values))
    check(try c.loadLibrary().copies.count == 3 && c.loadLibrary().locations.count == 2, "samme Discogs-plader bliver ikke dobbelte")

    // En slettet afspilning forsvinder også på de andre enheder.
    try a.db.run("DELETE FROM plays")
    _ = try push(a)
    try b.applySyncDocs(Array(cloud.values))
    check(try b.loadPlays().isEmpty, "sletning følger med")

    // En plade, der kun findes i appen, slettes på A: den forsvinder også på B (også fra reolen).
    let local = try a.db.run("INSERT INTO copies(release_id, status, in_discogs) VALUES(950001, 'home', 0)")
    try a.move(copyID: local, to: try a.loadLibrary().locations[0].id, index: 0)
    _ = try push(a)
    try b.applySyncDocs(Array(cloud.values))
    let bHas = try b.loadLibrary().copies.count
    try a.deleteCopy(local)
    _ = try push(a)
    try b.applySyncDocs(Array(cloud.values))
    let lbAfter = try b.loadLibrary()
    let laAfter = try a.loadLibrary()
    check(bHas == 4 && lbAfter.copies.count == 3 && order(lbAfter) == order(laAfter), "slettet plade forsvinder også på den anden enhed")

    // En afspilning af en plade, som enheden ikke kender, huskes ikke som synkroniseret, så den ikke slettes i skyen.
    try b.applySyncDocs([SyncDoc(kind: .play, key: "ukendt-afspilning", data: ["copy": .string("findes-ikke"), "at": .double(1)])])
    check(!(try b.pendingSyncDocs()).contains { $0.key == "ukendt-afspilning" }, "en post, der ikke kunne lægges ind, slettes ikke i skyen")
} catch { check(false, "synkronisering: \(error)") }

// MARK: Sanglister (søg på en sang)
do {
    let json = #"{"id":1,"tracklist":[{"position":"","type_":"heading","title":"Side 1"},{"position":"A1","type_":"track","title":"Shine On You Crazy Diamond (Parts I-V)","duration":"13:30"},{"position":"A2","type_":"track","title":"Welcome To The Machine","duration":""},{"position":"","type_":"index","title":"Suite","sub_tracks":[{"position":"B1a","type_":"track","title":"Have A Cigar"},{"position":"B1b","type_":"track","title":"Wish You Were Here"}]}]}"#
    let tracks = try DiscogsClient.parseTracklist(Data(json.utf8))
    check(tracks.map(\.position) == ["A1", "A2", "B1a", "B1b"] && tracks[0].duration == "13:30" && tracks[1].duration == nil,
          "sanglisten læses: overskrifter springes over, delte numre giver delene: \(tracks.map(\.position))")
    check((try? DiscogsClient.parseTracklist(Data("{}".utf8)))?.isEmpty == true, "udgivelse uden sangliste giver en tom liste")

    let (s, url) = try freshStore("tracks"); defer { try? FileManager.default.removeItem(at: url) }
    _ = try s.applyCollection([
        DiscogsCollectionItem(instanceID: 7_000_001, dateAdded: nil, release: Release(id: 970_001, artist: "Pink Floyd", title: "Wish You Were Here", format: "Vinyl, LP")),
        DiscogsCollectionItem(instanceID: 7_000_002, dateAdded: nil, release: Release(id: 970_002, artist: "Pink Floyd", title: "Animals", format: "Vinyl, LP")),
        DiscogsCollectionItem(instanceID: 7_000_003, dateAdded: nil, release: Release(id: 970_003, artist: "The Beatles", title: "Help!", format: "Vinyl, LP")),
    ])
    let p0 = try s.trackProgress(), missing0 = try s.releasesWithoutTracks()
    check(s.db.userVersion >= 7 && p0 == (0, 3) && missing0 == [970_001, 970_002, 970_003],
          "ny database har tabellen til sanglister, og intet er hentet endnu")
    try s.saveTracks(releaseID: 970_002, [Track(position: "A1", title: "Pigs On The Wing (Part One)"), Track(position: "B1", title: "Dogs")])
    try s.saveTracks(releaseID: 970_003, [Track(position: "A1", title: "Help!"), Track(position: "B7", title: "Yesterday")])
    try s.saveTracks(releaseID: 970_001, [])
    let p1 = try s.trackProgress(), missing1 = try s.releasesWithoutTracks()
    check(p1 == (3, 3) && missing1.isEmpty, "hentede (også tomme) lister tælles som hentet")
    let lib = try s.loadLibrary()
    let index = SearchIndex(library: lib)
    func first(_ q: String) -> (title: String?, track: String?) {
        guard let h = index.hits(q).first else { return (nil, nil) }
        return (lib.item(h.id)?.title, h.track?.title)
    }
    check(first("dogs") == ("Animals", "Dogs"), "en sang findes, og sangen vises: \(first("dogs"))")
    check(first("floyd dogs") == ("Animals", "Dogs"), "kunstner + sang: \(first("floyd dogs"))")
    check(first("yesturday") == ("Help!", "Yesterday"), "sang med stavefejl: \(first("yesturday"))")
    check(first("help") == ("Help!", nil), "pladens egen titel vinder over en sang med samme navn: \(first("help"))")
    check(first("wish you were here").track == nil, "pladen selv vises uden sang, når det er albummet")
    check(index.search("dogs") == index.hits("dogs").map(\.id), "search og hits giver samme plader")

    // Albummer før sange: "blue" giver Joni Mitchell – Blue øverst, derefter Kind Of Blue, og først så sangene.
    let (bs, burl2) = try freshStore("tracks-blue"); defer { try? FileManager.default.removeItem(at: burl2) }
    func rel(_ i: Int, _ artist: String, _ title: String) -> DiscogsCollectionItem {
        DiscogsCollectionItem(instanceID: 7_100_000 + i, dateAdded: nil, release: Release(id: 971_000 + i, artist: artist, title: title, format: "Vinyl, LP"))
    }
    _ = try bs.applyCollection([rel(1, "Abba", "Arrival"), rel(2, "Miles Davis", "Kind Of Blue"), rel(3, "Joni Mitchell", "Blue"),
                                rel(4, "Elvis Presley", "Elvis"), rel(5, "Bill Evans", "Portrait In Jazz")])
    try bs.saveTracks(releaseID: 971_002, [Track(position: "A1", title: "So What"), Track(position: "B1", title: "Blue In Green")])
    try bs.saveTracks(releaseID: 971_003, [Track(position: "A1", title: "All I Want"), Track(position: "B1", title: "Blue")])
    try bs.saveTracks(releaseID: 971_004, [Track(position: "A1", title: "Blue Suede Shoes"), Track(position: "B1", title: "Blue Moon")])
    try bs.saveTracks(releaseID: 971_005, [Track(position: "A1", title: "Blue In Green")])
    let blib = try bs.loadLibrary()
    let blue = SearchIndex(library: blib).hits("blue").map { (blib.item($0.id)!.title, $0.track?.title) }
    check(blue.first?.0 == "Blue" && blue.first?.1 == nil && blue.dropFirst().first?.0 == "Kind Of Blue" && blue.dropFirst().first?.1 == nil
          && blue.dropFirst(2).allSatisfy { $0.1 != nil },
          "albummer før sange, og et album med præcis den titel øverst: \(blue)")

    // Søgereglerne (samme checks på Windows): faste tilfælde fra testene af den nye søgning.
    let (rs, rurl) = try freshStore("search-rules"); defer { try? FileManager.default.removeItem(at: rurl) }
    func r2(_ i: Int, _ artist: String, _ title: String, cat: String? = nil, year: Int? = nil) -> DiscogsCollectionItem {
        DiscogsCollectionItem(instanceID: 7_200_000 + i, dateAdded: nil, release: Release(id: 972_000 + i, artist: artist, title: title, year: year,
                                                                                           catalogNumber: cat, format: "Vinyl, LP"))
    }
    _ = try rs.applyCollection([r2(1, "The Beatles", "Please Please Me"), r2(2, "The Beatles", "Beatles For Sale"),
                                r2(3, "Led Zeppelin", "Led Zeppelin II"), r2(4, "AC/DC", "Back In Black", cat: "K 50735"),
                                r2(5, "Amy Winehouse", "Back To Black"), r2(6, "Prince", "1999", year: 1982),
                                r2(7, "Bryan Adams", "Reckless", year: 1999), r2(8, "Elvis Costello", "This Year's Model", cat: "RAD 3"),
                                r2(9, "Radiohead", "OK Computer")])
    try rs.saveTracks(releaseID: 972_007, [Track(position: "A1", title: "Summer Of '69")])
    let rlib = try rs.loadLibrary(), ridx = SearchIndex(library: rlib)
    func top(_ q: String) -> [String] { ridx.hits(q).map { h in rlib.item(h.id)!.title + (h.track.map { " ♪ " + $0.title } ?? "") } }
    let ruleCases: [(String, [String])] = [
        ("rad", ["OK Computer"]), ("1999", ["1999"]), ("back i", ["Back In Black"]), ("led zeppelin 2", ["Led Zeppelin II"]),
        ("acdc", ["Back In Black"]), ("okcomputer", ["OK Computer"]), ("k50735", ["Back In Black"]), ("summer of 69", ["Reckless ♪ Summer Of '69"]),
        ("beatles", ["Please Please Me", "Beatles For Sale"]), ("beetles", ["Please Please Me", "Beatles For Sale"]), ("zepelin", ["Led Zeppelin II"]),
    ]
    for (q, want) in ruleCases {
        check(Array(top(q).prefix(want.count)) == want, "søgning \"\(q)\" giver \(want): \(top(q).prefix(3))")
    }
    check(top("the zzzzzz").isEmpty && top("!!!").isEmpty, "en artikel alene (eller tegn) giver ingen resultater")

    // Sanglisten følger med til en anden enhed – og en enhed uden liste sletter den ikke.
    let docs = try s.exportSyncDocs()
    let animals = docs.first { $0.kind == .release && $0.key == "970002" }
    check(animals?.data?["tracks"]?.array?.count == 2, "sanglisten er med i udgivelsens post")
    let (b, burl) = try freshStore("tracks-b"); defer { try? FileManager.default.removeItem(at: burl) }
    try b.applySyncDocs(docs)
    check(try b.loadLibrary().releases[970_002]?.tracks.map(\.title) == ["Pigs On The Wing (Part One)", "Dogs"] && (try b.pendingSyncDocs()).isEmpty,
          "en anden enhed får sanglisten og sender intet tilbage")
    var noTracks = animals!.data!; noTracks["tracks"] = nil; noTracks["title"] = .string("Animals (2018 Remix)")
    try b.applySyncDocs([SyncDoc(kind: .release, key: "970002", data: noTracks)])
    let afterOld = try b.loadLibrary().releases[970_002]
    check(afterOld?.title == "Animals (2018 Remix)" && afterOld?.tracks.count == 2, "en post uden sangliste (ældre app) sletter ikke listen")
} catch { check(false, "sanglister: \(error)") }

// MARK: Kontoen i skyen (falsk Supabase, uden net)
/// Svarer som Supabase: login med koden 123456, og en tabel med poster, hvor serveren sætter updated_at.
final class StubCloud: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var rows: [String: [String: Any]] = [:]
    nonisolated(unsafe) static var tick = 0
    nonisolated(unsafe) static var requests: [String] = []
    /// Totrinslogin: kontoens kode-apps (som Supabases `factors`).
    nonisolated(unsafe) static var factors: [[String: Any]] = []
    static let lock = NSLock()
    static func reset() { lock.lock(); rows = [:]; tick = 0; requests = []; factors = []; lock.unlock() }
    /// Et login med koden skrevet ("aal2"): en JWT, appen kan læse.
    static let aal2Token = "x." + Data(#"{"sub":"00000000-0000-0000-0000-000000000001","aal":"aal2","exp":2000000000}"#.utf8).base64EncodedString()
        .replacingOccurrences(of: "=", with: "").replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_") + ".y"
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    private func body() -> Data? {
        if let b = request.httpBody { return b }
        guard let s = request.httpBodyStream else { return nil }
        s.open(); defer { s.close() }
        var data = Data(); var buf = [UInt8](repeating: 0, count: 65536)
        while s.hasBytesAvailable { let n = s.read(&buf, maxLength: buf.count); if n <= 0 { break }; data.append(buf, count: n) }
        return data
    }
    override func startLoading() {
        let url = request.url!, path = url.path
        let q = Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        let json = body().flatMap { try? JSONSerialization.jsonObject(with: $0) }
        var status = 200, out: Any = [String: Any]()
        Self.lock.lock()
        Self.requests.append("\(request.httpMethod ?? "") \(path)")
        let session: [String: Any] = ["access_token": "adgang", "refresh_token": "forny", "expires_in": 3600,
                                      "user": ["id": "00000000-0000-0000-0000-000000000001", "email": "test@example.com"]]
        switch (request.httpMethod ?? "", path) {
        case ("POST", "/auth/v1/otp"): out = [String: Any]()
        case ("POST", "/auth/v1/verify"):
            let j = json as? [String: Any]
            if (j?["token"] as? String) == "123456" || (j?["token_hash"] as? String) == "pkce_hash1" { out = session }
            else { status = 403; out = ["code": 403, "error_code": "otp_expired", "msg": "Token has expired or is invalid"] }
        case ("POST", "/auth/v1/token") where q["grant_type"] == "password":
            let j = json as? [String: Any]
            if (j?["email"] as? String) == "test@example.com" && (j?["password"] as? String) == "hemmelig-kode" { out = session }
            else { status = 400; out = ["code": 400, "error_code": "invalid_credentials", "msg": "Invalid login credentials"] }
        case ("POST", "/auth/v1/token"): out = session
        case ("PUT", "/auth/v1/user"):
            if request.value(forHTTPHeaderField: "Authorization") != "Bearer adgang" { status = 401; out = ["code": 401]; break }
            out = ["id": "00000000-0000-0000-0000-000000000001", "email": "test@example.com"]
        case ("GET", "/auth/v1/user"):
            out = ["id": "00000000-0000-0000-0000-000000000001", "email": "test@example.com", "factors": Self.factors]
        case ("POST", "/auth/v1/factors"):
            let id = "f\(Self.factors.count + Self.tick + 1)"
            Self.tick += 1
            Self.factors.append(["id": id, "factor_type": "totp", "status": "unverified"])
            out = ["id": id, "type": "totp", "totp": ["qr_code": "data:image/svg+xml;utf-8,<svg/>", "secret": "JBSWY3DPEHPK3PXP",
                                                      "uri": "otpauth://totp/Vinyl%20Shelf:test@example.com?secret=JBSWY3DPEHPK3PXP&issuer=Vinyl%20Shelf"]]
        case ("DELETE", _) where path.hasPrefix("/auth/v1/factors/"):
            let id = String(path.dropFirst("/auth/v1/factors/".count))
            let verified = Self.factors.contains { $0["id"] as? String == id && $0["status"] as? String == "verified" }
            if verified && request.value(forHTTPHeaderField: "Authorization") != "Bearer \(Self.aal2Token)" {
                status = 403; out = ["code": 403, "error_code": "insufficient_aal"]; break
            }
            Self.factors.removeAll { $0["id"] as? String == id }
        case ("POST", _) where path.hasPrefix("/auth/v1/factors/") && path.hasSuffix("/challenge"):
            out = ["id": "c1", "type": "totp", "expires_at": 2000000000]
        case ("POST", _) where path.hasPrefix("/auth/v1/factors/") && path.hasSuffix("/verify"):
            let id = path.dropFirst("/auth/v1/factors/".count).dropLast("/verify".count)
            let j = json as? [String: Any]
            guard (j?["challenge_id"] as? String) == "c1", (j?["code"] as? String) == "123456",
                  let i = Self.factors.firstIndex(where: { $0["id"] as? String == String(id) }) else {
                status = 422; out = ["code": 422, "error_code": "mfa_verification_failed", "msg": "Invalid TOTP code entered"]; break
            }
            Self.factors[i]["status"] = "verified"
            var s2 = session
            s2["access_token"] = Self.aal2Token
            out = s2
        case ("GET", "/rest/v1/sync_records"):
            if request.value(forHTTPHeaderField: "Authorization") != "Bearer adgang" { status = 401; out = ["code": "PGRST301"]; break }
            let from = (q["updated_at"] ?? "").replacingOccurrences(of: "gte.", with: "")
            var list = Self.rows.values.filter { from.isEmpty || ($0["updated_at"] as! String) >= from }
            list.sort { ($0["updated_at"] as! String) < ($1["updated_at"] as! String) }
            let offset = Int(q["offset"] ?? "0") ?? 0, limit = Int(q["limit"] ?? "1000") ?? 1000
            out = Array(list.dropFirst(offset).prefix(limit))
        case ("POST", "/rest/v1/sync_records"):
            for var r in (json as? [[String: Any]]) ?? [] {
                Self.tick += 1
                r["updated_at"] = String(format: "2026-10-18T12:%02d:%02d.123456+00:00", Self.tick / 60, Self.tick % 60)
                Self.rows["\(r["kind"]!)|\(r["key"]!)"] = r
            }
            status = 201
        default: status = 404
        }
        Self.lock.unlock()
        let resp = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: (try? JSONSerialization.data(withJSONObject: out)) ?? Data())
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

/// Kører async kode på hovedtråden færdig (synkroniseringen hører til hovedtråden ligesom databasen).
@MainActor func onMain<T>(_ op: @escaping @MainActor () async throws -> T) -> Result<T, Error> {
    var result: Result<T, Error>?
    Task { @MainActor in do { result = .success(try await op()) } catch { result = .failure(error) } }
    while result == nil { _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
    return result!
}

do { try MainActor.assumeIsolated {
    StubCloud.reset()
    let cfg = URLSessionConfiguration.ephemeral
    cfg.protocolClasses = [StubCloud.self]
    let cloud = CloudClient(base: URL(string: "https://stub.supabase.co")!, key: "sb_publishable_test", session: URLSession(configuration: cfg))

    check(CloudClient.date("2026-10-18T15:01:02.123456+00:00") != nil && CloudClient.date("2026-10-18T15:01:02+00:00") != nil,
          "serverens tidsstempler læses (også med mikrosekunder)")
    check(errorText(onMain { try await cloud.requestCode(email: "test@example.com") }) == nil, "kode sendes")
    check(errorText(onMain { try await cloud.verify(email: "test@example.com", code: "000000") }) == "Koden er forkert eller udløbet. Bed om en ny kode.",
          "forkert kode giver en dansk besked")
    guard case .success(let session) = onMain({ try await cloud.verify(email: "test@example.com", code: "123456") }) else {
        throw CloudError("login fejlede i testen")
    }
    check(session.userID.hasSuffix("1") && session.accessToken == "adgang" && !session.isExpired, "rigtig kode giver et login")

    func it(_ i: Int, _ artist: String, _ title: String) -> DiscogsCollectionItem {
        DiscogsCollectionItem(instanceID: 960_000 + i, dateAdded: nil, release: Release(id: 960_000 + i, artist: artist, title: title, format: "Vinyl, LP"))
    }
    let (mac, murl) = try freshStore("cloud-mac"); defer { try? FileManager.default.removeItem(at: murl) }
    _ = try mac.applyCollection([it(1, "ABBA", "Arrival"), it(2, "Bowie", "Low")])
    try mac.createLayout([(shelf: 1, section: "A", copies: SortRules().sorted(try mac.loadLibrary().allItems).map(\.id))])
    let up = onMain { try await CloudSync.run(store: mac, client: cloud, session: session, device: "mac") }
    check((try? up.get())?.sent ?? 0 > 0 && StubCloud.rows.count > 0, "første synkronisering sender systemet op: \(String(describing: try? up.get()))")
    let again = onMain { try await CloudSync.run(store: mac, client: cloud, session: session, device: "mac") }
    check((try? again.get()) == CloudSync.Report(received: 0, sent: 0), "intet nyt: intet sendes eller hentes: \(String(describing: try? again.get()))")

    let (phone, purl) = try freshStore("cloud-phone"); defer { try? FileManager.default.removeItem(at: purl) }
    let down = onMain { try await CloudSync.run(store: phone, client: cloud, session: session, device: "iphone") }
    let pl = try phone.loadLibrary()
    check((try? down.get())?.received ?? 0 > 0 && pl.locations.count == 1 && pl.sections.values.first?.count == 2,
          "en ny enhed henter reolen fra kontoen")

    // Begge har egne reoler første gang: brugeren skal vælge.
    let (win, wurl) = try freshStore("cloud-win"); defer { try? FileManager.default.removeItem(at: wurl) }
    _ = try win.applyCollection([it(1, "ABBA", "Arrival"), it(2, "Bowie", "Low")])
    try win.createLayout([(shelf: 9, section: "Z", copies: try win.loadLibrary().allItems.map(\.id))])
    let choice = onMain { try await CloudSync.run(store: win, client: cloud, session: session, device: "windows") }
    var asked = false
    if case .failure(let e) = choice, e is CloudSync.NeedsChoice { asked = true }
    check(asked, "konto og enhed har hver deres reoler: brugeren spørges")
    var safetyCopies = 0
    _ = onMain { try await CloudSync.run(store: win, client: cloud, session: session, device: "windows", firstSync: .useCloud,
                                         safetyCopy: { safetyCopies += 1 }) }
    let wl = try win.loadLibrary()
    check(wl.locations.count == 1 && wl.locations[0].shelf == 1 && wl.copies.count == 2, "\"Brug kontoens reoler\" erstatter enhedens reoler, plader bevares")
    check(safetyCopies == 1, "der tages en sikkerhedskopi, før enhedens reoler erstattes")

    // En sektion slettet på Mac'en: telefonen tager en sikkerhedskopi, før den slettes der.
    let extra = try mac.db.run("INSERT INTO locations(shelf, section, sort_index, medium) VALUES(2, 'X', 5, 'vinyl')")
    _ = onMain { try await CloudSync.run(store: mac, client: cloud, session: session, device: "mac") }
    _ = onMain { try await CloudSync.run(store: phone, client: cloud, session: session, device: "iphone") }
    let phoneHad = try phone.loadLibrary().locations.count
    try mac.deleteEmptySection(extra)
    _ = onMain { try await CloudSync.run(store: mac, client: cloud, session: session, device: "mac") }
    var phoneCopies = 0
    _ = onMain { try await CloudSync.run(store: phone, client: cloud, session: session, device: "iphone", safetyCopy: { phoneCopies += 1 }) }
    let phoneNow = try phone.loadLibrary().locations.count
    check(phoneHad == 2 && phoneNow == 1 && phoneCopies == 1,
          "slettet sektion: sikkerhedskopi først, så slettes den (\(phoneHad), \(phoneCopies))")
    var failingCopy = false
    _ = onMain { try await CloudSync.run(store: phone, client: cloud, session: session, device: "iphone", safetyCopy: { failingCopy = true }) }
    check(!failingCopy, "ingen sikkerhedskopi, når intet slettes")

    // Login fra linket i mailen (vinylshelf://auth#…). Adgangsnøglen er en JWT med bruger-ID og e-mail.
    let claims = Data(#"{"sub":"abc-123","email":"a@b.dk","exp":2000000000}"#.utf8).base64EncodedString()
        .replacingOccurrences(of: "=", with: "").replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
    let link = URL(string: "vinylshelf://auth#access_token=x.\(claims).y&refresh_token=r1&expires_in=3600&expires_at=1999999999&type=magiclink")!
    let fromLink = try CloudClient.session(fromLink: link)
    check(fromLink?.userID == "abc-123" && fromLink?.email == "a@b.dk" && fromLink?.refreshToken == "r1" && fromLink?.expiresAt == 1999999999,
          "login fra linket i mailen")
    check((try? CloudClient.session(fromLink: URL(string: "vinylshelf://section/4")!)) == .some(nil), "en QR-adresse er ikke et login")
    let pastedURL = URL(string: "http://localhost:3000/#access_token=x.\(claims).y&refresh_token=r2&expires_in=3600&type=signup")!
    check((try? CloudClient.session(fromLink: pastedURL))??.refreshToken == "r2", "en indsat localhost-adresse fra browseren virker også")
    check((try? CloudClient.session(fromLink: URL(string: "https://example.com/side")!)) == .some(nil), "en almindelig webadresse er ikke et login")
    var linkError = ""
    do { _ = try CloudClient.session(fromLink: URL(string: "vinylshelf://auth#error=access_denied&error_code=otp_expired&error_description=Email+link+is+invalid+or+has+expired")!) }
    catch { linkError = error.localizedDescription }
    check(linkError == "Linket er brugt eller udløbet. Bed om en ny mail.", "udløbet link giver en dansk besked")

    // Linket fra mailen, kopieret og indsat i appen: appen bytter det selv for et login.
    let mailLink = "https://stub.supabase.co/auth/v1/verify?token=pkce_hash1&type=magiclink&redirect_to=vinylshelf://auth"
    check(CloudClient.emailLinkToken(mailLink)?.token == "pkce_hash1" && CloudClient.emailLinkToken(mailLink)?.type == "magiclink"
          && CloudClient.emailLinkToken("https://example.com/") == nil, "linket fra mailen genkendes")
    let viaLink = onMain { try await cloud.verifyEmailLink(mailLink) }
    check((try? viaLink.get())??.accessToken == "adgang", "indsat link fra mailen giver et login")
    var usedError = ""
    if case .failure(let e as CloudError) = onMain({ try await cloud.verifyEmailLink(mailLink.replacingOccurrences(of: "pkce_hash1", with: "brugt")) }) { usedError = e.message }
    check(usedError == CloudClient.usedLink.message, "brugt link fra mailen siger, at linket er brugt (ikke koden)")

    // Adgangskode: vælges, mens man er logget ind, og bruges til at logge ind på en ny enhed uden mail.
    check(errorText(onMain { try await cloud.setPassword("hemmelig-kode", session: session) }) == nil, "adgangskode kan vælges")
    check(errorText(onMain { try await cloud.setPassword("kort", session: session) }) == CloudClient.shortPassword.message, "for kort adgangskode afvises på dansk")
    guard case .success(let viaPassword) = onMain({ try await cloud.signIn(email: "test@example.com", password: "hemmelig-kode") }) else {
        throw CloudError("login med adgangskode fejlede i testen")
    }
    check(viaPassword.accessToken == "adgang" && viaPassword.email == "test@example.com", "login med e-mail og adgangskode")
    check(errorText(onMain { try await cloud.signIn(email: "test@example.com", password: "forkert-kode") }) == CloudClient.wrongPassword.message,
          "forkert adgangskode giver en dansk besked")

    // Totrinslogin (TOTP): slå til med en kode fra kode-appen, log ind med koden bagefter, og slå fra igen.
    check(CloudClient.assurance(session) == "aal1", "totrinslogin: et almindeligt login er aal1")
    check((try? onMain { try await cloud.pendingSecondFactor(session: session) }.get()) == .some(nil), "totrinslogin: uden kode-app kræves ingen kode")
    _ = onMain { try await cloud.enrollSecondFactor(session: session) }
    guard case .success(let enrol) = onMain({ try await cloud.enrollSecondFactor(session: session) }) else { throw CloudError("tilmelding fejlede i testen") }
    check(StubCloud.factors.count == 1 && enrol.groupedSecret == "JBSW Y3DP EHPK 3PXP" && enrol.uri.hasPrefix("otpauth://totp/"),
          "totrinslogin: et nyt forsøg fjerner det halvfærdige, og koden kan skrives af i grupper")
    check(errorText(onMain { try await cloud.verifySecondFactor(factorID: enrol.factorID, code: "000000", session: session) }) == CloudClient.wrongSecondFactorCode.message
          && errorText(onMain { try await cloud.verifySecondFactor(factorID: enrol.factorID, code: "12", session: session) }) == CloudClient.wrongSecondFactorCode.message,
          "totrinslogin: en forkert kode giver en dansk besked")
    guard case .success(let strong) = onMain({ try await cloud.verifySecondFactor(factorID: enrol.factorID, code: "123 456", session: session) }) else {
        throw CloudError("bekræftelse fejlede i testen")
    }
    check(CloudClient.assurance(strong) == "aal2" && strong.email == session.email, "totrinslogin: koden giver et sikrere login (aal2)")
    let pending = try? onMain { try await cloud.pendingSecondFactor(session: session) }.get()
    check(pending?.id == enrol.factorID && (try? onMain { try await cloud.pendingSecondFactor(session: strong) }.get()) == .some(nil),
          "totrinslogin: et login uden koden skal skrive den, et login med koden skal ikke")
    check(errorText(onMain { try await cloud.removeSecondFactor(factorID: enrol.factorID, session: session) }) == CloudClient.secondFactorRequired.message,
          "totrinslogin: kan ikke slås fra uden koden")
    check(errorText(onMain { try await cloud.removeSecondFactor(factorID: enrol.factorID, session: strong) }) == nil && StubCloud.factors.isEmpty,
          "totrinslogin: kan slås fra med koden")
    check(CloudClient.error(status: 403, data: Data(#"{"code":"42501","message":"new row violates row-level security policy"}"#.utf8)).needsSecondFactor,
          "totrinslogin: en afvist post betyder, at koden mangler")
    let denied = CloudClient.error(status: 403, data: Data(#"{"code":"42501","message":"permission denied for table mfa_factors"}"#.utf8))
    check(!denied.needsSecondFactor && denied.message == CloudClient.databaseDenied.message,
          "totrinslogin: \"permission denied\" er en regel i databasen, ikke den manglende kode")

    // Udløbet login.
    let bad = CloudSession(accessToken: "forkert", refreshToken: "x", expiresAt: 0, userID: session.userID, email: session.email)
    var needsLogin = false
    if case .failure(let e as CloudError) = onMain({ try await cloud.fetch(since: nil, session: bad) }) { needsLogin = e.needsLogin }
    check(needsLogin, "afvist login: brugeren bedes logge ind igen")
} } catch { check(false, "kontoen i skyen: \(error)") }

// MARK: Opdatering fra GitHub Releases (uden net)
do {
    check(AppVersion("v1.2.3")! > AppVersion("1.2")! && AppVersion("1.10")! > AppVersion("1.9")!
          && AppVersion("1.0")! == AppVersion("1.0.0")!, "versioner sammenlignes tal for tal")
    check(AppVersion("v2.0.0-beta.1")?.description == "2.0.0" && AppVersion("abc") == nil && AppVersion("") == nil
          && AppVersion("1..2") == nil, "versionstekst renses, og affald afvises")
    let json = #"{"tag_name":"v1.1.0","html_url":"https://github.com/Agg3mam/vinyl-shelf-finder/releases/tag/v1.1.0","draft":false,"prerelease":false,"body":"Cd'er får deres egen hylde.\r\n","assets":[{"name":"VinylShelfFinder-Windows-x64.zip","size":66000000,"browser_download_url":"https://github.com/Agg3mam/vinyl-shelf-finder/releases/download/v1.1.0/VinylShelfFinder-Windows-x64.zip"},{"name":"VinylShelfFinder-macOS.zip","size":9000000,"browser_download_url":"https://github.com/Agg3mam/vinyl-shelf-finder/releases/download/v1.1.0/VinylShelfFinder-macOS.zip"}]}"#
    let r = AppUpdate.parseLatest(Data(json.utf8))
    check(r?.version.description == "1.1.0" && r?.downloadURL.lastPathComponent == "VinylShelfFinder-macOS.zip"
          && r?.notes == "Cd'er får deres egen hylde.", "udgivelse læses: version, Mac-zip og tekst")
    check(AppUpdate.parseLatest(Data(json.utf8), assetName: "VinylShelfFinder-Windows-x64.zip")?.size == 66000000, "Windows-zippen findes også")
    check(r.map { AppUpdate.isNewer($0, than: "1.0.0") } == true && r.map { AppUpdate.isNewer($0, than: "1.1") } == false
          && r.map { AppUpdate.isNewer($0, than: "2.0") } == false, "kun nyere versioner tilbydes")
    let pre = json.replacingOccurrences(of: #""prerelease":false"#, with: #""prerelease":true"#)
    check(AppUpdate.parseLatest(Data(pre.utf8)) == nil, "prøveudgaver tilbydes ikke")
    let noMac = json.replacingOccurrences(of: "VinylShelfFinder-macOS.zip", with: "andet.zip")
    check(AppUpdate.parseLatest(Data(noMac.utf8)) == nil, "udgave uden Mac-zip springes over")
    let evil = json.replacingOccurrences(of: "https://github.com/Agg3mam/vinyl-shelf-finder/releases/download/v1.1.0/VinylShelfFinder-macOS.zip",
                                         with: "https://example.com/VinylShelfFinder-macOS.zip")
    check(AppUpdate.parseLatest(Data(evil.utf8)) == nil, "kun filer fra GitHub")
    check(AppUpdate.isTrustedHost("objects.githubusercontent.com") && !AppUpdate.isTrustedHost("github.com.example.com")
          && !AppUpdate.isTrustedHost(nil), "GitHubs downloadadresser")
    check(AppUpdate.parseLatest(Data("ikke json".utf8)) == nil, "affald giver ingen opdatering")
    let now = Date()
    check(AppUpdate.isCheckDue(last: nil, now: now) && !AppUpdate.isCheckDue(last: now.addingTimeInterval(-3600), now: now)
          && AppUpdate.isCheckDue(last: now.addingTimeInterval(-25 * 3600), now: now), "højst ét tjek pr. døgn")
}

print(failures == 0 ? "✓ Alle \(passes) checks bestået" : "✗ \(failures) fejl, \(passes) bestået")
exit(failures == 0 ? 0 : 1)
