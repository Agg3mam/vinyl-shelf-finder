import SwiftUI
import AppKit
import VinylCore

/// Cover Flow som på en iPod classic: sektionens plader i reolens rækkefølge.
/// Vises i detaljekolonnen, når Cover Flow er slået til i en sektion. Midterpladen er
/// altid den valgte plade, så listen til venstre og Cover Flow følger hinanden.
/// Styres med ← →, trackpad (coverne følger fingrene, et kraftigt stryg fortsætter), musehjul,
/// træk med musen, klik på et sidecover og ↩ eller klik på midten (Find i reolen).
struct CoverFlowView: View {
    @Environment(AppModel.self) private var model
    let locationID: Int64
    /// false i snapshots: ImageRenderer kan ikke tegne AppKit-views og viser et advarselsskilt i stedet.
    var catchesScroll = true

    var body: some View {
        let items = model.library.items(in: locationID)
        // Midten udledes af valget hver gang, så den aldrig peger på en forkert plade,
        // når en sektionsgrænse flyttes, en plade flyttes, eller en sync ændrer sektionen.
        let center = items.firstIndex { $0.id == model.selection } ?? 0
        let current = items.indices.contains(center) ? items[center] : nil
        let numbers = model.library.shelfNumbers(in: locationID)
        let onShelf = model.library.onShelfCount(in: locationID)
        CoverFlowStage(items: items, center: center, catchesScroll: catchesScroll,
                       isAway: { model.isAway($0) },
                       setCenter: { model.selection = items[$0].id },
                       onOpen: { model.findModeCopy = items[$0].id }) {
            CoverFlowCaption(item: current, line: current.map { numbers[$0.id].map { "Nr. \($0) af \(onShelf)" } ?? $0.awayMessage ?? "Ude af reolen" })
        }
        .onAppear {
            // Står den valgte plade ikke i sektionen, vælges den første (som i listen).
            if current == nil || model.selection != current?.id { model.selection = items.first?.id }
        }
    }
}

/// "Hvad skal jeg høre?": hele reolen som Cover Flow. "Giv mig en plade" (eller mellemrum) får rækken til at snurre
/// hen til forslaget som et lykkehjul – hurtigt først, så bremser den op, og coveret popper, når det lander.
struct ListenCoverFlow: View {
    @Environment(AppModel.self) private var model
    /// false i snapshots (se `CoverFlowView.catchesScroll`).
    var catchesScroll = true
    @ViewState private var center = 0
    @ViewState private var spin: Int?

    var body: some View {
        let lib = model.library
        let items = lib.locations.flatMap { lib.items(in: $0.id) }
        let c = items.isEmpty ? 0 : min(max(center, 0), items.count - 1)
        let current = items.indices.contains(c) ? items[c] : nil
        CoverFlowStage(items: items, center: c, catchesScroll: catchesScroll, isAway: { model.isAway($0) },
                       setCenter: { center = $0 },
                       onOpen: { model.findModeCopy = items[$0].id },
                       spin: $spin) {
            CoverFlowCaption(item: current, line: current.map { line($0, lib) })
        }
        .onAppear {
            if let p = model.currentPick ?? model.selection, let i = items.firstIndex(where: { $0.id == p }) { center = i }
        }
        .onChange(of: model.currentPick) { _, pick in
            guard let pick, let i = items.firstIndex(where: { $0.id == pick }) else { return }
            spin = i
        }
        .onChange(of: spin == nil) { _, landed in model.wheelSpinning = !landed }
    }

    private func line(_ item: RecordItem, _ lib: Library) -> String {
        guard let loc = lib.location(of: item.id), let nr = lib.shelfNumbers(in: loc.id)[item.id] else {
            return item.awayMessage ?? "Ude af reolen"
        }
        return "\(loc.medium.shelfWord) \(loc.shelf) · Sektion \(loc.section) · Nr. \(nr) af \(lib.onShelfCount(in: loc.id))"
    }
}

