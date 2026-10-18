import Foundation

// MARK: - Lyttelog

public struct Play: Identifiable, Equatable {
    public let id: Int64
    public let copyID: Int64
    public let playedAt: Date
}

public struct ListeningStats {
    public let plays: [Play]
    public let count: [Int64: Int]
    public let lastPlayed: [Int64: Date]

    public init(plays: [Play]) {
        self.plays = plays.sorted { $0.playedAt > $1.playedAt }
        var c: [Int64: Int] = [:], l: [Int64: Date] = [:]
        for p in plays {
            c[p.copyID, default: 0] += 1
            if l[p.copyID].map({ p.playedAt > $0 }) ?? true { l[p.copyID] = p.playedAt }
        }
        count = c
        lastPlayed = l
    }

    public static let empty = ListeningStats(plays: [])

    public func plays(since date: Date) -> Int { plays.filter { $0.playedAt >= date }.count }

    /// Mest spillede kopier, flest først.
    public func mostPlayed(limit: Int = 10) -> [(copyID: Int64, count: Int)] {
        count.sorted { $0.value != $1.value ? $0.value > $1.value : (lastPlayed[$0.key] ?? .distantPast) > (lastPlayed[$1.key] ?? .distantPast) }
            .prefix(limit).map { ($0.key, $0.value) }
    }
}

extension ShelfStore {
    @discardableResult
    public func logPlay(copyID: Int64, at date: Date = Date()) throws -> Int64 {
        try db.run("INSERT INTO plays(copy_id, played_at) VALUES(?, ?)", copyID, date.timeIntervalSince1970)
    }

    public func deletePlay(_ id: Int64) throws {
        try db.run("DELETE FROM plays WHERE id = ?", id)
    }

    public func loadPlays() throws -> [Play] {
        try db.query("SELECT id, copy_id, played_at FROM plays").map {
            Play(id: $0["id"]!.int!, copyID: $0["copy_id"]!.int!,
                 playedAt: Date(timeIntervalSince1970: $0["played_at"]?.double ?? 0))
        }
    }

    public func setScanCode(locationID: Int64, code: String) throws {
        try db.run("UPDATE locations SET scan_code = ? WHERE id = ?", code, locationID)
        try db.run("INSERT INTO scan_codes(code, kind, target_id) VALUES(?, 'location', ?) ON CONFLICT(code) DO UPDATE SET kind = 'location', target_id = excluded.target_id", code, locationID)
    }
}

// MARK: - "Hvad skal jeg høre?"

public struct ListenFilter: Equatable {
    public enum Freshness: String, CaseIterable, Identifiable {
        case any, neverPlayed, notIn3Months, notInYear
        public var id: String { rawValue }
        public var label: String {
            switch self {
            case .any: return "Alle plader"
            case .neverPlayed: return "Aldrig spillet"
            case .notIn3Months: return "Ikke hørt i 3 måneder"
            case .notInYear: return "Ikke hørt i et år"
            }
        }
    }

    public var genre: String?
    /// Fx 1970 for 70'erne.
    public var decade: Int?
    public var freshness: Freshness = .any

    public init(genre: String? = nil, decade: Int? = nil, freshness: Freshness = .any) {
        self.genre = genre; self.decade = decade; self.freshness = freshness
    }
}

public enum ListenPicker {
    public static func genres(in items: [RecordItem]) -> [String] {
        Set(items.flatMap { ($0.release.genres ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } })
            .filter { !$0.isEmpty }.sorted()
    }

    public static func decades(in items: [RecordItem]) -> [Int] {
        Set(items.compactMap { $0.release.year.map { $0 / 10 * 10 } }).sorted()
    }

    /// Plader der opfylder filteret og står i reolen.
    public static func candidates(_ items: [RecordItem], library: Library, filter: ListenFilter,
                                  stats: ListeningStats, now: Date = Date()) -> [RecordItem] {
        items.filter { it in
            guard it.copy.status.isOnShelf, library.locationOfCopy[it.id] != nil else { return false }
            if let g = filter.genre, !(it.release.genres ?? "").split(separator: ",")
                .contains(where: { $0.trimmingCharacters(in: .whitespaces) == g }) { return false }
            if let d = filter.decade, (it.release.year.map { $0 / 10 * 10 }) != d { return false }
            let last = stats.lastPlayed[it.id]
            switch filter.freshness {
            case .any: return true
            case .neverPlayed: return last == nil
            case .notIn3Months: return last.map { now.timeIntervalSince($0) > 90 * 86400 } ?? true
            case .notInYear: return last.map { now.timeIntervalSince($0) > 365 * 86400 } ?? true
            }
        }
    }

    /// Vælger tilfældigt, vægtet mod plader der ikke er hørt længe. Undgår nylige forslag.
    public static func pick<R: RandomNumberGenerator>(from candidates: [RecordItem], stats: ListeningStats,
                                                      avoiding recent: [Int64], now: Date = Date(),
                                                      using rng: inout R) -> RecordItem? {
        var pool = candidates.filter { !recent.contains($0.id) }
        if pool.isEmpty { pool = candidates }
        guard !pool.isEmpty else { return nil }
        // Vægt: aldrig spillet = 4, ellers 1 + år siden sidst (max 4).
        let weights: [Double] = pool.map { it in
            guard let last = stats.lastPlayed[it.id] else { return 4 }
            // Afspilninger med dato i fremtiden (fx ændret ur) må ikke give vægt ≤ 0 –
            // så bliver intervallet til Double.random tomt, og appen crasher.
            return min(4, 1 + max(0, now.timeIntervalSince(last)) / (365 * 86400))
        }
        var r = Double.random(in: 0..<weights.reduce(0, +), using: &rng)
        for (i, w) in weights.enumerated() {
            if r < w { return pool[i] }
            r -= w
        }
        return pool.last
    }
}

// MARK: - Reolskilte

public struct ShelfLabel: Identifiable, Equatable {
    public let location: Location
    public let firstArtist: String?
    public let lastArtist: String?
    /// Antal plader, der står i sektionen nu (`Library.onShelfCount`).
    public let count: Int
    public var id: Int64 { location.id }

    /// Kode på QR-skiltet. Appen åbner sektionen, når koden scannes eller klikkes.
    /// Et skilt, der allerede er trykt (evt. på en anden enhed), beholder sin kode.
    public var scanCode: String { location.scanCode ?? "vinylshelf://section/\(location.id)" }

    /// Ét skilt pr. sektion. Antal og første/sidste kunstner tæller kun plader, der står
    /// i reolen – en plade på væggen eller udlånt er ikke med.
    public static func labels(for library: Library) -> [ShelfLabel] {
        library.locations.map { loc in
            let onShelf = library.items(in: loc.id).filter { $0.copy.status.isOnShelf }
            return ShelfLabel(location: loc, firstArtist: onShelf.first?.artist, lastArtist: onShelf.last?.artist,
                              count: library.onShelfCount(in: loc.id))
        }
    }

    /// Fortolker `vinylshelf://section/<id>`.
    public static func locationID(fromScanCode code: String) -> Int64? {
        guard let url = URL(string: code), url.scheme == "vinylshelf", url.host == "section" else { return nil }
        return Int64(url.lastPathComponent)
    }
}
