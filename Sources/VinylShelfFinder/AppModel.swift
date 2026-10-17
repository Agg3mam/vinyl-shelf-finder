import Foundation
import SwiftUI
import AppKit
import VinylCore

enum SidebarItem: Hashable {
    case search
    case newRecords
    case removed
    case away
    case section(Int64)
    case history
    case value
    case listen
    case plays
    /// "Find nye plader": søg, se priser og køb i hele Discogs' katalog.
    case findNew
}

enum SyncState: Equatable {
    case idle
    case running(done: Int, total: Int)
    case failed(String)
}

@MainActor
@Observable
final class AppModel {
    let store: ShelfStore
    private(set) var library: Library = .empty
    private(set) var searchIndex = SearchIndex(library: .empty)
    private(set) var rules: SortRules

    /// Plader eller cd'er: hver har sine egne reoler. Skiftet øverst vises, når der er cd'er.
    var medium: Medium = .vinyl {
        didSet {
            guard medium != oldValue else { return }
            store.setSetting("medium", medium.rawValue)
            // Valg, ark og forslag hører til den anden hylde.
            selection = nil
            findModeCopy = nil
            returnCopy = nil
            moveCopy = nil
            checkSection = nil
            currentPick = nil
            forceOnboarding = false
            sidebar = .search
            reload()
        }
    }
    /// Antal kopier pr. hylde i hele samlingen.
    private(set) var mediumCounts: [Medium: Int] = [:]
    /// Skiftet "Plader / Cd'er" giver kun mening, når der er cd'er i samlingen.
    var showsMediumPicker: Bool { (mediumCounts[.cd] ?? 0) > 0 || medium == .cd }

    var sidebar: SidebarItem? = .search
    var query = "" { didSet { runSearch(autoSelect: true) } }
    private(set) var results: [Int64] = []
    var selection: Int64?

    var neighborCount: Int {
        didSet { store.setSetting("neighbor_count", String(neighborCount)) }
    }

    private(set) var username: String?
    private(set) var hasToken: Bool
    var syncState: SyncState = .idle

    // Lytning
    private(set) var stats: ListeningStats = .empty
    /// Et nyt filter gør det gamle forslag ugyldigt: forslaget (og valget, hvis det var
    /// forslaget) nulstilles, så skærmen ikke viser en plade, der ikke passer til filteret.
    var listenFilter = ListenFilter() {
        didSet { if listenFilter != oldValue { clearPick() } }
    }
    private(set) var currentPick: Int64?
    private var recentPicks: [Int64] = []

    // Værdi
    private(set) var market: [Int: MarketInfo] = [:]
    private(set) var collectionValue: CollectionValue?
    var valueState: SyncState = .idle
    var currency: String {
        didSet { store.setSetting("market_currency", currency) }
    }
    var lastReport: ShelfStore.SyncReport?
    var showSyncReport = false
    var errorMessage: String?

    // Ark/overlays
    var findModeCopy: Int64?
    /// "Sæt tilbage"-guiden: viser præcis, hvor en plade, der har været ude, skal stå.
    /// Pladen registreres først som hjemme, når man trykker "Sat på plads".
    var returnCopy: Int64?
    var moveCopy: Int64?
    var checkSection: Int64?
    var focusSearchRequest = 0
    var forceOnboarding = false
    /// "Udlånt" / "Opbevaret andet sted" fra en højrekliksmenu: spørg efter navn/sted
    /// (vises som dialog i hovedvinduet, se `StatusNoteAlert`).
    var statusNoteRequest: StatusNoteRequest?

    /// Cover Flow i sektionerne (i stedet for plade-detaljen). Huskes mellem gange.
    var showCoverFlow = UserDefaults.standard.bool(forKey: "cover_flow") {
        didSet { UserDefaults.standard.set(showCoverFlow, forKey: "cover_flow") }
    }

    /// "Find nye plader" (Discogs' katalog, priser, ønskeliste og køb).
    let findNew = FindNewModel()

