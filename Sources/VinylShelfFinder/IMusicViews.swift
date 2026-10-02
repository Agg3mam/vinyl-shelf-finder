import SwiftUI
import AppKit
import VinylCore

// iMusic.dk som ekstra købssted. Uden feed: knappen "Søg på iMusic". Med brugerens Daisycon-feed:
// pris og lager fra feedet og "Køb på iMusic" (affiliate-linket). Købet sker altid på imusic.dk i
// standardbrowseren, aldrig i Discogs-vinduet.

/// Arbejder med cache-databasen (imusic.sqlite) uden for main thread.
actor IMusicWorker {
    private var cache: IMusicCache?

    private func open() throws -> IMusicCache {
        if let cache { return cache }
        let c = try IMusicCache()
        cache = c
        return c
    }

    func info() -> (count: Int, fetched: Date?) {
        guard let c = try? open() else { return (0, nil) }
        return (c.count, c.lastFetched)
    }

    func needsRefresh() -> Bool {
        IMusicCache.needsRefresh(lastFetched: (try? open())?.lastFetched)
    }

    func refresh(feed: URL) async throws -> Int {
        try await IMusicFeedUpdater.refresh(feed: feed, cache: try open())
    }

    func match(barcodes: [String], artist: String, title: String, preferVinyl: Bool) -> IMusicProduct? {
        (try? open())?.match(barcodes: barcodes, artist: artist, title: title, preferVinyl: preferVinyl)
    }
}

@MainActor
@Observable
final class IMusicModel {
    enum Phase: Equatable {
        case idle
        case updating
        case failed(String)
    }

    /// Er der gemt en feed-URL? (Læser kun nøgleringens egenskaber, ikke selve URL'en.)
    private(set) var hasFeed: Bool
    private(set) var phase: Phase = .idle
    private(set) var productCount = 0
    private(set) var lastFetched: Date?
    /// Stiger, når cachen er opdateret, så åbne skærme slår prisen op igen.
    private(set) var revision = 0
    @ObservationIgnored private let worker = IMusicWorker()
    @ObservationIgnored private let enabled: Bool

    /// Slået fra i demo- og snapshot-tilstand: hverken nøglering eller net.
    init(enabled: Bool) {
        self.enabled = enabled
        hasFeed = enabled && KeychainSecret.iMusicFeed.exists
    }

    /// Ved start: hent feedet, hvis det er over et døgn gammelt. Ellers vises bare antal og dato.
    func start() {
        guard enabled else { return }
        Task {
            let i = await worker.info()
            productCount = i.count
            lastFetched = i.fetched
            if hasFeed, await worker.needsRefresh() { refresh() }
        }
    }

    /// Gemmer feed-URL'en i nøgleringen. Returnerer en fejltekst, hvis den ikke kan bruges.
    func saveFeed(_ text: String) -> String? {
        guard enabled else { return "iMusic-feedet er slået fra i demo-tilstand." }
        guard let url = IMusicFeedUpdater.validate(text) else { return IMusicFeedError.badURL.localizedDescription }
        do {
            try KeychainSecret.iMusicFeed.save(url.absoluteString)
        } catch {
            return error.localizedDescription
        }
        hasFeed = true
        refresh()
        return nil
    }

    func removeFeed() {
        guard enabled else { return }
        KeychainSecret.iMusicFeed.delete()
        hasFeed = false
        phase = .idle
    }

    /// Henter feedet nu (fx "Opdatér nu" i Indstillinger).
    func refresh() {
        guard enabled, hasFeed, phase != .updating else { return }
        // URL'en læses først her og gives kun til hentningen; den gemmes ikke andre steder.
        guard let text = KeychainSecret.iMusicFeed.load(), let url = IMusicFeedUpdater.validate(text) else {
            phase = .failed(IMusicFeedError.badURL.localizedDescription)
            return
        }
        phase = .updating
        Task {
            do {
                _ = try await worker.refresh(feed: url)
                let i = await worker.info()
                productCount = i.count
                lastFetched = i.fetched
                revision += 1
                phase = .idle
            } catch {
                phase = .failed(Self.message(for: error))
            }
        }
    }

    func offer(barcodes: [String], artist: String, title: String, preferVinyl: Bool) async -> IMusicProduct? {
        guard enabled, productCount > 0 else { return nil }
        return await worker.match(barcodes: barcodes, artist: artist, title: title, preferVinyl: preferVinyl)
    }

    private static func message(for error: Error) -> String {
        if let e = error as? IMusicFeedError { return e.localizedDescription }
        if error is URLError { return "Kunne ikke hente iMusic-feedet. Tjek internetforbindelsen, og prøv igen." }
        return "iMusic-feedet kunne ikke opdateres."
    }
}

// MARK: - Linjen med pris og knap

