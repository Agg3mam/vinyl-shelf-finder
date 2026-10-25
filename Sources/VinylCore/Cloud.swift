import Foundation

// Kontoen i skyen (Supabase): login med en kode på e-mail, og hentning/afsendelse af poster.
// Port: windows/src/VinylCore/Cloud.cs. Kun den offentlige nøgle ligger i appen; den giver kun
// adgang til egne poster efter login (se supabase/schema.sql). Login gemmes i nøgleringen.

public enum CloudConfig {
    public static let url = URL(string: "https://vbtxbnwcsipapnfiphlw.supabase.co")!
    /// Offentlig nøgle (publishable). Må ligge i appen; rækkerne er låst til den, der er logget ind.
    public static let publishableKey = "sb_publishable_q7aX_h3J1W6uyvzQsYEk4Q_85bkkwQm"
}

/// En kode-app på kontoen (totrinslogin). `verified` = slået til (en kode er bekræftet).
public struct CloudFactor: Equatable, Sendable {
    public let id: String
    public let verified: Bool
    public init(id: String, verified: Bool) { self.id = id; self.verified = verified }
}

/// Det, kode-appen skal have for at lave koder: `uri` (otpauth://…, også som QR-kode) eller `secret` (skrives ind).
public struct TOTPEnrollment: Equatable, Sendable {
    public let factorID: String
    public let secret: String
    public let uri: String
    public init(factorID: String, secret: String, uri: String) { self.factorID = factorID; self.secret = secret; self.uri = uri }

    /// Hemmeligheden i grupper á 4, så den er nem at skrive af.
    public var groupedSecret: String {
        stride(from: 0, to: secret.count, by: 4).map { i in
            let a = secret.index(secret.startIndex, offsetBy: i), b = secret.index(a, offsetBy: min(4, secret.count - i))
            return String(secret[a..<b])
        }.joined(separator: " ")
    }
}

/// Et login. Gemmes som JSON i nøgleringen (`KeychainSecret.cloudSession`).
public struct CloudSession: Codable, Equatable, Sendable {
    public var accessToken: String
    public var refreshToken: String
    public var expiresAt: Double
    public var userID: String
    public var email: String

    public var isExpired: Bool { Date().timeIntervalSince1970 > expiresAt - 60 }

    public init(accessToken: String, refreshToken: String, expiresAt: Double, userID: String, email: String) {
        self.accessToken = accessToken; self.refreshToken = refreshToken; self.expiresAt = expiresAt
        self.userID = userID; self.email = email
    }
}

extension KeychainSecret {
    public static let cloudSession = KeychainSecret(service: "dk.vinylshelffinder.cloud", account: "supabase-session")
}

public struct CloudError: LocalizedError, Equatable {
    public let message: String
    /// Login er udløbet eller tilbagekaldt: brugeren skal logge ind igen.
    public var needsLogin = false
    /// Kontoen har totrinslogin, og dette login mangler koden fra kode-appen.
    public var needsSecondFactor = false
    public init(_ message: String, needsLogin: Bool = false, needsSecondFactor: Bool = false) {
        self.message = message; self.needsLogin = needsLogin; self.needsSecondFactor = needsSecondFactor
    }
    public var errorDescription: String? { message }
}

public final class CloudClient: @unchecked Sendable {
    private let base: URL
    private let key: String
    private let http: URLSession

    public init(base: URL = CloudConfig.url, key: String = CloudConfig.publishableKey, session: URLSession = .shared) {
        self.base = base; self.key = key; self.http = session
    }

    // MARK: Login med kode

    /// Hvor linket i login-mailen sender hen: appen selv (vinylshelf://auth), ikke en webside.
    /// Adressen skal stå under Redirect URLs i Supabase (Authentication › URL Configuration).
    public static let loginRedirect = "vinylshelf://auth"

