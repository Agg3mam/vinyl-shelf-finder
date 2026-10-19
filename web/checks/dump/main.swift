import Foundation

// Facit til webappens checks (web/checks/checks.mjs): demo-samlingen plus de faste søgetilfælde som kontoens
// poster, Swifts top-20 for en lang række søgninger og "Find i reolen"-teksterne for hver plade.
// Køres af web/checks/run.sh (bygges sammen med Sources/VinylCore). Bruger kun eksempeldata.

let store = try ShelfStore(path: ":memory:")
try DemoData.seedIfEmpty(store)
// Nogle plader ude af reolen, så naboer og tælling over huller afprøves.
for (n, id) in try store.loadLibrary().globalOrder.enumerated() where n % 7 == 3 {
    try store.setStatus(copyID: id, n % 2 == 0 ? .lent : .wall, note: n % 2 == 0 ? "Hos en ven" : nil)
}
// De faste søgetilfælde fra VinylCoreChecks (uden plads på en reol).
func rel(_ i: Int, _ artist: String, _ title: String, cat: String? = nil, year: Int? = nil) -> DiscogsCollectionItem {
    DiscogsCollectionItem(instanceID: 7_200_000 + i, dateAdded: nil, release: Release(id: 972_000 + i, artist: artist, title: title, year: year,
                                                                                       catalogNumber: cat, format: "Vinyl, LP"))
}
_ = try store.applyCollection([rel(1, "The Beatles", "Please Please Me"), rel(2, "The Beatles", "Beatles For Sale"),
                               rel(3, "Led Zeppelin", "Led Zeppelin II"), rel(4, "AC/DC", "Back In Black", cat: "K 50735"),
                               rel(5, "Amy Winehouse", "Back To Black"), rel(6, "Prince", "1999", year: 1982),
                               rel(7, "Bryan Adams", "Reckless", year: 1999), rel(8, "Elvis Costello", "This Year's Model", cat: "RAD 3"),
                               rel(9, "Radiohead", "OK Computer"), rel(10, "Björk", "Homogenic"), rel(11, "Sigur Rós", "Ágætis byrjun"),
                               rel(12, "Kim Larsen & Kjukken", "Sange Fra Glemmebogen"), rel(13, "Tv-2", "Nærmest Lykkelig"),
                               rel(14, "Hüsker Dü", "Zen Arcade"), rel(15, "Various", "Absolute Music 1"), rel(16, "David Bowie", "★")])
try store.saveTracks(releaseID: 972_007, [Track(position: "A1", title: "Summer Of '69"), Track(position: "A2", title: "Heaven")])
try store.saveTracks(releaseID: 972_012, [Track(position: "A1", title: "Papirsklip"), Track(position: "B1", title: "Haveje")])
for id in try store.loadLibrary().globalOrder.prefix(8) {
    let r = try store.loadLibrary().item(id)!.release
    try store.saveTracks(releaseID: r.id, [Track(position: "A1", title: "Heart Of \(r.title)", duration: "3:12"), Track(position: "B1", title: "Heart")])
}

let docs = try store.exportSyncDocs()
var uid: [Int64: String] = [:]
for r in try store.db.query("SELECT id, uid FROM copies") { uid[r["id"]!.int!] = r["uid"]!.text! }

var t = 1_760_000_000.0
let enc = JSONEncoder()
let iso = ISO8601DateFormatter()
var rows: [Any] = []
for d in docs {
    t += 1
    let data = try d.data.map { try JSONSerialization.jsonObject(with: enc.encode($0)) } ?? NSNull()
    rows.append(["kind": d.kind.rawValue, "key": d.key, "data": data, "deleted": false, "updated_at": iso.string(from: Date(timeIntervalSince1970: t))])
}

// Søgninger: hele og halve navne, stavefejl, sange, katalognumre og de faste tilfælde.
var queries: [String] = ["", "!!!", "the zzzzzz", "÷", "★", "k", "t", "ab", "rad", "1999", "back i", "led zeppelin 2", "acdc", "ac dc", "AC/DC",
                         "okcomputer", "k50735", "k 50735", "summer of 69", "beatles", "beetles", "zepelin", "bjork", "björk", "sigur ros",
                         "agaetis", "kim larsen og kjukken", "naermest lykkelig", "huesker du", "absolute music i", "heart", "heaven", "papirsklip"]
func typo(_ s: String) -> [String] {
    let c = Array(s)
    guard c.count >= 4 else { return [] }
    var out = [String(c[0..<1] + c[2...])]
    var sw = c; sw.swapAt(1, 2); out.append(String(sw))
    out.append(String(c.prefix(3)))
    return out
}
var libs: [Medium: Library] = [:]
for m in Medium.allCases { libs[m] = try store.loadLibrary(medium: m) }
for m in Medium.allCases {
    for it in libs[m]!.allItems.sorted(by: { $0.id < $1.id }) {
        let r = it.release
        queries += [r.artist, r.title, "\(r.artist) \(r.title)", r.title.lowercased()] + typo(r.title.lowercased()) + typo(r.artist.lowercased())
        if let c = r.catalogNumber { queries.append(c) }
        queries += r.tracks.map(\.title)
    }
}
var seen = Set<String>()
queries = queries.filter { seen.insert($0).inserted }

var results: [Any] = []
for q in queries {
    var hits: [String] = []
    for m in Medium.allCases {
        hits += SearchIndex(library: libs[m]!).hits(q, limit: 20).map { "\(uid[$0.id]!)|\($0.track?.title ?? "")" }
    }
    results.append(["q": q, "hits": hits])
}

func ref(_ r: Library.Reference?) -> Any {
    r.map { ["side": "\($0.side)", "item": $0.item.map { uid[$0.id]! } ?? NSNull(), "reason": $0.reason] as [String: Any] } ?? NSNull()
}
func adv(_ a: Library.ReferenceAdvice?) -> Any {
    guard let a else { return NSNull() }
    return ["primary": ref(a.primary), "secondary": ref(a.secondary), "artistBlockHint": a.artistBlockHint ?? NSNull(),
            "placementHint": a.placementHint, "sectionEdgeHint": a.sectionEdgeHint ?? NSNull()] as [String: Any]
}
var advice: [String: Any] = [:]
for m in Medium.allCases {
    let lib = libs[m]!
    for id in lib.copies.keys {
        let n = lib.neighbors(of: id)
        advice[uid[id]!] = ["find": adv(lib.referenceAdvice(for: id)), "putBack": adv(lib.returnAdvice(for: id)),
                            "position": n?.position ?? NSNull(), "count": n?.sectionCount ?? 0, "medium": m.rawValue]
    }
}

let out = ["records": rows, "results": results, "advice": advice] as [String: Any]
try JSONSerialization.data(withJSONObject: out, options: [.sortedKeys]).write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
print("Swift: \(rows.count) poster, \(queries.count) søgninger, \(advice.count) plader")
