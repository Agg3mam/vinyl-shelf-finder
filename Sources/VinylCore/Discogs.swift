import Foundation

/// Én post i Discogs Collection = én fysisk kopi (instance) af en release.
public struct DiscogsCollectionItem: Equatable {
    public var instanceID: Int
    public var dateAdded: String?
    public var release: Release

    public init(instanceID: Int, dateAdded: String?, release: Release) {
        self.instanceID = instanceID; self.dateAdded = dateAdded; self.release = release
    }
}

public enum DiscogsError: LocalizedError {
    case missingToken
    case unauthorized
    case http(Int)
    case rateLimited
    case decoding(String)
    /// Ingen forbindelse til Discogs (fx intet internet). Tilføjet, så netværksfejl vises på dansk.
    case offline

    public var errorDescription: String? {
        switch self {
        case .missingToken: return "Der er ikke gemt noget Discogs-token."
        case .unauthorized: return "Discogs-tokenet blev afvist. Kontrollér, at det er korrekt."
        // 404 beholdes som `.http(404)`, så eksisterende `catch DiscogsError.http(404)` stadig virker.
        case .http(404): return "Pladen findes ikke længere på Discogs."
        case .http(let code): return "Discogs svarede med en fejl (kode \(code)). Prøv igen senere."
        case .rateLimited: return "Discogs begrænser antallet af forespørgsler. Prøv igen om et øjeblik."
        case .decoding(let m): return "Svaret fra Discogs kunne ikke læses (\(m))."
        case .offline: return "Kunne ikke få forbindelse til Discogs. Tjek, at Mac'en er på internettet, og prøv igen."
        }
    }
}

/// Discogs API-klient (personal access token). Tokenet logges eller vises aldrig.
public struct DiscogsClient: Sendable {
    private let token: String
    private let session: URLSession
    public static let userAgent = "VinylShelfFinder/1.0 +https://github.com/local/vinyl-shelf-finder"
    private let base = URL(string: "https://api.discogs.com")!

    public init(token: String, session: URLSession = .shared) {
        self.token = token
        self.session = session
    }