    /// Sender en login-mail (et link, der åbner appen, og en kode, hvis skabelonen viser den).
    /// Kontoen oprettes, hvis den ikke findes.
    public func requestCode(email: String) async throws {
        let redirect = Self.loginRedirect.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        _ = try await send("POST", "auth/v1/otp?redirect_to=\(redirect)", body: ["email": email, "create_user": true], token: nil)
    }

    /// Login fra linket i mailen: vinylshelf://auth#access_token=…&refresh_token=…&expires_at=…
    /// Bruger-ID og e-mail står i adgangsnøglen (JWT). nil, hvis adressen ikke er et login.
    /// Virker også med en indsat adresse fra browseren (fx http://localhost:3000/#access_token=…),
    /// hvis linket endte på Supabases standardside.
    public static func session(fromLink url: URL) throws -> CloudSession? {
        let isAppLink = url.scheme == "vinylshelf" && url.host == "auth"
        let isPasted = (url.scheme == "http" || url.scheme == "https")
            && ((url.fragment ?? "").contains("access_token=") || (url.fragment ?? "").contains("error="))
        guard isAppLink || isPasted else { return nil }
        let raw = url.fragment ?? URLComponents(url: url, resolvingAgainstBaseURL: false)?.query ?? ""
        var p: [String: String] = [:]
        for pair in raw.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1).map { String($0).removingPercentEncoding ?? String($0) }
            if kv.count == 2 { p[kv[0]] = kv[1] }
        }
        if let desc = p["error_description"] ?? p["error"] {
            throw CloudError(desc.contains("expired") || desc.contains("invalid")
                             ? "Linket er brugt eller udløbet. Bed om en ny mail."
                             : "Login mislykkedes: \(desc.replacingOccurrences(of: "+", with: " "))")
        }
        guard let access = p["access_token"], let refresh = p["refresh_token"],
              let claims = jwtClaims(access), let id = claims["sub"] as? String else {
            throw CloudError("Linket kunne ikke læses. Bed om en ny mail.")
        }
        let expiresAt = p["expires_at"].flatMap(Double.init)
            ?? (claims["exp"] as? Double) ?? Date().timeIntervalSince1970 + (p["expires_in"].flatMap(Double.init) ?? 3600)
        return CloudSession(accessToken: access, refreshToken: refresh, expiresAt: expiresAt,
                            userID: id, email: (claims["email"] as? String) ?? "")
    }

    static func jwtClaims(_ jwt: String) -> [String: Any]? {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var b = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b.count % 4 != 0 { b += "=" }
        guard let data = Data(base64Encoded: b) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// Bytter koden for et login.
    public func verify(email: String, code: String) async throws -> CloudSession {
        let data = try await send("POST", "auth/v1/verify", body: ["type": "email", "email": email, "token": code], token: nil)
        return try Self.session(from: data, email: email)
    }

    /// Linket fra mailen, kopieret og indsat i appen (https://….supabase.co/auth/v1/verify?token=…&type=…).
    /// Appen bytter det selv for et login, så browseren ikke skal bruges. nil, hvis adressen ikke er sådan et link.
    public static func emailLinkToken(_ text: String) -> (token: String, type: String)? {
        guard let c = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              c.path.hasSuffix("/auth/v1/verify"),
              let token = c.queryItems?.first(where: { $0.name == "token" })?.value, !token.isEmpty else { return nil }
        let type = c.queryItems?.first(where: { $0.name == "type" })?.value ?? "magiclink"
        return (token, type)
    }

    public func verifyEmailLink(_ text: String) async throws -> CloudSession? {
        guard let (token, type) = Self.emailLinkToken(text) else { return nil }
        let data: Data
        do { data = try await send("POST", "auth/v1/verify", body: ["type": type, "token_hash": token], token: nil) }
        catch let e as CloudError where e == Self.expiredCode { throw Self.usedLink }
        return try Self.session(from: data, email: "")
    }

    // MARK: Adgangskode

    /// Mindste længde på en adgangskode (tjekkes i appen, før den sendes).
    public static let minPasswordLength = 8

    /// Login med e-mail og adgangskode. Adgangskoden vælges i appen, mens man er logget ind (`setPassword`),
    /// så en ny enhed kan logge ind uden en mail.
    public func signIn(email: String, password: String) async throws -> CloudSession {
        let data = try await send("POST", "auth/v1/token?grant_type=password", body: ["email": email, "password": password], token: nil)
        return try Self.session(from: data, email: email)
    }

    /// Vælger eller skifter kontoens adgangskode. Kræver login.
    public func setPassword(_ password: String, session s: CloudSession) async throws {
        guard password.count >= Self.minPasswordLength else { throw Self.shortPassword }
        _ = try await send("PUT", "auth/v1/user", body: ["password": password], token: s.accessToken)
    }

    public static let wrongPassword = CloudError("Forkert e-mail eller adgangskode. Har du valgt en adgangskode under Konto i appen på computeren?")
    public static let shortPassword = CloudError("Adgangskoden er for kort. Brug mindst 8 tegn.")

    /// Fornyer et udløbet login.
    public func refresh(_ s: CloudSession) async throws -> CloudSession {
        let data = try await send("POST", "auth/v1/token?grant_type=refresh_token", body: ["refresh_token": s.refreshToken], token: nil)
        return try Self.session(from: data, email: s.email)
    }

    static func session(from data: Data, email: String) throws -> CloudSession {
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = o["access_token"] as? String, let refresh = o["refresh_token"] as? String,
              let user = o["user"] as? [String: Any], let id = user["id"] as? String else {
            throw CloudError("Svaret fra kontoen kunne ikke læses.")
        }
        let expiresIn = (o["expires_in"] as? Double) ?? 3600
        let expiresAt = (o["expires_at"] as? Double) ?? Date().timeIntervalSince1970 + expiresIn
        return CloudSession(accessToken: access, refreshToken: refresh, expiresAt: expiresAt,
                            userID: id, email: (user["email"] as? String) ?? email)
    }

    // MARK: Totrinslogin (en kode fra en kode-app, TOTP)
    //
    // Supabases indbyggede totrinslogin. Et login med adgangskode eller mail er "aal1"; når koden er skrevet,
    // bliver det "aal2". supabase/mfa.sql sørger for, at en konto med totrinslogin kun kan læse og skrive sine
    // poster med "aal2". Fornyede logins beholder "aal2".

    /// Hvor sikkert et login er: "aal1" (adgangskode eller mail) eller "aal2" (også koden fra kode-appen).
    public static func assurance(_ s: CloudSession) -> String { (jwtClaims(s.accessToken)?["aal"] as? String) ?? "aal1" }

    /// Kontoens kode-apps (kun TOTP).
    public func factors(session s: CloudSession) async throws -> [CloudFactor] {
        Self.factors(from: try await send("GET", "auth/v1/user", body: nil, token: s.accessToken))
    }

    static func factors(from data: Data) -> [CloudFactor] {
        let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        return ((o["factors"] as? [[String: Any]]) ?? []).compactMap { f in
            guard let id = f["id"] as? String, (f["factor_type"] as? String) == "totp" else { return nil }
            return CloudFactor(id: id, verified: (f["status"] as? String) == "verified")
        }
    }

    /// Kontoen har totrinslogin, men dette login mangler koden: den kode-app, koden skal komme fra. Ellers nil.
    public func pendingSecondFactor(session s: CloudSession) async throws -> CloudFactor? {
        guard Self.assurance(s) != "aal2" else { return nil }
        return try await factors(session: s).first(where: \.verified)
    }

    /// Begynder at slå totrinslogin til: giver koden til kode-appen (QR-kode og tekst). Først når en kode fra
    /// appen er bekræftet (`verifySecondFactor`), er totrinslogin slået til. Halvfærdige forsøg fjernes først.
    public func enrollSecondFactor(session s: CloudSession) async throws -> TOTPEnrollment {
        for f in try await factors(session: s) where !f.verified {
            _ = try await send("DELETE", "auth/v1/factors/\(f.id)", body: nil, token: s.accessToken)
        }
        let data = try await send("POST", "auth/v1/factors",
                                  body: ["factor_type": "totp", "friendly_name": "Vinyl Shelf \(Int(Date().timeIntervalSince1970))", "issuer": "Vinyl Shelf"],
                                  token: s.accessToken)
        guard let e = Self.enrollment(from: data) else { throw CloudError("Svaret fra kontoen kunne ikke læses.") }
        return e
    }

    static func enrollment(from data: Data) -> TOTPEnrollment? {
        guard let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let id = o["id"] as? String,
              let t = o["totp"] as? [String: Any], let secret = t["secret"] as? String, let uri = t["uri"] as? String else { return nil }
        return TOTPEnrollment(factorID: id, secret: secret, uri: uri)
    }

    /// Bekræfter en kode fra kode-appen. Giver et nyt, sikrere login ("aal2"), som skal gemmes i stedet for det gamle.
    public func verifySecondFactor(factorID: String, code: String, session s: CloudSession) async throws -> CloudSession {
        let digits = code.filter(\.isNumber)
        guard digits.count == 6 else { throw Self.wrongSecondFactorCode }
        let ch = try await send("POST", "auth/v1/factors/\(factorID)/challenge", body: [String: String](), token: s.accessToken)
        guard let challenge = ((try? JSONSerialization.jsonObject(with: ch)) as? [String: Any])?["id"] as? String else {
            throw CloudError("Svaret fra kontoen kunne ikke læses.")
        }
        let data = try await send("POST", "auth/v1/factors/\(factorID)/verify", body: ["challenge_id": challenge, "code": digits], token: s.accessToken)
        return try Self.session(from: data, email: s.email)
    }

    /// Slår totrinslogin fra (kræver et login, hvor koden er skrevet).
    public func removeSecondFactor(factorID: String, session s: CloudSession) async throws {
        _ = try await send("DELETE", "auth/v1/factors/\(factorID)", body: nil, token: s.accessToken)
    }

    public static let wrongSecondFactorCode = CloudError("Koden passer ikke. Skriv de 6 tal, kode-appen viser lige nu, ud for Vinyl Shelf.")
    public static let secondFactorRequired = CloudError("Skriv koden fra din kode-app for at synkronisere.", needsSecondFactor: true)
    public static let databaseDenied = CloudError("Kontoen afviste synkroniseringen (ingen adgang til databasen). Kør den nyeste supabase/mfa.sql i Supabase › SQL Editor.")

    // MARK: Poster

    /// Poster ændret siden `since` (serverens tid), og det nye `since`. Henter i sider á 1000.
    public func fetch(since: String?, session s: CloudSession) async throws -> (docs: [SyncDoc], cursor: String?) {
        var docs: [SyncDoc] = []
        var cursor = since
        var offset = 0
        // Lidt overlap, så en ændring, der blev gemt samtidig med den forrige hentning, ikke tabes.
        let from = since.flatMap(Self.date).map { Self.isoString($0.addingTimeInterval(-5)) }
        while true {
            var path = "rest/v1/sync_records?select=kind,key,data,deleted,updated_at&order=updated_at.asc,kind.asc,key.asc&limit=1000&offset=\(offset)"
            if let from { path += "&updated_at=gte.\(from.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? from)" }
            let data = try await send("GET", path, body: nil, token: s.accessToken)
            guard let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                throw CloudError("Svaret fra kontoen kunne ikke læses.")
            }
            for r in rows {
                guard let k = (r["kind"] as? String).flatMap(SyncDoc.Kind.init(rawValue:)), let key = r["key"] as? String else { continue }
                var payload: [String: JSONValue]?
                if (r["deleted"] as? Bool) != true, let d = r["data"], !(d is NSNull),
                   let raw = try? JSONSerialization.data(withJSONObject: d) {
                    payload = try? JSONDecoder().decode([String: JSONValue].self, from: raw)
                }
                docs.append(SyncDoc(kind: k, key: key, data: payload))
                if let u = r["updated_at"] as? String { cursor = u }
            }
            if rows.count < 1000 { break }
            offset += rows.count
        }
        return (docs, cursor)
    }

    /// Sender poster (i bunker á 500). Den nyeste ændring på serveren vinder.
    public func upsert(_ docs: [SyncDoc], session s: CloudSession, device: String) async throws {
        let enc = JSONEncoder()
        for start in stride(from: 0, to: docs.count, by: 500) {
            let rows: [[String: Any]] = try docs[start..<min(start + 500, docs.count)].map { d in
                var row: [String: Any] = ["user_id": s.userID, "kind": d.kind.rawValue, "key": d.key,
                                          "deleted": d.data == nil, "device": device, "data": NSNull()]
                if let data = d.data { row["data"] = try JSONSerialization.jsonObject(with: enc.encode(data)) }
                return row
            }
            _ = try await send("POST", "rest/v1/sync_records?on_conflict=user_id,kind,key", body: rows, token: s.accessToken,
                               headers: ["Prefer": "resolution=merge-duplicates,return=minimal"])
        }
    }

    // MARK: HTTP

    private func send(_ method: String, _ path: String, body: Any?, token: String?, headers: [String: String] = [:]) async throws -> Data {
        guard let url = URL(string: path, relativeTo: base) else { throw CloudError("Ugyldig adresse.") }
        var req = URLRequest(url: url, timeoutInterval: 30)
        req.httpMethod = method
        req.setValue(key, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(token ?? key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        if let body { req.httpBody = try JSONSerialization.data(withJSONObject: body) }
        let (data, response): (Data, URLResponse)
        do { (data, response) = try await http.data(for: req) }
        catch { throw CloudError("Kontoen kunne ikke nås. Tjek internetforbindelsen, og prøv igen.") }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw Self.error(status: status, data: data) }
        return data
    }

    static let expiredCode = CloudError("Koden er forkert eller udløbet. Bed om en ny kode.")
    /// Hvert link virker kun én gang – også når man har klikket på det i mailen.
    public static let usedLink = CloudError("Linket er allerede brugt eller er ikke fra den nyeste mail. Hvert link virker kun én gang – også hvis du har klikket på det. Bed om en ny mail, og klik ikke på linket.")

    public static func error(status: Int, data: Data) -> CloudError {
        let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let code = (o["error_code"] as? String) ?? (o["code"] as? String) ?? (o["error"] as? String) ?? ""
        switch code {
        case "otp_expired": return expiredCode
        case "invalid_credentials": return wrongPassword
        case "weak_password": return shortPassword
        case "same_password": return CloudError("Det er allerede din adgangskode.")
        case "over_email_send_rate_limit", "over_request_rate_limit":
            return CloudError("Der er sendt for mange koder for nylig. Vent lidt, og prøv igen.")
        case "email_address_invalid", "validation_failed": return CloudError("E-mailadressen ser forkert ud.")
        case "mfa_verification_failed", "mfa_challenge_expired": return wrongSecondFactorCode
        case "insufficient_aal": return secondFactorRequired
        case "42501":
            // "permission denied" er ikke den manglende kode, men en regel i databasen, der ikke må det, den prøver
            // (fx den første supabase/mfa.sql, der læste auth.mfa_factors direkte). Kun en afvist række er koden.
            if ((o["message"] as? String) ?? "").contains("permission denied") { return databaseDenied }
            return secondFactorRequired // rækken blev afvist (supabase/mfa.sql): koden mangler
        case "invalid_grant", "refresh_token_not_found", "refresh_token_already_used", "session_not_found", "bad_jwt":
            return CloudError("Du skal logge ind igen.", needsLogin: true)
        default: break
        }
        if status == 401 { return CloudError("Du skal logge ind igen.", needsLogin: true) }
        if status == 429 { return CloudError("Der er sendt for mange forespørgsler. Vent lidt, og prøv igen.") }
        return CloudError("Kontoen svarede med en fejl (\(status)). Prøv igen senere.")
    }

    // Serverens tidsstempler, fx "2026-10-18T15:01:02.123456+00:00".
    public static func date(_ s: String) -> Date? {
        var t = s
        if let dot = t.firstIndex(of: "."), let end = t[dot...].firstIndex(where: { $0 == "+" || $0 == "-" || $0 == "Z" }) {
            let frac = t[t.index(after: dot)..<end]
            t.replaceSubrange(dot..<end, with: "." + String((frac + "000").prefix(3)))
        }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: t) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: t)
    }

    static func isoString(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: d)
    }
}

