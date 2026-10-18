import Foundation

// Synkronisering mellem enheder (Mac, Windows, iPhone) via en konto i skyen (se supabase/schema.sql).
// Port: windows/src/VinylCore/SyncDocs.cs. Felterne i `data` skal være ens på alle platforme.
//
// Appen sammenligner ved hver synkronisering sine data med det, der sidst blev synkroniseret
// (tabellen `sync_state`). Kun det ændrede sendes op. Poster fra skyen lægges ind i den lokale
// database. Ved samtidig ændring af samme post vinder den, der allerede ligger i skyen.

/// En JSON-værdi (til posternes `data`).
public enum JSONValue: Codable, Equatable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let i = try? c.decode(Int64.self) { self = .int(i) }
        else if let d = try? c.decode(Double.self) { self = .double(d) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .int(let i): try c.encode(i)
        case .double(let d): try c.encode(d)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    public var string: String? { if case .string(let s) = self { return s }; return nil }
    public var int: Int64? {
        switch self {
        case .int(let i): return i
        case .double(let d) where d == d.rounded(): return Int64(d)
        default: return nil
        }
    }
    public var double: Double? {
        switch self {
        case .double(let d): return d
        case .int(let i): return Double(i)
        default: return nil
        }
    }
    public var bool: Bool? { if case .bool(let b) = self { return b }; return nil }
    public var array: [JSONValue]? { if case .array(let a) = self { return a }; return nil }

    static func from(_ v: SQLValue?) -> JSONValue {
        switch v {
        case .int(let i)?: return .int(i)
        case .double(let d)?: return .double(d)
        case .text(let s)?: return .string(s)
        default: return .null
        }
    }
}

/// Én post: én ting fra den lokale database. `data == nil` betyder slettet.
public struct SyncDoc: Equatable {
    public enum Kind: String, CaseIterable { case release, copy, location, section, play, setting }

    public let kind: Kind
    public let key: String
    public let data: [String: JSONValue]?

    public init(kind: Kind, key: String, data: [String: JSONValue]?) {
        self.kind = kind; self.key = key; self.data = data
    }

    /// Fast JSON-tekst (sorterede nøgler), så to ens poster altid giver samme tekst.
    public var canonical: String? {
        guard let data else { return nil }
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? enc.encode(data)).flatMap { String(data: $0, encoding: .utf8) }
    }

    static func decode(_ json: String) -> [String: JSONValue]? {
        try? JSONDecoder().decode([String: JSONValue].self, from: Data(json.utf8))
    }
}

extension ShelfStore {
    /// Indstillinger, der følger kontoen. Valg, der hører til den enkelte enhed (fx viste hylde og valuta), synkroniseres ikke.
    static let syncedSettings = ["sort_rules", "neighbor_count", "surname_not_persons"]

    // MARK: Fælles ID'er

    /// Giver alle kopier, reoler og afspilninger et fælles ID. Plader fra Discogs bruger Discogs' kopinummer.
    public func ensureSyncIDs() throws {
        try db.transaction {
            try db.run("UPDATE copies SET uid = 'i' || discogs_instance_id WHERE uid IS NULL AND discogs_instance_id IS NOT NULL")
            for table in ["copies", "locations", "plays"] {
                for r in try db.query("SELECT id FROM \(table) WHERE uid IS NULL") {
                    try db.run("UPDATE \(table) SET uid = ? WHERE id = ?", UUID().uuidString.lowercased(), r["id"]!.int!)
                }
            }
        }
    }

    // MARK: Lokale data som poster