    /// iMusic.dk som ekstra købssted (Daisycon-feed). Slået fra i demo- og snapshot-tilstand.
    let imusic = IMusicModel(enabled: !CommandLine.arguments.contains("--demo")
                                      && !CommandLine.arguments.contains("--snapshot"))

    /// `--demo`: separat database med eksempeldata, ingen Discogs-forbindelse.
    let isDemo = CommandLine.arguments.contains("--demo")

    /// "Ny version klar" fra GitHub. Slået fra i demo- og snapshot-tilstand.
    let updater = Updater(enabled: !CommandLine.arguments.contains("--demo")
                                   && !CommandLine.arguments.contains("--snapshot"))

    // Sikkerhedskopi (én gang om dagen, se `DatabaseBackup`)
    let backupFolder = DatabaseBackup.defaultFolder()
    private(set) var lastBackup: Date?
    private(set) var backupError: String?
    @ObservationIgnored private var backupTask: Task<Void, Never>?

    init() {
        do {
            if isDemo {
                let url = ShelfStore.defaultURL.deletingLastPathComponent().appendingPathComponent("demo.sqlite")
                store = try ShelfStore(path: url.path)
                try DemoData.seedIfEmpty(store)
            } else {
                store = try ShelfStore(path: ShelfStore.defaultURL.path)
            }
        } catch {
            fatalError("Kunne ikke åbne databasen: \(error)")
        }
        rules = store.loadSortRules()
        neighborCount = Int(store.setting("neighbor_count") ?? "") ?? 1
        username = store.setting("discogs_username")
        hasToken = isDemo ? false : Keychain.hasToken
        // Danske kroner fandtes ikke som valg før; en gemt euro (den gamle standard) flyttes
        // derfor én gang over til kroner. Vælger man euro igen bagefter, bliver det stående.
        var savedCurrency = store.setting("market_currency") ?? "DKK"
        if savedCurrency == "EUR", store.setting("currency_dkk_migrated") == nil {
            savedCurrency = "DKK"
            store.setSetting("market_currency", "DKK")
        }
        store.setSetting("currency_dkk_migrated", "1")
        currency = savedCurrency
        // Priser gemt før 1. okt 2026 blev regnet forkert om (kroner tolket som euro). Hent dem igen.
        if store.setting("market_prices_v2") == nil {
            try? store.clearMarket()
            store.setSetting("market_prices_v2", "1")
        }
        market = (try? store.loadMarket()) ?? [:]
        collectionValue = store.loadCollectionValue()
        // Sættes før `reload` og uden `didSet` (det kører ikke i init).
        medium = store.setting("medium").flatMap(Medium.init(rawValue:)) ?? .vinyl
        reload()
        findNew.app = self
        startBackups()
        imusic.start()
        updater.start()
    }

    // MARK: - Data

