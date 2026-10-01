import Foundation

// Søgning i hele Discogs' katalog, udgaver af et album og ønskelisten.
// Selve købet sker på Discogs' hjemmeside (API'et kan ikke købe), se `marketplaceURL`.

/// Et album fra Discogs' katalog: en master, eller en release uden master.
public struct DiscogsAlbum: Identifiable, Hashable, Sendable {
    public let id: Int            // master-id hvis isMaster, ellers release-id
    public let isMaster: Bool
    public let title: String      // albumtitel uden "Kunstner – "
    public let artist: String     // renset kunstnernavn (fx uden "(2)")
    public let year: Int?
    public let thumbURL: URL?
    public let coverURL: URL?
    public let formats: [String]  // fx ["Vinyl", "LP", "Album"] – kan være tom for masters
    public let inCollection: Bool // fra search-resultatets user_data
    public let inWantlist: Bool

    public init(id: Int, isMaster: Bool, title: String, artist: String, year: Int?, thumbURL: URL?, coverURL: URL?,
                formats: [String], inCollection: Bool, inWantlist: Bool) {
        self.id = id; self.isMaster = isMaster; self.title = title; self.artist = artist; self.year = year
        self.thumbURL = thumbURL; self.coverURL = coverURL; self.formats = formats
        self.inCollection = inCollection; self.inWantlist = inWantlist
    }
}

/// Én udgave (release) af et album.
public struct DiscogsVersion: Identifiable, Hashable, Sendable {
    public let id: Int            // release-id
    public let title: String
    public let format: String     // læsbar tekst, fx "Vinyl, LP, Album, Reissue"
    public let label: String
    public let catno: String
    public let country: String
    public let year: Int?
    public let thumbURL: URL?
    public let inCollection: Bool
    public let inWantlist: Bool
    /// Hvor udbredt udgaven er: antal Discogs-brugere, der har den eller ønsker sig den.
    public let popularity: Int

    public init(id: Int, title: String, format: String, label: String, catno: String, country: String, year: Int?,
                thumbURL: URL?, inCollection: Bool, inWantlist: Bool, popularity: Int = 0) {
        self.id = id; self.title = title; self.format = format; self.label = label; self.catno = catno
        self.country = country; self.year = year; self.thumbURL = thumbURL
        self.inCollection = inCollection; self.inWantlist = inWantlist; self.popularity = popularity
    }

    /// De mest udbredte udgaver først (stabil: lige udbredte beholder Discogs' rækkefølge).
    public static func mostPopularFirst(_ list: [DiscogsVersion]) -> [DiscogsVersion] {
        list.enumerated().sorted { a, b in
            a.element.popularity != b.element.popularity ? a.element.popularity > b.element.popularity : a.offset < b.offset
        }.map(\.element)
    }
}

extension DiscogsAlbum {
    /// Sorterer søgeresultater, så album, der indeholder flere af søgeordene i kunstner og titel,
    /// kommer først ("blue latour" → "LaTour – Blue" før "LaTour – LaTour"). Ellers Discogs' rækkefølge.
    public static func rankedForQuery(_ albums: [DiscogsAlbum], query: String) -> [DiscogsAlbum] {
        let fold: (String) -> String = { $0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) }
        let words = Set(fold(query).split { !$0.isLetter && !$0.isNumber }.map(String.init))
        guard words.count > 1 else { return albums }
        func score(_ a: DiscogsAlbum) -> Int {
            let have = Set(fold("\(a.artist) \(a.title)").split { !$0.isLetter && !$0.isNumber }.map(String.init))
            return words.filter { have.contains($0) }.count
        }
        return albums.enumerated().map { ($0.offset, $0.element, score($0.element)) }
            .sorted { $0.2 != $1.2 ? $0.2 > $1.2 : $0.0 < $1.0 }
            .map(\.1)
    }
}

/// Markedstal for et helt album (master) fra `GET /masters/{id}`: gælder alle formater samlet.
public struct MasterOffer: Equatable, Sendable {
    public var lowestPrice: Double?
    /// Valutaen, hvis svaret selv oplyser den. Ellers er prisen i brugerens Discogs-valuta.
    public var currency: String?
    public var numForSale: Int?
    /// Discogs' hovedudgave af albummet (release-id).
    public var mainRelease: Int?

