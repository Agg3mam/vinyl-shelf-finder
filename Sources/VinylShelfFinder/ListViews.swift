import SwiftUI
import VinylCore

struct SearchResultsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var searchFocused: Bool

    private enum Phase { case prompt, noResults, results }

    private var phase: Phase {
        if model.query.isEmpty { return .prompt }
        return model.results.isEmpty ? .noResults : .results
    }

    /// Listen er altid monteret (bare skjult uden resultater). Ellers skulle hele
    /// tabellen bygges op ved første tastetryk, hvilket gav en mærkbar forsinkelse.
    private var resultsArea: some View {
        ZStack {
            resultsList
                .opacity(phase == .results ? 1 : 0)
                .allowsHitTesting(phase == .results)
                .accessibilityHidden(phase != .results)
            emptyState
        }
    }

    @ViewBuilder private var emptyState: some View {
        switch phase {
        case .prompt:
            ContentUnavailableView {
                Label(pladerText(model.library.copies.count), systemImage: "opticaldisc")
            } description: {
                Text("Skriv for at søge. ↑↓ vælger, ↩ åbner “Find i reolen”, esc rydder.")
            }
            .transition(.opacity)
        case .noResults:
            // Egen tekst i stedet for `.search(text:)`, som er på engelsk, når appen
            // ikke kører som .app med dansk sprog.
            ContentUnavailableView {
                Label("Ingen resultater", systemImage: "magnifyingglass")
            } description: {
                Text("Ingen plader matcher “\(model.query.trimmingCharacters(in: .whitespaces))”. Prøv med færre ord, eller søg på katalognummer.")
            }
            .transition(.opacity)
        case .results:
            EmptyView()
        }
    }

    /// Valget skrives kun tilbage, når det faktisk ændres. Tabellen melder samme valg
    /// tilbage, mens den opdaterer rækker; et ekstra skriv ville starte en ny opdatering
    /// midt i tabellens egen (AppKit: "reentrant operation").
    private var selectionBinding: Binding<Int64?> {
        let model = model
        return Binding(get: { model.selection },
                       set: { if $0 != model.selection { model.selection = $0 } })
    }

    private var resultsList: some View {
        List(model.results, id: \.self, selection: selectionBinding) { id in
            if let it = model.library.item(id) {
                VStack(alignment: .leading, spacing: 2) {
                    RecordRow(item: it, showLocation: true)
                    if let t = model.resultTracks[id] { SongLine(track: t) }
                }
            }
        }
        .listStyle(.inset)
        // 1 pt luft, så listen ikke rører værktøjslinjen (ellers et hvidt bånd over den mørke detalje).
        .padding(.top, 1)
        // Rækker, der kommer og går under søgning, glider blødt. Værdien er kun
        // resultatlisten, så ↑↓ (der ændrer valget) aldrig venter på en animation.
        .animation(Motion.rows(reduceMotion), value: model.results)
        .onKeyPress(.return) {
            if let s = model.selection { model.findModeCopy = s }
            return .handled
        }
    }

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            HStack(spacing: Spacing.xs) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Kunstner, titel, label, katalognr. …", text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($searchFocused)
                    .onKeyPress(.downArrow) { model.moveSelection(by: 1); return .handled }
                    .onKeyPress(.upArrow) { model.moveSelection(by: -1); return .handled }
                    .onKeyPress(.return) {
                        if let s = model.selection { model.findModeCopy = s }
                        return .handled
                    }
                    .onKeyPress(.escape) { model.query = ""; return .handled }
                    // Reserve: på macOS kan feltets editor selv tage ↩ (onSubmit fyrer da i stedet).
                    .onSubmit { if let s = model.selection { model.findModeCopy = s } }
                if !model.query.isEmpty {
                    Button { model.query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                        .accessibilityLabel("Ryd søgning")
                        .help("Ryd søgning (esc)")
                }
                Text("⌘K").font(.caption).foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .padding(Spacing.s)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .padding(Spacing.s)

            resultsArea
                // Kun skift mellem tom tilstand / ingen resultater / liste toner. Rækkerne
                // animeres i selve listen (se `resultsList`).
                .animation(Motion.state(reduceMotion), value: phase)
        }
        .navigationTitle("Søg")
        .onAppear { searchFocused = true }
        .onChange(of: model.focusSearchRequest) { searchFocused = true }
    }
}