/// Rækken af covers med al bevægelsen: træk med musen, trackpad, musehjul, piletaster, fart efter et kraftigt
/// stryg og (med `spin`) lykkehjulet. Hvid baggrund, sort i mørk tilstand. Samme bevægelse som telefonen.
struct CoverFlowStage<Caption: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    let items: [RecordItem]
    let center: Int
    var catchesScroll = true
    let isAway: (Int64) -> Bool
    /// Midten skifter (under et glid uden animation).
    let setCenter: (Int) -> Void
    /// Klik eller ↩ på midtercoveret.
    let onOpen: (Int) -> Void
    /// Sæt til en plade (indeks), så snurrer rækken derhen; sættes til nil, når den er landet.
    var spin: Binding<Int?> = .constant(nil)
    @ViewBuilder let caption: () -> Caption

    @FocusState private var focused: Bool
    /// Hvor langt rækken er skubbet under en trackpad- eller musebevægelse (i plader).
    @ViewState private var shift = 0.0
    @ViewState private var lastDrag: CGFloat = 0
    @ViewState private var stripWidth: CGFloat = 0
    /// Står rækken mod enden af sektionen (så enden kun mærkes én gang pr. skub).
    @ViewState private var atEdge = false
    /// Et glid efter et kraftigt stryg eller lykkehjulet.
    @ViewState private var glideTask: Task<Void, Never>?
    /// Midtercoveret "popper" kort, når forslaget er fundet.
    @ViewState private var pop = false

    var body: some View {
        VStack(spacing: Spacing.l) {
            Spacer(minLength: 0)
            CoverFlowStrip(items: items, center: center, shift: shift, pop: pop, isAway: isAway) { i in
                stopGlide()
                if i == center { onOpen(i) } else { setCenter(i) }
            }
            .frame(maxHeight: 460)
            .animation(glideTask == nil ? Motion.coverFlow(reduceMotion) : nil, value: center)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { stripWidth = $0 }
            .simultaneousGesture(DragGesture(minimumDistance: 6)
                .onChanged { v in
                    if lastDrag == 0 { stopGlide() }
                    let delta = v.translation.width - lastDrag
                    lastDrag = v.translation.width
                    // Rækken følger musen: ét cover pr. stak-afstand.
                    pan(-Double(delta) / dragPointsPerCover)
                }
                .onEnded { v in
                    lastDrag = 0
                    fling(-Double(v.velocity.width) / dragPointsPerCover)
                })
            caption()
                .animation(Motion.fade(reduceMotion), value: items.indices.contains(center) ? items[center].id : nil)
            Spacer(minLength: 0)
        }
        .padding(Spacing.l)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            if catchesScroll {
                ScrollWheelCatcher(
                    onSteps: { step($0) },
                    onPanBegan: { stopGlide() },
                    onPan: { pan($0 / CoverFlowView.trackpadPointsPerCover) },
                    onPanEnded: { fling($0 / CoverFlowView.trackpadPointsPerCover) })
            }
        }
        // Hvid baggrund i lys tilstand og sort i mørk (ikke tonet efter coveret). Samme på Windows og telefonen.
        .environment(\.coverTone, .coverFlow)
        .tint(CoverTone.coverFlow.accent)
        .background((colorScheme == .dark ? Color.black : Color.white).ignoresSafeArea())
        // Fokus kun ved klik, så ↑↓ i listen til venstre stadig virker efter skift af sektion.
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(.leftArrow) { step(-1); return .handled }
        .onKeyPress(.rightArrow) { step(1); return .handled }
        .onKeyPress(.upArrow) { step(-1); return .handled }
        .onKeyPress(.downArrow) { step(1); return .handled }
        .onKeyPress(.return) {
            if items.indices.contains(center) { onOpen(center) }
            return .handled
        }
        .onChange(of: spin.wrappedValue) { _, target in if let target { startSpin(to: target) } }
        .onDisappear { glideTask?.cancel(); glideTask = nil; if spin.wrappedValue != nil { spin.wrappedValue = nil } }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Cover Flow")
    }

    /// Træk med musen: ét cover pr. afstand mellem de stablede sidecovers.
    private var dragPointsPerCover: Double {
        let side = CoverFlowGeometry.side(width: Double(stripWidth), height: 460)
        return max(24, side * 0.25)
    }

    private func step(_ delta: Int) {
        guard !items.isEmpty else { return }
        stopGlide()
        let target = min(max(center + delta, 0), items.count - 1)
        // Musehjul: mærkes kun med en Magic Mouse/trackpad under fingeren; ellers sker der intet.
        if target != center { Haptics.tick() }
        setCenter(target)
    }

    /// Skubber rækken under fingrene/musen. Passerer den en halv plade, skifter midten, uden
    /// animation, så coverne bliver, hvor de er (rækken flytter sig kun med bevægelsen).
    private func pan(_ plates: Double) {
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
            if g.center != center { setCenter(g.center) }
        }
    }

    /// Fingrene er løftet: et kraftigt stryg fortsætter med farten og bremser op; ellers falder coverne på plads.
    /// `velocity` er i plader pr. sekund.
    private func fling(_ velocity: Double) {
        if !reduceMotion, let f = CoverFlowGeometry.fling(from: Double(center) + shift, velocity: velocity, count: items.count) {
            glide(to: f.target, duration: f.duration, landing: false)
        } else if shift != 0 {
            withAnimation(Motion.coverFlow(reduceMotion)) { shift = 0 }
        }
    }

    /// Lykkehjulet: snurrer hen til pladen `target` i én blød bevægelse.
    private func startSpin(to target: Int) {
        guard items.indices.contains(target) else { spin.wrappedValue = nil; return }
        let total = Double(target) - (Double(center) + shift)
        if reduceMotion || abs(total) < 0.5 {
            stopGlide()
            setCenter(target)
            shift = 0
            landed()
            return
        }
        glide(to: target, duration: CoverFlowGeometry.spinDuration(distance: total), landing: true)
    }

    /// Rækken glider hen til `target`: hurtigt først, bremser jævnt op. Et klik i trackpad'en for hver plade, der
    /// passerer midten (højst ét pr. 35 ms; det mærkes kun, mens en finger hviler på trackpad'en).
    private func glide(to target: Int, duration: Double, landing: Bool) {
        glideTask?.cancel()
        let from = Double(center) + shift
        let total = Double(target) - from
        let count = items.count
        glideTask = Task { @MainActor in
            let clock = ContinuousClock(), begin = clock.now
            var lastTick = begin - .seconds(1)
            var c = center
            while !Task.isCancelled {
                let t = min(1, (clock.now - begin) / .seconds(duration))
                let pos = from + total * CoverFlowGeometry.easeOut(t)
                let next = min(max(Int(pos.rounded()), 0), count - 1)
                var tr = Transaction()
                tr.disablesAnimations = true
                withTransaction(tr) {
                    if next != c {
                        if clock.now - lastTick >= .milliseconds(35) { Haptics.tick(); lastTick = clock.now }
                        c = next
                        setCenter(next)
                    }
                    shift = pos - Double(next)
                }
                if t >= 1 { break }
                try? await Task.sleep(for: .milliseconds(8))
            }
            guard !Task.isCancelled else { return }
            shift = 0
            glideTask = nil
            if landing { landed() }
        }
    }

    /// En finger, et klik eller en tast stopper et glid, der er i gang (lykkehjulet lander straks).
    private func stopGlide() {
        guard let task = glideTask else { return }
        task.cancel()
        glideTask = nil
        if let target = spin.wrappedValue {
            setCenter(target)
            withAnimation(Motion.coverFlow(reduceMotion)) { shift = 0 }
            spin.wrappedValue = nil
        } else if shift != 0 {
            withAnimation(Motion.coverFlow(reduceMotion)) { shift = 0 }
        }
    }

    private func landed() {
        spin.wrappedValue = nil
        Haptics.edge()
        guard !reduceMotion else { return }
        withAnimation(.spring(response: 0.22, dampingFraction: 0.5)) { pop = true }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(220))
            withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) { pop = false }
        }
    }
}

