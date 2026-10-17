import SwiftUI
import VinylCore

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Group {
            if model.needsOnboarding {
                OnboardingView()
            } else {
                MainView()
            }
        }
        .onOpenURL { model.open($0) }
        .modifier(UpdatePrompt())
        .task {
            if model.needsRankSync { await model.sync(showReport: false) }
        }
        .alert("Der opstod en fejl", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .appRoot()
    }
}

// MARK: - Fælles rod: dansk og fast accentfarve

/// Appens accentfarve på systemskærmene: en rolig blågrøn i stedet for systemblå.
/// Pladeskærmene (mørke, med cover) sætter selv deres egen tone indeni.
enum AppAccent {
    /// Til knapper, kontakter, ikoner og links. Lys: 6:1 mod hvid. Mørk: 5:1 mod
    /// vinduets baggrund og 3,3:1 for hvid tekst på knapper (som systemblå).
    static let color = Color(nsColor: dynamic(light: 0x1C6E66, dark: 0x2E9D8F))
    /// Til tekst på en svag accentflade (fx placeringsmærket "2A"). Lysere i mørk tilstand.
    static let ink = Color(nsColor: dynamic(light: 0x1C6E66, dark: 0x5EC4B6))

    private static func dynamic(light: UInt32, dark: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return rgb(isDark ? dark : light)
        }
    }

    private static func rgb(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

extension View {
    /// Sættes i roden af hvert vindue (hovedvindue og Indstillinger): dansk sprog til
    /// datoer/tal og appens accentfarve.
    func appRoot() -> some View {
        self
            .environment(\.locale, Locale(identifier: "da_DK"))
            .tint(AppAccent.color)
    }
}

struct MainView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 190, ideal: 220)
        } content: {
            ContentColumn()
                .navigationSplitViewColumnWidth(min: 300, ideal: 360)
        } detail: {
            DetailColumn()
        }
        .toolbar {
            if model.showsMediumPicker {
                ToolbarItem(placement: .principal) { MediumPicker() }
            }
            ToolbarItem(placement: .primaryAction) { SyncButton() }
        }
        .modifier(MainSheets())
        .modifier(StatusNoteAlert())
    }
}

/// Spørger efter navn ("Udlånt") eller sted ("Opbevaret andet sted"), når status
/// vælges i en højrekliksmenu. Samme tekster som menuen i plade-detaljen.
struct StatusNoteAlert: ViewModifier {
    @Environment(AppModel.self) private var model
    @ViewState private var note = ""

    func body(content: Content) -> some View {
        let request = model.statusNoteRequest
        let lent = request?.status == .lent
        return content
            .alert(lent ? "Hvem har lånt pladen?" : "Hvor er pladen?",
                   isPresented: Binding(get: { model.statusNoteRequest != nil },
                                        set: { if !$0 { model.statusNoteRequest = nil } })) {
                TextField(lent ? "Navn" : "Sted", text: $note)
                Button("Gem") {
                    if let r = model.statusNoteRequest { model.setStatus(r.copyID, r.status, note: note) }
                    model.statusNoteRequest = nil
                }
                Button("Annullér", role: .cancel) { model.statusNoteRequest = nil }
            }
            .onChange(of: request) { _, new in note = new?.note ?? "" }
    }
}

/// "Plader / Cd'er" øverst i vinduet. Hver hylde har sine egne reoler og sektioner.
struct MediumPicker: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Picker("Hylde", selection: $model.medium) {
            ForEach(Medium.allCases) { m in
                Text(m.title).tag(m)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .help("Skift mellem pladereolerne og cd-reolerne")
    }
}