    /// Hele det lokale system som poster.
    public func exportSyncDocs() throws -> [SyncDoc] {
        try ensureSyncIDs()
        var docs: [SyncDoc] = []

        for r in try db.query("SELECT * FROM releases") {
            docs.append(SyncDoc(kind: .release, key: String(r["discogs_release_id"]!.int!), data: [
                "artist": .from(r["artist"]), "title": .from(r["title"]), "year": .from(r["year"]),
                "label": .from(r["label"]), "catalog": .from(r["catalog_number"]), "format": .from(r["format"]),
                "cover": .from(r["cover_url"]), "thumb": .from(r["thumb_url"]), "genres": .from(r["genres"]),
            ]))
        }

        var uidOfCopy: [Int64: String] = [:]
        for r in try db.query("SELECT * FROM copies") {
            let uid = r["uid"]!.text!
            uidOfCopy[r["id"]!.int!] = uid
            docs.append(SyncDoc(kind: .copy, key: uid, data: [
                "instance": .from(r["discogs_instance_id"]), "release": .from(r["release_id"]),
                "status": .from(r["status"]), "note": .from(r["status_note"]),
                "inDiscogs": .bool((r["in_discogs"]?.int ?? 1) != 0), "removedAt": .from(r["removed_from_discogs_at"]),
                "sortArtist": .from(r["sort_artist_override"]), "sortTitle": .from(r["sort_title_override"]),
                "dateAdded": .from(r["date_added"]), "rank": .from(r["discogs_rank"]), "medium": .from(r["medium_override"]),
            ]))
        }

        var uidOfLocation: [Int64: String] = [:]
        for r in try db.query("SELECT * FROM locations") {
            let uid = r["uid"]!.text!
            uidOfLocation[r["id"]!.int!] = uid
            docs.append(SyncDoc(kind: .location, key: uid, data: [
                "shelf": .from(r["shelf"]), "section": .from(r["section"]), "sortIndex": .from(r["sort_index"]),
                "medium": .from(r["medium"]),
            ]))
        }

        var sections: [Int64: [String]] = [:]
        for r in try db.query("SELECT copy_id, location_id FROM placements ORDER BY location_id, position") {
            guard let c = uidOfCopy[r["copy_id"]!.int!] else { continue }
            sections[r["location_id"]!.int!, default: []].append(c)
        }
        for (locID, uid) in uidOfLocation {
            docs.append(SyncDoc(kind: .section, key: uid, data: ["copies": .array((sections[locID] ?? []).map { .string($0) })]))
        }

        for r in try db.query("SELECT uid, copy_id, played_at FROM plays") {
            guard let c = uidOfCopy[r["copy_id"]!.int!] else { continue }
            docs.append(SyncDoc(kind: .play, key: r["uid"]!.text!, data: ["copy": .string(c), "at": .from(r["played_at"])]))
        }

        for key in Self.syncedSettings {
            if let v = setting(key) { docs.append(SyncDoc(kind: .setting, key: key, data: ["value": .string(v)])) }
        }
        var overrides: [String: JSONValue] = [:]
        for r in try db.query("SELECT artist, sort_name FROM artist_sort_overrides") {
            if let a = r["artist"]?.text, let n = r["sort_name"]?.text { overrides[a] = .string(n) }
        }
        docs.append(SyncDoc(kind: .setting, key: "artist_overrides", data: ["value": .object(overrides)]))
        for m in Medium.allCases {
            let uids = sortChecked(m).compactMap { uidOfCopy[$0] }.sorted()
            docs.append(SyncDoc(kind: .setting, key: "sort_checked_\(m.rawValue)", data: ["value": .array(uids.map { .string($0) })]))
        }
        return docs
    }

    // MARK: Hvad er ændret siden sidst

    /// Poster, der er ændret, nye eller slettet siden sidste synkronisering.
    public func pendingSyncDocs() throws -> [SyncDoc] {
        let current = try exportSyncDocs()
        var state: [String: String?] = [:]
        for r in try db.query("SELECT kind, key, data FROM sync_state") {
            state["\(r["kind"]!.text!)|\(r["key"]!.text!)"] = r["data"]?.text
        }
        var pending: [SyncDoc] = []
        var seen = Set<String>()
        for d in current {
            let id = "\(d.kind.rawValue)|\(d.key)"
            seen.insert(id)
            if state[id] ?? nil != d.canonical { pending.append(d) }
        }
        for (id, data) in state where data != nil && !seen.contains(id) {
            let parts = id.split(separator: "|", maxSplits: 1).map(String.init)
            if let kind = SyncDoc.Kind(rawValue: parts[0]) { pending.append(SyncDoc(kind: kind, key: parts[1], data: nil)) }
        }
        return pending
    }