struct RecordListView: View {
    @Environment(AppModel.self) private var model
    let title: String
    let items: [RecordItem]
    let empty: String
    var headerAction: HeaderAction? = nil
    var emptySymbol = "checkmark.circle"
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        @Bindable var model = model
        Group {
            if items.isEmpty {
                ContentUnavailableView(title, systemImage: emptySymbol, description: Text(empty))
                    .transition(.opacity)
            } else {
                List(selection: $model.selection) {
                    if let headerAction {
                        Button(headerAction.label, action: headerAction.action)
                            .buttonStyle(.borderedProminent)
                            .padding(.vertical, Spacing.xxs)
                    }
                    ForEach(items) { it in
                        RecordRow(item: it, showLocation: true).tag(it.id)
                    }
                }
                .listStyle(.inset)
                // Plader, der får en plads, glider ud af listen.
                .animation(Motion.rows(reduceMotion), value: items.map(\.id))
                .transition(.opacity)
            }
        }
        // Den tomme tilstand toner ind, når den sidste plade er placeret.
        .animation(Motion.state(reduceMotion), value: items.isEmpty)
        .navigationTitle(title)
        .onAppear {
            if let s = model.selection, items.contains(where: { $0.id == s }) { return }
            model.selection = items.first?.id
        }
    }
}

struct HeaderAction {
    let label: String
    let action: () -> Void
}

struct RecordRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let item: RecordItem
    var showLocation = false
    var number: Int? = nil
    /// Sektionslisten: der er altid en talkolonne, også for plader uden nummer
    /// (dem, der er ude af reolen), så rækkerne flugter.
    var numberColumn = false
    var warning: Bool = false
    /// Nedton plader, der ikke står i reolen (bruges i sektionslisten).
    var dimAway = false
    /// Ekstra punkter i højrekliksmenuen (fx sektionsgrænser). Et ekstra `.contextMenu`
    /// uden på rækken vises ikke, fordi rækkens egen menu vinder.
    var extraMenu: AnyView? = nil

    private var dimmed: Bool { dimAway && item.copy.status != .home }

    var body: some View {
        HStack(spacing: Spacing.s) {
            if numberColumn || number != nil {
                numberLabel
            }
            CoverView(release: item.release, size: model.lookStyle.bigCovers ? 52 : 38)
                .opacity(dimmed ? 0.45 : 1)
                .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
            VStack(alignment: .leading, spacing: 2) {
                // Én tekst, der må bryde over to linjer: kunstner og titel klippes ikke,
                // før detaljelinjen gør (den har lavere prioritet).
                Text("\(Text(item.artist).fontWeight(.semibold)) \(Text("–").foregroundStyle(.secondary)) \(item.title)")
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .layoutPriority(1)
                    .opacity(dimmed ? 0.55 : 1)
                if item.copy.status != .home {
                    Label(item.copy.status.listText(note: item.copy.statusNote), systemImage: item.copy.status.symbol)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Text(item.detailLine).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    .opacity(dimmed ? 0.55 : 1)
            }
            Spacer(minLength: Spacing.xxs)
            if warning {
                Image(systemName: "arrow.left.arrow.right")
                    .foregroundStyle(.orange)
                    .help("Står ikke i forventet sorteringsrækkefølge")
                    .accessibilityLabel("Står ikke i forventet sorteringsrækkefølge")
            }
            if !item.copy.inDiscogs {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                    .help("Ikke længere i din Discogs-samling")
                    .accessibilityLabel("Ikke længere i din Discogs-samling")
            }
            if showLocation {
                if let loc = model.library.location(of: item.id) {
                    LocationBadge(text: loc.shortName)
                        .help(loc.name)
                        .accessibilityLabel(loc.name)
                } else {
                    LocationBadge(text: "Ny", tint: .orange)
                        .help("Har endnu ingen plads i reolen")
                }
            }
        }
        .padding(.vertical, 2)
        // Når en plade går ud eller kommer tilbage, toner nedtoningen og statuslinjen blødt
        // (numrene ruller diskret i `numberLabel`; ingen rul ved "Reducér bevægelse").
        .animation(Motion.fade(reduceMotion), value: dimmed)
        .contextMenu {
            RecordContextMenu(copyID: item.id)
            if let extraMenu {
                Divider()
                extraMenu
            }
        }
    }
}

extension RecordRow {
    /// Pladens fysiske nummer i sektionen. Tom for plader, der ikke står i reolen.
    private var numberLabel: some View {
        Text(number.map(String.init) ?? "")
            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            .contentTransition(Motion.numberTransition(reduceMotion))
            .animation(Motion.number(reduceMotion), value: number)
            .frame(width: 34, alignment: .trailing)
            .accessibilityLabel(number.map { "Nummer \($0) i reolen" } ?? "Står ikke i reolen")
    }
}

