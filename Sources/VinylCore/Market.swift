import Foundation

/// Markedsdata for én release fra Discogs. Bemærk: det er *aktuelle udbud* og
/// community-tal – Discogs' API udleverer ikke salgshistorik pr. release.
public struct MarketInfo: Equatable {
    public var lowestPrice: Double?
    public var currency: String
    public var numForSale: Int?
    public var have: Int?
    public var want: Int?
    public var fetchedAt: Date

    public init(lowestPrice: Double?, currency: String, numForSale: Int?, have: Int?, want: Int?, fetchedAt: Date = Date()) {
        self.lowestPrice = lowestPrice; self.currency = currency; self.numForSale = numForSale
        self.have = have; self.want = want; self.fetchedAt = fetchedAt
    }

    /// Ønsker pr. ejer. Høj værdi = efterspurgt.
    public var demand: Double? {
        guard let have, let want, have > 0 else { return nil }
        return Double(want) / Double(have)
    }
}

/// Discogs' eget værdiestimat for hele samlingen (baseret på faktiske salg).
public struct CollectionValue: Equatable, Codable {
    public var minimum: String
    public var median: String
    public var maximum: String
    public var fetchedAt: Date
}

public enum MarketCurrency: String, CaseIterable, Identifiable {
    case DKK, EUR, USD, GBP, SEK, CHF
    public var id: String { rawValue }

    /// Kronen er fast bundet til euroen (centralkurs 7,46038), så de to kan regnes præcist om.
    /// Discogs giver selv priser i kroner; omregningen bruges kun, hvis et svar kommer i den anden.
    public static let dkkPerEur = 7.46038

    /// Omregner mellem euro og kroner. Andre valutaer røres ikke – der gættes aldrig en kurs.
    public static func converted(_ m: MarketInfo, to code: String) -> MarketInfo {
        let rate: Double
        switch (m.currency, code) {
        case ("EUR", "DKK"): rate = dkkPerEur
        case ("DKK", "EUR"): rate = 1 / dkkPerEur
        default: return m
        }
        var out = m
        out.lowestPrice = m.lowestPrice.map { ($0 * rate * 100).rounded() / 100 }
        out.currency = code
        return out
    }
}

extension DiscogsClient {
    public func collectionValue(username: String) async throws -> CollectionValue {
        let user = username.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? username
        let data = try await get("/users/\(user)/collection/value")
        return try Self.parseCollectionValue(data)
    }

    /// Laveste pris for én udgave via /marketplace/stats, hvor valutaen står i svaret.
    /// (/releases/{id} ignorerer `curr_abbr` og giver altid brugerens Discogs-valuta – målt 1. okt 2026.)
    public func marketInfo(releaseID: Int, currency: String) async throws -> MarketInfo {
        let data = try await get("/marketplace/stats/\(releaseID)", query: [URLQueryItem(name: "curr_abbr", value: currency)])
        return MarketCurrency.converted(try Self.parseMarketStats(data, fallbackCurrency: currency), to: currency)
    }

    /// Markedsdata til Værdi-skærmen: pris og har/ønsker fra /releases/{id}. Prisen dér er i
    /// brugerens Discogs-valuta (`discogsCurrency`). Kan den ikke regnes om til `appCurrency`,
    /// hentes prisen i stedet fra /marketplace/stats; er valutaen ukendt, gemmes ingen pris.
    public func releaseMarketInfo(releaseID: Int, discogsCurrency: String?, appCurrency: String) async throws -> MarketInfo {
        let data = try await get("/releases/\(releaseID)")
        var m = try Self.parseMarketInfo(data, currency: discogsCurrency ?? appCurrency)
        if discogsCurrency == nil { m.lowestPrice = nil }
        m = MarketCurrency.converted(m, to: appCurrency)
        if discogsCurrency == nil || m.currency != appCurrency {
            let stats = try await marketInfo(releaseID: releaseID, currency: appCurrency)
            m.lowestPrice = stats.lowestPrice; m.currency = stats.currency; m.numForSale = stats.numForSale
        }
        return m
    }