    /// Husker, at posterne nu er ens lokalt og i skyen.
    public func markSynced(_ docs: [SyncDoc]) throws {
        try db.transaction {
            for d in docs {
                try db.run("INSERT INTO sync_state(kind, key, data) VALUES(?, ?, ?) ON CONFLICT(kind, key) DO UPDATE SET data = excluded.data",
                           d.kind.rawValue, d.key, d.canonical)
            }
        }
    }

    // MARK: Poster fra skyen ind i den lokale database

    /// Lægger poster fra skyen ind. Rækkefølgen sikrer, at pladen findes, før den placeres.
    /// Returnerer antallet af ændrede poster.
    @discardableResult
    public func applySyncDocs(_ remote: [SyncDoc]) throws -> Int {
        try ensureSyncIDs()
        var stateData: [String: String] = [:]
        for r in try db.query("SELECT kind, key, data FROM sync_state") {
            if let d = r["data"]?.text { stateData["\(r["kind"]!.text!)|\(r["key"]!.text!)"] = d }
        }
        // Egne ændringer, der kommer tilbage fra skyen, springes over.
        let fresh = remote.filter { stateData["\($0.kind.rawValue)|\($0.key)"] != $0.canonical }
        let order: [SyncDoc.Kind] = [.release, .copy, .location, .section, .play, .setting]
        try db.transaction {
            for kind in order {
                for d in fresh where d.kind == kind { try apply(d) }
            }
            // Slettede reoler fjernes til sidst, når deres plader er flyttet.
            for d in fresh where d.kind == .location && d.data == nil {
                if let id = try localID("locations", uid: d.key) {
                    try db.run("DELETE FROM placements WHERE location_id = ?", id)
                    try db.run("DELETE FROM locations WHERE id = ?", id)
                }
            }
        }
        try markSynced(remote)
        return fresh.count
    }

    private func localID(_ table: String, uid: String) throws -> Int64? {
        try db.query("SELECT id FROM \(table) WHERE uid = ?", uid).first?["id"]?.int
    }

    private func copyID(uid: String) throws -> Int64? {
        if let id = try localID("copies", uid: uid) { return id }
        // En kopi fra Discogs, som denne enhed kender, men endnu uden fælles ID.
        if uid.hasPrefix("i"), let inst = Int64(uid.dropFirst()) {
            return try db.query("SELECT id FROM copies WHERE discogs_instance_id = ?", inst).first?["id"]?.int
        }
        return nil
    }

