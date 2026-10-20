import Foundation
import VinylCore

/// Status for kontoen i skyen (vises i Indstillinger › Konto).
enum CloudPhase: Equatable {
    case idle
    case syncing
    case failed(String)
}

// Kontoen i skyen: login med e-mail-kode og automatisk synkronisering
// (ved start, kort efter hver ændring og hvert 5. minut). Samme forløb som Windows (CloudModel.cs).
extension AppModel {
    static let cloudDevice = "mac"

    func startCloud() {
        guard cloudEnabled else { return }
        cloudLoggedIn = KeychainSecret.cloudSession.exists
        cloudEmail = store.setting("cloud_email")
        cloudLastSync = store.setting("cloud_last_sync").flatMap(Double.init).map(Date.init(timeIntervalSince1970:))
        guard cloudLoggedIn else { return }
        Task { await syncCloud() }
        cloudTimer?.cancel()
        cloudTimer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(300))
                await self?.syncCloud()
            }
        }
    }

    /// Kort efter en ændring (flere ændringer i træk giver én synkronisering).
    func cloudChanged() {
        guard cloudEnabled, cloudLoggedIn else { return }
        cloudDebounce?.cancel()
        cloudDebounce = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            await self?.syncCloud()
        }
    }

    // MARK: Login

    func requestCloudCode(email: String) async -> Bool {
        let e = email.trimmingCharacters(in: .whitespaces).lowercased()
        do { try await cloud.requestCode(email: e); return true }
        catch { cloudPhase = .failed(error.localizedDescription); return false }
    }

    func verifyCloudCode(email: String, code: String) async -> Bool {
        let e = email.trimmingCharacters(in: .whitespaces).lowercased()
        let c = code.filter(\.isNumber)
        do {
            let s = try await cloud.verify(email: e, code: c)
            try saveCloudSession(s)
            cloudLoggedIn = true
            cloudEmail = s.email
            store.setSetting("cloud_email", s.email)
            cloudPhase = .idle
            startCloud()
            return true
        } catch {
            cloudPhase = .failed(error.localizedDescription)
            return false
        }
    }

    /// Login med e-mail og adgangskode (ingen mail).
    func signInCloud(email: String, password: String) async -> Bool {
        let e = email.trimmingCharacters(in: .whitespaces).lowercased()
        do {
            let s = try await cloud.signIn(email: e, password: password)
            try saveCloudSession(s)
            cloudLoggedIn = true
            cloudEmail = s.email.isEmpty ? e : s.email
            store.setSetting("cloud_email", cloudEmail)
            cloudPhase = .idle
            startCloud()
            return true
        } catch {
            cloudPhase = .failed(error.localizedDescription)
            return false
        }
    }

    /// Vælger kontoens adgangskode, så andre enheder kan logge ind uden mail. `nil` = gemt, ellers fejlbeskeden.
    func setCloudPassword(_ password: String) async -> String? {
        do {
            try await cloud.setPassword(password, session: try await validCloudSession())
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// Linket i login-mailen åbner appen (vinylshelf://auth#…). Returnerer true, hvis adressen var et login.
    @discardableResult
    func completeCloudLink(_ url: URL) -> Bool {
        do {
            guard let s = try CloudClient.session(fromLink: url) else { return false }
            guard cloudEnabled else { return true }
            try saveCloudSession(s)
            cloudLoggedIn = true
            let email = s.email.isEmpty ? (cloudEmail ?? "") : s.email
            cloudEmail = email
            store.setSetting("cloud_email", email)
            cloudPhase = .idle
            startCloud()
        } catch {
            cloudPhase = .failed(error.localizedDescription)
        }
        return true
    }

    /// Indsat tekst i fanen Konto: linket fra mailen, eller adressen fra en browserside.
    /// Feltet i fanen Konto: koden fra mailen eller det kopierede link.
    func completeCloudInput(email: String, text: String) async -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.contains("/") || t.contains(":") { return await completeCloudPaste(t) }
        return await verifyCloudCode(email: email, code: t)
    }

    func completeCloudPaste(_ text: String) async -> Bool {
        do {
            if let s = try await cloud.verifyEmailLink(text) {
                try saveCloudSession(s)
                cloudLoggedIn = true
                let email = s.email.isEmpty ? (cloudEmail ?? "") : s.email
                cloudEmail = email
                store.setSetting("cloud_email", email)
                cloudPhase = .idle
                startCloud()
                return true
            }
        } catch {
            cloudPhase = .failed(error.localizedDescription)
            return false
        }
        if let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)), completeCloudLink(url) { return cloudLoggedIn }
        cloudPhase = .failed("Det indsatte er ikke et login-link. Kopiér linket fra mailen (højreklik › Kopiér link).")
        return false
    }

    func logOutCloud() {
        cloudTimer?.cancel()
        cloudDebounce?.cancel()
        KeychainSecret.cloudSession.delete()
        cloudSession = nil
        cloudLoggedIn = false
        cloudNeedsCode = nil
        cloudSecondFactorOn = nil
        cloudPhase = .idle
        // Data på denne Mac bliver, hvor de er, og det sidst synkroniserede huskes, så ændringer, der laves
        // imens, sendes op ved næste login. Logger man ind på en anden konto, sammenlignes der forfra (CloudSync.run).
    }

    fileprivate func saveCloudSession(_ s: CloudSession) throws {
        let json = String(data: try JSONEncoder().encode(s), encoding: .utf8) ?? ""
        try KeychainSecret.cloudSession.save(json)
        cloudSession = s
    }

    /// Gyldigt login (hentet fra nøgleringen og fornyet efter behov).
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

    // MARK: Totrinslogin

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

    /// Henter, om totrinslogin er slået til (til fanen Konto).
    func refreshSecondFactorStatus() async {
        guard cloudEnabled, cloudLoggedIn, let s = try? await validCloudSession(),
              let factors = try? await cloud.factors(session: s) else { return }
        cloudSecondFactorOn = factors.contains(where: \.verified)
    }

    /// Guiden, trin 3: koden til kode-appen.
    func beginSecondFactor() async throws -> TOTPEnrollment {
        try await cloud.enrollSecondFactor(session: try await validCloudSession())
    }

    /// Guiden, trin 4: den første kode fra kode-appen slår totrinslogin til. `nil` = slået til, ellers fejlbeskeden.
    func confirmSecondFactor(_ e: TOTPEnrollment, code: String) async -> String? {
        do {
            let s = try await cloud.verifySecondFactor(factorID: e.factorID, code: code, session: try await validCloudSession())
            try saveCloudSession(s)
            cloudSecondFactorOn = true
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// Slår totrinslogin fra (kun fra et login, hvor koden er skrevet). `nil` = slået fra, ellers fejlbeskeden.
    func disableSecondFactor() async -> String? {
        do {
            let s = try await validCloudSession()
            for f in try await cloud.factors(session: s) { try await cloud.removeSecondFactor(factorID: f.id, session: s) }
            cloudSecondFactorOn = false
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
        if cloudSecondFactorOn == false { showSecondFactorGuide = true }
    }

    // MARK: Synkronisering

    /// `userInitiated`: brugeren trykkede "Synkronisér nu" (så stilles et udskudt spørgsmål igen).
    func syncCloud(firstSync: CloudSync.FirstSync? = nil, userInitiated: Bool = false) async {
        guard cloudEnabled, cloudLoggedIn, cloudPhase != .syncing else { return }
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
                                                 firstSync: firstSync, safetyCopy: { [self] in try cloudSafetyCopy() })
            if report.received > 0 {
                cloudApplying = true
                reloadSettingsFromStore()
                reload()
                cloudApplying = false
            }
            cloudLastSync = Date()
            store.setSetting("cloud_last_sync", String(Date().timeIntervalSince1970))
            cloudPhase = .idle
            await offerSecondFactorOnce(s)
        } catch let choice as CloudSync.NeedsChoice {
            if cloudChoicePostponed && !userInitiated {
                cloudPhase = .failed("Vælg, hvilke reoler der skal bruges: tryk Synkronisér nu.")
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

    func resolveCloudChoice(_ choice: CloudSync.FirstSync) {
        cloudChoice = nil
        Task { await syncCloud(firstSync: choice) }
    }

    func postponeCloudChoice() {
        cloudChoice = nil
        cloudChoicePostponed = true
    }

    /// Sikkerhedskopi, før synkroniseringen sletter reoler på denne Mac (kan importeres igen).
    private func cloudSafetyCopy() throws {
        try FileManager.default.createDirectory(at: backupFolder, withIntermediateDirectories: true)
        try DataTransfer.safetyCopy(store, folder: backupFolder, reason: "konto")
    }
}
