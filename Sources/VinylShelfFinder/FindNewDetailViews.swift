import SwiftUI
import VinylCore

// MARK: - Højre kolonne: billigste køb øverst, andre udgaver med pris nedenunder (pladeskærm)

struct FindNewDetailColumn: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let shop = model.findNew
        Group {
            if !shop.isAvailable {
                ContentUnavailableView {
                    Label("Køb via Discogs", systemImage: "bag")
                } description: {
                    Text("Priser, udgaver og køb vises her, når appen er forbundet til Discogs.")
                }
            } else if let album = shop.selectedAlbum {
                FindNewAlbumView(album: album)
            } else {
                ContentUnavailableView {
                    Label("Vælg et album", systemImage: "opticaldisc")
                } description: {
                    Text("Vælg et album i listen for at se, hvad det koster.")
                }
            }
        }
        // "Køb" beder om en side; vinduet åbnes (eller kommer frem) her.
        .onChange(of: shop.browserRequestID) { openWindow(id: DiscogsBrowser.windowID) }
    }
}

struct FindNewAlbumView: View {
    @Environment(AppModel.self) private var model
    let album: DiscogsAlbum
    @ViewState private var scrollPosition = ScrollPosition(edge: .top)

    var body: some View {
        let shop = model.findNew
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.l) {
                FindNewAlbumCard(album: album)
                FindNewVersionList()
                footer
            }
            .foregroundStyle(Ink.primary)
            .padding(Spacing.l)
            .frame(maxWidth: 640, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .scrollPosition($scrollPosition)
        .scrollEdgeEffectStyle(.soft, for: .top)
        .recordStage(album.asRelease)
        .navigationTitle(album.title)
        .onChange(of: album.key) { scrollPosition.scrollTo(edge: .top) }
        // Valutaskift: hent priserne igen i den nye valuta.
        .onChange(of: model.currency) { shop.loadCandidatePrices() }
    }

    private var footer: some View {
        let shop = model.findNew
        return VStack(alignment: .leading, spacing: Spacing.s) {
            Button { shop.openInBrowser(shop.offersURL(for: album)) } label: {
                Label(album.isMaster ? "Se alle tilbud på Discogs" : "Se tilbud på Discogs", systemImage: "arrow.up.right.square")
            }
            .buttonStyle(.stageSecondary)
            .help(album.isMaster && shop.format != .all
                  ? "Åbner Discogs' markedsplads med albummets \(shop.format.label)-udgaver i et vindue her i appen"
                  : "Åbner Discogs' markedsplads i et vindue her i appen")
            Text("Prisen er det billigste eksemplar til salg lige nu, uanset stand og uden fragt og moms, så Discogs' kurv viser et højere beløb. Billigste køb findes blandt de \(FindNewModel.pricedCount) mest udbredte udgaver. Du køber direkte hos Discogs i et vindue her i appen.")
                .font(.caption)
                .foregroundStyle(Ink.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: Albumkortet med billigste køb

private struct FindNewAlbumCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.coverTone) private var tone
    let album: DiscogsAlbum

    var body: some View {
        let shop = model.findNew
        VStack(alignment: .leading, spacing: Spacing.m) {
            FindNewAlbumHeader(album: album, owned: shop.owns(album), formatText: formatText)
            FindNewBestBuy(album: album)
        }
        .padding(Spacing.panelInset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(GlassPanel(tone: tone))
    }

    private var formatText: String {
        let shop = model.findNew
        if album.isMaster { return shop.format == .all ? "Alle formater" : shop.format.label }
        let f = album.formats.prefix(3).joined(separator: ", ")
        return f.isEmpty ? "Én udgave" : f
    }
}

private struct FindNewAlbumHeader: View {
    let album: DiscogsAlbum
    let owned: Bool
    let formatText: String

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.m) {
            CoverView(release: album.asRelease, size: 96)
                .modifier(CoverShadow())
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Cover: \(album.artist) – \(album.title)")
                .accessibilityAddTraits(.isImage)
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(album.artist).font(.title3).foregroundStyle(Ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(album.title)
                    .font(.system(size: 26, weight: .heavy))
                    .fixedSize(horizontal: false, vertical: true)
                    .layoutPriority(1)
                Text([album.year.map(String.init), formatText].compactMap { $0 }.joined(separator: " · "))
                    .font(.callout)
                    .foregroundStyle(Ink.tertiary)
                    .lineLimit(2)
                if owned || album.inWantlist {
                    HStack(spacing: Spacing.xxs) {
                        if owned { FindNewBadge(text: "I din samling", symbol: "checkmark.circle.fill", onStage: true) }
                        if album.inWantlist { FindNewBadge(text: "På ønskelisten", symbol: "heart.fill", onStage: true) }
                    }
                    .padding(.top, Spacing.xxs)
                }
            }
        }
    }
}

/// "Billigste vinyl lige nu: 189 kr." med udgaven, "Køb på Discogs" og ♡.
private struct FindNewBestBuy: View {
    @Environment(AppModel.self) private var model
    let album: DiscogsAlbum

