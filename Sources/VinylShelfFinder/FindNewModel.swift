import Foundation
import SwiftUI
import VinylCore

/// De Discogs-kald, "Find nye plader" bruger. `DiscogsClient` opfylder den direkte.
/// Protokollen gør det muligt at teste skærmene uden netværk og uden token.
protocol DiscogsCatalogService {
    func searchAlbums(_ query: String, page: Int, format: String?) async throws -> (albums: [DiscogsAlbum], hasMore: Bool)
    func versions(of album: DiscogsAlbum, page: Int, format: String?) async throws -> (versions: [DiscogsVersion], hasMore: Bool, total: Int)
    func addToWantlist(username: String, releaseID: Int) async throws
    func marketInfo(releaseID: Int, currency: String) async throws -> MarketInfo
}

extension DiscogsClient: DiscogsCatalogService {}

/// Hvilket format der ledes efter. Huskes mellem gange.
enum FormatFilter: String, CaseIterable, Identifiable {
    case all, vinyl, cd, cassette
    var id: String { rawValue }
    var label: String {
        switch self {
        case .all: return "Alle"
        case .vinyl: return "Vinyl"
        case .cd: return "CD"
        case .cassette: return "Kassette"
        }
    }
    /// Discogs' eget navn til `format`-filteret (`nil` = alle formater).
    var discogs: String? {
        switch self {
        case .all: return nil
        case .vinyl: return "Vinyl"
        case .cd: return "CD"
        case .cassette: return "Cassette"
        }
    }
}

/// Et album identificeres af id *og* art: et master-id og et release-id kan have samme tal.
struct AlbumKey: Hashable {
    let id: Int
    let isMaster: Bool
}

extension DiscogsAlbum {
    var key: AlbumKey { AlbumKey(id: id, isMaster: isMaster) }

    /// "1959 · Vinyl, LP, CD"
    var detailLine: String {
        var parts: [String] = []
        if let year { parts.append(String(year)) }
        let f = formats.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        if !f.isEmpty { parts.append(f.joined(separator: ", ")) }
        return parts.joined(separator: " · ")
    }

    /// Til covers og farvetone (genbruger `CoverView` og `.recordStage`). Masters får et
    /// negativt id, så deres cover aldrig forveksles med en release med samme tal i cachen.
    var asRelease: Release {
        Release(id: isMaster ? -id : id, artist: artist, title: title, year: year,
                format: formats.joined(separator: ", "),
                coverURL: (coverURL ?? thumbURL)?.absoluteString,
                thumbURL: (thumbURL ?? coverURL)?.absoluteString)
    }
}

extension DiscogsVersion {
    /// "1959 · US"
    var yearCountry: String {
        [year.map(String.init), country.isEmpty ? nil : country].compactMap { $0 }.joined(separator: " · ")
    }