    /// Om der overhovedet er et token (uden at afsløre det).
    var hasToken: Bool { !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// Bygger en forespørgsel til Discogs' API uden at sende den (ren funktion, bruges også af checks).
    /// Tokenet ligger kun i Authorization-headeren – aldrig i URL'en – og må aldrig logges.
    public func makeRequest(method: String = "GET", path: String, query: [URLQueryItem] = []) -> URLRequest {
        var comps = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { comps.queryItems = query }
        var req = URLRequest(url: comps.url!)
        req.httpMethod = method
        if method != "GET" { req.httpBody = Data() }   // tom krop → Content-Length: 0 ved PUT/POST
        req.setValue("Discogs token=\(token)", forHTTPHeaderField: "Authorization")
        req.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("application/vnd.discogs.v2.discogs+json", forHTTPHeaderField: "Accept")
        return req
    }

    func get(_ path: String, query: [URLQueryItem] = []) async throws -> Data {
        try await perform(makeRequest(path: path, query: query))
    }

    /// Sender en forespørgsel med en anden metode (fx PUT) med samme rate limit og fejlhåndtering som `get`.
    func send(method: String, path: String, query: [URLQueryItem] = []) async throws -> Data {
        try await perform(makeRequest(method: method, path: path, query: query))
    }

    /// Fælles afsendelse: rate limit, genforsøg ved 429 og danske fejl.
    func perform(_ req: URLRequest) async throws -> Data {
        for attempt in 0..<5 {
            let (data, response): (Data, URLResponse)
            do { (data, response) = try await session.data(for: req) }
            catch let e as URLError where e.code != .cancelled { throw DiscogsError.offline }
            guard let http = response as? HTTPURLResponse else { throw DiscogsError.http(-1) }
            switch http.statusCode {
            case 200..<300:
                // Vær venlig ved Discogs' rate limit (60/min).
                if let rem = http.value(forHTTPHeaderField: "X-Discogs-Ratelimit-Remaining").flatMap(Int.init), rem < 3 {
                    try await Task.sleep(nanoseconds: 3_000_000_000)
                }
                return data
            case 401, 403:
                throw DiscogsError.unauthorized
            case 429:
                try await Task.sleep(nanoseconds: UInt64(5 + attempt * 5) * 1_000_000_000)
            default:
                throw DiscogsError.http(http.statusCode)
            }
        }
        throw DiscogsError.rateLimited
    }

    /// Returnerer brugernavnet for tokenet.
    public func identity() async throws -> String {
        struct Identity: Decodable { let username: String }
        let data = try await get("/oauth/identity")
        do { return try JSONDecoder().decode(Identity.self, from: data).username }
        catch { throw DiscogsError.decoding("dine kontooplysninger") }
    }

    /// Henter hele Collection (mappe 0 = "All").
    public func fetchCollection(username: String, progress: @escaping (Int, Int) -> Void = { _, _ in }) async throws -> [DiscogsCollectionItem] {
        var page = 1, pages = 1
        var all: [DiscogsCollectionItem] = []
        let user = username.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? username
        repeat {
            let data = try await get("/users/\(user)/collection/folders/0/releases", query: [
                URLQueryItem(name: "per_page", value: "100"),
                URLQueryItem(name: "page", value: String(page)),
                URLQueryItem(name: "sort", value: "artist"),
                URLQueryItem(name: "sort_order", value: "asc"),
            ])
            let decoded: (items: [DiscogsCollectionItem], pages: Int, total: Int)
            do { decoded = try Self.parseCollectionPage(data) }
            catch { throw DiscogsError.decoding("samlingen, side \(page)") }
            pages = decoded.pages
            all.append(contentsOf: decoded.items)
            progress(all.count, decoded.total)
            page += 1
        } while page <= pages
        return all
    }

    // MARK: - JSON

    public static func parseCollectionPage(_ data: Data) throws -> (items: [DiscogsCollectionItem], pages: Int, total: Int) {
        let page = try JSONDecoder().decode(CollectionPage.self, from: data)
        return (page.releases.map(convert), page.pagination.pages, page.pagination.items)
    }

    struct CollectionPage: Decodable {
        struct Pagination: Decodable { let pages: Int; let items: Int }
        struct Item: Decodable {
            let id: Int
            let instance_id: Int
            let date_added: String?
            let basic_information: Basic
        }
        struct Basic: Decodable {
            struct Artist: Decodable { let name: String; let anv: String?; let join: String? }
            struct Label: Decodable { let name: String?; let catno: String? }
            struct Format: Decodable { let name: String?; let qty: String?; let descriptions: [String]? }
            let id: Int
            let title: String
            let year: Int?
            let artists: [Artist]?
            let labels: [Label]?
            let formats: [Format]?
            let cover_image: String?
            let thumb: String?
            let genres: [String]?
        }
        let pagination: Pagination
        let releases: [Item]
    }

    static func convert(_ it: CollectionPage.Item) -> DiscogsCollectionItem {
        let b = it.basic_information
        let label = b.labels?.first
        let fmt = b.formats?.first.map { f -> String in
            var parts: [String] = []
            if let q = f.qty, let n = Int(q), n > 1 { parts.append("\(n)×\(f.name ?? "")") } else if let n = f.name { parts.append(n) }
            parts.append(contentsOf: f.descriptions ?? [])
            return parts.joined(separator: ", ")
        }
        func nonEmpty(_ s: String?) -> String? {
            guard let s, !s.isEmpty, !s.contains("spacer.gif") else { return nil }
            return s
        }
        let release = Release(
            id: b.id,
            artist: artistName(b.artists ?? []),
            title: b.title,
            year: (b.year ?? 0) > 0 ? b.year : nil,
            label: label?.name.map(cleanDiscogsName),
            catalogNumber: label?.catno.flatMap { $0.lowercased() == "none" ? nil : $0 },
            format: fmt,
            coverURL: nonEmpty(b.cover_image),
            thumbURL: nonEmpty(b.thumb),
            genres: b.genres?.joined(separator: ", "))
        return DiscogsCollectionItem(instanceID: it.instance_id, dateAdded: it.date_added, release: release)
    }

    /// Samler kunstnernavne som Discogs viser dem: "Simon & Garfunkel", "Nirvana (2)" → "Nirvana".
    static func artistName(_ artists: [CollectionPage.Basic.Artist]) -> String {
        guard !artists.isEmpty else { return "Ukendt kunstner" }
        var out = ""
        for (i, a) in artists.enumerated() {
            let name = (a.anv?.isEmpty == false ? a.anv! : a.name)
            out += cleanDiscogsName(name)
            if i < artists.count - 1 {
                let j = (a.join ?? "").trimmingCharacters(in: .whitespaces)
                out += j.isEmpty ? ", " : (j == "," ? ", " : " \(j) ")
            }
        }
        return out
    }

    /// Fjerner Discogs' disambiguerings-suffiks " (2)".
    public static func cleanDiscogsName(_ s: String) -> String {
        s.replacingOccurrences(of: #"\s\(\d+\)$"#, with: "", options: .regularExpression)
    }
}

/// Tokenet må aldrig ende i logs, fejlbeskeder eller `print(client)`/`dump(client)`.
extension DiscogsClient: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String { "DiscogsClient(token: skjult)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["token": "skjult"], displayStyle: .struct) }
}
