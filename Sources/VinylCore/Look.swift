import Foundation

/// Udseende: tema og stil, som i webappen (web/app.css, `data-theme` og `data-style`). Valget gemmes kun på enheden.
public enum LookTheme: String, CaseIterable, Sendable, Identifiable {
    case auto = "", light, dark
    public var id: String { rawValue }
    public var name: String {
        switch self {
        case .auto: "Automatisk"
        case .light: "Lys"
        case .dark: "Mørk"
        }
    }
}

/// En stils farver i lys eller mørk tilstand (RGB som 0xRRGGBB).
public struct LookColors: Sendable, Equatable {
    public let background: UInt32
    public let cell: UInt32
    public let label: UInt32
    public let accent: UInt32
    /// Accent til tekst på en svag accentflade (lysere i mørk tilstand).
    public let accentInk: UInt32
}

public enum LookStyle: String, CaseIterable, Sendable, Identifiable {
    case standard = "", kasse, cover, fokus
    public var id: String { rawValue }

    public var name: String {
        switch self {
        case .standard: "Standard"
        case .kasse: "Hi-fi"
        case .cover: "Farve fra coveret"
        case .fokus: "Covers i fokus"
        }
    }

    public var note: String {
        switch self {
        case .standard: "Rent og enkelt, som Apples egne apps"
        case .kasse: "Børstet aluminium og signalrøde knapper, som en forstærker"
        case .cover: "Lys aluminium. Pladeskærmen farves af coveret"
        case .fokus: "Lys aluminium. Store covers på pladeskærmen og i listerne"
        }
    }

    /// Farverne i lys og mørk tilstand. `nil` for Standard (systemets egne farver).
    public var palette: (light: LookColors, dark: LookColors)? {
        switch self {
        case .standard: nil
        case .kasse: (LookColors(background: 0xD9DBDC, cell: 0xF3F4F4, label: 0x1C1F22, accent: 0xB8321C, accentInk: 0xA02A16),
                      LookColors(background: 0x131415, cell: 0x202224, label: 0xE9EBEC, accent: 0xD4442B, accentInk: 0xFF8A73))
        case .cover, .fokus: (LookColors(background: 0xD9DBDC, cell: 0xF3F4F4, label: 0x1C1F22, accent: 0x1C6E66, accentInk: 0x1C6E66),
                              LookColors(background: 0x131415, cell: 0x202224, label: 0xE9EBEC, accent: 0x2E9D8F, accentInk: 0x5EC4B6))
        }
    }

    /// Smalle, fede overskrifter som på skillekortet (systemets smalle skrift, Bahnschrift på Windows).
    public var condensedTitles: Bool { self != .standard }
    /// Større covers på pladeskærmen og i listerne.
    public var bigCovers: Bool { self == .fokus }
    /// Pladeskærmen farves kraftigere af coveret.
    public var strongCoverTint: Bool { self == .cover }

    /// Til små farveprøver i indstillingerne (baggrund, mørk baggrund, accent).
    public var swatch: [UInt32] {
        switch self {
        case .standard: [0xF2F2F7, 0xFFFFFF, 0x1C6E66]
        case .kasse: [0xD9DBDC, 0x131415, 0xB8321C]
        case .cover: [0xD9DBDC, 0x6E2F45, 0xE58C6A]
        case .fokus: [0xD9DBDC, 0xF3F4F4, 0x8A7560]
        }
    }
}
