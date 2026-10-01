import SwiftUI
import VinylCore

// MARK: - Midterkolonnen: søgning i Discogs' katalog (systemskærm)

struct FindNewSearchView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if model.findNew.isAvailable {
                FindNewSearchContent()
            } else {
                FindNewUnavailable()
            }
        }
        .navigationTitle("Find nye plader")
    }
}

/// Uden forbindelse til Discogs (intet token eller demo-tilstand).
struct FindNewUnavailable: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ContentUnavailableView {
            Label("Find nye plader", systemImage: "bag")
        } description: {
            Text(model.isDemo
                 ? "Her kan du søge i hele Discogs' katalog, se priser og købe plader. Demo-tilstanden har ingen forbindelse til Discogs, så funktionen er ikke med her."
                 : "Her kan du søge i hele Discogs' katalog, se priser og købe plader. Det kræver, at appen er forbundet til Discogs.")
        } actions: {
            if !model.isDemo {
                SettingsLink { Text("Forbind i Indstillinger") }
            }
        }
    }
}

private struct FindNewSearchContent: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var searchFocused: Bool

    private enum Phase: Equatable { case prompt, searching, failed, empty, results }

    private var phase: Phase {
        let shop = model.findNew
        if case .failed = shop.searchPhase { return .failed }
        if shop.query.trimmingCharacters(in: .whitespacesAndNewlines).count < FindNewModel.minimumQueryLength { return .prompt }
        if !shop.albums.isEmpty { return .results }
        return shop.searchPhase == .loaded ? .empty : .searching
    }

    var body: some View {
        @Bindable var shop = model.findNew
        VStack(spacing: 0) {
            searchField
            Picker("Format", selection: $shop.format) {
                ForEach(FormatFilter.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityLabel("Format")
            .help("Vis kun album og udgaver i dette format")
            .padding(.horizontal, Spacing.s)
            .padding(.bottom, Spacing.xs)
            ZStack {
                switch phase {
                case .results: FindNewResultsList()
                case .prompt: prompt
                case .searching: searching
                case .failed: failure
                case .empty: empty
                }
            }
            .frame(maxHeight: .infinity)
            .animation(Motion.state(reduceMotion), value: phase)
        }
        .onAppear { searchFocused = true }
    }

    private var searchField: some View {
        @Bindable var shop = model.findNew
        return HStack(spacing: Spacing.xs) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("Kunstner eller album på Discogs …", text: $shop.query)
                .textFieldStyle(.plain)
                .font(.title3)
                .focused($searchFocused)
                .accessibilityLabel("Søg i Discogs' katalog")
                .onKeyPress(.downArrow) { shop.moveSelection(by: 1); return .handled }
                .onKeyPress(.upArrow) { shop.moveSelection(by: -1); return .handled }
                .onKeyPress(.return) { shop.chooseHighlighted(); return .handled }
                .onKeyPress(.escape) { shop.query = ""; return .handled }
                // Reserve: på macOS kan feltets editor selv tage ↩ (onSubmit fyrer da i stedet).
                .onSubmit { shop.chooseHighlighted() }
            if shop.searchPhase == .loading && !shop.albums.isEmpty {
                ProgressView().controlSize(.small)
                    .accessibilityLabel("Søger")
            }
            if !shop.query.isEmpty {
                Button { shop.query = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .accessibilityLabel("Ryd søgning")
                    .help("Ryd søgning (esc)")
            }
        }
        .padding(.horizontal, Spacing.s)
        .padding(.vertical, Spacing.xs)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .padding(Spacing.s)
    }

    private var prompt: some View {
        ContentUnavailableView {
            Label("Søg i hele Discogs", systemImage: "bag")
        } description: {
            Text("Skriv kunstner eller album. Du ser album fra hele Discogs' katalog, også dem du ikke ejer. ↑↓ vælger et album.")
        }
        .transition(.opacity)
    }

    private var searching: some View {
        VStack(spacing: Spacing.s) {
            ProgressView()
            Text("Søger på Discogs …").foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .transition(.opacity)
    }

    private var empty: some View {
        ContentUnavailableView {
            Label("Ingen album fundet", systemImage: "magnifyingglass")
        } description: {
            Text("Discogs har ikke noget, der matcher “\(model.findNew.resultQuery)”. Prøv med færre ord eller en anden stavemåde.")
        }
        .transition(.opacity)
    }

    @ViewBuilder private var failure: some View {
        if case .failed(let message) = model.findNew.searchPhase {
            FindNewErrorView(message: message) { model.findNew.retrySearch() }
                .transition(.opacity)
        }
    }
}

/// Fejl vist roligt: et symbol, en dansk forklaring og "Prøv igen".
struct FindNewErrorView: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("Discogs svarer ikke lige nu", systemImage: "icloud.slash")
        } description: {
            Text(message)
        } actions: {
            Button("Prøv igen", action: retry)
        }
    }
}

