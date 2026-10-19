import SwiftUI
import AppKit
import VinylCore

/// Cover Flow som på en iPod classic: sektionens plader i reolens rækkefølge.
/// Vises i detaljekolonnen, når Cover Flow er slået til i en sektion. Midterpladen er
/// altid den valgte plade, så listen til venstre og Cover Flow følger hinanden.
/// Styres med ← →, trackpad (coverne følger fingrene), musehjul, træk med musen, klik på et
/// sidecover og ↩ eller klik på midten (Find i reolen).
struct CoverFlowView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let locationID: Int64
    /// false i snapshots: ImageRenderer kan ikke tegne AppKit-views og viser et advarselsskilt i stedet.
    var catchesScroll = true
    @FocusState private var focused: Bool
    /// Hvor langt rækken er skubbet under en trackpad- eller musebevægelse (i plader).
    @ViewState private var shift = 0.0
    @ViewState private var lastDrag: CGFloat = 0
    @ViewState private var stripWidth: CGFloat = 0
    /// Står rækken mod enden af sektionen (så enden kun mærkes én gang pr. skub).
    @ViewState private var atEdge = false

    var body: some View {
        let items = model.library.items(in: locationID)
        // Midten udledes af valget hver gang, så den aldrig peger på en forkert plade,
        // når en sektionsgrænse flyttes, en plade flyttes, eller en sync ændrer sektionen.
        let center = items.firstIndex { $0.id == model.selection } ?? 0
        let current = items.indices.contains(center) ? items[center] : nil
        let numbers = model.library.shelfNumbers(in: locationID)
        let onShelf = model.library.onShelfCount(in: locationID)
        VStack(spacing: Spacing.l) {
            Spacer(minLength: 0)
            CoverFlowStrip(items: items, center: center, shift: shift, isAway: { model.isAway($0) }) { i in
                if i == center { model.findModeCopy = items[i].id } else { select(i, in: items) }
            }
            .frame(maxHeight: 460)
            .animation(Motion.coverFlow(reduceMotion), value: center)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { stripWidth = $0 }
            .simultaneousGesture(DragGesture(minimumDistance: 6)
                .onChanged { v in
                    let delta = v.translation.width - lastDrag
                    lastDrag = v.translation.width
                    // Rækken følger musen: ét cover pr. stak-afstand.
                    pan(-Double(delta) / dragPointsPerCover, center: center, items: items)
                }
                .onEnded { _ in
                    lastDrag = 0
                    settle()
                })
            CoverFlowCaption(item: current, number: current.flatMap { numbers[$0.id] }, onShelf: onShelf)
                .animation(Motion.fade(reduceMotion), value: current?.id)
            Spacer(minLength: 0)
        }
        .padding(Spacing.l)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            if catchesScroll {
                ScrollWheelCatcher(
                    onSteps: { step($0, from: center, in: items) },
                    onPan: { pan($0 / Self.trackpadPointsPerCover, center: center, items: items) },
                    onPanEnded: { settle() })
            }
        }
        // Altid hvid baggrund (ikke tonet efter coveret), også i mørk tilstand. Samme på Windows og telefonen.
        .environment(\.colorScheme, .light)
        .environment(\.coverTone, .coverFlow)
        .tint(CoverTone.coverFlow.accent)
        .background(Color.white.ignoresSafeArea())
        // Fokus kun ved klik, så ↑↓ i listen til venstre stadig virker efter skift af sektion.
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(.leftArrow) { step(-1, from: center, in: items); return .handled }
        .onKeyPress(.rightArrow) { step(1, from: center, in: items); return .handled }
        .onKeyPress(.upArrow) { step(-1, from: center, in: items); return .handled }
        .onKeyPress(.downArrow) { step(1, from: center, in: items); return .handled }
        .onKeyPress(.return) {
            if let current { model.findModeCopy = current.id }
            return .handled
        }
        .onAppear {
            // Står den valgte plade ikke i sektionen, vælges den første (som i listen).
            if current == nil || model.selection != current?.id { model.selection = items.first?.id }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Cover Flow")
    }

    /// Trackpad: så mange punkters fingerbevægelse flytter én plade.
    static let trackpadPointsPerCover = 36.0

    /// Træk med musen: ét cover pr. afstand mellem de stablede sidecovers.
    private var dragPointsPerCover: Double {
        let side = CoverFlowGeometry.side(width: Double(stripWidth), height: 460)
        return max(24, side * 0.25)
    }

    private func select(_ i: Int, in items: [RecordItem]) {
        guard items.indices.contains(i) else { return }
        model.selection = items[i].id
    }

    private func step(_ delta: Int, from center: Int, in items: [RecordItem]) {
        guard !items.isEmpty else { return }
        let target = min(max(center + delta, 0), items.count - 1)
        // Musehjul: mærkes kun med en Magic Mouse/trackpad under fingeren; ellers sker der intet.
        if target != center { Haptics.tick() }
        select(target, in: items)
    }

    /// Skubber rækken under fingrene/musen. Passerer den en halv plade, skifter midten, uden
    /// animation, så coverne bliver, hvor de er (rækken flytter sig kun med bevægelsen).
    private func pan(_ plates: Double, center: Int, items: [RecordItem]) {
        guard !items.isEmpty else { return }
        let g = CoverFlowGeometry.glide(center: center, shift: shift + plates, count: items.count)
        // Et let "klik" i trackpad'en for hver plade, der passerer midten (som hjulet på iPod'en),
        // og et tydeligere ved enden af sektionen.
        let edge = (g.center == 0 && g.shift <= -0.3) || (g.center == items.count - 1 && g.shift >= 0.3)
        if g.center != center {
            Haptics.tick()
        } else if edge && !atEdge {
            Haptics.edge()
        }
        atEdge = edge
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) {
            shift = g.shift
            if g.center != center { model.selection = items[g.center].id }
        }
    }

    /// Fingrene er løftet: coverne falder på plads med en fjeder.
    private func settle() {
        guard shift != 0 else { return }
        withAnimation(Motion.coverFlow(reduceMotion)) { shift = 0 }
    }
}

