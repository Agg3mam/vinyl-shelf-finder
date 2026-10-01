import Foundation

// MARK: - Discogs-data ("Jeg ejer denne release")

/// Metadata for én Discogs-release. Identificeres altid ved `id` (Discogs release ID),
/// aldrig ved artist + titel.
public struct Release: Equatable, Hashable {
    public var id: Int
    /// Kunstnernavn som Discogs viser det (efter fjernelse af Discogs' "(2)"-suffikser).
    public var artist: String
    public var title: String
    public var year: Int?
    public var label: String?
    public var catalogNumber: String?
    public var format: String?
    public var coverURL: String?
    public var thumbURL: String?
    public var genres: String?

    public init(id: Int, artist: String, title: String, year: Int? = nil, label: String? = nil,
                catalogNumber: String? = nil, format: String? = nil, coverURL: String? = nil,
                thumbURL: String? = nil, genres: String? = nil) {
        self.id = id; self.artist = artist; self.title = title; self.year = year
        self.label = label; self.catalogNumber = catalogNumber; self.format = format
        self.coverURL = coverURL; self.thumbURL = thumbURL; self.genres = genres
    }

    public var discogsURL: URL { URL(string: "https://www.discogs.com/release/\(id)")! }
}

// MARK: - Fysisk data ("Denne konkrete kopi står her")

/// Pladens fysiske status. Gemmes som tekst (`rawValue`) i `copies.status`.
/// Alle andre end `.home` er "ude af reolen": pladen beholder sin plads i `placements`,
/// men tæller ikke med i reolens fysiske nummerering, før den er sat tilbage.
public enum CopyStatus: String, CaseIterable, Identifiable {
    case home       // På plads
    case wall       // På væggen (fx hængt op som udstilling)
    case lent       // Udlånt
    case stored     // Opbevaret andet sted
    case missing    // Mangler (ikke fundet ved kontrol)

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .home: return "På plads"
        case .wall: return "På væggen"
        case .stored: return "Opbevaret andet sted"
        case .lent: return "Udlånt"
        case .missing: return "Mangler"
        }
    }

    public var emoji: String {
        switch self {
        case .home: return "🏠"
        case .wall: return "🖼"
        case .stored: return "📦"
        case .lent: return "👤"
        case .missing: return "❓"
        }
    }

    /// Står pladen faktisk i reolen? Kun sådanne plader bruges som referencepunkter
    /// og tæller med i reolens fysiske nummerering ("Plade 13 af 14").
    public var isOnShelf: Bool { self == .home }
}

/// Én fysisk kopi. Svarer til en Discogs collection-"instance", så to kopier af samme
/// release (eller to pressings) altid er to forskellige rækker.
public struct Copy: Equatable, Hashable, Identifiable {
    public var id: Int64
    public var instanceID: Int?
    public var releaseID: Int
    public var status: CopyStatus
    public var statusNote: String?
    /// false når kopien er forsvundet fra Discogs Collection. Fysisk placering bevares.
    public var inDiscogs: Bool
    public var removedFromDiscogsAt: Date?
    public var sortArtistOverride: String?
    public var sortTitleOverride: String?
    public var dateAdded: String?
    /// Pladens plads i Discogs' egen artist-sortering ved seneste sync (0-baseret).
    public var discogsRank: Int?

    public init(id: Int64, instanceID: Int?, releaseID: Int, status: CopyStatus = .home,
                statusNote: String? = nil, inDiscogs: Bool = true, removedFromDiscogsAt: Date? = nil,
                sortArtistOverride: String? = nil, sortTitleOverride: String? = nil, dateAdded: String? = nil,
                discogsRank: Int? = nil) {
        self.id = id; self.instanceID = instanceID; self.releaseID = releaseID; self.status = status
        self.statusNote = statusNote; self.inDiscogs = inDiscogs; self.removedFromDiscogsAt = removedFromDiscogsAt
        self.sortArtistOverride = sortArtistOverride; self.sortTitleOverride = sortTitleOverride
        self.dateAdded = dateAdded
        self.discogsRank = discogsRank
    }
}

/// En sektion i en reol, fx "Reol 3 / Sektion B".
public struct Location: Equatable, Hashable, Identifiable {
    public var id: Int64
    public var shelf: Int
    public var section: String
    /// Global rækkefølge af sektioner (reol 1A, 1B, 2A ...).
    public var sortIndex: Int
    /// Til fremtidig QR-scanning af en sektion.
    public var scanCode: String?

    public init(id: Int64, shelf: Int, section: String, sortIndex: Int, scanCode: String? = nil) {
        self.id = id; self.shelf = shelf; self.section = section; self.sortIndex = sortIndex; self.scanCode = scanCode
    }

    public var name: String { "Reol \(shelf) · Sektion \(section)" }
    public var shortName: String { "\(shelf)\(section)" }
}

public struct HistoryEntry: Identifiable, Equatable {
    public enum Kind: String {
        case moved, placed, statusChanged, addedFromDiscogs, removedFromDiscogs, metadataUpdated
        case unplaced, deleted, layoutCreated
    }
    public var id: Int64
    public var at: Date
    public var copyID: Int64?
    public var kind: Kind
    public var summary: String
    public var fromLocationID: Int64?
    public var fromPosition: Int?
    public var toLocationID: Int64?
    public var toPosition: Int?
}

/// Kombinerer fysisk kopi og Discogs-metadata til visning.
public struct RecordItem: Identifiable, Hashable {
    public let copy: Copy
    public let release: Release
    public var id: Int64 { copy.id }

    public init(copy: Copy, release: Release) { self.copy = copy; self.release = release }

    public var artist: String { release.artist }
    public var title: String { release.title }
    public var fullName: String { "\(release.artist) – \(release.title)" }

    /// "1973 • Harvest • SHVL 804 • Vinyl, LP" – bruges til at skelne pressings.
    public var detailLine: String {
        var parts: [String] = []
        if let y = release.year, y > 0 { parts.append(String(y)) }
        if let l = release.label, !l.isEmpty { parts.append(l) }
        if let c = release.catalogNumber, !c.isEmpty, c.lowercased() != "none" { parts.append(c) }
        if let f = release.format, !f.isEmpty { parts.append(f) }
        return parts.joined(separator: " • ")
    }
}
