import SwiftUI
import AppKit
import VinylCore

// MARK: - Skillekortet
//
// Placeringen vises som skillekortene i en pladebutiks kasser: sektionsbogstavet står stort på en fane,
// og reolen står ved siden af. Fanen har kategoriens farve (jazz, underholdning, klassisk) eller pladens
// tone. Det er appens ene dristige element; alt omkring det holdes roligt.

extension VinylCore.Category {
    var color: Color {
        let (l, d) = colorHex
        return adaptive(light: NSColor(hex: l), dark: NSColor(hex: d))
    }
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

/// Fanens farve og teksten ovenpå: kategoriens farve med hvid tekst, ellers pladens tone.
struct DividerColors {
    let fill: Color
    let ink: Color

    init(location: Location, tone: CoverTone) {
        if let c = location.category { fill = c.color; ink = .white } else { fill = tone.accent; ink = tone.onAccent }
    }
}

/// "A" på fanen og "Reol 1 / Sektion A" ved siden af. `compact` til den smalle detaljekolonne.
struct PlacementLine: View {
    let location: Location
    let tone: CoverTone
    var compact = false

    var body: some View {
        let colors = DividerColors(location: location, tone: tone)
        HStack(alignment: .bottom, spacing: Spacing.s) {
            Text(location.section)
                .font(compact ? Typo.dividerLetterCompact : Typo.dividerLetter)
                .foregroundStyle(colors.ink)
                .padding(.horizontal, compact ? 10 : 14)
                .padding(.top, 2)
                .frame(minWidth: compact ? 40 : 54)
                .background(colors.fill, in: UnevenRoundedRectangle(topLeadingRadius: 8, topTrailingRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 0) {
                Text("\(location.kind.shelfWord) \(location.shelf)").font(compact ? Typo.locationCompact : Typo.location)
                Text("Sektion \(location.section)").font(.callout).foregroundStyle(Ink.secondary)
            }
            .padding(.bottom, 4)
        }
        .lineLimit(1)
        .overlay(alignment: .bottom) {
            // Kortets overkant: fanen sidder på en streg i samme farve.
            Rectangle().fill(colors.fill).frame(height: 3).offset(y: 3)
                .frame(maxWidth: .infinity)
        }
        .padding(.bottom, 3)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(location.kind.shelfWord) \(location.shelf), sektion \(location.section)")
    }
}

/// "Nr. 7 af 15 fra venstre" i den smalle skrift, med "ca. 45 % inde" svagere ved siden af (under, hvis der ikke er plads).
struct PlacementCount: View {
    let text: String
    var percent: String? = nil
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 12) { line; extra }
            VStack(alignment: .leading, spacing: 2) { line; extra }
        }
    }
    private var line: some View {
        Text(text).font(Typo.count).foregroundStyle(Ink.secondary).contentTransition(.opacity)
    }
    @ViewBuilder private var extra: some View {
        if let percent { Text(percent).font(Typo.count).foregroundStyle(Ink.tertiary).contentTransition(.opacity) }
    }
}

/// Lille fane med et bogstav til lister og sidepanelet (sektioner og kategorier).
struct SectionTab: View {
    let letter: String
    let color: Color
    var body: some View {
        Text(letter)
            .font(.system(size: 11, weight: .bold).width(.condensed))
            .foregroundStyle(.white)
            .frame(width: 16, height: 15)
            .background(color, in: UnevenRoundedRectangle(topLeadingRadius: 4, topTrailingRadius: 4, style: .continuous))
            .accessibilityHidden(true)
    }
}

// MARK: - Blankt omslag

/// Plader uden cover: et blankt omslag i kunstnerens faste farve med navnet trykt på,
/// i stedet for en grå flade med et pladesymbol. Små størrelser viser forbogstaverne.
struct SleevePlaceholder: View {
    let release: Release
    let size: CGFloat

    var body: some View {
        let tone = CoverTone.fallback(for: release)
        ZStack(alignment: .bottomLeading) {
            Rectangle().fill(tone.strong)
            if size > 80 {
                VStack(alignment: .leading, spacing: 2) {
                    Text(release.artist).font(.system(size: size * 0.11, weight: .bold).width(.condensed))
                    Text(release.title).font(.system(size: size * 0.08, weight: .regular).width(.condensed)).opacity(0.85)
                }
                .lineLimit(2)
                .foregroundStyle(.white)
                .padding(size * 0.08)
            } else {
                Text(Self.initials(release.artist))
                    .font(.system(size: size * 0.4, weight: .bold).width(.condensed))
                    .foregroundStyle(.white.opacity(0.92))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .accessibilityHidden(true)
    }

    /// "Pink Floyd" → "PF", "Madonna" → "MA", "The Beatles" → "B".
    static func initials(_ artist: String) -> String {
        let words = artist.split(separator: " ").filter { $0.lowercased() != "the" }
        if words.count >= 2 { return String(words[0].prefix(1) + words[1].prefix(1)).uppercased() }
        return String((words.first ?? "").prefix(2)).uppercased()
    }
}