/// Selve rækken af covers.
private struct CoverFlowStrip: View {
    let items: [RecordItem]
    let center: Int
    let shift: Double
    let isAway: (Int64) -> Bool
    let onSelect: (Int) -> Void

    var body: some View {
        GeometryReader { geo in
            let side = CoverFlowGeometry.side(width: geo.size.width, height: geo.size.height)
            let range = CoverFlowGeometry.visibleRange(center: center, count: items.count)
            ZStack {
                // Identitet efter plade (ikke indeks), så et cover aldrig skifter plade undervejs.
                ForEach(Array(zip(range, items[range])), id: \.1.id) { i, item in
                    let o = Double(i - center) - shift
                    Button { onSelect(i) } label: {
                        CoverFlowCover(item: item, o: o, side: side, away: isAway(item.id))
                    }
                    .buttonStyle(.plain)
                    .zIndex(CoverFlowGeometry.zIndex(o))
                    .transition(.opacity)
                    .accessibilityLabel(item.fullName)
                    .accessibilityHint(i == center ? "Find i reolen" : "Vis pladen i midten")
                }
            }
            // Coveret står lidt over midten, så spejlingen har plads nedenunder.
            .offset(y: -side * CoverFlowGeometry.reflectionHeight / 2)
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .clipped()
    }
}

private struct CoverFlowCover: View {
    let item: RecordItem
    let o: Double
    let side: Double
    let away: Bool

    var body: some View {
        let reflection = side * CoverFlowGeometry.reflectionHeight
        CoverView(release: item.release, size: side)
            .modifier(CoverShadow())
            // Spejlingen hører til coveret, så den drejer og flytter sig med det.
            .overlay(alignment: .bottom) {
                CoverView(release: item.release, size: side)
                    .scaleEffect(x: 1, y: -1)
                    .frame(width: side, height: reflection, alignment: .top)
                    .clipped()
                    .mask {
                        LinearGradient(colors: [.black.opacity(CoverFlowGeometry.reflectionOpacity), .clear],
                                       startPoint: .top, endPoint: .bottom)
                    }
                    .offset(y: reflection + 1)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            // Plader ude af reolen er nedtonede, som i sektionslisten.
            .opacity(away ? 0.45 : 1)
            .rotation3DEffect(.degrees(CoverFlowGeometry.angle(o)), axis: (x: 0, y: 1, z: 0),
                              perspective: CoverFlowGeometry.perspective)
            .scaleEffect(CoverFlowGeometry.scale(o))
            .offset(x: CoverFlowGeometry.x(o, side: side))
    }
}

/// Titel, kunstner og nummer under midtercoveret.
private struct CoverFlowCaption: View {
    @Environment(AppModel.self) private var model
    let item: RecordItem?
    let number: Int?
    let onShelf: Int

