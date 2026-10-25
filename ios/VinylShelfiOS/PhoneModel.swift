import Foundation
import Observation
import VinylCore

/// Status for kontoen (vises under Konto).
enum CloudPhase: Equatable {
    case idle
    case syncing
    case failed(String)
}

/// iPhone-appens tilstand. Data kommer fra kontoen i skyen (der er ingen Discogs-forbindelse på telefonen).
/// Login og synkronisering følger samme forløb som Mac (AppModel+Cloud.swift) og Windows (AppModel.Cloud.cs).
@MainActor @Observable
final class PhoneModel {
    static let cloudDevice = "iphone"

    let store: ShelfStore
    /// Plader og cd'er har hver deres reoler (som på Mac).
    private(set) var libraries: [ShelfKind: Library] = [:]
    private var indexes: [ShelfKind: SearchIndex] = [:]
    private(set) var stats: ListeningStats = .empty
    /// Hylden, der vises under Reol.
    var medium: ShelfKind = .vinyl

    var library: Library { libraries[medium] ?? .empty }
    func library(_ m: ShelfKind) -> Library { libraries[m] ?? .empty }
    /// Medier med reoler (Plader først).
    var media: [ShelfKind] { ShelfKind.all.filter { !(libraries[$0]?.locations.isEmpty ?? true) } }
    var errorMessage: String?

    /// Sorteringsreglerne fra computeren (følger med via kontoen) og fluebenene i sorteringslisten pr. hylde.
    private(set) var rules = SortRules()
    private(set) var sortChecked: [ShelfKind: Set<Int64>] = [:]

    /// Flueben i sorteringslisten (som på Mac); følger med til de andre enheder via kontoen.
    func setSortChecked(_ m: ShelfKind, _ copyID: Int64, _ checked: Bool) {
        store.setSortChecked(m, copyID: copyID, checked: checked)
        sortChecked[m] = store.sortChecked(m)
        cloudChanged()
    }

    func clearSortChecked(_ m: ShelfKind) {
        store.clearSortChecked(m)
        sortChecked[m] = []
        cloudChanged()
    }

    /// "Hvad skal jeg høre?": filtre og de seneste forslag (som på Mac).
    var listenFilter = ListenFilter()
    private(set) var recentPicks: [Int64] = []
    private(set) var currentPick: Int64?
    func rememberPick(_ id: Int64) {
        currentPick = id
        recentPicks.append(id)
        if recentPicks.count > 20 { recentPicks.removeFirst() }
    }

    /// Åbnes fra en QR-kode eller et link (vinylshelf://section/…).
    var openedSection: OpenedSection?
    struct OpenedSection: Identifiable, Equatable { let medium: ShelfKind; let locationID: Int64; var id: Int64 { locationID } }

    let cloud = CloudClient()
    var cloudLoggedIn = false
    var cloudEmail: String?
    var cloudPhase: CloudPhase = .idle
    var cloudLastSync: Date?
    var cloudChoice: CloudSync.NeedsChoice?
    /// Totrinslogin: kontoen kræver koden fra kode-appen, før der kan synkroniseres (nil = ingen kode mangler).
    var cloudNeedsCode: CloudFactor?
    /// Totrinslogin er slået til på kontoen (nil = ikke hentet endnu).
    var cloudSecondFactorOn: Bool?
    /// Guiden til totrinslogin: tilbuddet én gang efter login og knappen under Konto. Vises fra RootView (uden for
    /// listerne), så en synkronisering ikke lukker den, når man kommer tilbage fra Adgangskoder.
    var showSecondFactorGuide = false
    /// Guidens trin og den påbegyndte kode. Bevares, hvis guiden tegnes forfra, så koden, der allerede er gemt i
    /// kode-appen, stadig passer (en ny `beginSecondFactor` sletter den halvfærdige).
    var secondFactorStep = 0
    var secondFactorEnrollment: TOTPEnrollment?
    @ObservationIgnored private var cloudSession: CloudSession?
    @ObservationIgnored private var cloudDebounce: Task<Void, Never>?
    @ObservationIgnored private var cloudChoicePostponed = false