    var body: some View {
        content
            .padding(Spacing.s)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background.opacity(0.35), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var what: String {
        switch model.findNew.format {
        case .all: return "udgave"
        case .vinyl: return "vinyl"
        case .cd: return "cd"
        case .cassette: return "kassette"
        }
    }

    @ViewBuilder private var content: some View {
        let shop = model.findNew
        if let best = shop.bestBuy {
            found(best.version, best.market, stillChecking: !shop.candidatesPriced)
        } else {
            switch shop.versionsPhase {
            case .failed(let message):
                Notice(icon: "exclamationmark.triangle.fill", color: Ink.warning, text: message) {
                    Button("Prøv igen") { shop.retryVersions() }.buttonStyle(.stageSecondary)
                }
            case .loaded where shop.versions.isEmpty:
                Text(shop.format == .all ? "Discogs har ingen udgaver af dette album."
                                         : "Discogs har ingen \(shop.format.label)-udgaver af dette album.")
                    .foregroundStyle(Ink.secondary)
            case .loaded where shop.candidatesPriced:
                noneForSale
            default:
                FindNewLoadingLine(text: "Finder den billigste \(what) …")
            }
        }
    }

    private func found(_ version: DiscogsVersion, _ m: MarketInfo, stillChecking: Bool) -> some View {
        let shop = model.findNew
        return VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(spacing: Spacing.xs) {
                Text(stillChecking ? "Billigste \(what) indtil videre" : "Billigste \(what) lige nu").font(.callout.weight(.semibold)).foregroundStyle(Ink.secondary)
                if stillChecking {
                    ProgressView().controlSize(.mini).accessibilityLabel("Tjekker flere udgaver")
                }
            }
            Text(FindNewPrice.text(m))
                .font(.system(size: 30, weight: .bold))
                .monospacedDigit()
                .contentTransition(.numericText())
            Text(version.summary.isEmpty ? "Ukendt udgave" : version.summary)
                .font(.callout)
                .foregroundStyle(Ink.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("\(FindNewPrice.forSale(m.numForSale ?? 0)) · + fragt")
                .font(.caption)
                .foregroundStyle(Ink.tertiary)
            GlassEffectContainer(spacing: Spacing.xs) {
                HStack(spacing: Spacing.xs) {
                    Button { shop.openInBrowser(DiscogsClient.marketplaceURL(releaseID: version.id)) } label: {
                        Label("Køb på Discogs", systemImage: "bag")
                    }
                    .buttonStyle(.stagePrimary)
                    .controlSize(.large)
                    .help("Åbner Discogs' sælgere af netop denne udgave i et vindue her i appen")
                    .accessibilityLabel("Køb på Discogs: \(version.summary), \(FindNewPrice.text(m))")

                    FindNewWantButton(releaseID: version.id,
                                      help: "Lægger netop denne udgave på din ønskeliste på Discogs: \(version.summary)")
                        .controlSize(.large)
                }
            }
            .padding(.top, Spacing.xxs)
            FindNewWantError(releaseID: version.id)
        }
        .accessibilityElement(children: .contain)
    }

    private var noneForSale: some View {
        let shop = model.findNew
        return VStack(alignment: .leading, spacing: Spacing.xs) {
            Text("Ingen af de mest udbredte udgaver er til salg lige nu")
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
            Text("Måske er der en sjældnere udgave til salg. Se alle tilbud hos Discogs, eller hent prisen på en bestemt udgave nedenfor.")
                .font(.callout)
                .foregroundStyle(Ink.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button { shop.openInBrowser(shop.offersURL(for: album)) } label: {
                Label("Se alle tilbud på Discogs", systemImage: "bag")
            }
            .buttonStyle(.stagePrimary)
        }
    }
}

// MARK: Andre udgaver (med pris)

private struct FindNewVersionList: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let shop = model.findNew
        let listed = shop.listedCandidates
        if shop.versionsPhase == .loaded, !(listed.isEmpty && shop.otherVersions.isEmpty) {
            VStack(alignment: .leading, spacing: 0) {
                if !listed.isEmpty {
                    Text("Andre udgaver").font(.headline).padding(Spacing.s)
                    rows(listed, autoPriced: true)
                }
                if !shop.otherVersions.isEmpty || shop.versionsHasMore {
                    if !listed.isEmpty { Divider() }
                    allToggle
                    if shop.showAllVersions {
                        Divider()
                        rows(shop.otherVersions, autoPriced: false)
                        if shop.versionsHasMore { moreButton }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(ContentSurface.fill, in: ContentSurface.shape)
            .animation(Motion.move(reduceMotion), value: listed.map(\.id))
        }
    }

    private func rows(_ list: [DiscogsVersion], autoPriced: Bool) -> some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(list) { version in
                FindNewPricedRow(version: version, autoPriced: autoPriced)
                if version.id != list.last?.id { Divider().padding(.leading, Spacing.s) }
            }
        }
    }

    private var allToggle: some View {
        let shop = model.findNew
        let total = max(shop.versionsTotal, shop.versions.count)
        return Button {
            withAnimation(Motion.move(reduceMotion)) { shop.showAllVersions.toggle() }
        } label: {
            HStack(spacing: Spacing.xs) {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .rotationEffect(.degrees(shop.showAllVersions ? 90 : 0))
                    .frame(width: 14)
                Text(shop.showAllVersions ? "Skjul de andre udgaver" : "Vis alle \(FindNewPrice.number(total)) udgaver")
                Spacer(minLength: 0)
            }
            .foregroundStyle(Ink.secondary)
            .padding(Spacing.s)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(shop.showAllVersions ? "Foldet ud" : "Foldet sammen")
    }

    private var moreButton: some View {
        let shop = model.findNew
        return Button { shop.loadMoreVersions() } label: {
            if shop.loadingMoreVersions {
                Label("Henter flere …", systemImage: "hourglass")
            } else {
                Label("Vis flere udgaver", systemImage: "chevron.down")
            }
        }
        .buttonStyle(.stageSecondary)
        .disabled(shop.loadingMoreVersions)
        .padding(Spacing.s)
    }
}

/// Én udgave: år · land, label og format til venstre; pris, "Køb" og ♡ til højre.
private struct FindNewPricedRow: View {
    @Environment(AppModel.self) private var model
    let version: DiscogsVersion
    /// De mest udbredte udgaver får pris automatisk; resten har "Hent pris".
    let autoPriced: Bool

    var body: some View {
        let shop = model.findNew
        HStack(spacing: Spacing.s) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: Spacing.xs) {
                    Text(version.yearCountry.isEmpty ? "Ukendt år" : version.yearCountry).fontWeight(.semibold)
                    if shop.owns(version) {
                        FindNewBadge(text: "I samlingen", symbol: "checkmark.circle.fill", onStage: true)
                    }
                }
                Text(version.detailLine)
                    .font(.caption)
                    .foregroundStyle(Ink.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .help(version.summary)
            Spacer(minLength: Spacing.xs)
            price
            Button { shop.openInBrowser(DiscogsClient.marketplaceURL(releaseID: version.id)) } label: {
                Text("Køb")
            }
            .buttonStyle(.stageSecondary)
            .controlSize(.small)
            .help("Åbner Discogs' sælgere af netop denne udgave i et vindue her i appen")
            .accessibilityLabel("Køb \(version.summary)")
            FindNewWantButton(releaseID: version.id, iconOnly: true,
                              help: shop.isOnWantlist(version.id) ? "På din ønskeliste på Discogs"
                                                                  : "Læg denne udgave på din ønskeliste på Discogs")
                .controlSize(.small)
        }
        .font(.callout)
        .padding(.horizontal, Spacing.s)
        .padding(.vertical, 7)
    }

    @ViewBuilder private var price: some View {
        let shop = model.findNew
        switch shop.price(for: version.id) {
        case .loaded(let m)?:
            if m.lowestPrice != nil, (m.numForSale ?? 0) > 0 {
                VStack(alignment: .trailing, spacing: 0) {
                    Text(FindNewPrice.text(m)).font(.headline).monospacedDigit()
                    Text(FindNewPrice.forSale(m.numForSale ?? 0)).font(.caption2).foregroundStyle(Ink.tertiary)
                }
                .accessibilityElement(children: .combine)
            } else {
                Text("Ikke til salg").foregroundStyle(Ink.tertiary)
            }
        case .failed(let message)?:
            Button("Prøv igen") { shop.loadPrice(version.id) }
                .buttonStyle(.stageSecondary)
                .controlSize(.small)
                .help("Prisen kunne ikke hentes: \(message)")
        case .loading?:
            ProgressView().controlSize(.small).accessibilityLabel("Henter pris")
        case nil:
            if autoPriced {
                ProgressView().controlSize(.small).accessibilityLabel("Henter pris")
            } else {
                Button("Hent pris") { shop.loadPrice(version.id) }
                    .buttonStyle(.stageSecondary)
                    .controlSize(.small)
            }
        }
    }
}

// MARK: Fælles småting

enum FindNewPrice {
    static func number(_ n: Int) -> String { n.formatted(.number.locale(DanishDate.locale)) }

