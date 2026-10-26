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
    /// Sanglisten fra Discogs (tom, indtil den er hentet).
    public var tracks: [Track]

    public init(id: Int, artist: String, title: String, year: Int? = nil, label: String? = nil,
                catalogNumber: String? = nil, format: String? = nil, coverURL: String? = nil,
                thumbURL: String? = nil, genres: String? = nil, tracks: [Track] = []) {
        self.id = id; self.artist = artist; self.title = title; self.year = year
        self.label = label; self.catalogNumber = catalogNumber; self.format = format
        self.coverURL = coverURL; self.thumbURL = thumbURL; self.genres = genres; self.tracks = tracks
    }

    public var discogsURL: URL { URL(string: "https://www.discogs.com/release/\(id)")! }
}

/// Én sang på en udgivelse, som Discogs skriver den, fx position "B1" (side B, nummer 1) eller "3" på en cd.
public struct Track: Equatable, Hashable, Sendable {
    public var position: String
    public var title: String
    public var duration: String?

    public init(position: String, title: String, duration: String? = nil) {
        self.position = position; self.title = title; self.duration = duration
    }
}

// MARK: - Plader og cd'er

/// Hvilken slags hylde en kopi hører til. Plader og cd'er har hver deres reoler, sektioner og
/// nummerering, men samme Discogs-samling. Gemmes som tekst (`rawValue`).
public enum Medium: String, CaseIterable, Identifiable {
    case vinyl
    case cd

    public var id: String { rawValue }

    /// Ud fra Discogs' format, fx "Vinyl, LP" eller "2×CD, Album". Kun det første format tæller.
    /// Alt, der ikke er en cd (vinyl, kassetter, bokse …), hører til pladerne, som før.
    public static func of(format: String?) -> Medium {
        ["CD", "CDR", "SACD", "HDCD"].contains(firstFormat(format)) ? .cd : .vinyl
    }

    /// Første format uden antal: "2×CD, Album" → "CD", "8×File, MP3" → "FILE".
    private static func firstFormat(_ format: String?) -> String {
        guard let first = format?.split(separator: ",").first else { return "" }
        let name = first.trimmingCharacters(in: .whitespaces).uppercased()
        if let x = name.firstIndex(of: "×") { return String(name[name.index(after: x)...]) }
        return name
    }

    /// Kun digitale filer (Discogs-formatet "File"). De står ikke fysisk nogen steder.
    public static func isDigital(format: String?) -> Bool { firstFormat(format) == "FILE" }

    /// Hylden, en kopi hører til: brugerens valg, ellers ud fra formatet.
    /// nil = ingen hylde (digitale filer), medmindre brugeren selv har flyttet kopien.
    public static func shelfOf(override: Medium?, format: String?) -> Medium? {
        override ?? (isDigital(format: format) ? nil : of(format: format))
    }

    /// "Plader" / "Cd'er" – til skiftet øverst og overskrifter.
    public var title: String { self == .vinyl ? "Plader" : "Cd'er" }
    /// "plade" / "cd"
    public var singular: String { self == .vinyl ? "plade" : "cd" }
    /// "plader" / "cd'er"
    public var plural: String { self == .vinyl ? "plader" : "cd'er" }
    /// "Reol" / "Cd-reol"
    public var shelfWord: String { self == .vinyl ? "Reol" : "Cd-reol" }
}

// MARK: - Kategorier (Jazz, Underholdning, Klassisk)

/// Musik, der kan stå for sig: til sidst på reolerne eller på egne reoler. Rækkefølgen her er også rækkefølgen
/// til sidst på reolerne, og passer en plade i flere kategorier, vinder den første. Gemmes som tekst (`rawValue`).
public enum Category: String, CaseIterable, Identifiable, Codable {
    case jazz
    case entertainment
    case classical

    public var id: String { rawValue }

    /// "Jazz" / "Underholdning" / "Klassisk"
    public var title: String {
        switch self {
        case .jazz: return "Jazz"
        case .entertainment: return "Underholdning"
        case .classical: return "Klassisk"
        }
    }

