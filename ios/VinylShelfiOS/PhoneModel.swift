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
    private(set) var libraries: [Medium: Library] = [:]
    private var indexes: [Medium: SearchIndex] = [:]
    private(set) var stats: ListeningStats = .empty
    /// Hylden, der vises under Reol.
    var medium: Medium = .vinyl

    var library: Library { libraries[medium] ?? .empty }
    func library(_ m: Medium) -> Library { libraries[m] ?? .empty }
    /// Medier med reoler (Plader først).
    var media: [Medium] { Medium.allCases.filter { !(libraries[$0]?.locations.isEmpty ?? true) } }
    var errorMessage: String?

    /// Åbnes fra en QR-kode eller et link (vinylshelf://section/…).
    var openedSection: OpenedSection?
    struct OpenedSection: Identifiable, Equatable { let medium: Medium; let locationID: Int64; var id: Int64 { locationID } }

    let cloud = CloudClient()
    var cloudLoggedIn = false
    var cloudEmail: String?
    var cloudPhase: CloudPhase = .idle
    var cloudLastSync: Date?
    var cloudChoice: CloudSync.NeedsChoice?
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
            for m in Medium.allCases {
                let lib = try store.loadLibrary(medium: m)
                libraries[m] = lib
                indexes[m] = SearchIndex(library: lib)
            }
            stats = ListeningStats(plays: try store.loadPlays())
            if !media.contains(medium), let first = media.first { medium = first }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    var hasShelves: Bool { !media.isEmpty }

    /// Søgning i plader og cd'er (også på sange). Plader først ved samme relevans.
    /// `track` er sangen, der passede, når resultatet er fundet på en sang.
    func search(_ query: String) -> [(medium: Medium, item: RecordItem, track: Track?)] {
        Medium.allCases.flatMap { m in
            (indexes[m]?.hits(query) ?? []).compactMap { h in library(m).item(h.id).map { (m, $0, h.track) } }
        }
    }

    /// Den sektion (og hylde), en QR-kode peger på.
    func section(forScanCode code: String) -> (medium: Medium, location: Location)? {
        for m in Medium.allCases { if let l = library(m).location(forScanCode: code) { return (m, l) } }
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
        } catch let choice as CloudSync.NeedsChoice {
            if cloudChoicePostponed && !userInitiated {
                cloudPhase = .failed("Vælg, hvilke reoler der skal bruges: træk ned for at synkronisere.")
            } else {
                cloudChoicePostponed = false
                cloudChoice = choice
                cloudPhase = .idle
            }
        } catch let e as CloudError where e.needsLogin {
            logOutCloud()
            cloudPhase = .failed("Du er logget ud af kontoen. Log ind igen for at synkronisere.")
        } catch {
            cloudPhase = .failed(error.localizedDescription)
        }
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