    /// "189 kr." / "25,50 €"
    static func text(_ m: MarketInfo) -> String {
        guard let p = m.lowestPrice else { return "–" }
        return p.formatted(.currency(code: m.currency).locale(DanishDate.locale).precision(.fractionLength(p.rounded() == p ? 0 : 2)))
    }

    static func forSale(_ n: Int) -> String { "\(number(n)) til salg" }
}

private struct FindNewLoadingLine: View {
    let text: String

    var body: some View {
        HStack(spacing: Spacing.xs) {
            ProgressView().controlSize(.small)
            Text(text)
        }
        .foregroundStyle(Ink.secondary)
        .accessibilityElement(children: .combine)
    }
}

/// ♡ "Ønskeliste". `iconOnly` giver et lille hjerte til listen.
private struct FindNewWantButton: View {
    @Environment(AppModel.self) private var model
    let releaseID: Int?
    var iconOnly = false
    let help: String

    var body: some View {
        let shop = model.findNew
        let onList = releaseID.map { shop.isOnWantlist($0) } ?? false
        let adding = releaseID.map { shop.wants[$0] == .adding } ?? false
        Button { if let releaseID { shop.addToWantlist(releaseID) } } label: {
            let title = adding ? "Tilføjer …" : onList ? "På ønskelisten" : "Ønskeliste"
            let symbol = onList ? "heart.fill" : "heart"
            if iconOnly {
                Label(title, systemImage: symbol).labelStyle(.iconOnly)
            } else {
                Label(title, systemImage: symbol)
            }
        }
        .buttonStyle(.stageSecondary)
        .disabled(releaseID == nil || onList || adding)
        .help(help)
        .accessibilityLabel(onList ? "På ønskelisten" : "Læg på ønskelisten")
        .accessibilityHint(help)
    }
}

private struct FindNewWantError: View {
    @Environment(AppModel.self) private var model
    let releaseID: Int

    var body: some View {
        if case .failed(let message)? = model.findNew.wants[releaseID] {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(Ink.warning)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
