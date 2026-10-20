import SwiftUI
import VinylCore

/// Cover Flow som på Mac (CoverFlowView.swift) med samme geometri (`CoverFlowGeometry`): hvid baggrund (sort i mørk tilstand),
/// covers drejet i 3D med spejling. Stryg med fingeren, tryk på et sidecover for at hente det frem, og på midten
/// for at åbne pladen. Et let klik i telefonen for hver plade, der passerer midten, og et tydeligere ved enden.
struct PhoneCoverFlow: View {
    let items: [RecordItem]
    @Binding var center: Int
    /// Sæt til en plade (indeks), så snurrer Cover Flow derhen i én blød bevægelse; sættes til nil, når den er landet.
    var spin: Binding<Int?> = .constant(nil)
    let onOpen: (RecordItem) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Hvor langt rækken er skubbet under fingeren (i plader).
    @State private var shift = 0.0
    @State private var lastDrag: CGFloat = 0
    @State private var atEdge = false
    @State private var edgeTick = 0
    @State private var dragging = false
    /// Fingeren stoppede et glid: det er ikke et tryk på et cover.
    @State private var stoppedGlide = false
    /// Et klik i telefonen pr. plade, der passerer midten (kun når det går så langsomt, at man kan mærke det).
    @State private var tick = 0
    @State private var landedTick = 0
    /// Midtercoveret "popper" kort, når forslaget er fundet.
    @State private var pop = false
    @State private var spinTask: Task<Void, Never>?

    var body: some View {
        GeometryReader { geo in
            let side = CoverFlowGeometry.side(width: geo.size.width, height: geo.size.height)
            let c = items.isEmpty ? 0 : min(max(center, 0), items.count - 1)
            let range = CoverFlowGeometry.visibleRange(center: c, count: items.count)
            ZStack {
                ForEach(Array(zip(range, items[range])), id: \.1.id) { i, item in
                    let o = Double(i - c) - shift
                    CoverFlowCover(item: item, o: o, side: side)
                        .scaleEffect(pop && i == c ? 1.07 : 1)
                        .zIndex(CoverFlowGeometry.zIndex(o))
                        .accessibilityElement()
                        .accessibilityAddTraits(.isButton)
                        .accessibilityLabel(item.fullName)
                        .accessibilityHint(i == c ? "Find i reolen" : "Vis pladen i midten")
                        .accessibilityAction { tapped(i, c) }
                }
            }
            .offset(y: -side * CoverFlowGeometry.reflectionHeight / 2)
            .frame(width: geo.size.width, height: geo.size.height)
            .allowsHitTesting(false)
            // Ét lag over hele Cover Flow tager både stryg og tryk. (Lader man coverne selv fange fingeren,
            // kan man kun bladre ved at stryge på den tomme flade under dem.)
            .overlay {
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { v in
                            // En finger på rækken stopper et glid, der er i gang (som når man stopper en scroll).
                            if !dragging, spinTask != nil, spin.wrappedValue == nil { spinTask?.cancel(); spinTask = nil; stoppedGlide = true }
                            guard dragging || abs(v.translation.width) > 6 else { return }
                            if !dragging { spinTask?.cancel(); spinTask = nil; spin.wrappedValue = nil }
                            dragging = true
                            let delta = v.translation.width - lastDrag
                            lastDrag = v.translation.width
                            pan(-Double(delta) / max(24, side * 0.25))
                        }
                        .onEnded { v in
                            if !dragging && !stoppedGlide {
                                // Et tryk: midtercoveret åbner pladen, et sidecover hentes frem.
                                let dx = v.location.x - geo.size.width / 2
                                if abs(dx) <= side / 2 { tapped(c, c) }
                                else if let i = range.filter({ $0 != c }).min(by: {
                                    abs(CoverFlowGeometry.x($0 - c, side: side) - dx) < abs(CoverFlowGeometry.x($1 - c, side: side) - dx)
                                }) { tapped(i, c) }
                            }
                            let wasDragging = dragging
                            stoppedGlide = false
                            dragging = false
                            lastDrag = 0
                            if wasDragging {
                                // Fingerens fart, når den slipper (plader pr. sekund; mod venstre = næste plade).
                                fling(velocity: -Double(v.velocity.width) / max(24, side * 0.25))
                            } else {
                                withAnimation(animation) { shift = 0 }
                            }
                        })
            }
        }
        .clipped()
        .sensoryFeedback(.selection, trigger: tick)
        .sensoryFeedback(.impact(weight: .medium), trigger: edgeTick)
        .sensoryFeedback(.success, trigger: landedTick)
        .onChange(of: spin.wrappedValue) { _, target in if let target { startSpin(to: target) } }
        .onChange(of: center) { old, new in if !spinning, old != new { tick += 1 } }
        .onDisappear { spinTask?.cancel() }
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