    init() {
        do {
            store = try ShelfStore(path: ShelfStore.defaultURL.path)
        } catch {
            // Databasen kunne ikke åbnes: start med en tom i hukommelsen, så appen ikke går ned.
            store = try! ShelfStore(path: ":memory:")
            errorMessage = "Databasen kunne ikke åbnes: \(error.localizedDescription)"
        }
        reload()
        cloudLoggedIn = KeychainSecret.cloudSession.exists
        cloudEmail = store.setting("cloud_email")
        cloudLastSync = store.setting("cloud_last_sync").flatMap(Double.init).map(Date.init(timeIntervalSince1970:))
    }

    func reload() {
        do {
            // Plader og cd'er altid; kategorierne, når de har egne reoler eller kopier.
            let counts = try store.shelfCounts()
            libraries = [:]; indexes = [:]
            for m in ShelfKind.all where m.category == nil || counts[m] != nil {
                let lib = try store.loadLibrary(kind: m)
                libraries[m] = lib
                indexes[m] = SearchIndex(library: lib)
            }
            stats = ListeningStats(plays: try store.loadPlays())
            rules = store.loadSortRules()
            for m in ShelfKind.all { sortChecked[m] = store.sortChecked(m) }
            if !media.contains(medium), let first = media.first { medium = first }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    var hasShelves: Bool { !media.isEmpty }

    /// Søgning i plader og cd'er (også på sange). Plader først ved samme relevans.
    /// `track` er sangen, der passede, når resultatet er fundet på en sang.
    func search(_ query: String) -> [(medium: ShelfKind, item: RecordItem, track: Track?)] {
        ShelfKind.all.flatMap { m in
            (indexes[m]?.hits(query) ?? []).compactMap { h in library(m).item(h.id).map { (m, $0, h.track) } }
        }
    }

    /// Den sektion (og hylde), en QR-kode peger på.
    func section(forScanCode code: String) -> (medium: ShelfKind, location: Location)? {
        for m in ShelfKind.all { if let l = library(m).location(forScanCode: code) { return (m, l) } }
        return nil
    }

    // MARK: Spillet

    /// Tidsrum, hvor endnu et "Spillet" på samme plade regnes som et dobbelttryk (som på Mac).
    static let replayWindow: TimeInterval = 120

    /// Registrerer, at pladen er spillet. `false`, hvis det var et dobbelttryk.
    @discardableResult
    func logPlay(_ copyID: Int64) -> Bool {
        if let last = stats.lastPlayed[copyID], Date().timeIntervalSince(last) < Self.replayWindow { return false }
        do { _ = try store.logPlay(copyID: copyID) } catch { errorMessage = error.localizedDescription; return false }
        reload()
        cloudChanged()
        return true
    }

    // MARK: QR-koder og links

    func open(_ url: URL) {
        if completeCloudLink(url) { return }
        _ = openScanned(url.absoluteString)
    }

    /// Fra scanneren. `false`, hvis koden ikke hører til en sektion.
    func openScanned(_ code: String) -> Bool {
        guard let hit = section(forScanCode: code) else { return false }
        openedSection = OpenedSection(medium: hit.medium, locationID: hit.location.id)
        return true
    }

    // MARK: Login

    func requestCloudCode(email: String) async -> Bool {
        let e = email.trimmingCharacters(in: .whitespaces).lowercased()
        do { try await cloud.requestCode(email: e); cloudPhase = .idle; return true }
        catch { cloudPhase = .failed(error.localizedDescription); return false }
    }

    /// Login med e-mail og adgangskode (adgangskoden vælges under Konto i appen på computeren).
    func signInCloud(email: String, password: String) async -> Bool {
        let e = email.trimmingCharacters(in: .whitespaces).lowercased()
        do { loggedIn(try await cloud.signIn(email: e, password: password)); return true }
        catch { cloudPhase = .failed(error.localizedDescription); return false }
    }

    /// Feltet under Konto: koden fra mailen eller det kopierede link.
    func completeCloudInput(email: String, text: String) async -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.contains("/") || t.contains(":") { return await completeCloudPaste(t) }
        let e = email.trimmingCharacters(in: .whitespaces).lowercased()
        do {
            loggedIn(try await cloud.verify(email: e, code: t.filter(\.isNumber)))
            return true
        } catch {
            cloudPhase = .failed(error.localizedDescription)
            return false
        }
    }

    private func completeCloudPaste(_ text: String) async -> Bool {
        do {
            if let s = try await cloud.verifyEmailLink(text) { loggedIn(s); return true }
        } catch {
            cloudPhase = .failed(error.localizedDescription)
            return false
        }
        if let url = URL(string: text), completeCloudLink(url) { return cloudLoggedIn }
        cloudPhase = .failed("Det indsatte er ikke et login-link. Kopiér linket fra mailen (hold fingeren på linket › Kopiér).")
        return false
    }

    /// Linket i login-mailen åbner appen (vinylshelf://auth#…). `true`, hvis adressen var et login.
    @discardableResult
    func completeCloudLink(_ url: URL) -> Bool {
        do {
            guard let s = try CloudClient.session(fromLink: url) else { return false }
            loggedIn(s)
        } catch {
            cloudPhase = .failed(error.localizedDescription)
        }
        return true
    }

    private func loggedIn(_ s: CloudSession) {
        do { try saveCloudSession(s) } catch { cloudPhase = .failed(error.localizedDescription); return }
        cloudLoggedIn = true
        let email = s.email.isEmpty ? (cloudEmail ?? "") : s.email
        cloudEmail = email
        store.setSetting("cloud_email", email)
        cloudPhase = .idle
        Task { await syncCloud() }
    }

    func logOutCloud() {
        cloudDebounce?.cancel()
        KeychainSecret.cloudSession.delete()
        cloudSession = nil
        cloudLoggedIn = false
        cloudNeedsCode = nil
        cloudSecondFactorOn = nil
        cloudPhase = .idle
        // Data på telefonen bliver, hvor de er, og det sidst synkroniserede huskes (som på Mac og Windows).
    }

    private func saveCloudSession(_ s: CloudSession) throws {
        try KeychainSecret.cloudSession.save(String(decoding: try JSONEncoder().encode(s), as: UTF8.self))
        cloudSession = s
    }

    private func validCloudSession() async throws -> CloudSession {
        if cloudSession == nil, let json = KeychainSecret.cloudSession.load() {
            cloudSession = try? JSONDecoder().decode(CloudSession.self, from: Data(json.utf8))
        }
        guard var s = cloudSession else { throw CloudError("Du skal logge ind igen.", needsLogin: true) }
        if s.isExpired {
            s = try await cloud.refresh(s)
            try saveCloudSession(s)
        }
        return s
    }

    // MARK: Synkronisering

    /// Kort efter en ændring (flere ændringer i træk giver én synkronisering).
    func cloudChanged() {
        guard cloudLoggedIn else { return }
        cloudDebounce?.cancel()
        cloudDebounce = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            await self?.syncCloud()
        }
    }