private struct FindNewResultsList: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Valget skrives kun tilbage, når det faktisk ændres (som i Søg).
    private var selection: Binding<AlbumKey?> {
        let shop = model.findNew
        return Binding(get: { shop.selectedKey },
                       set: { if $0 != shop.selectedKey { shop.selectedKey = $0 } })
    }

    var body: some View {
        let shop = model.findNew
        List(selection: selection) {
            ForEach(shop.albums, id: \.key) { album in
                FindNewAlbumRow(album: album, owned: shop.owns(album))
                    .tag(album.key)
            }
            if shop.hasMore {
                FindNewMoreButton(title: "Vis flere", loading: shop.loadingMore) { shop.loadMore() }
                    .selectionDisabled()
            }
        }
        .listStyle(.inset)
        // 1 pt luft, så listen ikke rører værktøjslinjen.
        .padding(.top, 1)
        .animation(Motion.rows(reduceMotion), value: shop.albums.map(\.key))
        .onKeyPress(.return) { shop.chooseHighlighted(); return .handled }
        .transition(.opacity)
    }
}

struct FindNewAlbumRow: View {
    let album: DiscogsAlbum
    let owned: Bool

    var body: some View {
        HStack(spacing: Spacing.s) {
            CoverView(release: album.asRelease, size: 38)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(Text(album.artist).fontWeight(.semibold)) \(Text("–").foregroundStyle(.secondary)) \(album.title)")
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .layoutPriority(1)
                if !album.detailLine.isEmpty {
                    Text(album.detailLine).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                if owned || album.inWantlist {
                    HStack(spacing: Spacing.xxs) {
                        if owned { FindNewBadge(text: "I din samling", symbol: "checkmark.circle.fill") }
                        if album.inWantlist { FindNewBadge(text: "På ønskelisten", symbol: "heart.fill") }
                    }
                    .padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

/// Lille mærke ("I din samling", "På ønskelisten"). På pladeskærmen i pladens tone,
/// ellers i appens accentfarve.
struct FindNewBadge: View {
    let text: String
    let symbol: String
    var onStage = false
    @Environment(\.coverTone) private var tone

    var body: some View {
        Label(text, systemImage: symbol)
            .labelStyle(.titleAndIcon)
            .font(.caption.weight(.semibold))
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 7).padding(.vertical, 2)
            .foregroundStyle(onStage ? Ink.primary : AppAccent.ink)
            .background((onStage ? tone.accent.opacity(0.22) : AppAccent.color.opacity(0.15)), in: Capsule())
    }
}

/// "Vis flere" nederst i en liste.
struct FindNewMoreButton: View {
    let title: String
    let loading: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Spacing.xs) {
                if loading {
                    ProgressView().controlSize(.small)
                    Text("Henter flere …")
                } else {
                    Label(title, systemImage: "chevron.down")
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, Spacing.xxs)
        }
        .buttonStyle(.borderless)
        .disabled(loading)
    }
}