/// Det lille placeringsmærke ("2A"/"Ny"). Ét udseende overalt.
struct LocationBadge: View {
    let text: String
    var tint: Color? = nil

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold).monospaced())
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 6).padding(.vertical, 2)
            .foregroundStyle(tint ?? AppAccent.ink)
            .background((tint ?? AppAccent.color).opacity(0.15), in: Capsule())
    }
}

/// "1 plade" / "2 plader".
func pladerText(_ n: Int) -> String { n == 1 ? "1 plade" : "\(n) plader" }

struct RecordContextMenu: View {
    @Environment(AppModel.self) private var model
    let copyID: Int64

    var body: some View {
        Button("Find i reolen") { model.selection = copyID; model.findModeCopy = copyID }
        if model.isAway(copyID) {
            // Lige ved hånden i "Ude af reolen": guiden viser, hvor pladen skal stå.
            Button("Sæt tilbage på plads…") { model.selection = copyID; model.startReturn(copyID) }
        }
        Button("Flyt…") { model.moveCopy = copyID }
        Menu("Status") {
            StatusChoices(copyID: copyID)
        }
        MediumChoice(copyID: copyID)
        if let it = model.library.item(copyID) {
            Divider()
            Link("Åbn på Discogs", destination: it.release.discogsURL)
        }
    }
}

/// "Flyt til cd-hylden" / "Flyt til pladehylden", når Discogs' format ikke passer (fx en boks,
/// der i virkeligheden står blandt cd'erne). Med eget valg: også "Følg Discogs' format".
struct MediumChoice: View {
    @Environment(AppModel.self) private var model
    let copyID: Int64

    var body: some View {
        if let it = model.library.item(copyID) {
            let other: Medium = it.medium == .vinyl ? .cd : .vinyl
            Button(other == .cd ? "Flyt til cd-hylden" : "Flyt til pladehylden") { model.setMedium(copyID, other) }
            if it.copy.mediumOverride != nil, Medium.of(format: it.release.format) != it.medium {
                Button("Følg Discogs' format (\(Medium.of(format: it.release.format).singular))") { model.setMedium(copyID, nil) }
            }
        }
    }
}

// MARK: - Sektion ("Jeg står her")

