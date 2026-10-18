import Foundation

// Kontoen i skyen (Supabase): login med en kode på e-mail, og hentning/afsendelse af poster.
// Port: windows/src/VinylCore/Cloud.cs. Kun den offentlige nøgle ligger i appen; den giver kun
// adgang til egne poster efter login (se supabase/schema.sql). Login gemmes i nøgleringen.

public enum CloudConfig {
    public static let url = URL(string: "https://vbtxbnwcsipapnfiphlw.supabase.co")!
    /// Offentlig nøgle (publishable). Må ligge i appen; rækkerne er låst til den, der er logget ind.
    public static let publishableKey = "sb_publishable_q7aX_h3J1W6uyvzQsYEk4Q_85bkkwQm"
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
    public init(_ message: String, needsLogin: Bool = false) { self.message = message; self.needsLogin = needsLogin }
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

    static func error(status: Int, data: Data) -> CloudError {
        let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let code = (o["error_code"] as? String) ?? (o["code"] as? String) ?? (o["error"] as? String) ?? ""
        switch code {
        case "otp_expired": return CloudError("Koden er forkert eller udløbet. Bed om en ny kode.")
        case "over_email_send_rate_limit", "over_request_rate_limit":
            return CloudError("Der er sendt for mange koder for nylig. Vent lidt, og prøv igen.")
        case "email_address_invalid", "validation_failed": return CloudError("E-mailadressen ser forkert ud.")
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
    @MainActor
    public static func run(store: ShelfStore, client: CloudClient, session: CloudSession, device: String,
                           firstSync: FirstSync? = nil) async throws -> Report {
        // En anden konto end sidst: start forfra med sammenligningen.
        if store.setting("cloud_user") != session.userID {
            try store.db.run("DELETE FROM sync_state")
            store.setSetting("cloud_cursor", nil)
        }
        let since = store.setting("cloud_cursor")
        var (remote, cursor) = try await client.fetch(since: since, session: session)
        var report = Report()

        if since == nil {
            let remoteLocations = Set(remote.filter { $0.kind == .location && $0.data != nil }.map(\.key))
            try store.ensureSyncIDs()
            let localLocations = Set(try store.db.query("SELECT uid FROM locations").compactMap { $0["uid"]?.text })
            if !remoteLocations.isEmpty, !localLocations.isEmpty, remoteLocations.isDisjoint(with: localLocations) {
                switch firstSync {
                case nil:
                    throw NeedsChoice(cloudSections: remoteLocations.count, localSections: localLocations.count)
                case .useCloud:
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