/// "iMusic: 249 kr. · på lager" med "Køb på iMusic", eller "Søg på iMusic", når der ikke er et match.
/// `compact` er den lille udgave til plade-detaljen (som linket til Discogs).
struct IMusicOfferLine: View {
    @Environment(AppModel.self) private var model
    let barcodes: [String]
    let artist: String
    let title: String
    var preferVinyl = true
    var compact = false
    @ViewState private var offer: IMusicProduct?

    var body: some View {
        let imusic = model.imusic
        Group {
            if let offer {
                found(offer)
            } else {
                Button { NSWorkspace.shared.open(IMusicLink.searchURL(artist: artist, title: title, vinylOnly: preferVinyl)) } label: {
                    Label("Søg på iMusic", systemImage: "magnifyingglass")
                }
                .modifier(IMusicButtonStyle(compact: compact))
                .help("Åbner iMusics søgning på \(artist) – \(title) i din browser")
            }
        }
        .task(id: "\(artist)|\(title)|\(barcodes.joined(separator: ","))|\(imusic.revision)|\(imusic.productCount)") {
            offer = await imusic.offer(barcodes: barcodes, artist: artist, title: title, preferVinyl: preferVinyl)
        }
    }

    private func found(_ p: IMusicProduct) -> some View {
        HStack(spacing: Spacing.xs) {
            Text(Self.summary(p))
                .font(compact ? .caption : .callout)
                .foregroundStyle(compact ? Ink.tertiary : Ink.secondary)
                .monospacedDigit()
                .lineLimit(1)
            Button { NSWorkspace.shared.open(p.link) } label: {
                Label("Køb på iMusic", systemImage: "arrow.up.right.square")
            }
            .modifier(IMusicButtonStyle(compact: compact))
            .help("Åbner varen hos iMusic i din browser: \(p.artist) – \(p.title) (\(p.format))")
        }
        .accessibilityElement(children: .contain)
    }

    /// "iMusic: 249 kr. · på lager"
    static func summary(_ p: IMusicProduct) -> String {
        var parts = ["iMusic"]
        if let price = p.price {
            parts[0] += ": " + FindNewPrice.text(MarketInfo(lowestPrice: price, currency: p.currency, numForSale: nil, have: nil, want: nil))
        }
        if let a = p.availabilityText { parts.append(a) }
        return parts.joined(separator: " · ")
    }
}

private struct IMusicButtonStyle: ViewModifier {
    let compact: Bool

    func body(content: Content) -> some View {
        if compact {
            content
                .buttonStyle(.link)
                .font(.caption)
                .tint(Ink.tertiary)
                .foregroundStyle(Ink.tertiary)
        } else {
            content.buttonStyle(.stageSecondary)
        }
    }
}

// MARK: - Indstillinger

struct IMusicSettings: View {
    @Environment(AppModel.self) private var model
    @ViewState private var feedText = ""
    @ViewState private var error: String?

    var body: some View {
        let imusic = model.imusic
        Form {
            Section {
                LabeledContent("Feed", value: imusic.hasFeed ? "Gemt i nøgleringen" : "Ikke sat op")
                if imusic.productCount > 0 {
                    LabeledContent("Varer", value: "\(FindNewPrice.number(imusic.productCount)) musikvarer")
                }
                if let d = imusic.lastFetched {
                    LabeledContent("Sidst hentet", value: d.danskDatoTid)
                }
                switch imusic.phase {
                case .updating:
                    HStack(spacing: Spacing.xs) {
                        ProgressView().controlSize(.small)
                        Text("Henter iMusic-feedet …").foregroundStyle(.secondary)
                    }
                case .failed(let message):
                    Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
                case .idle:
                    EmptyView()
                }
                SecureField("iMusic-feed (Daisycon)", text: $feedText, prompt: Text("https://daisycon.io/datafeed/?…"))
                if let error {
                    Text(error).font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Button("Gem feed") {
                        error = imusic.saveFeed(feedText)
                        if error == nil { feedText = "" }
                    }
                    .disabled(feedText.trimmingCharacters(in: .whitespaces).isEmpty || model.isDemo)
                    if imusic.hasFeed {
                        Button("Opdatér nu") { imusic.refresh() }
                            .disabled(imusic.phase == .updating)
                        Button("Fjern feed", role: .destructive) { imusic.removeFeed() }
                    }
                }
            } header: {
                Text("iMusic-feed (Daisycon)")
            } footer: {
                Text("Med dit eget produktfeed fra Daisycon viser appen iMusics pris og lagerstatus ved siden af Discogs. Feedet hentes højst én gang i døgnet og gemmes kun som cache på denne Mac. URL'en indeholder dit Daisycon-id; den gemmes kun i nøgleringen og vises aldrig. Uden feed kan du stadig søge på iMusic.")
            }
        }
        .formStyle(.grouped)
    }
}