struct ContentColumn: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        switch model.sidebar ?? .search {
        case .search:
            SearchResultsView()
        case .newRecords:
            let items = model.unplacedItems
            let m = model.medium
            RecordListView(title: "Nye \(m.plural)", items: items,
                           empty: "Ingen nye \(m.plural) venter på en plads.",
                           headerAction: items.isEmpty ? nil : HeaderAction(label: "Placér alle som foreslået") { model.placeAllAsSuggested() },
                           emptySymbol: "tray")
        case .removed:
            RecordListView(title: "Fjernet fra Discogs", items: model.removedItems,
                           empty: "Alle \(model.medium.plural) findes stadig i din Discogs-samling.")
        case .away:
            RecordListView(title: "Ude af reolen", items: model.awayItems,
                           empty: "Alle \(model.medium.plural) står på plads.", emptySymbol: "house")
        case .section(let id):
            SectionView(locationID: id)
                .id(id)
        case .history:
            HistoryView()
                .animation(Motion.rows(reduceMotion), value: model.library.globalOrder)
        case .value:
            ValueView()
        case .listen:
            ListenView()
        case .plays:
            PlaysView()
        case .findNew:
            FindNewSearchView()
        }
    }
}

struct DetailColumn: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if case .findNew = model.sidebar ?? .search {
            FindNewDetailColumn()
        } else if case .history = model.sidebar ?? .search {
            ContentUnavailableView("Historik", systemImage: "clock.arrow.circlepath",
                                   description: Text("Flytninger kan fortrydes direkte i listen."))
        } else if case .section(let id) = model.sidebar ?? .search, model.showCoverFlow,
                  model.library.location(id) != nil {
            // Cover Flow: sektionen i reolens rækkefølge. Valget følger listen til venstre.
            CoverFlowView(locationID: id)
                .id(id)
        } else if let sel = model.selection, model.library.item(sel) != nil {
            // Ingen `.id(sel)`: detaljen beholder sin identitet ved skift af plade, så
            // SwiftUI kun opdaterer forskellen (hurtigere ↑↓, og farvetonen kan tone over).
            RecordDetailView(copyID: sel)
        } else if case .listen = model.sidebar ?? .search {
            ContentUnavailableView {
                Label("Intet forslag endnu", systemImage: "dice")
            } description: {
                Text("Tryk “Giv mig en plade” eller mellemrum.")
            }
        } else {
            ContentUnavailableView {
                Label("Find en plade", systemImage: "opticaldisc")
            } description: {
                Text("Tryk ⌘K og skriv kunstner, titel eller katalognummer.")
            }
        }
    }
}

struct MainSheets: ViewModifier {
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        @Bindable var model = model
        return content
            .sheet(item: idBinding(\.findModeCopy)) { box in FindModeView(copyID: box.id) }
            .sheet(item: idBinding(\.returnCopy)) { box in FindModeView(copyID: box.id, putBack: true) }
            .sheet(item: idBinding(\.moveCopy)) { box in MoveSheet(copyID: box.id) }
            .sheet(item: idBinding(\.checkSection)) { box in CheckShelfView(locationID: box.id) }
            .sheet(isPresented: $model.showSyncReport) { SyncReportView() }
    }

    private func idBinding(_ path: ReferenceWritableKeyPath<AppModel, Int64?>) -> Binding<IDBox?> {
        let model = model
        return Binding(get: { model[keyPath: path].map(IDBox.init) },
                       set: { model[keyPath: path] = $0?.id })
    }
}

struct IDBox: Identifiable { let id: Int64 }

