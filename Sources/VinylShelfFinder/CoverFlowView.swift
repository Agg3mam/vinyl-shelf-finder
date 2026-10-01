import SwiftUI
import AppKit
import VinylCore

/// Cover Flow som på en iPod classic: sektionens plader i reolens rækkefølge.
/// Vises i detaljekolonnen, når Cover Flow er slået til i en sektion. Midterpladen er
/// altid den valgte plade, så listen til venstre og Cover Flow følger hinanden.
/// Styres med ← →, trackpad/musehjul, klik på et sidecover og ↩ (Find i reolen).
struct CoverFlowView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let locationID: Int64
    @FocusState private var focused: Bool

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
            CoverFlowStrip(items: items, center: center, isAway: { model.isAway($0) }) { i in
                if i == center { model.findModeCopy = items[i].id } else { select(i, in: items) }
            }
            .frame(maxHeight: 440)
            .animation(Motion.move(reduceMotion), value: center)
            CoverFlowCaption(item: current, number: current.flatMap { numbers[$0.id] }, onShelf: onShelf)
            Spacer(minLength: 0)
        }
        .padding(Spacing.l)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ScrollWheelCatcher { step($0, from: center, in: items) })
        .recordStage(current?.release)
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

    private func select(_ i: Int, in items: [RecordItem]) {
        guard items.indices.contains(i) else { return }
        model.selection = items[i].id
    }

    private func step(_ delta: Int, from center: Int, in items: [RecordItem]) {
        guard !items.isEmpty else { return }
        select(min(max(center + delta, 0), items.count - 1), in: items)
    }
}

/// Selve rækken af covers.
private struct CoverFlowStrip: View {
    let items: [RecordItem]
    let center: Int
    let isAway: (Int64) -> Bool
    let onSelect: (Int) -> Void

    var body: some View {
        GeometryReader { geo in
            let side = CoverFlowGeometry.side(width: geo.size.width, height: geo.size.height)
            let range = CoverFlowGeometry.visibleRange(center: center, count: items.count)
            ZStack {
                // Identitet efter plade (ikke indeks), så et cover aldrig skifter plade undervejs.
                ForEach(Array(zip(range, items[range])), id: \.1.id) { i, item in
                    Button { onSelect(i) } label: {
                        CoverFlowCover(item: item, d: i - center, side: side, away: isAway(item.id))
                    }
                    .buttonStyle(.plain)
                    .zIndex(CoverFlowGeometry.zIndex(i - center))
                    .transition(.opacity)
                    .accessibilityLabel(item.fullName)
                    .accessibilityHint(i == center ? "Find i reolen" : "Vis pladen i midten")
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .clipped()
    }
}

private struct CoverFlowCover: View {
    let item: RecordItem
    let d: Int
    let side: Double
    let away: Bool

    var body: some View {
        CoverView(release: item.release, size: side)
            .modifier(CoverShadow())
            // Plader ude af reolen er nedtonede, som i sektionslisten.
            .opacity(away ? 0.45 : 1)
            .rotation3DEffect(.degrees(CoverFlowGeometry.angle(d)), axis: (x: 0, y: 1, z: 0), perspective: 0.5)
            .scaleEffect(CoverFlowGeometry.scale(d))
            .offset(x: CoverFlowGeometry.x(d, side: side))
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
    let onSteps: (Int) -> Void

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.onSteps = onSteps
        return view
    }

    func updateNSView(_ view: CatcherView, context: Context) {
        view.onSteps = onSteps
    }

    static func dismantleNSView(_ view: CatcherView, coordinator: ()) {
        view.stopMonitor()
    }

    final class CatcherView: NSView {
        var onSteps: ((Int) -> Void)?
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
            // Efter at fingrene er løftet: ingen flere trin (ellers suser et hurtigt svirp gennem hele sektionen).
            if event.momentumPhase != [] { return true }
            if event.phase == .began { stepper.reset() }
            let dx = Double(event.scrollingDeltaX), dy = Double(event.scrollingDeltaY)
            // Fingrene mod venstre (eller hjulet ned) → næste plade til højre.
            let delta = abs(dx) >= abs(dy) ? -dx : -dy
            let steps = stepper.add(delta, precise: event.hasPreciseScrollingDeltas)
            if steps != 0 { onSteps?(steps) }
            return true
        }
    }
}