    public init(lowestPrice: Double?, currency: String?, numForSale: Int?, mainRelease: Int?) {
        self.lowestPrice = lowestPrice; self.currency = currency; self.numForSale = numForSale; self.mainRelease = mainRelease
    }

    /// Til visning i appens valuta. Prisen er i svarets valuta eller i `userCurrency` (brugerens
    /// Discogs-valuta). Euro regnes om til kroner; alle andre valutaer vises, som Discogs giver dem
    /// (ingen opfundne vekselkurser). Kendes valutaen ikke, vises ingen pris, kun antal til salg.
    public func market(userCurrency: String?, appCurrency: String) -> MarketInfo {
        let cur = currency ?? userCurrency
        let info = MarketInfo(lowestPrice: cur == nil ? nil : lowestPrice, currency: cur ?? appCurrency,
                              numForSale: numForSale, have: nil, want: nil)
        return MarketCurrency.converted(info, to: appCurrency)
    }
}

extension DiscogsClient {
    static let searchPageSize = 50
    static let versionsPageSize = 100
    /// Finder master-søgningen mindst så mange album, søges der ikke også efter enkelte udgaver.
    static let releaseSearchBelow = 10

    /// Søger efter album i hele Discogs (alle formater). Masters + releases uden master,
    /// uden dubletter. Kræver token (database/search).
    ///
    /// Først søges der kun efter masters (ét kald). Finder den mindst `releaseSearchBelow` album,
    /// er det nok. Ellers søges der også efter releases (type=release), så album uden master og
    /// søgninger på katalognummer eller stregkode stadig giver resultater. Releases med master vises
    /// via deres master; finder master-søgningen intet, vises releases som enkelte udgaver.
    /// `format` (fx "Vinyl", "CD", "Cassette") begrænser søgningen til udgivelser i det format;
    /// `nil` = alle formater.
    public func searchAlbums(_ query: String, page: Int = 1, format: String? = nil) async throws -> (albums: [DiscogsAlbum], hasMore: Bool) {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return ([], false) }
        guard hasToken else { throw DiscogsError.missingToken }
        var common = [URLQueryItem(name: "q", value: q),
                      URLQueryItem(name: "page", value: String(max(1, page))),
                      URLQueryItem(name: "per_page", value: String(Self.searchPageSize))]
        if let format, !format.isEmpty { common.append(URLQueryItem(name: "format", value: format)) }
        let masterQuery = common + [URLQueryItem(name: "type", value: "master")]
        let m = try await get("/database/search", query: masterQuery, priority: .interactive)
        if let enough = try Self.mastersOnly(m) { return enough }
        let releaseQuery = common + [URLQueryItem(name: "type", value: "release")]
        let r = try await get("/database/search", query: releaseQuery, priority: .interactive)
        return try Self.combineSearch(masters: m, releases: r)
    }

    /// Master-søgningen alene, hvis den fandt nok album (se `releaseSearchBelow`); ellers nil.
    /// Afgørelsen bygger på det samlede antal, så alle sider af samme søgning behandles ens.
    public static func mastersOnly(_ masters: Data) throws -> (albums: [DiscogsAlbum], hasMore: Bool)? {
        let m = try decodeSearch(masters)
        guard m.total >= releaseSearchBelow else { return nil }
        return (albums(from: m.results.filter { $0.type == "master" }, keepReleasesWithMaster: false), m.hasMore)
    }

    /// Udgaver af et album: for en master `/masters/{id}/versions` (Discogs' standardsortering),
    /// for en release uden master én version (`/releases/{id}`).
    /// `format` filtrerer udgaverne (Discogs' eget filter på `/masters/{id}/versions`).
    /// `total` er Discogs' samlede antal udgaver (med formatfilteret), ikke kun denne side.
    public func versions(of album: DiscogsAlbum, page: Int = 1, format: String? = nil) async throws -> (versions: [DiscogsVersion], hasMore: Bool, total: Int) {
        if album.isMaster {
            var query = [URLQueryItem(name: "page", value: String(max(1, page))),
                         URLQueryItem(name: "per_page", value: String(Self.versionsPageSize))]
            if let format, !format.isEmpty { query.append(URLQueryItem(name: "format", value: format)) }
            let data = try await get("/masters/\(album.id)/versions", query: query, priority: .interactive)
            return try Self.parseVersions(data)
        }
        guard page <= 1 else { return ([], false, 1) }
        let data = try await get("/releases/\(album.id)", priority: .interactive)
        let version = try Self.parseReleaseVersion(data, inCollection: album.inCollection, inWantlist: album.inWantlist)
        return ([version], false, 1)
    }

    /// PUT /users/{username}/wants/{release_id}
    public func addToWantlist(username: String, releaseID: Int) async throws {
        guard hasToken else { throw DiscogsError.missingToken }
        _ = try await perform(wantlistRequest(username: username, releaseID: releaseID))
    }

    /// Forespørgslen bag `addToWantlist` – bygges uden netværk, så den kan tjekkes.
    public func wantlistRequest(username: String, releaseID: Int) -> URLRequest {
        let user = username.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? username
        return makeRequest(method: "PUT", path: "/users/\(user)/wants/\(releaseID)")
    }

    /// https://www.discogs.com/sell/release/{id} – Discogs' liste over sælgere af præcis den udgave.
    public static func marketplaceURL(releaseID: Int) -> URL {
        URL(string: "https://www.discogs.com/sell/release/\(releaseID)")!
    }

    /// Discogs' markedsplads for et helt album (alle udgaver af en master), evt. kun i ét format:
    /// https://www.discogs.com/sell/list?master_id={id}&format={Vinyl|CD|Cassette} (uden format = alle).
    public static func marketplaceURL(masterID: Int, format: String?) -> URL {
        var c = URLComponents(string: "https://www.discogs.com/sell/list")!
        var items = [URLQueryItem(name: "master_id", value: String(masterID))]
        if let format, !format.isEmpty { items.append(URLQueryItem(name: "format", value: format)) }
        c.queryItems = items
        return c.url!
    }

    /// GET /masters/{id}: laveste pris og antal til salg for hele albummet (alle formater samlet)
    /// og albummets hovedudgave. Prisen er i brugerens Discogs-valuta (se `userCurrency`).
    public func masterOffer(id: Int) async throws -> MasterOffer {
        try Self.parseMasterOffer(try await get("/masters/\(id)"))
    }

    /// GET /users/{username} → `curr_abbr`: valutaen, Discogs viser brugerens priser i.
    /// `nil`, hvis Discogs ikke oplyser den.
    public func userCurrency(username: String) async throws -> String? {
        let user = username.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? username
        return try Self.parseUserCurrency(try await get("/users/\(user)"))
    }

    /// https://www.discogs.com/release/{id}
    public static func releasePageURL(releaseID: Int) -> URL {
        URL(string: "https://www.discogs.com/release/\(releaseID)")!
    }

    // MARK: - Rene parsere

    /// Ét svar fra /database/search → album. Masters og releases uden master; releases med master
    /// vises via deres master. Artister, labels og dubletter springes over.
    public static func parseSearch(_ data: Data) throws -> (albums: [DiscogsAlbum], hasMore: Bool) {
        let page = try decodeSearch(data)
        return (albums(from: page.results, keepReleasesWithMaster: false), page.hasMore)
    }

    /// Samler master- og release-søgningen til én side album (se `searchAlbums`).
    public static func combineSearch(masters: Data, releases: Data) throws -> (albums: [DiscogsAlbum], hasMore: Bool) {
        let m = try decodeSearch(masters), r = try decodeSearch(releases)
        // Ingen masters overhovedet → søgningen ramte konkrete udgaver (katalognr., stregkode …).
        let fallback = m.total == 0
        let all = m.results.filter { $0.type == "master" } + r.results.filter { $0.type == "release" }
        return (albums(from: all, keepReleasesWithMaster: fallback), m.hasMore || r.hasMore)
    }

    /// Svar fra /masters/{id}/versions → udgaver.
    public static func parseVersions(_ data: Data) throws -> (versions: [DiscogsVersion], hasMore: Bool, total: Int) {
        guard let page = try? JSONDecoder().decode(VersionsPage.self, from: data), let list = page.versions else {
            throw DiscogsError.decoding("udgaverne")
        }
        let versions = list.compactMap(\.value).map { v in
            DiscogsVersion(
                id: v.id,
                title: v.title ?? "",
                format: versionFormat(major: v.major_formats ?? [], format: v.format ?? ""),
                label: v.label.map(cleanDiscogsName) ?? "",
                catno: cleanCatno(v.catno),
                country: v.country ?? "",
                year: yearValue(v.released),
                thumbURL: imageURL(v.thumb),
                inCollection: v.stats?.user?.in_collection?.value ?? false,
                inWantlist: v.stats?.user?.in_wantlist?.value ?? false,
                popularity: (v.stats?.community?.in_collection?.value ?? 0) + (v.stats?.community?.in_wantlist?.value ?? 0))
        }
        return (versions, page.pagination?.hasMore ?? false, page.pagination?.items?.value ?? versions.count)
    }

    /// Svar fra /releases/{id} → én udgave (bruges for releases uden master).
    /// /releases har ingen brugerdata, så de kommer fra søgeresultatet.
    public static func parseReleaseVersion(_ data: Data, inCollection: Bool, inWantlist: Bool) throws -> DiscogsVersion {
        struct R: Decodable {
            struct Label: Decodable { let name: String?; let catno: String? }
            struct Format: Decodable { let name: String?; let qty: String?; let descriptions: [String]?; let text: String? }
            struct Image: Decodable { let uri150: String? }
            let id: Int
            let title: String?
            let year: FlexInt?
            let released: FlexString?
            let country: String?
            let labels: [Label]?
            let formats: [Format]?
            let thumb: String?
            let images: [Image]?
        }
        guard let r = try? JSONDecoder().decode(R.self, from: data) else { throw DiscogsError.decoding("udgaven") }
        let format = (r.formats ?? []).map { f -> String in
            var parts: [String] = []
            let name = f.name ?? ""
            if let q = f.qty, let n = Int(q), n > 1 { parts.append("\(n)×\(name)") } else if !name.isEmpty { parts.append(name) }
            parts.append(contentsOf: f.descriptions ?? [])
            if let t = f.text, !t.isEmpty { parts.append(t) }
            return parts.filter { !$0.isEmpty }.joined(separator: ", ")
        }.filter { !$0.isEmpty }.joined(separator: " + ")
        let label = r.labels?.first
        let year = r.year?.value.flatMap { $0 > 0 ? $0 : nil } ?? yearValue(r.released)
        return DiscogsVersion(
            id: r.id, title: r.title ?? "", format: format,
            label: label?.name.map(cleanDiscogsName) ?? "", catno: cleanCatno(label?.catno),
            country: r.country ?? "", year: year,
            thumbURL: imageURL(r.thumb) ?? imageURL(r.images?.first?.uri150),
            inCollection: inCollection, inWantlist: inWantlist)
    }

    /// Svar fra /masters/{id} → markedstal for hele albummet. `curr_abbr` er ikke dokumenteret
    /// for masters, men læses, hvis Discogs sender den.
    public static func parseMasterOffer(_ data: Data) throws -> MasterOffer {
        struct M: Decodable {
            let id: Int
            let lowest_price: Double?
            let num_for_sale: FlexInt?
            let main_release: FlexInt?
            let curr_abbr: String?
            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                id = try c.decode(Int.self, forKey: .id)
                lowest_price = try? c.decodeIfPresent(Double.self, forKey: .lowest_price)
                num_for_sale = try? c.decodeIfPresent(FlexInt.self, forKey: .num_for_sale)
                main_release = try? c.decodeIfPresent(FlexInt.self, forKey: .main_release)
                curr_abbr = try? c.decodeIfPresent(String.self, forKey: .curr_abbr)
            }
            enum CodingKeys: String, CodingKey { case id, lowest_price, num_for_sale, main_release, curr_abbr }
        }
        guard let m = try? JSONDecoder().decode(M.self, from: data) else { throw DiscogsError.decoding("albummets priser") }
        return MasterOffer(lowestPrice: m.lowest_price, currency: currencyCode(m.curr_abbr),
                           numForSale: m.num_for_sale?.value, mainRelease: m.main_release?.value.flatMap { $0 > 0 ? $0 : nil })
    }

    /// Svar fra /users/{username} → brugerens valuta (`curr_abbr`). Tom eller manglende → nil.
    public static func parseUserCurrency(_ data: Data) throws -> String? {
        struct U: Decodable { let curr_abbr: String? }
        guard let u = try? JSONDecoder().decode(U.self, from: data) else { throw DiscogsError.decoding("din valuta") }
        return currencyCode(u.curr_abbr)
    }

    /// "eur " → "EUR". Kun tre bogstaver godtages; alt andet → nil.
    static func currencyCode(_ s: String?) -> String? {
        guard let c = s?.trimmingCharacters(in: .whitespaces).uppercased(), c.count == 3,
              c.allSatisfy({ $0.isASCII && $0.isLetter }) else { return nil }
        return c
    }

    // MARK: - Hjælpere

    /// Deler "Kunstner - Titel" (Discogs bruger " - "; " – " accepteres også) ved første skilletegn.
    static func splitSearchTitle(_ s: String) -> (artist: String, title: String) {
        let seps = [" - ", " – ", " — "]
        let hit = seps.compactMap { s.range(of: $0) }.min { $0.lowerBound < $1.lowerBound }
        guard let hit else { return ("", s.trimmingCharacters(in: .whitespaces)) }
        return (cleanSearchArtist(String(s[..<hit.lowerBound])),
                String(s[hit.upperBound...]).trimmingCharacters(in: .whitespaces))
    }

    /// "Nirvana (2)" → "Nirvana", også inde i "A (2) & B (3)". ANV-stjerner ("Simon*") fjernes.
    static func cleanSearchArtist(_ s: String) -> String {
        let noNumbers = s.replacingOccurrences(of: #"\s\(\d+\)(?=$|\s|,)"#, with: "", options: .regularExpression)
        let noStars = noNumbers.replacingOccurrences(of: #"(?<=\S)\*(?=$|\s|,)"#, with: "", options: .regularExpression)
        return cleanDiscogsName(noStars.trimmingCharacters(in: .whitespaces))
    }

    /// "Vinyl" + "LP, Album, Stereo" → "Vinyl, LP, Album, Stereo" (uden gentagelser).
    static func versionFormat(major: [String], format: String) -> String {
        var seen = Set<String>(), out: [String] = []
        let parts = major + format.components(separatedBy: ",")
        for p in parts.map({ $0.trimmingCharacters(in: .whitespaces) }) where !p.isEmpty {
            if seen.insert(p.lowercased()).inserted { out.append(p) }
        }
        return out.joined(separator: ", ")
    }

    /// "1969", "1969-09-26", 1969 → 1969. "0", "" og nil → nil.
    static func yearValue(_ s: FlexString?) -> Int? {
        guard let s = s?.value, let y = Int(s.prefix(4)), y > 0 else { return nil }
        return y
    }

    static func cleanCatno(_ s: String?) -> String {
        guard let s = s?.trimmingCharacters(in: .whitespaces), s.lowercased() != "none" else { return "" }
        return s
    }

    static func imageURL(_ s: String?) -> URL? {
        guard let s, !s.isEmpty, !s.contains("spacer.gif") else { return nil }
        return URL(string: s)
    }

    static func albums(from results: [SearchResult], keepReleasesWithMaster: Bool) -> [DiscogsAlbum] {
        var seen = Set<String>(), out: [DiscogsAlbum] = []
        for r in results {
            let isMaster: Bool
            switch r.type {
            case "master": isMaster = true
            case "release":
                if let m = r.master_id?.value, m > 0, !keepReleasesWithMaster { continue }
                isMaster = false
            default: continue   // artist, label …
            }
            guard seen.insert("\(isMaster ? "m" : "r")\(r.id)").inserted else { continue }
            let (artist, title) = splitSearchTitle(r.title ?? "")
            var formats: [String] = []
            for f in r.format ?? [] where !f.isEmpty && !formats.contains(f) { formats.append(f) }
            out.append(DiscogsAlbum(
                id: r.id, isMaster: isMaster, title: title, artist: artist,
                year: yearValue(r.year), thumbURL: imageURL(r.thumb), coverURL: imageURL(r.cover_image),
                formats: formats,
                inCollection: r.user_data?.in_collection?.value ?? false,
                inWantlist: r.user_data?.in_wantlist?.value ?? false))
        }
        return out
    }

    static func decodeSearch(_ data: Data) throws -> (results: [SearchResult], hasMore: Bool, total: Int) {
        guard let page = try? JSONDecoder().decode(SearchPage.self, from: data), let list = page.results else {
            throw DiscogsError.decoding("søgeresultaterne")
        }
        let results = list.compactMap(\.value)
        return (results, page.pagination?.hasMore ?? false, page.pagination?.items?.value ?? results.count)
    }

    // MARK: - JSON-modeller (tolerante: manglende eller forkerte felter giver nil, ikke fejl)

    struct Pagination: Decodable {
        let page: FlexInt?
        let pages: FlexInt?
        let items: FlexInt?
        var hasMore: Bool {
            guard let p = page?.value, let n = pages?.value else { return false }
            return p < n
        }
    }

    struct UserFlags: Decodable {
        let in_collection: FlexBool?
        let in_wantlist: FlexBool?
    }

    struct SearchResult: Decodable {
        let id: Int
        let type: String?
        let master_id: FlexInt?
        let title: String?
        let year: FlexString?
        let thumb: String?
        let cover_image: String?
        let format: [String]?
        let user_data: UserFlags?

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(Int.self, forKey: .id)
            type = try? c.decodeIfPresent(String.self, forKey: .type)
            master_id = try? c.decodeIfPresent(FlexInt.self, forKey: .master_id)
            title = try? c.decodeIfPresent(String.self, forKey: .title)
            year = try? c.decodeIfPresent(FlexString.self, forKey: .year)
            thumb = try? c.decodeIfPresent(String.self, forKey: .thumb)
            cover_image = try? c.decodeIfPresent(String.self, forKey: .cover_image)
            format = try? c.decodeIfPresent([String].self, forKey: .format)
            user_data = try? c.decodeIfPresent(UserFlags.self, forKey: .user_data)
        }
        enum CodingKeys: String, CodingKey { case id, type, master_id, title, year, thumb, cover_image, format, user_data }
    }

    struct SearchPage: Decodable {
        let pagination: Pagination?
        let results: [Lossy<SearchResult>]?
    }

    struct VersionsPage: Decodable {
        struct Version: Decodable {
            struct Community: Decodable { let in_collection: FlexInt?; let in_wantlist: FlexInt? }
            struct Stats: Decodable {
                let user: UserFlags?
                let community: Community?
                init(from decoder: Decoder) throws {
                    let c = try decoder.container(keyedBy: CodingKeys.self)
                    user = try? c.decodeIfPresent(UserFlags.self, forKey: .user)
                    community = try? c.decodeIfPresent(Community.self, forKey: .community)
                }
                enum CodingKeys: String, CodingKey { case user, community }
            }
            let id: Int
            let title: String?
            let format: String?
            let major_formats: [String]?
            let label: String?
            let catno: String?
            let country: String?
            let released: FlexString?
            let thumb: String?
            let stats: Stats?

            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                id = try c.decode(Int.self, forKey: .id)
                title = try? c.decodeIfPresent(String.self, forKey: .title)
                format = try? c.decodeIfPresent(String.self, forKey: .format)
                major_formats = try? c.decodeIfPresent([String].self, forKey: .major_formats)
                label = try? c.decodeIfPresent(String.self, forKey: .label)
                catno = try? c.decodeIfPresent(String.self, forKey: .catno)
                country = try? c.decodeIfPresent(String.self, forKey: .country)
                released = try? c.decodeIfPresent(FlexString.self, forKey: .released)
                thumb = try? c.decodeIfPresent(String.self, forKey: .thumb)
                stats = try? c.decodeIfPresent(Stats.self, forKey: .stats)
            }
            enum CodingKeys: String, CodingKey { case id, title, format, major_formats, label, catno, country, released, thumb, stats }
        }
        let pagination: Pagination?
        let versions: [Lossy<Version>]?
    }
}