    var body: some View {
        VStack(spacing: Spacing.xxs) {
            if let item {
                Text(item.title)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(Ink.primary)
                Text(item.artist)
                    .font(.title3)
                    .foregroundStyle(Ink.secondary)
                Text(number.map { "Nr. \($0) af \(onShelf)" } ?? item.awayMessage ?? "Ude af reolen")
                    .font(.callout)
                    .foregroundStyle(Ink.tertiary)
                    .monospacedDigit()
                Button {
                    model.findModeCopy = item.id
                } label: {
                    Label("Find i reolen", systemImage: "scope")
                }
                .buttonStyle(.stagePrimary)
                .controlSize(.large)
                .help("Find i reolen (↩ eller ⌘F)")
                .padding(.top, Spacing.xs)
            } else {
                Text("Sektionen er tom.")
                    .foregroundStyle(Ink.secondary)
            }
        }
        .lineLimit(1)
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
    }
}

/// Fanger trackpad- og musehjulsbevægelser over Cover Flow og laver dem om til trin.
/// Viewet tager ikke imod klik (`hitTest` → nil), så klik går videre til covers og knapper.
private struct ScrollWheelCatcher: NSViewRepresentable {
    /// Musehjul: hele trin.
    let onSteps: (Int) -> Void
    /// Trackpad: glidende bevægelse i punkter (positiv = mod næste plade).
    let onPan: (Double) -> Void
    /// Trackpad: fingrene er løftet.
    let onPanEnded: () -> Void

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        update(view)
        return view
    }

    func updateNSView(_ view: CatcherView, context: Context) {
        update(view)
    }

    private func update(_ view: CatcherView) {
        view.onSteps = onSteps
        view.onPan = onPan
        view.onPanEnded = onPanEnded
    }

    static func dismantleNSView(_ view: CatcherView, coordinator: ()) {
        view.stopMonitor()
    }

    final class CatcherView: NSView {
        var onSteps: ((Int) -> Void)?
        var onPan: ((Double) -> Void)?
        var onPanEnded: (() -> Void)?
        private var monitor: Any?
        private var stepper = ScrollStepper()

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        func stopMonitor() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopMonitor()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                let used = MainActor.assumeIsolated { self?.handle(event) ?? false }
                return used ? nil : event
            }
        }

        /// true, hvis bevægelsen skete over Cover Flow og er brugt.
        private func handle(_ event: NSEvent) -> Bool {
            guard event.window === window, !isHiddenOrHasHiddenAncestor,
                  bounds.contains(convert(event.locationInWindow, from: nil)) else { return false }
            // Efter at fingrene er løftet: ingen glid (ellers suser et hurtigt svirp gennem hele sektionen).
            if event.momentumPhase != [] { return true }
            let dx = Double(event.scrollingDeltaX), dy = Double(event.scrollingDeltaY)
            // Fingrene mod venstre (eller hjulet ned) → næste plade til højre.
            let delta = abs(dx) >= abs(dy) ? -dx : -dy
            guard event.hasPreciseScrollingDeltas else {
                let steps = stepper.add(delta, precise: false)
                if steps != 0 { onSteps?(steps) }
                return true
            }
            if delta != 0 { onPan?(delta) }
            if event.phase == .ended || event.phase == .cancelled { onPanEnded?() }
            return true
        }
    }
}

/// Haptisk feedback i Force Touch-trackpad'en. Mærkes kun, mens fingeren rører trackpad'en,
/// og kun hvis "Tvangsklik og haptisk feedback" er slået til i Systemindstillinger.
enum Haptics {
    /// Én plade passerer midten.
    static func tick() {
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }

    /// Enden af sektionen.
    static func edge() {
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
    }
}