extension CoverFlowView {
    /// Trackpad: så mange punkters fingerbevægelse flytter én plade.
    static let trackpadPointsPerCover = 36.0
}

/// Selve rækken af covers.
private struct CoverFlowStrip: View {
    let items: [RecordItem]
    let center: Int
    let shift: Double
    var pop = false
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
                            .scaleEffect(pop && i == center ? 1.07 : 1)
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

/// Titel, kunstner og en linje (nummer i sektionen, eller hvor pladen står) under midtercoveret.
private struct CoverFlowCaption: View {
    @Environment(AppModel.self) private var model
    let item: RecordItem?
    let line: String?

    var body: some View {
        VStack(spacing: Spacing.xxs) {
            if let item {
                Text(item.title)
                    .font(.title2.weight(.semibold))
                    .fontDesign(model.lookStyle.serifTitles ? .serif : nil)
                    .foregroundStyle(Ink.primary)
                Text(item.artist)
                    .font(.title3)
                    .foregroundStyle(Ink.secondary)
                Text(line ?? "")
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
    /// Trackpad: fingrene rører trackpad'en (stopper et glid).
    let onPanBegan: () -> Void
    /// Trackpad: glidende bevægelse i punkter (positiv = mod næste plade).
    let onPan: (Double) -> Void
    /// Trackpad: fingrene er løftet, med farten lige før (punkter pr. sekund).
    let onPanEnded: (Double) -> Void

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
        view.onPanBegan = onPanBegan
        view.onPan = onPan
        view.onPanEnded = onPanEnded
    }

    static func dismantleNSView(_ view: CatcherView, coordinator: ()) {
        view.stopMonitor()
    }

    final class CatcherView: NSView {
        var onSteps: ((Int) -> Void)?
        var onPanBegan: (() -> Void)?
        var onPan: ((Double) -> Void)?
        var onPanEnded: ((Double) -> Void)?
        private var monitor: Any?
        private var stepper = ScrollStepper()
        /// Fingrenes bevægelse de sidste 100 ms (tid, punkter), til farten når de løftes.
        private var samples: [(t: TimeInterval, d: Double)] = []

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
            // Efter at fingrene er løftet, sender macOS sin egen fart; den bruges ikke, for Cover Flow glider selv
            // videre med samme kurve som telefonen (ellers suser et hurtigt svirp gennem hele sektionen).
            if event.momentumPhase != [] { return true }
            let dx = Double(event.scrollingDeltaX), dy = Double(event.scrollingDeltaY)
            // Fingrene mod venstre (eller hjulet ned) → næste plade til højre.
            let delta = abs(dx) >= abs(dy) ? -dx : -dy
            guard event.hasPreciseScrollingDeltas else {
                let steps = stepper.add(delta, precise: false)
                if steps != 0 { onSteps?(steps) }
                return true
            }
            if event.phase == .began || event.phase == .mayBegin { samples = []; onPanBegan?() }
            if delta != 0 {
                samples.append((event.timestamp, delta))
                samples.removeAll { event.timestamp - $0.t > 0.1 }
                onPan?(delta)
            }
            if event.phase == .ended || event.phase == .cancelled {
                // Farten de sidste 100 ms. Har fingrene stået stille et øjeblik før de løftes, er der ingen fart.
                let recent = samples.filter { event.timestamp - $0.t <= 0.1 }
                let span = (recent.last?.t ?? 0) - (recent.first?.t ?? 0)
                let velocity = recent.count >= 2 && span > 0.01 ? recent.dropFirst().reduce(0) { $0 + $1.d } / span : 0
                samples = []
                onPanEnded?(event.phase == .cancelled ? 0 : velocity)
            }
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