/// Et element, der ikke kan læses, springes over i stedet for at vælte hele siden.
struct Lossy<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws { value = try? T(from: decoder) }
}

/// Tal, der kan komme som 1973 eller "1973".
struct FlexInt: Decodable {
    let value: Int?
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let i = try? c.decode(Int.self) { value = i }
        else if let s = try? c.decode(String.self) { value = Int(s.trimmingCharacters(in: .whitespaces)) }
        else { value = nil }
    }
}

/// Beløb, der kan komme som 3.36 eller "3.36".
struct FlexDouble: Decodable {
    let value: Double?
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let d = try? c.decode(Double.self) { value = d }
        else if let s = try? c.decode(String.self) { value = Double(s.trimmingCharacters(in: .whitespaces)) }
        else { value = nil }
    }
}

/// Tekst, der kan komme som "1969-09-26" eller 1969.
struct FlexString: Decodable {
    let value: String?
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) { value = s }
        else if let i = try? c.decode(Int.self) { value = String(i) }
        else { value = nil }
    }
}

/// Ja/nej, der kan komme som true/false eller 1/0.
struct FlexBool: Decodable {
    let value: Bool?
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let b = try? c.decode(Bool.self) { value = b }
        else if let i = try? c.decode(Int.self) { value = i != 0 }
        else { value = nil }
    }
}