    /// `userInitiated`: brugeren bad selv om det (så stilles et udskudt spørgsmål igen).
    func syncCloud(firstSync: CloudSync.FirstSync? = nil, userInitiated: Bool = false) async {
        guard cloudLoggedIn, cloudPhase != .syncing else { return }
        cloudPhase = .syncing
        do {
            let s = try await validCloudSession()
            // Totrinslogin: kontoen kræver koden, og dette login har den ikke endnu. Intet hentes eller sendes.
            if let f = try await cloud.pendingSecondFactor(session: s) {
                cloudNeedsCode = f
                cloudSecondFactorOn = true
                cloudPhase = .failed(CloudClient.secondFactorRequired.message)
                return
            }
            let report = try await CloudSync.run(store: store, client: cloud, session: s, device: Self.cloudDevice,
                                                 firstSync: firstSync, safetyCopy: { [store] in
                let folder = DatabaseBackup.defaultFolder()
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try DataTransfer.safetyCopy(store, folder: folder, reason: "konto")
            })
            if report.received > 0 { reload() }
            cloudLastSync = Date()
            store.setSetting("cloud_last_sync", String(Date().timeIntervalSince1970))
            cloudPhase = .idle
            await offerSecondFactorOnce(s)
        } catch let choice as CloudSync.NeedsChoice {
            if cloudChoicePostponed && !userInitiated {
                cloudPhase = .failed("Vælg, hvilke reoler der skal bruges: træk ned for at synkronisere.")
            } else {
                cloudChoicePostponed = false
                cloudChoice = choice
                cloudPhase = .idle
            }
        } catch let e as CloudError where e.needsSecondFactor {
            if let s = try? await validCloudSession() { cloudNeedsCode = try? await cloud.pendingSecondFactor(session: s) }
            cloudPhase = .failed(e.message)
        } catch let e as CloudError where e.needsLogin {
            logOutCloud()
            cloudPhase = .failed("Du er logget ud af kontoen. Log ind igen for at synkronisere.")
        } catch {
            cloudPhase = .failed(error.localizedDescription)
        }
    }

