import SwiftUI
import VinylCore

/// Reolerne: alle sektioner, grupperet efter reol. Træk ned for at synkronisere.
struct ShelvesView: View {
    @Environment(PhoneModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Group {
            if model.hasShelves {
                List {
                    if model.media.count > 1 {
                        Picker("Hylde", selection: $model.medium) {
                            ForEach(model.media) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .listRowBackground(Color.clear)
                    }
                    let lib = model.library
                    ForEach(lib.shelves, id: \.self) { shelf in
                        Section("\(model.medium.shelfWord) \(shelf)") {
                            ForEach(lib.locations.filter { $0.shelf == shelf }) { loc in
                                NavigationLink(value: SectionRoute(medium: model.medium, locationID: loc.id)) {
                                    SectionRow(location: loc, library: lib)
                                }
                            }
                        }
                    }
                    if !lib.unplaced.isEmpty {
                        Section {
                            Text("\(lib.unplaced.count) \(model.medium.plural) har endnu ingen plads. De får en plads i appen på computeren.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
            } else if model.cloudPhase == .syncing {
                ContentUnavailableView {
                    Label("Henter dine reoler …", systemImage: "icloud.and.arrow.down")
                } description: {
                    ProgressView()
                }
            } else {
                ContentUnavailableView("Ingen reoler endnu", systemImage: "books.vertical",
                                       description: Text("Reolerne laves i appen på computeren og kommer hertil via din konto. Træk ned for at hente dem."))
            }
        }
        .navigationTitle("Reol")
        .refreshable { await model.syncCloud(userInitiated: true) }
        .toolbar {
            if case .failed(let message) = model.cloudPhase {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Text(message)
                        Button("Prøv igen", systemImage: "arrow.clockwise") { Task { await model.syncCloud(userInitiated: true) } }
                    } label: {
                        Label("Synkroniseringen fejlede", systemImage: "exclamationmark.icloud")
                    }
                }
            }
        }
    }
}

/// "Sektion A · ABBA – Cohen · 34 plader".
private struct SectionRow: View {
    let location: Location
    let library: Library

    var body: some View {
        let onShelf = library.items(in: location.id).filter { $0.copy.status.isOnShelf }
        HStack(spacing: 12) {
            // Sektionens bogstav på en lille fane i kategoriens farve (som webappen og sidepanelet på Mac).
            Text(location.section)
                .font(.system(size: 19, weight: .bold).width(.condensed))
                .foregroundStyle(.white)
                .lineLimit(1).minimumScaleFactor(0.6)
                .frame(width: 30, height: 28)
                .background(location.category?.color ?? AppAccent.color,
                            in: UnevenRoundedRectangle(topLeadingRadius: 6, topTrailingRadius: 6, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Sektion \(location.section)").font(.headline)
                if let first = onShelf.first?.artist, let last = onShelf.last?.artist {
                    Text(first == last ? first : "\(first) – \(last)").font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
                Text("\(library.onShelfCount(in: location.id)) \(location.medium.plural)")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
    }
}

/// Én sektion: pladerne i den rækkefølge, de står (nummereret fra venstre).
struct SectionView: View {
    @Environment(PhoneModel.self) private var model
    let route: SectionRoute
    /// Liste eller Cover Flow (huskes mellem sektioner, som på Mac).
    @AppStorage("coverFlow") private var coverFlow = false
    @State private var center = 0
    @State private var open: RecordRoute?

    var body: some View {
        let lib = model.library(route.medium)
        if let loc = lib.location(route.locationID) {
            Group {
                if coverFlow { flow(lib, loc) } else { list(lib, loc) }
            }
            .navigationTitle("\(loc.kind.shelfWord) \(loc.shelf) · Sektion \(loc.section)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(coverFlow ? "Vis som liste" : "Vis som Cover Flow", systemImage: coverFlow ? "list.bullet" : "square.stack.3d.forward.dottedline") {
                        coverFlow.toggle()
                    }
                }
            }
            .navigationDestination(item: $open) { RecordView(route: $0) }
        } else {
            ContentUnavailableView("Sektionen findes ikke længere", systemImage: "books.vertical")
        }
    }

    /// Cover Flow med hvid baggrund (som på Mac og Windows).
    private func flow(_ lib: Library, _ loc: Location) -> some View {
        let items = lib.items(in: loc.id)
        return VStack(spacing: 16) {
            Spacer(minLength: 0)
            PhoneCoverFlow(items: items, center: $center) { open = RecordRoute(medium: route.medium, copyID: $0.id) }
                .frame(height: 320)
            CoverFlowCaption(item: items.indices.contains(center) ? items[center] : nil, library: lib) {
                open = RecordRoute(medium: route.medium, copyID: $0.id)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .coverFlowStage()
    }

    private func list(_ lib: Library, _ loc: Location) -> some View {
        let numbers = lib.shelfNumbers(in: loc.id)
        return List {
                Section {
                    ForEach(lib.items(in: loc.id)) { item in
                        NavigationLink(value: RecordRoute(medium: route.medium, copyID: item.id)) {
                            RecordRow(item: item, location: loc, number: numbers[item.id])
                        }
                    }
                } footer: {
                    Text("Nummereret fra venstre. Plader, der er ude af reolen, tælles ikke med.")
                }
            }
    }
}
