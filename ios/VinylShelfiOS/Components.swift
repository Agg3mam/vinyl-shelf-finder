import SwiftUI
import VinylCore

/// Coveret fra Discogs. Uden cover: en rolig flade med en node.
struct CoverImage: View {
    let url: String?
    var size: CGFloat? = nil
    var corner: CGFloat = 6

    var body: some View {
        AsyncImage(url: url.flatMap(URL.init(string:))) { phase in
            if let image = phase.image {
                image.resizable().scaledToFill()
            } else {
                ZStack {
                    Rectangle().fill(.quaternary)
                    Image(systemName: "music.note").foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: size, height: size)
        .aspectRatio(1, contentMode: .fit)
        .clipShape(.rect(cornerRadius: corner))
        .accessibilityHidden(true)
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

    var body: some View {
        HStack(spacing: 12) {
            if let number {
                Text("\(number)")
                    .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                    .frame(minWidth: 28, alignment: .trailing)
            }
            CoverImage(url: item.release.thumbURL ?? item.release.coverURL, size: 48)
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

/// "Reol 1 › Sektion A" – samme linje som på Mac.
struct PlacementLine: View {
    let location: Location

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "books.vertical.fill").foregroundStyle(AppAccent.color).accessibilityHidden(true)
            Text("\(location.medium.shelfWord) \(location.shelf)")
            Image(systemName: "chevron.right").imageScale(.small).fontWeight(.semibold)
                .foregroundStyle(.tertiary).accessibilityHidden(true)
            Text("Sektion \(location.section)")
        }
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .accessibilityElement(children: .combine)
    }
}

/// Sektionen tegnet som pladerygge set forfra: én streg pr. plade, målet fremhævet (som på Mac).
struct ShelfSpines: View {
    let position: Int
    let count: Int

    var body: some View {
        Canvas { ctx, size in
            let n = max(count, 1)
            let idx = min(max(position - 1, 0), n - 1)
            let slot = size.width / CGFloat(n)
            if slot >= 3 {
                let w = min(max(slot * 0.45, 2), 6)
                for i in 0..<n {
                    let x = slot * (CGFloat(i) + 0.5) - w / 2
                    let isTarget = i == idx
                    let h: CGFloat = isTarget ? size.height : size.height * 0.55
                    let rect = CGRect(x: x, y: size.height - h, width: isTarget ? w + 2 : w, height: h)
                    ctx.fill(Path(roundedRect: rect, cornerRadius: 1.5),
                             with: isTarget ? .color(AppAccent.color) : .style(.tertiary))
                }
            } else {
                let track = CGRect(x: 0, y: size.height - 6, width: size.width, height: 6)
                ctx.fill(Path(roundedRect: track, cornerRadius: 3), with: .style(.tertiary))
                let x = n > 1 ? CGFloat(idx) / CGFloat(n - 1) * (size.width - 6) : 0
                ctx.fill(Path(roundedRect: CGRect(x: x, y: 0, width: 6, height: size.height), cornerRadius: 2),
                         with: .color(AppAccent.color))
            }
        }
        .frame(height: 24)
        .accessibilityLabel("Plade \(position) af \(count) i sektionen")
    }
}

extension CopyStatus {
    /// SF Symbol for status (samme som på Mac).
    var symbol: String {
        switch self {
        case .home: "house.fill"
        case .wall: "photo.artframe"
        case .stored: "shippingbox.fill"
        case .lent: "person.fill"
        case .missing: "circle.dashed"
        }
    }
}