    /// "Columbia CL 1355"
    var labelLine: String {
        let cat = catno.lowercased() == "none" ? "" : catno
        return [label, cat].filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// "Columbia CL 1355 · Vinyl, LP, Album, Mono" (resten af den kompakte linje efter år og land).
    var detailLine: String {
        [labelLine, format].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// Hele udgaven i én linje: "1959 · US · Columbia CL 1355 · Vinyl, LP, Album, Mono".
    var summary: String {
        [yearCountry, detailLine].filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

/// Tilstanden bag "Find nye plader": søgning i Discogs' katalog, valgt album, udgaver med
/// pris (de mest udbredte hentes med det samme), billigste køb og ønskeliste. Købet sker hos Discogs.
@MainActor
@Observable
final class FindNewModel {
    @ObservationIgnored weak var app: AppModel?

    /// Kun til test: en erstatning for Discogs (fx eksempeldata i demo-tilstand).
    var testService: DiscogsCatalogService?

    enum Phase: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    enum Loadable<Value: Equatable>: Equatable {
        case loading
        case loaded(Value)
        case failed(String)
    }

    enum WantState: Equatable {
        case adding
        case added
        case failed(String)
    }

    // MARK: Søgning

    var query = "" {
        didSet {
            let new = query.trimmingCharacters(in: .whitespacesAndNewlines)
            if new != oldValue.trimmingCharacters(in: .whitespacesAndNewlines) { scheduleSearch() }
        }
    }
    /// Formatet, der søges efter. Et skift søger igen og henter udgaverne igen.
    var format: FormatFilter = FormatFilter(rawValue: UserDefaults.standard.string(forKey: "findnew_format") ?? "") ?? .all {
        didSet {
            guard format != oldValue else { return }
            UserDefaults.standard.set(format.rawValue, forKey: "findnew_format")
            scheduleSearch()
            if selectedAlbum != nil { showAllVersions = false; retryVersions() }
        }
    }
    private(set) var albums: [DiscogsAlbum] = []
    private(set) var hasMore = false
    private(set) var searchPhase: Phase = .idle
    private(set) var loadingMore = false
    /// Søgningen, som `albums` hører til (vises i "Ingen album fundet").
    private(set) var resultQuery = ""
    private var page = 1
    @ObservationIgnored private var searchTask: Task<Void, Never>?

    /// Kortere end dette søges der ikke på (sparer kald hos Discogs).
    static let minimumQueryLength = 2
    /// Søgningen starter først efter et kort ophold i tastningen.
    @ObservationIgnored var searchDelay: Duration = .milliseconds(400)

    // MARK: Valgt album og udgaver

    var selectedKey: AlbumKey? {
        didSet { if selectedKey != oldValue { albumChanged() } }
    }
    /// Albummet, der vises til højre. Bevares, selv om en ny søgning ikke indeholder det.
    private(set) var selectedAlbum: DiscogsAlbum?
    /// Alle hentede udgaver, de mest udbredte først.
    private(set) var versions: [DiscogsVersion] = []
    private(set) var versionsHasMore = false
    /// Discogs' samlede antal udgaver (i det valgte format), ikke kun de hentede.
    private(set) var versionsTotal = 0
    private(set) var versionsPhase: Phase = .idle
    /// "Vis alle udgaver" er foldet ud (lukket for hvert nyt album).
    var showAllVersions = false
    private(set) var loadingMoreVersions = false
    private var versionsPage = 1
    @ObservationIgnored private var versionsTask: Task<Void, Never>?
    @ObservationIgnored private var pricesTask: Task<Void, Never>?
    /// Ophold før udgaverne hentes, så ↑↓ gennem listen ikke sender kald pr. tastetryk.
    @ObservationIgnored var versionsDelay: Duration = .milliseconds(350)

    /// Så mange af de mest udbredte udgaver får hentet pris med det samme. Discogs giver kun
    /// pris for én udgave pr. kald (og højst ~60 kald i minuttet), så alle kan ikke tjekkes.
    static let pricedCount = 12
    /// Så mange sider (á 100) udgaver hentes for at finde de mest udbredte.
    static let versionPagesToRank = 3
    /// Så mange prisopslag kører samtidig.
    static let priceConcurrency = 3
    /// Priser ældre end dette hentes igen.
    static let priceMaxAge: TimeInterval = 15 * 60

    // MARK: Priser og ønskeliste

    /// Priser pr. release og valuta.
    private(set) var prices: [String: Loadable<MarketInfo>] = [:]
    private(set) var wants: [Int: WantState] = [:]
    /// Én delt forbindelse pr. session (tokenet læses kun én gang fra nøgleringen).
    @ObservationIgnored private var cachedClient: DiscogsClient?
    /// Søgninger og udgaver, der allerede er hentet (10 minutter), så samme søgning eller
    /// album ikke koster nye kald hos Discogs.
    @ObservationIgnored private var responseCache = DiscogsResponseCache()

    // MARK: - Tilgængelighed

    /// Kræver forbindelse til Discogs (token) og er slået fra i demo-tilstand.
    var isAvailable: Bool {
        if testService != nil { return true }
        guard let app else { return false }
        return !app.isDemo && app.hasToken
    }

    private var currency: String { app?.currency ?? "DKK" }

    /// Brugernavnet til ønskeliste og valuta. Testdata har intet rigtigt brugernavn
    /// (demo-tilstand er aldrig forbundet).
    private var username: String? {
        let name = app?.username ?? (testService != nil ? "eksempel" : nil)
        return name?.isEmpty == false ? name : nil
    }

    /// Tokenet læses først, når der faktisk skal kaldes Discogs, og aldrig i demo-tilstand.
    /// Det læses kun én gang pr. session, så macOS ikke spørger om nøgleringen ved hvert kald.
    private func service() throws -> DiscogsCatalogService {
        if let testService { return testService }
        guard let app, !app.isDemo, app.hasToken else { throw DiscogsError.missingToken }
        if let cachedClient { return cachedClient }
        guard let token = Keychain.loadToken() else { throw DiscogsError.missingToken }
        let client = DiscogsClient(token: token, cache: responseCache)
        cachedClient = client
        return client
    }

    /// Kaldes, når tokenet skiftes eller fjernes. Cachen tømmes også, da søgeresultaterne
    /// indeholder kontoens egne mærker ("I din samling", "På ønskelisten").
    func resetClient() {
        cachedClient = nil
        responseCache = DiscogsResponseCache()
    }

    /// Ejer jeg denne release? Discogs' eget flag eller den lokale samling.
    func owns(_ version: DiscogsVersion) -> Bool {
        if version.inCollection { return true }
        return app?.library.copies.values.contains { $0.releaseID == version.id } ?? false
    }

    func owns(_ album: DiscogsAlbum) -> Bool {
        if album.inCollection { return true }
        guard !album.isMaster else { return false }
        return app?.library.copies.values.contains { $0.releaseID == album.id } ?? false
    }

    // MARK: - Søgning

    private func scheduleSearch() {
        searchTask?.cancel()
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard q.count >= Self.minimumQueryLength else {
            albums = []
            hasMore = false
            resultQuery = ""
            searchPhase = .idle
            loadingMore = false
            return
        }
        searchPhase = .loading
        loadingMore = false
        let delay = searchDelay
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.runSearch(q)
        }
    }

    /// Søger igen med det samme (fx "Prøv igen").
    func retrySearch() {
        searchTask?.cancel()
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard q.count >= Self.minimumQueryLength else { return }
        searchPhase = .loading
        searchTask = Task { [weak self] in await self?.runSearch(q) }
    }

    private func runSearch(_ q: String) async {
        do {
            let r = try await service().searchAlbums(q, page: 1, format: format.discogs)
            guard !Task.isCancelled else { return }
            albums = DiscogsAlbum.rankedForQuery(Self.unique(r.albums), query: q)
            hasMore = r.hasMore
            page = 1
            resultQuery = q
            searchPhase = .loaded
        } catch {
            guard !Task.isCancelled, !Self.isCancellation(error) else { return }
            searchPhase = .failed(Self.message(for: error))
        }
    }

    /// "Vis flere": næste side af søgningen.
    func loadMore() {
        guard hasMore, !loadingMore, searchPhase == .loaded else { return }
        let q = resultQuery
        let next = page + 1
        loadingMore = true
        searchTask = Task { [weak self] in
            guard let self else { return }
            do {
                let r = try await self.service().searchAlbums(q, page: next, format: self.format.discogs)
                guard !Task.isCancelled, q == self.resultQuery else { return }
                self.albums = Self.unique(self.albums + r.albums)
                self.hasMore = r.hasMore
                self.page = next
            } catch {
                if !Task.isCancelled, !Self.isCancellation(error) {
                    self.searchPhase = .failed(Self.message(for: error))
                }
            }
            self.loadingMore = false
        }
    }

    private static func unique(_ list: [DiscogsAlbum]) -> [DiscogsAlbum] {
        var seen = Set<AlbumKey>()
        return list.filter { seen.insert($0.key).inserted }
    }

    // MARK: - Tastatur i resultatlisten

    func moveSelection(by delta: Int) {
        guard !albums.isEmpty else { return }
        let i = selectedKey.flatMap { k in albums.firstIndex { $0.key == k } } ?? -1
        selectedKey = albums[max(0, min(albums.count - 1, i + delta))].key
    }

    /// ↩: vælg det markerede album (eller det første) og hent udgaverne med det samme.
    func chooseHighlighted() {
        if selectedKey == nil || !albums.contains(where: { $0.key == selectedKey }) {
            guard let first = albums.first else { return }
            selectedKey = first.key
        }
        loadVersions(delay: .zero)
    }

    // MARK: - Udgaver

    /// Et nyt album er markeret. Et ryddet valg (eller et album, der allerede vises)
    /// ændrer ikke højre kolonne: den bliver ved med at vise det sidst valgte album.
    private func albumChanged() {
        guard let key = selectedKey, key != selectedAlbum?.key,
              let album = albums.first(where: { $0.key == key }) else { return }
        versionsTask?.cancel()
        pricesTask?.cancel()
        versions = []
        versionsHasMore = false
        versionsTotal = 0
        versionsPage = 1
        loadingMoreVersions = false
        showAllVersions = false
        selectedAlbum = album
        loadVersions(delay: versionsDelay)
    }

    /// Henter op til `versionPagesToRank` sider udgaver, sorterer dem efter udbredelse og
    /// henter derefter pris for de mest udbredte.
    func loadVersions(delay: Duration) {
        guard let album = selectedAlbum else { return }
        // ↩ på et album, hvis udgaver allerede er hentet: intet nyt kald.
        if delay == .zero, versionsPhase == .loaded { loadCandidatePrices(); return }
        versionsTask?.cancel()
        pricesTask?.cancel()
        versionsPhase = .loading
        let format = format.discogs
        versionsTask = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled, let self else { return }
            do {
                let svc = try self.service()
                var all: [DiscogsVersion] = []
                var page = 0, hasMore = true, total = 0
                while hasMore && page < Self.versionPagesToRank {
                    page += 1
                    let r = try await svc.versions(of: album, page: page, format: format)
                    guard !Task.isCancelled else { return }
                    let known = Set(all.map(\.id))
                    all += r.versions.filter { !known.contains($0.id) }
                    hasMore = r.hasMore
                    total = r.total
                }
                guard self.selectedAlbum?.key == album.key else { return }
                self.versions = DiscogsVersion.mostPopularFirst(all)
                self.versionsHasMore = hasMore
                self.versionsTotal = max(total, all.count)
                self.versionsPage = page
                self.versionsPhase = .loaded
                self.loadCandidatePrices()
            } catch {
                guard !Task.isCancelled, !Self.isCancellation(error) else { return }
                self.versionsPhase = .failed(Self.message(for: error))
            }
        }
    }

    func retryVersions() {
        versions = []
        versionsTotal = 0
        versionsPhase = .idle
        loadVersions(delay: .zero)
    }

    /// "Vis flere": udgaver ud over de første sider (de kommer bagest, uden pris).
    func loadMoreVersions() {
        guard let album = selectedAlbum, versionsHasMore, !loadingMoreVersions else { return }
        let next = versionsPage + 1
        loadingMoreVersions = true
        versionsTask = Task { [weak self] in
            guard let self else { return }
            do {
                let r = try await self.service().versions(of: album, page: next, format: self.format.discogs)
                guard !Task.isCancelled, self.selectedAlbum?.key == album.key else { return }
                let known = Set(self.versions.map(\.id))
                self.versions += r.versions.filter { !known.contains($0.id) }
                self.versionsHasMore = r.hasMore
                self.versionsTotal = max(r.total, self.versions.count)
                self.versionsPage = next
            } catch {
                if !Task.isCancelled, !Self.isCancellation(error) {
                    self.versionsPhase = .failed(Self.message(for: error))
                }
            }
            self.loadingMoreVersions = false
        }
    }

    // MARK: - Priser og billigste køb

    /// De mest udbredte udgaver, der får pris med det samme.
    var candidates: [DiscogsVersion] { Array(versions.prefix(Self.pricedCount)) }

    /// Resten (pris hentes først, når man beder om den).
    var otherVersions: [DiscogsVersion] { Array(versions.dropFirst(Self.pricedCount)) }

    private func priceKey(_ releaseID: Int) -> String { "\(releaseID)-\(currency)" }

    func price(for releaseID: Int) -> Loadable<MarketInfo>? { prices[priceKey(releaseID)] }

    /// Den købbare pris for en udgave (kendt pris og mindst én til salg).
    func buyablePrice(_ releaseID: Int) -> MarketInfo? {
        guard case .loaded(let m)? = price(for: releaseID), m.lowestPrice != nil, (m.numForSale ?? 0) > 0 else { return nil }
        return m
    }

    /// Er alle de mest udbredte udgaver prissat (eller fejlet)?
    var candidatesPriced: Bool {
        versionsPhase == .loaded && candidates.allSatisfy {
            switch price(for: $0.id) {
            case .loaded?, .failed?: return true
            case .loading?, nil: return false
            }
        }
    }

    /// Billigste køb blandt alle udgaver med hentet pris.
    var bestBuy: (version: DiscogsVersion, market: MarketInfo)? {
        Self.cheapest(versions.compactMap { v in buyablePrice(v.id).map { (v, $0) } })
    }

    /// Den laveste pris; ved lige pris vinder den først nævnte (mest udbredte).
    static func cheapest(_ list: [(version: DiscogsVersion, market: MarketInfo)]) -> (version: DiscogsVersion, market: MarketInfo)? {
        list.min { ($0.market.lowestPrice ?? .infinity) < ($1.market.lowestPrice ?? .infinity) }
    }

    /// "Andre udgaver" under billigste køb: de mest udbredte uden det bedste køb. Når alle
    /// priser er hentet, sorteres de: billigst først, så dem uden pris.
    var listedCandidates: [DiscogsVersion] {
        let best = bestBuy?.version.id
        let rest = candidates.filter { $0.id != best }
        guard candidatesPriced else { return rest }
        return rest.enumerated().sorted { a, b in
            let pa = buyablePrice(a.element.id)?.lowestPrice ?? .infinity
            let pb = buyablePrice(b.element.id)?.lowestPrice ?? .infinity
            return pa != pb ? pa < pb : a.offset < b.offset
        }.map(\.element)
    }

    private func needsPrice(_ releaseID: Int) -> Bool {
        switch price(for: releaseID) {
        case .loaded(let m)?: return Date().timeIntervalSince(m.fetchedAt) > Self.priceMaxAge
        case .loading?: return false
        case .failed?, nil: return true
        }
    }

    /// Henter pris for de mest udbredte udgaver, højst `priceConcurrency` ad gangen.
    func loadCandidatePrices() {
        let todo = candidates.map(\.id).filter(needsPrice)
        guard !todo.isEmpty else { return }
        pricesTask?.cancel()
        pricesTask = Task { [weak self] in
            guard let self else { return }
            await withTaskGroup(of: Void.self) { group in
                var queue = todo[...]
                for _ in 0..<Self.priceConcurrency {
                    guard let id = queue.popFirst() else { break }
                    group.addTask { await self.fetchPrice(id) }
                }
                while await group.next() != nil {
                    guard !Task.isCancelled, let id = queue.popFirst() else { continue }
                    group.addTask { await self.fetchPrice(id) }
                }
            }
        }
    }

    /// Henter prisen for én udgave (fx "Hent pris" på en mindre udbredt udgave).
    func loadPrice(_ releaseID: Int) {
        guard needsPrice(releaseID) else { return }
        Task { [weak self] in await self?.fetchPrice(releaseID) }
    }

    private func fetchPrice(_ releaseID: Int) async {
        guard !Task.isCancelled, needsPrice(releaseID) else { return }
        let key = priceKey(releaseID)
        let cur = currency
        prices[key] = .loading
        do {
            prices[key] = .loaded(try await service().marketInfo(releaseID: releaseID, currency: cur))
        } catch {
            if case DiscogsError.unauthorized? = error as? DiscogsError { cachedClient = nil }
            prices[key] = Self.isCancellation(error) ? nil : .failed(Self.shortMessage(for: error))
        }
    }

    /// Discogs' markedsplads for hele albummet i det valgte format (en release uden master: dens egen side).
    func offersURL(for album: DiscogsAlbum) -> URL {
        album.isMaster ? DiscogsClient.marketplaceURL(masterID: album.id, format: format.discogs)
                       : DiscogsClient.marketplaceURL(releaseID: album.id)
    }

    // MARK: - Ønskeliste

    func isOnWantlist(_ releaseID: Int) -> Bool {
        if wants[releaseID] == .added { return true }
        if versions.contains(where: { $0.id == releaseID && $0.inWantlist }) { return true }
        if let a = selectedAlbum, !a.isMaster, a.id == releaseID { return a.inWantlist }
        return false
    }

    func addToWantlist(_ releaseID: Int) {
        guard !isOnWantlist(releaseID), wants[releaseID] != .adding else { return }
        guard let username else {
            wants[releaseID] = .failed("Appen kender ikke dit Discogs-brugernavn. Forbind til Discogs igen i Indstillinger.")
            return
        }
        wants[releaseID] = .adding
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.service().addToWantlist(username: username, releaseID: releaseID)
                self.wants[releaseID] = .added
            } catch {
                self.wants[releaseID] = Self.isCancellation(error) ? nil : .failed(Self.message(for: error))
            }
        }
    }

    // MARK: - Discogs-vinduet

    /// Siden, som Discogs-vinduet skal vise. `requestID` stiger ved hver anmodning, så
    /// samme side kan åbnes igen.
    private(set) var browserURL: URL?
    private(set) var browserRequestID = 0

    func openInBrowser(_ url: URL) {
        browserURL = url
        browserRequestID += 1
    }

    // MARK: - Fejl på dansk

    static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let u = error as? URLError, u.code == .cancelled { return true }
        return false
    }

    /// Kernens danske fejltekster (offline, afvist token, 404, rate limit …).
    static func message(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? "Noget gik galt. Prøv igen om lidt."
    }

    /// Kort udgave til en enkelt prislinje.
    static func shortMessage(for error: Error) -> String {
        switch error as? DiscogsError {
        case .offline?: return "Ingen forbindelse"
        case .rateLimited?: return "Discogs har travlt"
        case .http(404)?: return "Ikke fundet"
        default: return "Kunne ikke hentes"
        }
    }
}