    private var spinning: Bool { spinTask != nil }

    /// Snurrer hen til pladen `target`: rækken glider i én bevægelse, starter hurtigt og bremser jævnt op
    /// (som et lykkehjul), og midtercoveret popper, når den lander.
    private func startSpin(to target: Int) {
        guard items.indices.contains(target) else { spin.wrappedValue = nil; return }
        let total = Double(target) - (Double(center) + shift)
        if reduceMotion || abs(total) < 0.5 { spinTask?.cancel(); center = target; shift = 0; landed(); return }
        // Længere afstande tager lidt længere tid, men aldrig over ca. 2,7 sekunder.
        glide(to: target, duration: 1.3 + min(1.4, abs(total) * 0.035), landing: true)
    }

    /// Fortsætter et kraftigt stryg med farten og bremser jævnt op (som at scrolle på iPhone). `velocity` er i plader pr. sekund.
    private func fling(velocity: Double) {
        let from = Double(center) + shift
        let target = min(max(Int((from + velocity * 0.45).rounded()), 0), items.count - 1)
        let total = Double(target) - from
        guard !reduceMotion, abs(velocity) > 2.5, abs(total) >= 0.5 else {
            withAnimation(animation) { shift = 0 }
            return
        }
        // Kurven starter med samme fart som fingeren (ease-out i fjerde potens starter med 4 × afstand / tid).
        glide(to: target, duration: min(2.5, max(0.35, 4 * abs(total) / abs(velocity))), landing: false)
    }

    /// Rækken glider hen til `target`: hurtigt først, bremser jævnt op. Et klik i telefonen for hver plade, der passerer
    /// midten, hele vejen (højst ét pr. 35 ms, som er det, telefonen kan nå).
    private func glide(to target: Int, duration: Double, landing: Bool) {
        spinTask?.cancel()
        let from = Double(center) + shift
        let total = Double(target) - from
        spinTask = Task { @MainActor in
            let clock = ContinuousClock(), begin = clock.now
            var lastTick = begin - .seconds(1)
            while !Task.isCancelled {
                let t = min(1, (clock.now - begin) / .seconds(duration))
                let pos = from + total * (1 - pow(1 - t, 4)) // ease-out (kvart)
                let c = min(max(Int(pos.rounded()), 0), items.count - 1)
                var tr = Transaction(); tr.disablesAnimations = true
                withTransaction(tr) {
                    if c != center {
                        if clock.now - lastTick >= .milliseconds(35) { tick += 1; lastTick = clock.now }
                        center = c
                    }
                    shift = pos - Double(c)
                }
                if t >= 1 { break }
                try? await Task.sleep(for: .milliseconds(8))
            }
            guard !Task.isCancelled else { return }
            center = target
            shift = 0
            if landing { landed() } else { spinTask = nil }
        }
    }

    private func landed() {
        spinTask = nil
        spin.wrappedValue = nil
        landedTick += 1
        withAnimation(.spring(response: 0.22, dampingFraction: 0.5)) { pop = true }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(220))
            withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) { pop = false }
        }
    }

    private func tapped(_ i: Int, _ c: Int) {
        guard items.indices.contains(i) else { return }
        if i == c { onOpen(items[i]) } else { withAnimation(animation) { center = i } }
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

/// Cover Flow har hvid baggrund i lys tilstand og sort i mørk (som Mac og Windows).
extension View {
    func coverFlowStage() -> some View { modifier(CoverFlowBackground()) }
}

private struct CoverFlowBackground: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content.background((colorScheme == .dark ? Color.black : Color.white).ignoresSafeArea())
    }
}
