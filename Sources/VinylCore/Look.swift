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
        case .kasse: "Pladekasse"
        case .cover: "Farve fra coveret"
        case .fokus: "Covers i fokus"
        }
    }

    public var note: String {
        switch self {
        case .standard: "Rent og enkelt, som Apples egne apps"
        case .kasse: "Varm benhvid som pap og papir, rustfarvede knapper"
        case .cover: "Varm papirfarve. Pladeskærmen farves af coveret"
        case .fokus: "Varm papirfarve. Store covers på pladeskærmen og i listerne"
        }
    }

    /// Farverne i lys og mørk tilstand. `nil` for Standard (systemets egne farver).
    public var palette: (light: LookColors, dark: LookColors)? {
        switch self {
        case .standard: nil
        case .kasse: (LookColors(background: 0xEAE2D3, cell: 0xF8F4EC, label: 0x221C15, accent: 0xA9572A, accentInk: 0x94491F),
                      LookColors(background: 0x16130F, cell: 0x24201A, label: 0xEEE6D8, accent: 0xC2703D, accentInk: 0xE9A273))
        case .cover, .fokus: (LookColors(background: 0xF3EFE8, cell: 0xFFFDF9, label: 0x000000, accent: 0x1C6E66, accentInk: 0x1C6E66),
                              LookColors(background: 0x181512, cell: 0x24201C, label: 0xFFFFFF, accent: 0x2E9D8F, accentInk: 0x5EC4B6))
        }
    }

    /// Overskrifter med fødder (Apples New York / Georgia).
    public var serifTitles: Bool { self != .standard }
    /// Større covers på pladeskærmen og i listerne.
    public var bigCovers: Bool { self == .fokus }
    /// Pladeskærmen farves kraftigere af coveret.
    public var strongCoverTint: Bool { self == .cover }

    /// Til små farveprøver i indstillingerne (baggrund, mørk baggrund, accent).
    public var swatch: [UInt32] {
        switch self {
        case .standard: [0xF2F2F7, 0xFFFFFF, 0x1C6E66]
        case .kasse: [0xEAE2D3, 0x16130F, 0xA9572A]
        case .cover: [0xF3EFE8, 0x6E2F45, 0xE58C6A]
        case .fokus: [0xF3EFE8, 0xFFFDF9, 0x8A7560]
        }
    }
}