    /// Underholdning er brugerens egen mappe i Discogs-samlingen med dette navn.
    public static let entertainmentFolder = "Underholdning"

    /// Jazz og Klassisk er Discogs-genrer ("Jazz, Rock" tæller som jazz). Underholdning er Discogs-mappen.
    public func matches(genres: String?, folder: String?) -> Bool {
        switch self {
        case .jazz: return Self.hasGenre(genres, "jazz")
        case .classical: return Self.hasGenre(genres, "classical")
        case .entertainment:
            return folder?.trimmingCharacters(in: .whitespaces).lowercased() == Self.entertainmentFolder.lowercased()
        }
    }

    /// Skillekortets farve (lys og mørk tilstand), som RGB-hex. Hvid tekst ovenpå. Samme farver på Windows og i webappen.
    public var colorHex: (light: UInt32, dark: UInt32) {
        switch self {
        case .jazz: return (0x1F4F8F, 0x3A6DB5)
        case .entertainment: return (0x85621A, 0xA67C24)
        case .classical: return (0x6E2433, 0x93394B)
        }
    }

    static func hasGenre(_ genres: String?, _ name: String) -> Bool {
        (genres ?? "").split(separator: ",").contains { $0.trimmingCharacters(in: .whitespaces).lowercased() == name }
    }
}

/// Hvor en kategori står. `off` = sammen med alt det andet (som før).
public enum CategoryMode: String, CaseIterable, Identifiable, Codable {
    case off
    case end
    case own

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .off: return "Fra"
        case .end: return "Sidst på reolerne"
        case .own: return "Egne reoler"
        }
    }
}

/// En slags hylde med egne reoler, sektioner og nummerering: plader eller cd'er, og evt. en kategori med
/// egne reoler (fx jazz-cd'er). Gemmes som tekst: "vinyl", "cd", "vinyl.jazz", "cd.classical" osv.
public struct ShelfKind: Hashable, Identifiable {
    public var medium: Medium
    public var category: Category?

    public init(_ medium: Medium, _ category: Category? = nil) { self.medium = medium; self.category = category }

    public static let vinyl = ShelfKind(.vinyl)
    public static let cd = ShelfKind(.cd)

    public var rawValue: String { category.map { "\(medium.rawValue).\($0.rawValue)" } ?? medium.rawValue }
    public var id: String { rawValue }

    public init?(rawValue: String) {
        let parts = rawValue.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard let m = Medium(rawValue: parts[0]), parts.count <= 2 else { return nil }
        if parts.count == 2 {
            guard let c = Category(rawValue: parts[1]) else { return nil }
            self.init(m, c)
        } else {
            self.init(m)
        }
    }

    /// Alle slags hylder i fast rækkefølge: plader, cd'er, og så kategorierne (plader før cd'er).
    public static var all: [ShelfKind] {
        Medium.allCases.map { ShelfKind($0) } + Category.allCases.flatMap { c in Medium.allCases.map { ShelfKind($0, c) } }
    }

    /// "Plader" / "Cd'er" / "Jazz (plader)" / "Klassisk (cd'er)" – til skiftet øverst og overskrifter.
    public var title: String { category.map { "\($0.title) (\(medium.plural))" } ?? medium.title }
    /// "Reol" / "Cd-reol" / "Jazz-reol" / "Klassisk-cd-reol"
    public var shelfWord: String {
        guard let category else { return medium.shelfWord }
        return medium == .vinyl ? "\(category.title)-reol" : "\(category.title)-cd-reol"
    }
    /// "plade" / "cd" og "plader" / "cd'er" (som mediet).
    public var singular: String { medium.singular }
    public var plural: String { medium.plural }
    /// "Reolerne" / "Cd-reolerne" / "Jazz-reolerne" – til historikken.
    public var shelvesWord: String { shelfWord + "erne" }
}

// MARK: - Fysisk data ("Denne konkrete kopi står her")

