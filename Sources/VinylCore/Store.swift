import Foundation

/// Lokal SQLite-database. Holder Discogs-data (`releases`) og fysiske data
/// (`copies`, `locations`, `placements`) adskilt, så en sync aldrig rører placeringer.
public final class ShelfStore {
    public let db: SQLiteDatabase

    public static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VinylShelfFinder", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("vinyl.sqlite")
    }

    public init(path: String) throws {
        db = try SQLiteDatabase(path: path)
        try migrate()
        try keepPlacedDigitalFiles()
    }

    /// Digitale filer står ikke på en hylde. Men en fil, der allerede har en plads (fra før appen
    /// kendte forskel), bliver stående: den får den hylde, den står på, som brugerens valg. Ellers
    /// ville pladerne efter den skifte nummer ved en opdatering. Samme regel på Windows.
    func keepPlacedDigitalFiles() throws {
        let rows = try db.query("""
            SELECT c.id, r.format, l.medium FROM copies c
            JOIN placements p ON p.copy_id = c.id
            JOIN locations l ON l.id = p.location_id
            JOIN releases r ON r.discogs_release_id = c.release_id
            WHERE c.medium_override IS NULL
            """)
        for r in rows where Medium.isDigital(format: r["format"]?.text) {
            guard let id = r["id"]?.int, let m = r["medium"]?.text else { continue }
            try db.run("UPDATE copies SET medium_override = ? WHERE id = ?", m, id)
        }
    }

    // MARK: - Skema

    /// Hvert trin kører i én transaktion sammen med `user_version`, så et afbrudt trin
    /// (fx `ALTER TABLE` uden opdateret version) ikke efterlader en database, der ikke kan åbnes.
    private func migrate() throws {
        if db.userVersion < 1 {
            try db.transaction {
            try db.execute("""
            CREATE TABLE IF NOT EXISTS releases (
                discogs_release_id INTEGER PRIMARY KEY,
                artist TEXT NOT NULL,
                title TEXT NOT NULL,
                year INTEGER,
                label TEXT,
                catalog_number TEXT,
                format TEXT,
                cover_url TEXT,
                thumb_url TEXT,
                genres TEXT,
                updated_at REAL
            );
            CREATE TABLE IF NOT EXISTS copies (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                discogs_instance_id INTEGER UNIQUE,
                release_id INTEGER NOT NULL REFERENCES releases(discogs_release_id),
                status TEXT NOT NULL DEFAULT 'home',
                status_note TEXT,
                in_discogs INTEGER NOT NULL DEFAULT 1,
                removed_from_discogs_at REAL,
                sort_artist_override TEXT,
                sort_title_override TEXT,
                date_added TEXT,
                created_at REAL
            );
            CREATE TABLE IF NOT EXISTS locations (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                shelf INTEGER NOT NULL,
                section TEXT NOT NULL,
                sort_index INTEGER NOT NULL,
                scan_code TEXT UNIQUE
            );
            CREATE TABLE IF NOT EXISTS placements (
                copy_id INTEGER PRIMARY KEY REFERENCES copies(id) ON DELETE CASCADE,
                location_id INTEGER NOT NULL REFERENCES locations(id),
                position INTEGER NOT NULL
            );
            CREATE INDEX IF NOT EXISTS placements_by_location ON placements(location_id, position);
            CREATE TABLE IF NOT EXISTS artist_sort_overrides (
                artist TEXT PRIMARY KEY,
                sort_name TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS settings (
                key TEXT PRIMARY KEY,
                value TEXT
            );
            CREATE TABLE IF NOT EXISTS history (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                at REAL NOT NULL,
                copy_id INTEGER,
                kind TEXT NOT NULL,
                summary TEXT NOT NULL,
                from_location_id INTEGER,
                from_position INTEGER,
                to_location_id INTEGER,
                to_position INTEGER
            );
            -- Forberedt til fremtidig QR/barcode-scanning: kode → plade, release eller sektion.
            CREATE TABLE IF NOT EXISTS scan_codes (
                code TEXT PRIMARY KEY,
                kind TEXT NOT NULL CHECK (kind IN ('copy','release','location')),
                target_id INTEGER NOT NULL
            );
            """)
            try db.execute("PRAGMA user_version = 1")
            }
        }
        if db.userVersion < 2 {
            try db.transaction {
            try db.execute("ALTER TABLE copies ADD COLUMN discogs_rank INTEGER")
            try db.execute("PRAGMA user_version = 2")
            }
        }
        if db.userVersion < 3 {
            try db.transaction {
            try db.execute("""
            CREATE TABLE IF NOT EXISTS release_market (
                release_id INTEGER PRIMARY KEY,
                lowest_price REAL,
                currency TEXT,
                num_for_sale INTEGER,
                have INTEGER,
                want INTEGER,
                fetched_at REAL
            );
            """)
            try db.execute("PRAGMA user_version = 3")
            }
        }
        if db.userVersion < 4 {
            try db.transaction {
            try db.execute("""
            CREATE TABLE IF NOT EXISTS plays (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                copy_id INTEGER NOT NULL REFERENCES copies(id) ON DELETE CASCADE,
                played_at REAL NOT NULL
            );
            CREATE INDEX IF NOT EXISTS plays_by_copy ON plays(copy_id, played_at);
            """)
            try db.execute("PRAGMA user_version = 4")
            }
        }
        if db.userVersion < 5 {
            // Cd'er: egne reoler (`locations.medium`) og brugerens eget valg pr. kopi.
            try db.transaction {
            // Kan køres igen uden fejl (fx når en ældre user_version er sat tilbage).
            if !(try hasColumn("locations", "medium")) {
                try db.execute("ALTER TABLE locations ADD COLUMN medium TEXT NOT NULL DEFAULT 'vinyl'")
            }
            if !(try hasColumn("copies", "medium_override")) {
                try db.execute("ALTER TABLE copies ADD COLUMN medium_override TEXT")
            }
            try db.execute("PRAGMA user_version = 5")
            }
        }
        if db.userVersion < 6 {
            // Synkronisering mellem enheder: fælles ID'er (`uid`) og det, der sidst blev synkroniseret.
            // Samme skema på Windows. Kan køres igen uden fejl.
            try db.transaction {
            for table in ["copies", "locations", "plays"] where !(try hasColumn(table, "uid")) {
                try db.execute("ALTER TABLE \(table) ADD COLUMN uid TEXT")
            }
            try db.execute("""
            CREATE UNIQUE INDEX IF NOT EXISTS copies_uid ON copies(uid) WHERE uid IS NOT NULL;
            CREATE UNIQUE INDEX IF NOT EXISTS locations_uid ON locations(uid) WHERE uid IS NOT NULL;
            CREATE UNIQUE INDEX IF NOT EXISTS plays_uid ON plays(uid) WHERE uid IS NOT NULL;
            CREATE TABLE IF NOT EXISTS sync_state (
                kind TEXT NOT NULL,
                key TEXT NOT NULL,
                data TEXT,
                PRIMARY KEY (kind, key)
            );
            """)
            try db.execute("PRAGMA user_version = 6")
            }
        }
    }

    private func hasColumn(_ table: String, _ column: String) throws -> Bool {
        try db.query("SELECT name FROM pragma_table_info(?)", table).contains { $0["name"]?.text == column }
    }

    // MARK: - Indlæsning

    /// Samlingen for én slags hylde: kun plader (standard) eller kun cd'er, med deres egne reoler.
    public func loadLibrary(medium: Medium = .vinyl) throws -> Library {
        var releases: [Int: Release] = [:]
        for r in try db.query("SELECT * FROM releases") {
            let id = Int(r["discogs_release_id"]!.int!)
            releases[id] = Release(
                id: id, artist: r["artist"]?.text ?? "", title: r["title"]?.text ?? "",
                year: r["year"]?.int.map(Int.init), label: r["label"]?.text,
                catalogNumber: r["catalog_number"]?.text, format: r["format"]?.text,
                coverURL: r["cover_url"]?.text, thumbURL: r["thumb_url"]?.text, genres: r["genres"]?.text)
        }
        var copies: [Int64: Copy] = [:]
        for r in try db.query("SELECT * FROM copies") {
            let c = copy(from: r)
            guard Self.medium(of: c, releases) == medium else { continue }
            copies[c.id] = c
        }
        let locations = try db.query("SELECT * FROM locations WHERE medium = ?", medium.rawValue).map {
            Location(id: $0["id"]!.int!, shelf: Int($0["shelf"]!.int!), section: $0["section"]?.text ?? "",
                     sortIndex: Int($0["sort_index"]!.int!), scanCode: $0["scan_code"]?.text, medium: medium)
        }
        let locationIDs = Set(locations.map(\.id))
        // En kopi, der står på en reol af den anden slags (fx efter "Det er en cd"), regnes som uplaceret.
        let placements = try db.query("SELECT * FROM placements").map {
            (copyID: $0["copy_id"]!.int!, locationID: $0["location_id"]!.int!, position: Int($0["position"]!.int!))
        }.filter { copies[$0.copyID] != nil && locationIDs.contains($0.locationID) }
        return Library(releases: releases, copies: copies, locations: locations, placements: placements, medium: medium)
    }

    /// nil = ingen hylde (digitale filer kommer hverken på plade- eller cd-hylden).
    private static func medium(of c: Copy, _ releases: [Int: Release]) -> Medium? {
        Medium.shelfOf(override: c.mediumOverride, format: releases[c.releaseID]?.format)
    }

    /// Antal kopier pr. slags hylde (bruges til at vise skiftet "Plader / Cd'er", når der er cd'er).
    public func mediumCounts() throws -> [Medium: Int] {
        var counts: [Medium: Int] = [:]
        for r in try db.query("SELECT c.medium_override, r.format FROM copies c JOIN releases r ON r.discogs_release_id = c.release_id") {
            // Digitale filer tælles ikke med på nogen hylde.
            if let m = Medium.shelfOf(override: r["medium_override"]?.text.flatMap(Medium.init(rawValue:)), format: r["format"]?.text) {
                counts[m, default: 0] += 1
            }
        }
        return counts
    }

    private func copy(from r: SQLRow) -> Copy {
        Copy(id: r["id"]!.int!, instanceID: r["discogs_instance_id"]?.int.map(Int.init),
             releaseID: Int(r["release_id"]!.int!),
             status: CopyStatus(rawValue: r["status"]?.text ?? "home") ?? .home,
             statusNote: r["status_note"]?.text,
             inDiscogs: (r["in_discogs"]?.int ?? 1) != 0,
             removedFromDiscogsAt: r["removed_from_discogs_at"]?.double.map(Date.init(timeIntervalSince1970:)),
             sortArtistOverride: r["sort_artist_override"]?.text,
             sortTitleOverride: r["sort_title_override"]?.text,
             dateAdded: r["date_added"]?.text,
             discogsRank: r["discogs_rank"]?.int.map(Int.init),
             mediumOverride: r["medium_override"]?.text.flatMap(Medium.init(rawValue:)))
    }

    // MARK: - Indstillinger

    public func setting(_ key: String) -> String? {
        (try? db.query("SELECT value FROM settings WHERE key = ?", key))?.first?["value"]?.text
    }

    public func setSetting(_ key: String, _ value: String?) {
        if let value {
            _ = try? db.run("INSERT INTO settings(key, value) VALUES(?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value", key, value)
        } else {
            _ = try? db.run("DELETE FROM settings WHERE key = ?", key)
        }
    }

    public func loadSortRules() -> SortRules {
        var rules = SortRules()
        if let json = setting("sort_rules"), let data = json.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(SortRules.self, from: data) {
            rules = decoded
        }
        rules.artistOverrides = [:]
        for r in (try? db.query("SELECT artist, sort_name FROM artist_sort_overrides")) ?? [] {
            if let a = r["artist"]?.text, let s = r["sort_name"]?.text { rules.artistOverrides[a] = s }
        }
        return rules
    }

    public func saveSortRules(_ rules: SortRules) throws {
        var stored = rules
        stored.artistOverrides = [:]
        let data = try JSONEncoder().encode(stored)
        setSetting("sort_rules", String(data: data, encoding: .utf8))
        try db.transaction {
            try db.run("DELETE FROM artist_sort_overrides")
            for (a, s) in rules.artistOverrides where !s.trimmingCharacters(in: .whitespaces).isEmpty {
                try db.run("INSERT INTO artist_sort_overrides(artist, sort_name) VALUES(?, ?)", a, s)
            }
        }
    }

    // MARK: - Historik

    public func log(_ kind: HistoryEntry.Kind, copyID: Int64?, _ summary: String,
                    from: (Int64, Int)? = nil, to: (Int64, Int)? = nil) throws {
        try db.run("""
            INSERT INTO history(at, copy_id, kind, summary, from_location_id, from_position, to_location_id, to_position)
            VALUES(?, ?, ?, ?, ?, ?, ?, ?)
            """, Date().timeIntervalSince1970, copyID, kind.rawValue, summary,
            from?.0, from?.1, to?.0, to?.1)
    }

    public func history(limit: Int = 500) throws -> [HistoryEntry] {
        try db.query("SELECT * FROM history ORDER BY id DESC LIMIT ?", limit).map {
            HistoryEntry(id: $0["id"]!.int!, at: Date(timeIntervalSince1970: $0["at"]?.double ?? 0),
                         copyID: $0["copy_id"]?.int, kind: HistoryEntry.Kind(rawValue: $0["kind"]?.text ?? "") ?? .moved,
                         summary: $0["summary"]?.text ?? "",
                         fromLocationID: $0["from_location_id"]?.int, fromPosition: $0["from_position"]?.int.map(Int.init),
                         toLocationID: $0["to_location_id"]?.int, toPosition: $0["to_position"]?.int.map(Int.init))
        }
    }

    // MARK: - Fysisk struktur

    private func sectionIDs(_ locationID: Int64) throws -> [Int64] {
        try db.query("SELECT copy_id FROM placements WHERE location_id = ? ORDER BY position", locationID).map { $0["copy_id"]!.int! }
    }

    private func writeSection(_ locationID: Int64, _ ids: [Int64]) throws {
        for (i, id) in ids.enumerated() {
            try db.run("INSERT INTO placements(copy_id, location_id, position) VALUES(?, ?, ?) ON CONFLICT(copy_id) DO UPDATE SET location_id = excluded.location_id, position = excluded.position", id, locationID, i + 1)
        }
    }

    private func currentPlacement(_ copyID: Int64) throws -> (Int64, Int)? {
        guard let r = try db.query("SELECT location_id, position FROM placements WHERE copy_id = ?", copyID).first else { return nil }
        return (r["location_id"]!.int!, Int(r["position"]!.int!))
    }

    private func locationName(_ id: Int64?) -> String {
        guard let id, let r = try? db.query("SELECT shelf, section, medium FROM locations WHERE id = ?", id).first else { return "ukendt sektion" }
        let medium = r["medium"]?.text.flatMap(Medium.init(rawValue:)) ?? .vinyl
        return "\(medium.shelfWord) \(r["shelf"]?.int ?? 0) · Sektion \(r["section"]?.text ?? "")"
    }

    /// Placering til historikken: "Reol 1 · Sektion A, plads 16".
    private func placeText(_ locationID: Int64, _ position: Int) -> String {
        "\(locationName(locationID)), plads \(position)"
    }

    private func recordName(_ copyID: Int64) -> String {
        let r = try? db.query("SELECT r.artist, r.title FROM copies c JOIN releases r ON r.discogs_release_id = c.release_id WHERE c.id = ?", copyID).first
        return "\(r?["artist"]?.text ?? "?") – \(r?["title"]?.text ?? "?")"
    }

    /// Flytter (eller placerer) en kopi til `index` (0-baseret) i en sektion.
    /// Alle positioner i berørte sektioner omnummereres – naboer opdateres dermed automatisk.
    public func move(copyID: Int64, to locationID: Int64, index: Int, kind: HistoryEntry.Kind = .moved) throws {
        try db.transaction {
            let from = try currentPlacement(copyID)
            if let from {
                var old = try sectionIDs(from.0)
                old.removeAll { $0 == copyID }
                try db.run("DELETE FROM placements WHERE copy_id = ?", copyID)
                try writeSection(from.0, old)
            }
            var target = try sectionIDs(locationID)
            target.removeAll { $0 == copyID }
            let i = max(0, min(index, target.count))
            target.insert(copyID, at: i)
            try writeSection(locationID, target)

            let toText = placeText(locationID, i + 1)
            let summary = from.map { "\(recordName(copyID)) flyttet fra \(placeText($0.0, $0.1)) til \(toText)" }
                ?? "\(recordName(copyID)) placeret på \(toText)"
            try log(from == nil ? .placed : kind, copyID: copyID, summary, from: from, to: (locationID, i + 1))
        }
    }

    /// Fjerner fysisk placering (kræver brugerens bekræftelse i UI).
    public func unplace(copyID: Int64) throws {
        try db.transaction {
            guard let from = try currentPlacement(copyID) else { return }
            var ids = try sectionIDs(from.0)
            ids.removeAll { $0 == copyID }
            try db.run("DELETE FROM placements WHERE copy_id = ?", copyID)
            try writeSection(from.0, ids)
            try log(.unplaced, copyID: copyID, "\(recordName(copyID)) fjernet fra \(placeText(from.0, from.1))", from: from)
        }
    }

    /// Sletter en kopi helt (kun for plader fjernet fra Discogs, efter bekræftelse).
    public func deleteCopy(_ copyID: Int64) throws {
        try db.transaction {
            let name = recordName(copyID)
            let from = try currentPlacement(copyID)
            if let from {
                var ids = try sectionIDs(from.0)
                ids.removeAll { $0 == copyID }
                try db.run("DELETE FROM placements WHERE copy_id = ?", copyID)
                try writeSection(from.0, ids)
            }
            try db.run("DELETE FROM copies WHERE id = ?", copyID)
            try db.run("DELETE FROM releases WHERE discogs_release_id NOT IN (SELECT release_id FROM copies)")
            try log(.deleted, copyID: copyID, "\(name) slettet fra appen", from: from)
        }
    }

    public func setStatus(copyID: Int64, _ status: CopyStatus, note: String?) throws {
        let note = note?.trimmingCharacters(in: .whitespaces)
        try db.run("UPDATE copies SET status = ?, status_note = ? WHERE id = ?", status.rawValue, (note?.isEmpty ?? true) ? nil : note, copyID)
        // Ord, ikke emoji – historikken skal kunne læses som almindelig tekst.
        var summary = "\(recordName(copyID)): status ændret til “\(status.label)”"
        if let note, !note.isEmpty { summary += " (\(note))" }
        try log(.statusChanged, copyID: copyID, summary)
    }

    public func setSortOverrides(copyID: Int64, artist: String?, title: String?) throws {
        func clean(_ s: String?) -> String? {
            guard let t = s?.trimmingCharacters(in: .whitespaces), !t.isEmpty else { return nil }
            return t
        }
        try db.run("UPDATE copies SET sort_artist_override = ?, sort_title_override = ? WHERE id = ?", clean(artist), clean(title), copyID)
    }

    /// Opretter reol-strukturen fra onboarding. `layout` er sektioner i rækkefølge med
    /// kopier i fysisk rækkefølge. Erstatter eksisterende struktur for samme slags hylde
    /// (kun efter bekræftelse) – pladernes reoler røres ikke, når cd-reolerne oprettes, og omvendt.
    public func createLayout(_ layout: [(shelf: Int, section: String, copies: [Int64])], medium: Medium = .vinyl) throws {
        try db.transaction {
            try db.run("DELETE FROM placements WHERE location_id IN (SELECT id FROM locations WHERE medium = ?)", medium.rawValue)
            try db.run("DELETE FROM locations WHERE medium = ?", medium.rawValue)
            let offset = Int(try db.query("SELECT COALESCE(MAX(sort_index) + 1, 0) AS n FROM locations").first?["n"]?.int ?? 0)
            for (i, s) in layout.enumerated() {
                let locID = try db.run("INSERT INTO locations(shelf, section, sort_index, medium) VALUES(?, ?, ?, ?)", s.shelf, s.section, offset + i, medium.rawValue)
                try writeSection(locID, s.copies)
            }
            let total = layout.reduce(0) { $0 + $1.copies.count }
            let what = medium == .vinyl ? "Reolerne" : "Cd-reolerne"
            try log(.layoutCreated, copyID: nil, "\(what) er oprettet: \(layout.count == 1 ? "1 sektion" : "\(layout.count) sektioner"), \(total == 1 ? "1 \(medium.singular)" : "\(total) \(medium.plural)")")
        }
    }

    /// "Det er en cd" / "Det er en plade": flytter kopien til den anden slags hylde. Står den på en
    /// reol af den gamle slags, fjernes den derfra (og får en plads på den nye via "Nye cd'er").
    /// `nil` = følg Discogs' format igen.
    public func setMedium(copyID: Int64, _ medium: Medium?) throws {
        // `unplace` kører sin egen transaktion (og skriver i historikken), derfor ingen ydre transaktion her.
        if let p = try currentPlacement(copyID),
           let r = try db.query("SELECT medium FROM locations WHERE id = ?", p.0).first {
            let fmt = try db.query("SELECT r.format FROM copies c JOIN releases r ON r.discogs_release_id = c.release_id WHERE c.id = ?", copyID).first?["format"]?.text
            // nil = ingen hylde (en digital fil tilbage til "Følg Discogs"): pladsen fjernes også.
            let new = Medium.shelfOf(override: medium, format: fmt)
            if new == nil || r["medium"]?.text != new?.rawValue { try unplace(copyID: copyID) }
        }
        try db.run("UPDATE copies SET medium_override = ? WHERE id = ?", medium?.rawValue, copyID)
    }

    /// Tilføjer en ny tom sektion sidst i en reol (eller i en ny reol).
    @discardableResult
    public func addSection(shelf: Int, section: String, medium: Medium = .vinyl) throws -> Int64 {
        try db.transaction {
            let existing = try db.query("SELECT id, shelf, sort_index FROM locations WHERE medium = ? ORDER BY sort_index", medium.rawValue)
            // Indsæt efter den sidste sektion i samme (eller lavere) reol.
            let insertAfter = existing.last { Int($0["shelf"]!.int!) <= shelf }
            let newIndex = insertAfter.map { Int($0["sort_index"]!.int!) + 1 } ?? 0
            try db.run("UPDATE locations SET sort_index = sort_index + 1 WHERE sort_index >= ?", newIndex)
            return try db.run("INSERT INTO locations(shelf, section, sort_index, medium) VALUES(?, ?, ?, ?)", shelf, section, newIndex, medium.rawValue)
        }
    }

    public func deleteEmptySection(_ locationID: Int64) throws {
        guard try sectionIDs(locationID).isEmpty else {
            throw SQLiteError(message: "Sektionen er ikke tom. Flyt pladerne ud af den først.", userFacing: true)
        }
        try db.run("DELETE FROM locations WHERE id = ?", locationID)
    }

    // MARK: - Discogs-sync

    public struct SyncReport: Equatable {
        public var newCopies: [Int64] = []
        public var removedCopies: [Int64] = []
        public var returnedCopies: [Int64] = []
        public var updatedReleases: Int = 0
        public var total: Int = 0
        public init() {}
    }

    /// Anvender en fuld Discogs Collection. Rører ALDRIG `placements` eller `locations`:
    /// - kendt instance → behold kopi og placering, opdatér metadata
    /// - ny instance → ny, uplaceret kopi
    /// - forsvundet instance → markeres "ikke længere i Discogs" (slettes ikke)
    public func applyCollection(_ items: [DiscogsCollectionItem]) throws -> SyncReport {
        // Discogs kan levere samme instance to gange (fx hvis samlingen ændres, mens siderne
        // hentes). Den første forekomst vinder; ellers fejler hele syncen på UNIQUE(discogs_instance_id).
        var firstSeen = Set<Int>()
        let items = items.filter { firstSeen.insert($0.instanceID).inserted }
        var report = SyncReport()
        report.total = items.count
        try db.transaction {
            let now = Date().timeIntervalSince1970
            var existingReleases: [Int: SQLRow] = [:]
            for r in try db.query("SELECT * FROM releases") { existingReleases[Int(r["discogs_release_id"]!.int!)] = r }

            for it in items {
                let r = it.release
                if let old = existingReleases[r.id] {
                    let changed = old["artist"]?.text != r.artist || old["title"]?.text != r.title
                        || old["year"]?.int.map(Int.init) != r.year || old["label"]?.text != r.label
                        || old["catalog_number"]?.text != r.catalogNumber || old["format"]?.text != r.format
                        || old["cover_url"]?.text != r.coverURL || old["thumb_url"]?.text != r.thumbURL
                        || old["genres"]?.text != r.genres
                    if changed {
                        try db.run("""
                            UPDATE releases SET artist=?, title=?, year=?, label=?, catalog_number=?, format=?,
                                cover_url=?, thumb_url=?, genres=?, updated_at=? WHERE discogs_release_id=?
                            """, r.artist, r.title, r.year, r.label, r.catalogNumber, r.format,
                            r.coverURL, r.thumbURL, r.genres, now, r.id)
                        report.updatedReleases += 1
                        existingReleases[r.id] = Self.row(r)
                    }
                } else {
                    try db.run("""
                        INSERT INTO releases(discogs_release_id, artist, title, year, label, catalog_number, format,
                            cover_url, thumb_url, genres, updated_at) VALUES(?,?,?,?,?,?,?,?,?,?,?)
                        """, r.id, r.artist, r.title, r.year, r.label, r.catalogNumber, r.format,
                        r.coverURL, r.thumbURL, r.genres, now)
                    // Husk de indsatte værdier, så flere kopier af samme nye release
                    // ikke tælles som "opdateret metadata".
                    existingReleases[r.id] = Self.row(r)
                }
            }

            var copyByInstance: [Int: SQLRow] = [:]
            for c in try db.query("SELECT id, discogs_instance_id, in_discogs, release_id FROM copies WHERE discogs_instance_id IS NOT NULL") {
                copyByInstance[Int(c["discogs_instance_id"]!.int!)] = c
            }

            // Discogs' egen rækkefølge gemmes, så "Præcis som Discogs" kan bruge den.
            try db.run("UPDATE copies SET discogs_rank = NULL")
            var seen = Set<Int>()
            for (rank, it) in items.enumerated() {
                seen.insert(it.instanceID)
                if let c = copyByInstance[it.instanceID] {
                    let id = c["id"]!.int!
                    try db.run("UPDATE copies SET discogs_rank = ? WHERE id = ?", rank, id)
                    if Int(c["release_id"]!.int!) != it.release.id {
                        try db.run("UPDATE copies SET release_id = ? WHERE id = ?", it.release.id, id)
                    }
                    if c["in_discogs"]?.int == 0 {
                        try db.run("UPDATE copies SET in_discogs = 1, removed_from_discogs_at = NULL WHERE id = ?", id)
                        report.returnedCopies.append(id)
                    }
                } else {
                    let id = try db.run("""
                        INSERT INTO copies(discogs_instance_id, release_id, status, in_discogs, date_added, created_at, discogs_rank)
                        VALUES(?, ?, 'home', 1, ?, ?, ?)
                        """, it.instanceID, it.release.id, it.dateAdded, now, rank)
                    // Digitale filer gemmes (så de ikke ser "fjernet" ud), men meldes ikke som nye plader.
                    if !Medium.isDigital(format: it.release.format) { report.newCopies.append(id) }
                    try log(.addedFromDiscogs, copyID: id, "Ny i Discogs: \(it.release.artist) – \(it.release.title)")
                }
            }

            for (instance, c) in copyByInstance where !seen.contains(instance) && c["in_discogs"]?.int != 0 {
                let id = c["id"]!.int!
                try db.run("UPDATE copies SET in_discogs = 0, removed_from_discogs_at = ? WHERE id = ?", now, id)
                let fmt = try db.query("SELECT format FROM releases WHERE discogs_release_id = ?", c["release_id"]?.int).first?["format"]?.text
                if !Medium.isDigital(format: fmt) { report.removedCopies.append(id) }
                try log(.removedFromDiscogs, copyID: id, "\(recordName(id)) er ikke længere i din Discogs-samling. Pladsen i reolen er bevaret.")
            }
            if report.updatedReleases > 0 {
                let n = report.updatedReleases
                try log(.metadataUpdated, copyID: nil, "Oplysninger fra Discogs opdateret for \(n == 1 ? "1 plade" : "\(n) plader")")
            }
        }
        setSetting("last_sync", String(Date().timeIntervalSince1970))
        return report
    }

    private static func row(_ r: Release) -> SQLRow {
        ["artist": r.artist.sqlValue, "title": r.title.sqlValue, "year": r.year.sqlValue,
         "label": r.label.sqlValue, "catalog_number": r.catalogNumber.sqlValue, "format": r.format.sqlValue,
         "cover_url": r.coverURL.sqlValue, "thumb_url": r.thumbURL.sqlValue, "genres": r.genres.sqlValue]
    }

    /// Brugeren har bekræftet at en plade fjernet fra Discogs stadig står i reolen.
    public func keepLocalOnly(copyID: Int64) throws {
        try db.run("UPDATE copies SET removed_from_discogs_at = NULL WHERE id = ?", copyID)
    }
}