struct SectionView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let locationID: Int64

    var body: some View {
        let items = model.library.items(in: locationID)
        let outOfOrder = model.library.outOfOrder(in: locationID, rules: model.rules)
        let loc = model.library.location(locationID)
        let locIndex = model.library.locations.firstIndex { $0.id == locationID } ?? 0
        let prev = locIndex > 0 ? model.library.locations[locIndex - 1] : nil
        let next = locIndex + 1 < model.library.locations.count ? model.library.locations[locIndex + 1] : nil

        if loc == nil {
            ContentUnavailableView("Sektionen findes ikke længere", systemImage: "books.vertical",
                                   description: Text("Vælg en anden sektion i sidepanelet."))
        } else {
            sectionList(items: items, outOfOrder: outOfOrder, prev: prev, next: next)
                .navigationTitle(loc?.name ?? "Sektion")
                .navigationSubtitle(subtitle(total: items.count, outOfOrder: outOfOrder.count))
                .onAppear {
                    // Som de andre lister: står den valgte plade ikke her, vælges den første.
                    if let s = model.selection, items.contains(where: { $0.id == s }) { return }
                    model.selection = items.first?.id
                }
                .toolbar {
                    ToolbarItem {
                        CoverFlowToggle()
                    }
                    ToolbarItem {
                        Button { model.checkSection = locationID } label: {
                            Label("Kontrollér", systemImage: "checklist")
                                .labelStyle(.titleAndIcon)
                        }
                        .help("Kontrollér sektionen: gå den igennem plade for plade (⇧⌘K)")
                    }
                }
        }
    }

    /// "15 plader · 1 ude · 2 uden for sortering". Antallet er pladerne, der står i reolen.
    private func subtitle(total: Int, outOfOrder: Int) -> String {
        let onShelf = model.library.onShelfCount(in: locationID)
        var parts = [pladerText(onShelf)]
        if total > onShelf { parts.append("\(total - onShelf) ude") }
        if outOfOrder > 0 { parts.append("\(outOfOrder) uden for sortering") }
        return parts.joined(separator: " · ")
    }

    /// Første/sidste plade, der faktisk står i en nabosektion (det er den, man ser i reolen).
    private func edgeItem(_ loc: Location, last: Bool) -> RecordItem? {
        let ids = model.library.sections[loc.id] ?? []
        let onShelf = { (id: Int64) in !model.isAway(id) }
        return (last ? ids.last(where: onShelf) : ids.first(where: onShelf)).flatMap(model.library.item)
    }

    private func sectionList(items: [RecordItem], outOfOrder: Set<Int64>, prev: Location?, next: Location?) -> some View {
        @Bindable var model = model
        // Fysisk nummerering: kun plader i reolen får et nummer. Plader, der er ude,
        // står på deres plads i listen – nedtonet, uden nummer og med status.
        let numbers = model.library.shelfNumbers(in: locationID)
        return List(selection: $model.selection) {
            if let prev, let last = edgeItem(prev, last: true) {
                BoundaryRow(text: "Forrige sektion (\(prev.name)) slutter med", item: last)
            }
            if items.isEmpty {
                Text("Sektionen er tom.")
                    .foregroundStyle(.secondary)
                    .selectionDisabled()
            }
            ForEach(Array(items.enumerated()), id: \.element.id) { i, it in
                RecordRow(item: it, number: numbers[it.id], numberColumn: true,
                          warning: outOfOrder.contains(it.id), dimAway: true,
                          extraMenu: boundaryMenu(it.id, first: i == 0, last: i == items.count - 1, prev: prev, next: next))
                    .tag(it.id)
            }
            if let next, let first = edgeItem(next, last: false) {
                BoundaryRow(text: "Næste sektion (\(next.name)) starter med", item: first)
            }
        }
        .listStyle(.inset)
        // 1 pt luft, så listen ikke rører værktøjslinjen (ellers et hvidt bånd over den mørke detalje).
        .padding(.top, 1)
        // Når en sektionsgrænse flyttes, glider pladen ud/ind. Skift af sektion giver et
        // nyt view (`.id` i ContentColumn), så der animeres aldrig mellem to sektioner.
        .animation(Motion.rows(reduceMotion), value: items.map(\.id))
        // Med Cover Flow ved siden af bladrer ← → også, mens listen har fokus.
        .onKeyPress(.leftArrow) { coverFlowStep(-1, items) }
        .onKeyPress(.rightArrow) { coverFlowStep(1, items) }
    }

    private func coverFlowStep(_ delta: Int, _ items: [RecordItem]) -> KeyPress.Result {
        guard model.showCoverFlow, !items.isEmpty else { return .ignored }
        let i = items.firstIndex { $0.id == model.selection } ?? 0
        model.selection = items[min(max(i + delta, 0), items.count - 1)].id
        return .handled
    }

    private func boundaryMenu(_ id: Int64, first: Bool, last: Bool, prev: Location?, next: Location?) -> AnyView? {
        let model = model
        let toPrev = first ? prev : nil
        let toNext = last ? next : nil
        guard toPrev != nil || toNext != nil else { return nil }
        return AnyView(Group {
            if let toPrev {
                Button("Flyt sektionsgrænse: læg sidst i \(toPrev.shortName)") {
                    model.move(id, to: toPrev.id, index: Int.max)
                }
            }
            if let toNext {
                Button("Flyt sektionsgrænse: læg først i \(toNext.shortName)") {
                    model.move(id, to: toNext.id, index: 0)
                }
            }
        })
    }
}

struct BoundaryRow: View {
    @Environment(AppModel.self) private var model
    let text: String
    let item: RecordItem

    var body: some View {
        Button { model.reveal(item.id) } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(text).font(.caption).foregroundStyle(.secondary)
                Text(item.fullName).font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
        .selectionDisabled()
    }
}

/// Skifter mellem plade-detaljen og Cover Flow i en sektion.
struct CoverFlowToggle: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Toggle(isOn: $model.showCoverFlow) {
            Label("Cover Flow", systemImage: "rectangle.stack")
                .labelStyle(.titleAndIcon)
        }
        .toggleStyle(.button)
        .help(model.showCoverFlow ? "Vis plade-detaljen igen" : "Bladr i sektionen med Cover Flow (← →)")
    }
}

/// Under et søgeresultat, der er fundet på en sang: "♪ Wish You Were Here · B1".
struct SongLine: View {
    let track: Track

    var body: some View {
        Label {
            Text(track.position.isEmpty ? track.title : "\(track.title) · \(track.position)")
        } icon: {
            Image(systemName: "music.note")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .padding(.leading, 4)
        .accessibilityLabel("Sangen \(track.title)")
    }
}