// MARK: - Én synkronisering

public enum CloudSync {
    public struct Report: Equatable {
        public var received = 0
        public var sent = 0
        public init(received: Int = 0, sent: Int = 0) { self.received = received; self.sent = sent }
    }

    /// Første gang på en konto, når både kontoen og denne enhed har reoler: hvilke skal bruges?
    public enum FirstSync: Equatable { case useCloud, useThisDevice }

    public struct NeedsChoice: Error, Equatable {
        public let cloudSections: Int
        public let localSections: Int
    }

    /// Henter nyt fra skyen, lægger det ind, og sender egne ændringer op.
    /// Kaster `NeedsChoice`, hvis kontoen og enheden begge har reoler første gang (se `FirstSync`).
    /// `safetyCopy` kaldes, før reoler på denne enhed slettes (fx en sikkerhedskopi). Fejler den, ændres intet.
    @MainActor
    public static func run(store: ShelfStore, client: CloudClient, session: CloudSession, device: String,
                           firstSync: FirstSync? = nil, safetyCopy: (() throws -> Void)? = nil) async throws -> Report {
        // En anden konto end sidst: start forfra med sammenligningen.
        if store.setting("cloud_user") != session.userID {
            try store.db.run("DELETE FROM sync_state")
            store.setSetting("cloud_cursor", nil)
        }
        let since = store.setting("cloud_cursor")
        var (remote, cursor) = try await client.fetch(since: since, session: session)
        var report = Report()
        var copied = false

        if since == nil {
            let remoteLocations = Set(remote.filter { $0.kind == .location && $0.data != nil }.map(\.key))
            try store.ensureSyncIDs()
            let localLocations = Set(try store.db.query("SELECT uid FROM locations").compactMap { $0["uid"]?.text })
            if !remoteLocations.isEmpty, !localLocations.isEmpty, remoteLocations.isDisjoint(with: localLocations) {
                switch firstSync {
                case nil:
                    throw NeedsChoice(cloudSections: remoteLocations.count, localSections: localLocations.count)
                case .useCloud:
                    try safetyCopy?()
                    copied = true
                    try store.db.transaction {
                        try store.db.run("DELETE FROM placements")
                        try store.db.run("DELETE FROM locations")
                    }
                case .useThisDevice:
                    // Kontoens reoler slettes; resten (plader, afspilninger, indstillinger) flettes.
                    let drop = remote.filter { $0.kind == .location || $0.kind == .section }
                    remote.removeAll { $0.kind == .location || $0.kind == .section }
                    let deletions = drop.map { SyncDoc(kind: $0.kind, key: $0.key, data: nil) }
                    try await client.upsert(deletions, session: session, device: device)
                    report.sent += deletions.count
                }
            }
        }
        // En anden enhed har slettet reoler, som findes her.
        let removed = remote.filter { $0.kind == .location && $0.data == nil }
        if !copied, try removed.contains(where: { try store.hasLocation(uid: $0.key) }) {
            try safetyCopy?()
        }

        report.received = try store.applySyncDocs(remote)
        store.setSetting("cloud_user", session.userID)
        let pending = try store.pendingSyncDocs()
        if !pending.isEmpty {
            try await client.upsert(pending, session: session, device: device)
            try store.markSynced(pending)
            report.sent += pending.count
        }
        if let cursor { store.setSetting("cloud_cursor", cursor) }
        return report
    }
}