    // MARK: Totrinslogin (samme forløb som Mac, AppModel+Cloud.swift)

    /// Koden fra kode-appen, når kontoen kræver den. `nil` = koden passede, ellers fejlbeskeden.
    func submitSecondFactorCode(_ code: String) async -> String? {
        guard let f = cloudNeedsCode else { return nil }
        do {
            let s = try await cloud.verifySecondFactor(factorID: f.id, code: code, session: try await validCloudSession())
            try saveCloudSession(s)
            cloudNeedsCode = nil
            cloudSecondFactorOn = true
            cloudPhase = .idle
            await syncCloud()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func refreshSecondFactorStatus() async {
        guard cloudLoggedIn, let s = try? await validCloudSession(), let factors = try? await cloud.factors(session: s) else { return }
        cloudSecondFactorOn = factors.contains(where: \.verified)
    }

    func beginSecondFactor() async throws -> TOTPEnrollment {
        try await cloud.enrollSecondFactor(session: try await validCloudSession())
    }

    func confirmSecondFactor(_ e: TOTPEnrollment, code: String) async -> String? {
        do {
            let s = try await cloud.verifySecondFactor(factorID: e.factorID, code: code, session: try await validCloudSession())
            try saveCloudSession(s)
            cloudSecondFactorOn = true
            secondFactorEnrollment = nil
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// Åbner guiden forfra (en påbegyndt kode genbruges).
    func openSecondFactorGuide() {
        secondFactorStep = 0
        showSecondFactorGuide = true
    }

    func disableSecondFactor() async -> String? {
        do {
            let s = try await validCloudSession()
            for f in try await cloud.factors(session: s) { try await cloud.removeSecondFactor(factorID: f.id, session: s) }
            cloudSecondFactorOn = false
            secondFactorEnrollment = nil
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// Én gang efter login: et venligt tilbud om totrinslogin, hvis det ikke allerede er slået til.
    private func offerSecondFactorOnce(_ s: CloudSession) async {
        guard !UserDefaults.standard.bool(forKey: "mfa_offer_shown"), let factors = try? await cloud.factors(session: s) else { return }
        UserDefaults.standard.set(true, forKey: "mfa_offer_shown")
        cloudSecondFactorOn = factors.contains(where: \.verified)
        if cloudSecondFactorOn == false { openSecondFactorGuide() }
    }

    func resolveCloudChoice(_ choice: CloudSync.FirstSync) {
        cloudChoice = nil
        Task { await syncCloud(firstSync: choice) }
    }

    func postponeCloudChoice() {
        cloudChoice = nil
        cloudChoicePostponed = true
    }
}