    /// Svar fra /marketplace/stats/{id}: `lowest_price` er `{"value": …, "currency": "DKK"}` eller null.
    /// Mangler valutaen i et ellers gyldigt prisfelt, vises ingen pris (aldrig en gættet valuta).
    public static func parseMarketStats(_ data: Data, fallbackCurrency: String) throws -> MarketInfo {
        struct S: Decodable {
            struct Price: Decodable { let value: FlexDouble?; let currency: String? }
            let lowest_price: Lossy<Price>?
            let num_for_sale: FlexInt?
        }
        guard let s = try? JSONDecoder().decode(S.self, from: data) else { throw DiscogsError.decoding("markedspriser") }
        let p = s.lowest_price?.value
        let cur = p?.currency.flatMap { $0.isEmpty ? nil : $0.uppercased() }
        return MarketInfo(lowestPrice: cur == nil ? nil : p?.value?.value, currency: cur ?? fallbackCurrency,
                          numForSale: s.num_for_sale?.value, have: nil, want: nil)
    }

    public static func parseCollectionValue(_ data: Data) throws -> CollectionValue {
        struct V: Decodable { let minimum: String; let median: String; let maximum: String }
        guard let v = try? JSONDecoder().decode(V.self, from: data) else { throw DiscogsError.decoding("samlingens værdi") }
        return CollectionValue(minimum: v.minimum, median: v.median, maximum: v.maximum, fetchedAt: Date())
    }

    public static func parseMarketInfo(_ data: Data, currency: String) throws -> MarketInfo {
        struct R: Decodable {
            struct Community: Decodable { let have: Int?; let want: Int? }
            let lowest_price: Double?
            let num_for_sale: Int?
            let community: Community?
        }
        guard let r = try? JSONDecoder().decode(R.self, from: data) else { throw DiscogsError.decoding("markedspriser") }
        return MarketInfo(lowestPrice: r.lowest_price, currency: currency, numForSale: r.num_for_sale,
                          have: r.community?.have, want: r.community?.want)
    }
}

extension ShelfStore {
    public func saveMarket(_ releaseID: Int, _ m: MarketInfo) throws {
        try db.run("""
            INSERT INTO release_market(release_id, lowest_price, currency, num_for_sale, have, want, fetched_at)
            VALUES(?,?,?,?,?,?,?)
            ON CONFLICT(release_id) DO UPDATE SET lowest_price=excluded.lowest_price, currency=excluded.currency,
                num_for_sale=excluded.num_for_sale, have=excluded.have, want=excluded.want, fetched_at=excluded.fetched_at
            """, releaseID, m.lowestPrice, m.currency, m.numForSale, m.have, m.want, m.fetchedAt.timeIntervalSince1970)
    }

    /// Sletter alle gemte markedspriser (bruges én gang efter valutarettelsen).
    public func clearMarket() throws {
        try db.run("DELETE FROM release_market")
    }

    public func loadMarket() throws -> [Int: MarketInfo] {
        var out: [Int: MarketInfo] = [:]
        for r in try db.query("SELECT * FROM release_market") {
            out[Int(r["release_id"]!.int!)] = MarketInfo(
                lowestPrice: r["lowest_price"]?.double, currency: r["currency"]?.text ?? "EUR",
                numForSale: r["num_for_sale"]?.int.map(Int.init), have: r["have"]?.int.map(Int.init),
                want: r["want"]?.int.map(Int.init),
                fetchedAt: Date(timeIntervalSince1970: r["fetched_at"]?.double ?? 0))
        }
        return out
    }

    public func saveCollectionValue(_ v: CollectionValue) {
        if let d = try? JSONEncoder().encode(v) { setSetting("collection_value", String(data: d, encoding: .utf8)) }
    }

    public func loadCollectionValue() -> CollectionValue? {
        guard let s = setting("collection_value"), let d = s.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(CollectionValue.self, from: d)
    }
}