/// Pladens fysiske status. Gemmes som tekst (`rawValue`) i `copies.status`.
/// Alle andre end `.home` er "ude af reolen": pladen beholder sin plads i `placements`,
/// men tæller ikke med i reolens fysiske nummerering, før den er sat tilbage.
public enum CopyStatus: String, CaseIterable, Identifiable {
    case home       // På plads
    case playing    // På pladespilleren ("Jeg lytter til den" efter Find). Ældre versioner læser den som "home".
    case wall       // På væggen (fx hængt op som udstilling)
    case lent       // Udlånt
    case stored     // Opbevaret andet sted
    case missing    // Mangler (ikke fundet ved kontrol)

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .home: return "På plads"
        case .playing: return "På pladespilleren"
        case .wall: return "På væggen"
        case .stored: return "Opbevaret andet sted"
        case .lent: return "Udlånt"
        case .missing: return "Mangler"
        }
    }

    public var emoji: String {
        switch self {
        case .home: return "🏠"
        case .playing: return "🎶"
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
    /// Brugerens eget valg af hylde, når Discogs' format ikke passer (fx en boks med en cd).
    public var mediumOverride: Medium?
    /// Navnet på mappen i Discogs-samlingen (fx "Underholdning"). nil, indtil den er hentet.
    public var discogsFolder: String?

    public init(id: Int64, instanceID: Int?, releaseID: Int, status: CopyStatus = .home,
                statusNote: String? = nil, inDiscogs: Bool = true, removedFromDiscogsAt: Date? = nil,
                sortArtistOverride: String? = nil, sortTitleOverride: String? = nil, dateAdded: String? = nil,
                discogsRank: Int? = nil, mediumOverride: Medium? = nil, discogsFolder: String? = nil) {
        self.id = id; self.instanceID = instanceID; self.releaseID = releaseID; self.status = status
        self.statusNote = statusNote; self.inDiscogs = inDiscogs; self.removedFromDiscogsAt = removedFromDiscogsAt
        self.sortArtistOverride = sortArtistOverride; self.sortTitleOverride = sortTitleOverride
        self.dateAdded = dateAdded
        self.discogsRank = discogsRank
        self.mediumOverride = mediumOverride
        self.discogsFolder = discogsFolder
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
    /// Plade- eller cd-reol.
    public var medium: Medium
    /// En kategori med egne reoler (fx jazz). nil = de almindelige reoler.
    public var category: Category?

    public init(id: Int64, shelf: Int, section: String, sortIndex: Int, scanCode: String? = nil, medium: Medium = .vinyl,
                category: Category? = nil) {
        self.id = id; self.shelf = shelf; self.section = section; self.sortIndex = sortIndex; self.scanCode = scanCode
        self.medium = medium
        self.category = category
    }

    public var kind: ShelfKind { ShelfKind(medium, category) }

    /// "Reol 1 · Sektion A", "Cd-reol 1 · Sektion A" eller "Jazz-reol 1 · Sektion A".
    public var name: String { "\(kind.shelfWord) \(shelf) · Sektion \(section)" }
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
    /// Plade eller cd: brugerens valg, ellers Discogs' format.
    public var medium: Medium { copy.mediumOverride ?? Medium.of(format: release.format) }

    /// "Harvest SHVL 804 (1973)" – pladeselskab og katalognummer, som samlere skriver dem.
    public var pressingLine: String {
        let label = release.label.flatMap { $0.isEmpty ? nil : $0 }
        let cat = release.catalogNumber.flatMap { $0.isEmpty || $0.lowercased() == "none" ? nil : $0 }
        let name = [label, cat].compactMap { $0 }.joined(separator: " ")
        guard let y = release.year, y > 0 else { return name }
        return name.isEmpty ? String(y) : "\(name) (\(y))"
    }

    /// "Harvest SHVL 804 (1973). Vinyl, LP" – bruges til at skelne pressings. Samme tekst på Windows og i webappen.
    public var detailLine: String {
        let f = release.format.flatMap { $0.isEmpty ? nil : $0 }
        return [pressingLine.isEmpty ? nil : pressingLine, f].compactMap { $0 }.joined(separator: ". ")
    }
}