    func reload() {
        do {
            library = try store.loadLibrary(medium: medium)
            mediumCounts = try store.mediumCounts()
            stats = ListeningStats(plays: try store.loadPlays())
            searchIndex = SearchIndex(library: library)
            // Efter en handling (spillet, flyt, status …) må valget kun skifte, når man
            // står i søgningen. Ellers hopper valget i en sektion/liste til et søgeresultat.
            runSearch(autoSelect: sidebar == nil || sidebar == .search)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Plader fra Discogs mangler Discogs' rækkefølge (fx efter opdatering af appen).
    var needsRankSync: Bool {
        !isDemo && hasToken && rules.useDiscogsOrder
            && library.copies.values.contains { $0.inDiscogs && $0.discogsRank == nil }
    }

    var needsOnboarding: Bool { forceOnboarding || (!hasToken && !isDemo) || library.locations.isEmpty }

    var lastSync: Date? {
        store.setting("last_sync").flatMap(Double.init).map(Date.init(timeIntervalSince1970:))
    }

    private func runSearch(autoSelect: Bool) {
        let q = query.trimmingCharacters(in: .whitespaces)
        if q.isEmpty {
            if !results.isEmpty { results = [] }
            return
        }
        let new = searchIndex.search(q)
        // Kun ændringer sendes videre: samme liste må ikke få listen til at opdatere igen.
        if new != results { results = new }
        guard autoSelect else { return }
        // Ingen resultater: højre side må ikke blive ved med at vise den forrige plade.
        guard let first = results.first else {
            if selection != nil { selection = nil }
            return
        }
        if let s = selection, results.contains(s) { return }
        selection = first
    }

    func moveSelection(by delta: Int) {
        guard !results.isEmpty else { return }
        let i = selection.flatMap { results.firstIndex(of: $0) } ?? -1
        selection = results[max(0, min(results.count - 1, i + delta))]
    }

    /// Hop til en plade (fx en nabo) og vis den i søgningen.
    func reveal(_ copyID: Int64) {
        if case .section = sidebar {
            selection = copyID
            if let loc = library.locationOfCopy[copyID] { sidebar = .section(loc) }
            return
        }
        sidebar = .search
        if !results.contains(copyID), let it = library.item(copyID) {
            query = "\(it.artist) \(it.title)"
        }
        selection = copyID
    }

    var unplacedItems: [RecordItem] { rules.sorted(library.unplaced.compactMap(library.item)) }
    var removedItems: [RecordItem] {
        rules.sorted(library.allItems.filter { !$0.copy.inDiscogs && $0.copy.removedFromDiscogsAt != nil })
    }
    var awayItems: [RecordItem] { rules.sorted(library.allItems.filter { $0.copy.status != .home }) }

    // MARK: - Handlinger

    private func perform(_ body: () throws -> Void) {
        do {
            try body()
        } catch {
            errorMessage = error.localizedDescription
        }
        reload()
    }

    func move(_ copyID: Int64, to location: Int64, index: Int) {
        perform { try store.move(copyID: copyID, to: location, index: index) }
    }

    func placeAsSuggested(_ copyID: Int64) {
        guard let s = library.suggestPlacement(for: copyID, rules: rules) else { return }
        move(copyID, to: s.locationID, index: s.index)
    }

    func placeAllAsSuggested() {
        for id in unplacedItems.map(\.id) {
            if let s = library.suggestPlacement(for: id, rules: rules) {
                do { try store.move(copyID: id, to: s.locationID, index: s.index) }
                catch { errorMessage = error.localizedDescription; break }
                library = (try? store.loadLibrary(medium: medium)) ?? library
            }
        }
        reload()
    }

    func setStatus(_ copyID: Int64, _ status: CopyStatus, note: String? = nil) {
        perform { try store.setStatus(copyID: copyID, status, note: note) }
    }

    /// Sætter status fra en menu. "Udlånt" og "Opbevaret andet sted" spørger først
    /// efter navn eller sted (samme dialog som i plade-detaljen). "På plads" for en
    /// plade, der er ude, åbner "Sæt tilbage"-guiden i stedet for at skifte status med det samme.
    func chooseStatus(_ copyID: Int64, _ status: CopyStatus) {
        if status == .home, isAway(copyID) {
            startReturn(copyID)
        } else if status.wantsNote {
            statusNoteRequest = StatusNoteRequest(copyID: copyID, status: status,
                                                  note: library.copies[copyID]?.statusNote ?? "")
        } else {
            setStatus(copyID, status)
        }
    }

    /// Pladen står ikke i reolen (på væggen, udlånt, opbevaret andet sted eller mangler).
    func isAway(_ copyID: Int64) -> Bool {
        library.copies[copyID].map { !$0.status.isOnShelf } ?? false
    }

    /// Start på at sætte en plade tilbage. Har den en plads i reolen, vises guiden
    /// (samme udseende som Find). En plade uden plads får status "På plads" og går
    /// til den almindelige placering (Flyt-arket med foreslået plads).
    func startReturn(_ copyID: Int64) {
        guard library.copies[copyID] != nil else { return }
        if library.locationOfCopy[copyID] != nil {
            returnCopy = copyID
        } else {
            if isAway(copyID) { setStatus(copyID, .home) }
            moveCopy = copyID
        }
    }

    /// "Sat på plads" i guiden: nu står pladen i reolen igen.
    func finishReturn(_ copyID: Int64) {
        if isAway(copyID) { setStatus(copyID, .home) }
        if returnCopy == copyID { returnCopy = nil }
    }

    /// Sektionen, som "Kontrollér sektion" skal åbne: den viste sektion eller den
    /// valgte plades sektion.
    var sectionToCheck: Int64? {
        if case .section(let id) = sidebar, library.location(id) != nil { return id }
        return selection.flatMap { library.locationOfCopy[$0] }
    }

    func setSortOverrides(_ copyID: Int64, artist: String?, title: String?) {
        perform { try store.setSortOverrides(copyID: copyID, artist: artist, title: title) }
    }

    // MARK: - Lytning

    /// Et dobbelttryk (samme plade inden for 2 minutter) registreres kun én gang.
    /// Returnerer `false`, når registreringen blev sprunget over.
    @discardableResult
    func logPlay(_ copyID: Int64) -> Bool {
        if let last = stats.lastPlayed[copyID], Date().timeIntervalSince(last) < Self.replayWindow { return false }
        perform { try store.logPlay(copyID: copyID) }
        return true
    }

    /// Tidsrum, hvor endnu et "Spillet" på samme plade regnes som et dobbelttryk.
    static let replayWindow: TimeInterval = 120

    func deletePlay(_ id: Int64) { perform { try store.deletePlay(id) } }

    func pickRecord() {
        let candidates = ListenPicker.candidates(library.allItems, library: library, filter: listenFilter, stats: stats)
        var rng = SystemRandomNumberGenerator()
        guard let pick = ListenPicker.pick(from: candidates, stats: stats, avoiding: recentPicks, using: &rng) else {
            // Ingen plader passer: vis ikke et gammelt forslag, der ikke matcher filteret.
            clearPick()
            return
        }
        currentPick = pick.id
        selection = pick.id
        recentPicks.append(pick.id)
        if recentPicks.count > 20 { recentPicks.removeFirst() }
    }

    /// Nulstiller forslaget og – hvis det var forslaget, der var valgt – også valget.
    func clearPick() {
        guard let pick = currentPick else { return }
        if selection == pick { selection = nil }
        currentPick = nil
    }

    // MARK: - Skilte og scanning

    func exportLabels() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Reolskilte.pdf"
        panel.allowedContentTypes = [.pdf]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let labels = ShelfLabel.labels(for: library)
        do {
            try LabelsPDF.write(labels, to: url)
            for l in labels { try store.setScanCode(locationID: l.location.id, code: l.scanCode) }
            reload()
            NSWorkspace.shared.open(url)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Åbner en sektion fra en scannet eller klikket `vinylshelf://section/<id>`-kode.
    func open(_ url: URL) {
        guard let id = ShelfLabel.locationID(fromScanCode: url.absoluteString), library.location(id) != nil else { return }
        sidebar = .section(id)
        selection = library.sections[id]?.first
    }

    func keepLocalOnly(_ copyID: Int64) { perform { try store.keepLocalOnly(copyID: copyID) } }

    func deleteCopy(_ copyID: Int64) {
        if selection == copyID { selection = nil }
        if findModeCopy == copyID { findModeCopy = nil }
        if returnCopy == copyID { returnCopy = nil }
        if moveCopy == copyID { moveCopy = nil }
        if currentPick == copyID { currentPick = nil }
        perform { try store.deleteCopy(copyID) }
    }

    func unplace(_ copyID: Int64) { perform { try store.unplace(copyID: copyID) } }

    /// "Det er en cd" / "Det er en plade" (`nil`: følg Discogs' format). Kopien forsvinder fra
    /// den viste hylde og venter under "Nye cd'er"/"Nye plader" på den anden.
    func setMedium(_ copyID: Int64, _ new: Medium?) {
        if selection == copyID { selection = nil }
        if currentPick == copyID { currentPick = nil }
        perform { try store.setMedium(copyID: copyID, new) }
    }

    func addSection(shelf: Int) {
        let existing = library.locations.filter { $0.shelf == shelf }.count
        perform { try store.addSection(shelf: shelf, section: LayoutPlanner.sectionLetter(existing), medium: medium) }
    }

    func deleteSection(_ id: Int64) {
        if sidebar == .section(id) { sidebar = .search }
        perform { try store.deleteEmptySection(id) }
    }

    func updateRules(_ new: SortRules) {
        rules = new
        do { try store.saveSortRules(new) } catch { errorMessage = error.localizedDescription }
    }

    func undo(_ entry: HistoryEntry) {
        guard let copy = entry.copyID, let from = entry.fromLocationID, let pos = entry.fromPosition,
              library.location(from) != nil, library.copies[copy] != nil else {
            errorMessage = "Denne ændring kan ikke fortrydes (pladen eller sektionen findes ikke længere)."
            return
        }
        move(copy, to: from, index: pos - 1)
    }

    func createLayout(_ plan: [LayoutPlanner.SectionPlan]) {
        let sorted = rules.sorted(library.allItems.filter { $0.copy.inDiscogs }).map(\.id)
        let parts = LayoutPlanner.split(sorted, plan: plan)
        perform {
            try store.createLayout(zip(plan, parts).map { (shelf: $0.shelf, section: $0.section, copies: $1) }, medium: medium)
        }
        forceOnboarding = false
        sidebar = .search
        focusSearchRequest += 1
    }

    // MARK: - Discogs

    func connect(token: String) async -> Bool {
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return false }
        // Demo-tilstand må hverken røre nøgleringen eller Discogs.
        guard !isDemo else {
            errorMessage = "Demo-tilstanden forbinder ikke til Discogs. Start appen uden --demo."
            return false
        }
        do {
            let name = try await DiscogsClient(token: token).identity()
            try Keychain.saveToken(token)
            findNew.resetClient()
            store.setSetting("discogs_username", name)
            username = name
            hasToken = true
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func disconnect() {
        guard !isDemo else { return }
        Keychain.deleteToken()
        findNew.resetClient()
        hasToken = false
    }

    func sync(showReport: Bool = true) async {
        guard case .idle = syncState.normalizedForStart else { return }
        guard !isDemo else { return }
        guard let token = Keychain.loadToken(), let username else {
            syncState = .failed(DiscogsError.missingToken.localizedDescription)
            return
        }
        syncState = .running(done: 0, total: 0)
        do {
            let items = try await DiscogsClient(token: token).fetchCollection(username: username) { done, total in
                // Kan nå frem efter at sync er færdig – må ikke sætte tilstanden tilbage til
                // "running" (så hænger knappen, og ny sync blokeres).
                Task { @MainActor in
                    if case .running = self.syncState { self.syncState = .running(done: done, total: total) }
                }
            }
            let report = try store.applyCollection(items)
            syncState = .idle
            reload()
            lastReport = report
            if showReport && !library.locations.isEmpty { showSyncReport = true }
            if !report.newCopies.isEmpty && !library.locations.isEmpty { sidebar = .newRecords }
        } catch {
            syncState = .failed(error.localizedDescription)
        }
    }
}

// MARK: - Sikkerhedskopi

extension AppModel {
    /// Tager en kopi ved start, hvis der ikke er taget en i dag, og tjekker igen hver time
    /// (appen står ofte åben i flere dage). Aldrig i demo- eller snapshot-tilstand.
    func startBackups() {
        guard !isDemo, !CommandLine.arguments.contains("--snapshot") else { return }
        lastBackup = DatabaseBackup.latest(in: backupFolder)
        backupTask?.cancel()
        backupTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.backupIfDue()
                try? await Task.sleep(for: .seconds(3600))
            }
        }
    }

    func backupIfDue() {
        if DatabaseBackup.isDue(latest: lastBackup) { backupNow() }
    }

    /// "Tag en kopi nu" i Indstillinger (erstatter dagens kopi).
    func backupNow() {
        guard !isDemo else { return }
        do {
            try DatabaseBackup.run(store: store, to: backupFolder)
            lastBackup = Date()
            backupError = nil
        } catch {
            backupError = error.localizedDescription
        }
    }

    func showBackupsInFinder() {
        try? FileManager.default.createDirectory(at: backupFolder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(backupFolder)
    }
}

extension AppModel {
    /// Henter Discogs' samlingsestimat og markedsdata pr. release. Springer releases over,
    /// der er hentet i samme valuta inden for 7 dage.
    func refreshValues() async {
        guard case .idle = valueState.normalizedForStart else { return }
        guard !isDemo else { return }
        guard let token = Keychain.loadToken(), let username else {
            valueState = .failed(DiscogsError.missingToken.localizedDescription)
            return
        }
        let client = DiscogsClient(token: token)
        let cutoff = Date().addingTimeInterval(-7 * 24 * 3600)
        let ids = Set(library.copies.values.filter(\.inDiscogs).map(\.releaseID)).sorted()
        let stale = ids.filter { id in
            guard let m = market[id] else { return true }
            return m.currency != currency || m.fetchedAt < cutoff
        }
        valueState = .running(done: 0, total: stale.count)
        do {
            if let v = try? await client.collectionValue(username: username) {
                collectionValue = v
                store.saveCollectionValue(v)
            }
            let discogsCurrency = stale.isEmpty ? nil : try? await client.userCurrency(username: username)
            for (i, id) in stale.enumerated() {
                do {
                    let m = try await client.releaseMarketInfo(releaseID: id, discogsCurrency: discogsCurrency, appCurrency: currency)
                    try store.saveMarket(id, m)
                    market[id] = m
                } catch DiscogsError.http(404) {
                    // Releasen findes ikke længere på Discogs – spring den over i stedet
                    // for at stoppe hele opdateringen.
                }
                valueState = .running(done: i + 1, total: stale.count)
                // Hold os under Discogs' grænse på 60 forespørgsler i minuttet.
                try await Task.sleep(nanoseconds: 1_050_000_000)
            }
            valueState = .idle
        } catch {
            valueState = .failed(error.localizedDescription)
        }
    }
}

private extension SyncState {
    var normalizedForStart: SyncState {
        if case .failed = self { return .idle }
        return self
    }
}

extension SyncState {
    /// Kun selve fasen – bruges som animationsværdi, så fremdriftstal ikke animerer hele visningen.
    enum Phase: Equatable { case idle, running, failed }
    var phase: Phase {
        switch self {
        case .idle: return .idle
        case .running: return .running
        case .failed: return .failed
        }
    }
}

/// Spørgsmålet om navn (udlånt) eller sted (opbevaret andet sted).
struct StatusNoteRequest: Identifiable, Equatable {
    let copyID: Int64
    let status: CopyStatus
    let note: String
    var id: Int64 { copyID }
}

extension CopyStatus {
    /// Statusser, hvor appen spørger efter et navn eller et sted.
    var wantsNote: Bool { self == .lent || self == .stored }

    /// Kort tekst til lister, fx "Udlånt til Jens" eller "Opbevaret: kælderen".
    func listText(note: String?) -> String {
        let n = note?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !n.isEmpty else { return label }
        switch self {
        case .lent: return "Udlånt til \(n)"
        case .stored: return "Opbevaret: \(n)"
        default: return "\(label) – \(n)"
        }
    }
}

// MARK: - Dansk dato

extension Date {
    private static let danishDateTime: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "da_DK")
        f.dateFormat = "d. MMM y 'kl.' HH.mm"
        return f
    }()
    private static let danishDate: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "da_DK")
        f.dateFormat = "d. MMM y"
        return f
    }()

    /// "1. okt. 2026 kl. 10.26" – uanset systemets sprog og region.
    var danskDatoTid: String { Self.danishDateTime.string(from: self) }
    /// "1. okt. 2026".
    var danskDato: String { Self.danishDate.string(from: self) }
}
