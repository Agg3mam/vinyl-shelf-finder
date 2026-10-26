import SwiftUI
import VinylCore

/// Coveret fra Discogs. Uden cover: et blankt omslag i kunstnerens faste farve med navnet trykt på (som på Mac).
struct CoverImage: View {
    let url: String?
    var size: CGFloat? = nil
    var corner: CGFloat = 6
    var release: Release? = nil

    var body: some View {
        AsyncImage(url: url.flatMap(URL.init(string:))) { phase in
            if let image = phase.image {
                image.resizable().scaledToFill()
            } else if let release {
                SleevePlaceholder(release: release, size: size ?? 200)
            } else {
                Rectangle().fill(.quaternary)
            }
        }
        .frame(width: size, height: size)
        .aspectRatio(1, contentMode: .fit)
        .clipShape(.rect(cornerRadius: corner))
        .accessibilityHidden(true)
    }
}

/// Blankt omslag: kunstnerens faste farve (samme mønster som på Mac) og navnet, eller forbogstaverne i små størrelser.
struct SleevePlaceholder: View {
    let release: Release
    let size: CGFloat

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Rectangle().fill(Self.color(release.artist))
            if size > 80 {
                VStack(alignment: .leading, spacing: 2) {
                    Text(release.artist).font(.system(size: size * 0.11, weight: .bold).width(.condensed))
                    Text(release.title).font(.system(size: size * 0.08).width(.condensed)).opacity(0.85)
                }
                .lineLimit(2).foregroundStyle(.white).padding(size * 0.08)
            } else {
                Text(Self.initials(release.artist))
                    .font(.system(size: size * 0.4, weight: .bold).width(.condensed))
                    .foregroundStyle(.white.opacity(0.92))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    static func color(_ artist: String) -> Color {
        var h: UInt64 = 0xcbf29ce484222325
        for b in artist.lowercased().utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        let hue = Double(h % 24) / 24
        let sat = [0.30, 0.42][Int((h / 24) % 2)]
        return Color(hue: hue, saturation: min(max(sat, 0.5), 0.75), brightness: 0.34)
    }

    static func initials(_ artist: String) -> String {
        let words = artist.split(separator: " ").filter { $0.lowercased() != "the" }
        if words.count >= 2 { return String(words[0].prefix(1) + words[1].prefix(1)).uppercased() }
        return String((words.first ?? "").prefix(2)).uppercased()
    }
}

extension VinylCore.Category {
    /// Skillekortets farve (som på Mac), med hvid tekst ovenpå.
    var color: Color {
        Color(uiColor: UIColor { t in
            let hex = t.userInterfaceStyle == .dark ? self.colorHex.dark : self.colorHex.light
            return UIColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        })
    }
}

/// Placeringsmærket, fx "2A" (reol 2, sektion A), som på Mac.
struct PlacementBadge: View {
    let location: Location?

    var body: some View {
        if let location {
            Text(location.shortName)
                .font(.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(AppAccent.ink)
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(AppAccent.color.opacity(0.15), in: Capsule())
                .accessibilityLabel(location.name)
        } else {
            Text("Ingen plads").font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// Én plade i en liste: cover, kunstner, titel og plads.
struct RecordRow: View {
    let item: RecordItem
    let location: Location?
    /// Pladens nummer i sektionen (set fra venstre), når listen er en sektion.
    var number: Int? = nil
    @AppStorage("look_style") private var lookStyle = LookStyle.standard

    var body: some View {
        HStack(spacing: 12) {
            if let number {
                Text("\(number)")
                    .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                    .frame(minWidth: 28, alignment: .trailing)
            }
            CoverImage(url: item.release.thumbURL ?? item.release.coverURL, size: lookStyle.bigCovers ? 60 : 48, release: item.release)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.artist).font(.headline).lineLimit(1)
                Text(item.title).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                if !item.copy.status.isOnShelf {
                    Label(item.copy.status.label, systemImage: item.copy.status.symbol)
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            Spacer(minLength: 8)
            if number == nil { PlacementBadge(location: location) }
        }
        .opacity(item.copy.status.isOnShelf ? 1 : 0.7)
        .accessibilityElement(children: .combine)
    }
}

/// Skillekortet: sektionsbogstavet på en fane i kategoriens farve og reolen ved siden af (som på Mac).
struct PlacementLine: View {
    let location: Location

    var body: some View {
        let fill = location.category?.color ?? AppAccent.color
        HStack(alignment: .bottom, spacing: 10) {
            Text(location.section)
                .font(.system(size: 40, weight: .bold).width(.condensed))
                .foregroundStyle(.white)
                .padding(.horizontal, 12).padding(.top, 2)
                .frame(minWidth: 46)
                .background(fill, in: UnevenRoundedRectangle(topLeadingRadius: 8, topTrailingRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 0) {
                Text("\(location.kind.shelfWord) \(location.shelf)").font(.system(size: 22, weight: .semibold).width(.condensed))
                Text("Sektion \(location.section)").font(.callout).foregroundStyle(.secondary)
            }
            .padding(.bottom, 4)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .overlay(alignment: .bottom) { Rectangle().fill(fill).frame(height: 3).offset(y: 3) }
        .padding(.bottom, 3)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(location.kind.shelfWord) \(location.shelf), sektion \(location.section)")
    }
}

/// Sektionen tegnet som pladerygge set forfra: rygge i forskellig tykkelse, målet fremhævet (som på Mac).
struct ShelfSpines: View {
    let position: Int
    let count: Int
    var accent: Color = AppAccent.color

    var body: some View {
        Canvas { ctx, size in
            let n = max(count, 1)
            let idx = min(max(position - 1, 0), n - 1)
            let slot = size.width / CGFloat(n)
            if slot >= 3 {
                let maxW = min(max(slot * 0.8, 2), 14)
                for i in 0..<n {
                    let r = Double((i &* 2654435761) % 1000) / 1000
                    let isTarget = i == idx
                    let w = isTarget ? maxW : maxW * (0.45 + 0.55 * r)
                    let h: CGFloat = isTarget ? size.height : size.height * (0.72 + 0.16 * (1 - r))
                    let rect = CGRect(x: slot * (CGFloat(i) + 0.5) - w / 2, y: size.height - h, width: w, height: h)
                    ctx.fill(Path(roundedRect: rect, cornerRadius: 1), with: isTarget ? .color(accent) : .style(.tertiary))
                }
            } else {
                let track = CGRect(x: 0, y: size.height - 6, width: size.width, height: 6)
                ctx.fill(Path(roundedRect: track, cornerRadius: 3), with: .style(.tertiary))
                let x = n > 1 ? CGFloat(idx) / CGFloat(n - 1) * (size.width - 6) : 0
                ctx.fill(Path(roundedRect: CGRect(x: x, y: 0, width: 6, height: size.height), cornerRadius: 2), with: .color(accent))
            }
        }
        .frame(height: 30)
        .accessibilityLabel("Plade \(position) af \(count) i sektionen")
    }
}

extension CopyStatus {
    /// SF Symbol for status (samme som på Mac).
    var symbol: String {
        switch self {
        case .home: "house.fill"
        case .playing: "music.note"
        case .wall: "photo.artframe"
        case .stored: "shippingbox.fill"
        case .lent: "person.fill"
        case .missing: "circle.dashed"
        }
    }
}