struct SyncButton: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Kort bekræftelse (flueben) lige efter en sync, der lykkedes.
    @ViewState private var justFinished = false

    var body: some View {
        content
            .animation(Motion.state(reduceMotion), value: model.syncState.phase)
            .onChange(of: model.syncState.phase) { old, new in
                justFinished = old == .running && new == .idle
            }
            .task(id: justFinished) {
                guard justFinished else { return }
                try? await Task.sleep(for: .seconds(2))
                justFinished = false
            }
    }

    @ViewBuilder private var content: some View {
        switch model.syncState {
        case .running(let done, let total):
            HStack(spacing: Spacing.xs) {
                // Roterende symbol i stedet for en spinner. Med Reduce Motion står det stille.
                Image(systemName: "arrow.triangle.2.circlepath")
                    .symbolEffect(.rotate, options: .repeat(.continuous), isActive: !reduceMotion)
                    .foregroundStyle(.secondary)
                Text(total > 0 ? "\(done)/\(total)" : "Henter…").monospacedDigit().foregroundStyle(.secondary)
                    .contentTransition(Motion.numberTransition(reduceMotion))
                    .animation(Motion.number(reduceMotion), value: done)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(total > 0 ? "Synkroniserer, \(done) af \(total)" : "Synkroniserer")
            .transition(.opacity)
        case .failed(let msg):
            Button { Task { await model.sync() } } label: {
                Label("Synkronisering fejlede", systemImage: "exclamationmark.triangle")
            }
            .help(msg)
            .disabled(!model.hasToken)
            .transition(.opacity)
        case .idle:
            Button { Task { await model.sync() } } label: {
                Label(justFinished ? "Synkroniseret" : "Synkronisér",
                      systemImage: justFinished ? "checkmark.circle" : "arrow.triangle.2.circlepath")
                    .contentTransition(reduceMotion ? .opacity : .symbolEffect(.replace))
                    .animation(Motion.state(reduceMotion), value: justFinished)
            }
            .disabled(!model.hasToken)
            .help(model.hasToken
                  ? (model.lastSync.map { "Sidst synkroniseret \($0.danskDatoTid) (⌘R)" } ?? "Synkronisér med Discogs (⌘R)")
                  : "Forbind til Discogs i Indstillinger for at synkronisere")
            .transition(.opacity)
        }
    }
}

struct SidebarView: View {
    @Environment(AppModel.self) private var model

    /// Sidepanelets ikoner følger ellers systemets accentfarve (blå), ikke `.tint`.
    private func sidebarLabel(_ title: String, _ symbol: String) -> some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: symbol).foregroundStyle(AppAccent.color)
        }
    }

    var body: some View {
        @Bindable var model = model
        List(selection: $model.sidebar) {
            sidebarLabel("Søg", "magnifyingglass").tag(SidebarItem.search)
            sidebarLabel("Værdi", "chart.line.uptrend.xyaxis").tag(SidebarItem.value)

            Section("Discogs") {
                sidebarLabel("Find nye plader", "bag").tag(SidebarItem.findNew)
            }

            Section("Lytning") {
                sidebarLabel("Hvad skal jeg høre?", "dice").tag(SidebarItem.listen)
                sidebarLabel("Lyttelog", "music.note.list")
                    .badge(model.stats.plays.count)
                    .tag(SidebarItem.plays)
            }

            Section("Indbakke") {
                sidebarLabel("Nye \(model.medium.plural)", "sparkles")
                    .badge(model.library.unplaced.count)
                    .tag(SidebarItem.newRecords)
                sidebarLabel("Fjernet fra Discogs", "exclamationmark.triangle")
                    .badge(model.removedItems.count)
                    .tag(SidebarItem.removed)
                sidebarLabel("Ude af reolen", "shippingbox")
                    .badge(model.awayItems.count)
                    .tag(SidebarItem.away)
            }

            ForEach(model.library.shelves, id: \.self) { shelf in
                Section("\(model.medium.shelfWord) \(shelf)") {
                    ForEach(model.library.locations.filter { $0.shelf == shelf }) { loc in
                        sidebarLabel("Sektion \(loc.section)", "books.vertical")
                            // Kun plader, der faktisk står i reolen (ikke dem på væggen, udlånte osv.).
                            .badge(model.library.onShelfCount(in: loc.id))
                            .tag(SidebarItem.section(loc.id))
                            .contextMenu {
                                Button("Kontrollér sektion…") { model.checkSection = loc.id }
                                Button("Tilføj sektion i \(model.medium.shelfWord) \(shelf)") { model.addSection(shelf: shelf) }
                                if (model.library.sections[loc.id] ?? []).isEmpty {
                                    Button("Slet tom sektion", role: .destructive) { model.deleteSection(loc.id) }
                                }
                            }
                    }
                }
            }

            Section {
                sidebarLabel("Historik", "clock.arrow.circlepath").tag(SidebarItem.history)
            }
        }
        .listStyle(.sidebar)
        .onChange(of: model.sidebar) { _, new in
            // Ryd valg der ikke hører til den nye liste.
            if case .search = new ?? .search { if let s = model.selection, !model.results.contains(s) { model.selection = model.results.first } }
        }
    }
}
