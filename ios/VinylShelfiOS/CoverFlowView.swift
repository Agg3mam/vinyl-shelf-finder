import SwiftUI
import VinylCore

/// Cover Flow som på Mac (CoverFlowView.swift) med samme geometri (`CoverFlowGeometry`): altid hvid baggrund,
/// covers drejet i 3D med spejling. Stryg med fingeren, tryk på et sidecover for at hente det frem, og på midten
/// for at åbne pladen. Et let klik i telefonen for hver plade, der passerer midten, og et tydeligere ved enden.
struct PhoneCoverFlow: View {
    let items: [RecordItem]
    @Binding var center: Int
    let onOpen: (RecordItem) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Hvor langt rækken er skubbet under fingeren (i plader).
    @State private var shift = 0.0
    @State private var lastDrag: CGFloat = 0
    @State private var atEdge = false
    @State private var edgeTick = 0

    var body: some View {
        GeometryReader { geo in
            let side = CoverFlowGeometry.side(width: geo.size.width, height: geo.size.height)
            let c = items.isEmpty ? 0 : min(max(center, 0), items.count - 1)
            let range = CoverFlowGeometry.visibleRange(center: c, count: items.count)
            ZStack {
                ForEach(Array(zip(range, items[range])), id: \.1.id) { i, item in
                    let o = Double(i - c) - shift
                    Button {
                        if i == c { onOpen(item) } else { withAnimation(animation) { center = i } }
                    } label: {
                        CoverFlowCover(item: item, o: o, side: side)
                    }
                    .buttonStyle(.plain)
                    .zIndex(CoverFlowGeometry.zIndex(o))
                    .accessibilityLabel(item.fullName)
                    .accessibilityHint(i == c ? "Find i reolen" : "Vis pladen i midten")
                }
            }
            .offset(y: -side * CoverFlowGeometry.reflectionHeight / 2)
            .frame(width: geo.size.width, height: geo.size.height)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 6)
                .onChanged { v in
                    let delta = v.translation.width - lastDrag
                    lastDrag = v.translation.width
                    pan(-Double(delta) / max(24, side * 0.25))
                }
                .onEnded { _ in
                    lastDrag = 0
                    withAnimation(animation) { shift = 0 }
                })
        }
        .clipped()
        .sensoryFeedback(.selection, trigger: center)
        .sensoryFeedback(.impact(weight: .medium), trigger: edgeTick)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Cover Flow")
        .accessibilityAdjustableAction { dir in
            switch dir {
            case .increment: center = min(center + 1, items.count - 1)
            case .decrement: center = max(center - 1, 0)
            default: break
            }
        }
    }

    private var animation: Animation? { reduceMotion ? nil : .spring(response: 0.38, dampingFraction: 0.86) }

    /// Rækken følger fingeren; passerer den en halv plade, skifter midten (uden animation, så intet hopper).
    private func pan(_ plates: Double) {
        guard !items.isEmpty else { return }
        let g = CoverFlowGeometry.glide(center: center, shift: shift + plates, count: items.count)
        let edge = (g.center == 0 && g.shift <= -0.3) || (g.center == items.count - 1 && g.shift >= 0.3)
        if edge && !atEdge && g.center == center { edgeTick += 1 }
        atEdge = edge
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) {
            shift = g.shift
            center = g.center
        }
    }
}

private struct CoverFlowCover: View {
    let item: RecordItem
    let o: Double
    let side: Double

    var body: some View {
        let reflection = side * CoverFlowGeometry.reflectionHeight
        let url = item.release.coverURL ?? item.release.thumbURL
        CoverImage(url: url, size: side, corner: 3)
            .shadow(color: .black.opacity(0.18), radius: 12, y: 8)
            .overlay(alignment: .bottom) {
                CoverImage(url: url, size: side, corner: 3)
                    .scaleEffect(x: 1, y: -1)
                    .frame(width: side, height: reflection, alignment: .top)
                    .clipped()
                    .mask {
                        LinearGradient(colors: [.black.opacity(CoverFlowGeometry.reflectionOpacity), .clear], startPoint: .top, endPoint: .bottom)
                    }
                    .offset(y: reflection + 1)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .opacity(item.copy.status.isOnShelf ? 1 : 0.45)
            .rotation3DEffect(.degrees(CoverFlowGeometry.angle(o)), axis: (x: 0, y: 1, z: 0), perspective: CoverFlowGeometry.perspective)
            .scaleEffect(CoverFlowGeometry.scale(o))
            .offset(x: CoverFlowGeometry.x(o, side: side))
    }
}

/// Titel, kunstner og nummer under midtercoveret (som CoverFlowCaption på Mac).
struct CoverFlowCaption: View {
    let item: RecordItem?
    let library: Library
    /// Vis også reol og sektion (når Cover Flow viser hele hylden).
    var showsSection = false
    let onFind: (RecordItem) -> Void

    var body: some View {
        VStack(spacing: 4) {
            if let item {
                Text(item.title).font(.title3.weight(.semibold))
                Text(item.artist).font(.body).foregroundStyle(.secondary)
                Text(line(item)).font(.footnote.monospacedDigit()).foregroundStyle(.secondary)
                Button { onFind(item) } label: { Label("Find i reolen", systemImage: "scope") }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
                    .padding(.top, 6)
            } else {
                Text("Sektionen er tom.").foregroundStyle(.secondary)
            }
        }
        .lineLimit(1)
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.horizontal)
    }

    private func line(_ item: RecordItem) -> String {
        guard let loc = library.location(of: item.id), let nr = library.shelfNumbers(in: loc.id)[item.id] else {
            return item.awayMessage ?? "Ude af reolen"
        }
        let base = "Nr. \(nr) af \(library.onShelfCount(in: loc.id))"
        return showsSection ? "\(base) · \(loc.medium.shelfWord) \(loc.shelf) · Sektion \(loc.section)" : base
    }
}

extension RecordItem {
    /// Én sætning, når pladen ikke står i reolen (samme tekster som Mac). `nil`, når den står på plads.
    var awayMessage: String? {
        let note = copy.statusNote?.trimmingCharacters(in: .whitespaces) ?? ""
        switch copy.status {
        case .home: return nil
        case .wall: return "Hænger på væggen – står ikke i reolen"
        case .lent: return note.isEmpty ? "Udlånt – står ikke i reolen" : "Udlånt til \(note) – står ikke i reolen"
        case .stored: return note.isEmpty ? "Opbevaret andet sted – står ikke i reolen" : "Opbevaret andet sted (\(note)) – står ikke i reolen"
        case .missing: return "Mangler – står ikke i reolen"
        }
    }
}

/// Cover Flow har altid hvid baggrund, også i mørk tilstand.
extension View {
    func whiteStage() -> some View {
        environment(\.colorScheme, .light)
            .background(Color.white.ignoresSafeArea())
            .toolbarColorScheme(.light, for: .navigationBar)
    }
}