    private func apply(_ d: SyncDoc) throws {
        let v = d.data ?? [:]
        func text(_ k: String) -> String? { v[k]?.string }
        func int(_ k: String) -> Int64? { v[k]?.int }
        func dbl(_ k: String) -> Double? { v[k]?.double }
        switch d.kind {
        case .release:
            guard d.data != nil, let id = Int64(d.key) else { return }
            try db.run("""
                INSERT INTO releases(discogs_release_id, artist, title, year, label, catalog_number, format, cover_url, thumb_url, genres, updated_at)
                VALUES(?,?,?,?,?,?,?,?,?,?,?)
                ON CONFLICT(discogs_release_id) DO UPDATE SET artist = excluded.artist, title = excluded.title, year = excluded.year,
                    label = excluded.label, catalog_number = excluded.catalog_number, format = excluded.format,
                    cover_url = excluded.cover_url, thumb_url = excluded.thumb_url, genres = excluded.genres
                """, id, text("artist") ?? "", text("title") ?? "", int("year"), text("label"), text("catalog"), text("format"),
                       text("cover"), text("thumb"), text("genres"), Date().timeIntervalSince1970)

        case .copy:
            let existing = try copyID(uid: d.key)
            guard d.data != nil else {
                if let existing { try deleteCopy(existing) }
                return
            }
            guard let release = int("release"),
                  try db.query("SELECT 1 FROM releases WHERE discogs_release_id = ?", release).first != nil else { return }
            let fields: [SQLConvertible] = [
                int("instance"), release, text("status") ?? "home", text("note"),
                (v["inDiscogs"]?.bool ?? true) ? 1 : 0, dbl("removedAt"),
                text("sortArtist"), text("sortTitle"), text("dateAdded"),
                int("rank"), text("medium"),
            ]
            if let existing {
                try db.run("""
                    UPDATE copies SET discogs_instance_id = ?, release_id = ?, status = ?, status_note = ?, in_discogs = ?,
                        removed_from_discogs_at = ?, sort_artist_override = ?, sort_title_override = ?, date_added = ?,
                        discogs_rank = ?, medium_override = ?, uid = ? WHERE id = ?
                    """, params: fields + [d.key, existing])
            } else {
                try db.run("""
                    INSERT INTO copies(discogs_instance_id, release_id, status, status_note, in_discogs, removed_from_discogs_at,
                        sort_artist_override, sort_title_override, date_added, discogs_rank, medium_override, uid, created_at)
                    VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)
                    """, params: fields + [d.key, Date().timeIntervalSince1970])
            }

        case .location:
            guard d.data != nil else { return } // slettes til sidst (se applySyncDocs)
            if let id = try localID("locations", uid: d.key) {
                try db.run("UPDATE locations SET shelf = ?, section = ?, sort_index = ?, medium = ? WHERE id = ?",
                           int("shelf") ?? 1, text("section") ?? "A", int("sortIndex") ?? 0, text("medium") ?? "vinyl", id)
            } else {
                try db.run("INSERT INTO locations(shelf, section, sort_index, medium, uid) VALUES(?, ?, ?, ?, ?)",
                           int("shelf") ?? 1, text("section") ?? "A", int("sortIndex") ?? 0, text("medium") ?? "vinyl", d.key)
            }

        case .section:
            guard let loc = try localID("locations", uid: d.key) else { return }
            let ids = try (v["copies"]?.array ?? []).compactMap { $0.string }.compactMap { try copyID(uid: $0) }
            try db.run("DELETE FROM placements WHERE location_id = ?", loc)
            for (i, id) in ids.enumerated() {
                try db.run("INSERT INTO placements(copy_id, location_id, position) VALUES(?, ?, ?) ON CONFLICT(copy_id) DO UPDATE SET location_id = excluded.location_id, position = excluded.position",
                           id, loc, i + 1)
            }

        case .play:
            let existing = try localID("plays", uid: d.key)
            guard d.data != nil else {
                if let existing { try db.run("DELETE FROM plays WHERE id = ?", existing) }
                return
            }
            guard existing == nil, let c = text("copy"), let copy = try copyID(uid: c), let at = dbl("at") else { return }
            try db.run("INSERT INTO plays(copy_id, played_at, uid) VALUES(?, ?, ?)", copy, at, d.key)

        case .setting:
            if d.key == "artist_overrides" {
                try db.run("DELETE FROM artist_sort_overrides")
                if case .object(let o)? = v["value"] {
                    for (a, n) in o { if let n = n.string { try db.run("INSERT INTO artist_sort_overrides(artist, sort_name) VALUES(?, ?)", a, n) } }
                }
            } else if d.key.hasPrefix("sort_checked_"), let m = Medium(rawValue: String(d.key.dropFirst("sort_checked_".count))) {
                let ids = try (v["value"]?.array ?? []).compactMap { $0.string }.compactMap { try copyID(uid: $0) }
                setSetting("sort_checked_\(m.rawValue)", ids.sorted().map(String.init).joined(separator: ","))
            } else if Self.syncedSettings.contains(d.key) {
                setSetting(d.key, text("value"))
            }
        }
    }
}
