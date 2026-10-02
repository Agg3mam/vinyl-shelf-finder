import Foundation

// iMusic.dk som ekstra købssted.
// iMusic har ingen offentlig købs-API. Priser kommer fra brugerens eget produktfeed hos
// affiliate-netværket Daisycon (kampagnen "imusic dk"). Selve købet sker altid på imusic.dk.
// Feedet gemmes i en SEPARAT cache-database (imusic.sqlite under Caches), aldrig i vinyl.sqlite.

// MARK: - Søgning på imusic.dk (virker uden feed)

public enum IMusicLink {
    /// iMusics søgeside med kunstner og titel, fx https://imusic.dk/page/search?query=Pink%20Floyd%20Animals.
    /// `vinylOnly` søger kun i vinyl (https://imusic.dk/vinyl/search?query=…).
    /// Formatet er fundet i iMusic-adresser, som søgemaskiner har gemt (1. okt 2026). Siden selv
    /// kunne ikke åbnes fra udviklingsmiljøet, så det er ikke afprøvet i en browser.
    public static func searchURL(artist: String, title: String, vinylOnly: Bool = false) -> URL {
        let query = [artist, title]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        var c = URLComponents(string: vinylOnly ? "https://imusic.dk/vinyl/search" : "https://imusic.dk/page/search")!
        c.queryItems = [URLQueryItem(name: "query", value: query)]
        return c.url!
    }
}

// MARK: - Produkt og stregkoder

/// Én vare fra iMusic-feedet (kun musik).
public struct IMusicProduct: Equatable, Sendable {
    public var title: String
    public var artist: String
    public var ean: String?
    public var format: String
    public var price: Double?
    public var currency: String
    /// true/false hvis feedet siger det; nil hvis det er ukendt.
    public var inStock: Bool?
    /// Fx "Leveres om 1-2 hverdage" eller "Bestillingsvare".
    public var delivery: String?
    /// Affiliate-linket fra feedet. Købet sker på imusic.dk.
    public var link: URL

    public init(title: String, artist: String, ean: String?, format: String, price: Double?, currency: String,
                inStock: Bool?, delivery: String?, link: URL) {
        self.title = title; self.artist = artist; self.ean = ean; self.format = format; self.price = price
        self.currency = currency; self.inStock = inStock; self.delivery = delivery; self.link = link
    }

    /// "på lager" / "bestillingsvare" / leveringstekst.
    public var availabilityText: String? {
        if inStock == true { return "på lager" }
        if let d = delivery?.trimmingCharacters(in: .whitespacesAndNewlines), !d.isEmpty { return d.lowercased() }
        if inStock == false { return "bestillingsvare" }
        return nil
    }

    /// Vinyl (LP, 12", 7") ud fra format/titel.
    public var isVinyl: Bool {
        let w = Set(SearchIndex.words("\(format) \(title)"))
        return !w.isDisjoint(with: ["vinyl", "lp", "2lp", "3lp", "12", "7", "10"])
    }
}

public enum Barcode {
    /// Kun cifre. UPC-A (12 cifre) gøres til EAN-13 med et foranstillet 0, og GTIN-14 med
    /// foranstillet 0 til EAN-13, så samme vare får samme nøgle. Andre længder end 8, 12, 13
    /// og 14 cifre er ikke stregkoder (fx katalognumre) og giver nil.
    public static func normalize(_ s: String) -> String? {
        let digits = s.filter { $0.isASCII && $0.isNumber }
        switch digits.count {
        case 8, 13: return digits
        case 12: return "0" + digits
        case 14 where digits.hasPrefix("0"): return String(digits.dropFirst())
        default: return nil
        }
    }
}

// MARK: - Tolerant oversættelse af feltnavne

/// Daisycons feltnavne varierer mellem standarder og formater. Hvert felt har en liste af
/// mulige navne (små bogstaver). Det første, der findes og ikke er tomt, bruges.
/// Daisycons egne navne (standarden "General", JSON og XML: datafeed › programs › products ›
/// product_info / update_info) står først: title, link, price, ean, brand, category, category_path,
/// keywords, in_stock, in_stock_amount, delivery_time, delivery_description og update_info.status.
/// Der er ikke noget kunstner-, format- eller valutafelt; kunstneren tages fra titlen eller brand,
/// formatet fra kategori/nøgleord/titel, og valutaen er kroner (iMusic.dk).
public enum IMusicFields {
    static let title = ["title", "name", "product_title", "productname", "product_name"]
    static let link = ["link", "url", "deeplink", "deep_link", "product_url", "productlink", "product_link", "affiliate_link"]
    static let price = ["minimum_price", "price", "price_new", "sale_price", "selling_price", "price_incl_vat"]
    static let currency = ["currency", "currency_code", "price_currency"]
    static let ean = ["ean", "ean13", "gtin", "gtin13", "barcode", "upc", "ean_code"]
    static let artist = ["artist", "artists", "performer", "brand", "author", "manufacturer"]
    static let format = ["format", "media", "medium", "media_type", "product_type", "material", "binding"]
    static let category = ["category_path", "category", "sub_category", "sub_sub_category", "google_category", "categories"]
    static let keywords = ["keywords", "tags"]
    static let status = ["status"]
    static let inStock = ["in_stock", "instock", "stock", "availability", "in_stock_amount", "stock_amount"]
    static let delivery = ["delivery_time", "delivery_description", "delivery", "shipping_time", "lead_time"]

    static func first(_ names: [String], in f: [String: String]) -> String? {
        for n in names {
            if let v = f[n]?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty { return v }
        }
        return nil
    }

    /// Ord, der viser, at varen er musik. Alt andet (film, spil, bøger) springes over.
    static let musicWords: Set<String> = ["vinyl", "lp", "2lp", "3lp", "cd", "2cd", "kassette", "cassette", "musik", "music",
                                          "single", "maxi", "sacd", "boxset"]

    /// Laver én vare ud af et fladt felt-opslag (nøgler med små bogstaver), eller nil hvis det
    /// ikke er en musikvare med titel og link.
    public static func product(from f: [String: String], fallbackCurrency: String = "DKK") -> IMusicProduct? {
        guard let rawTitle = first(title, in: f), let linkText = first(link, in: f),
              let url = URL(string: linkText), url.scheme?.hasPrefix("http") == true else { return nil }
        // update_info.status: varer, der er udgået hos iMusic.
        if let st = first(status, in: f)?.lowercased(), st == "inactive" || st == "deleted" { return nil }
        let formatText = first(format, in: f) ?? ""
        let categoryText = first(category, in: f) ?? ""
        let keywordText = first(keywords, in: f) ?? ""
        let hay = Set(SearchIndex.words("\(formatText) \(categoryText) \(keywordText) \(rawTitle)"))
        guard !hay.isDisjoint(with: musicWords) else { return nil }

        // "Pink Floyd - Animals (LP)": kunstner foran bindestregen, hvis feedet ikke har et kunstnerfelt.
        var artistText = first(artist, in: f) ?? ""
        var titleText = rawTitle
        if artistText.isEmpty, let r = rawTitle.range(of: " - ") ?? rawTitle.range(of: " – ") {
            artistText = String(rawTitle[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
            titleText = String(rawTitle[r.upperBound...]).trimmingCharacters(in: .whitespaces)
        }
        let eanText = first(ean, in: f).flatMap(Barcode.normalize)
        let priceValue = first(price, in: f).flatMap(parsePrice)
        let stockText = first(inStock, in: f)
        return IMusicProduct(
            title: titleText, artist: artistText, ean: eanText,
            format: formatText.isEmpty ? categoryText : formatText,
            price: priceValue, currency: (first(currency, in: f) ?? fallbackCurrency).uppercased(),
            inStock: stockText.flatMap(parseStock), delivery: first(delivery, in: f), link: url)
    }

    /// "249", "249.00", "249,00", "1.249,95", "DKK 249" → tal.
    public static func parsePrice(_ s: String) -> Double? {
        var t = s.filter { $0.isNumber || $0 == "," || $0 == "." }
        guard !t.isEmpty else { return nil }
        if let comma = t.lastIndex(of: ","), let dot = t.lastIndex(of: ".") {
            // Den sidste af , og . er decimaltegnet; den anden er tusindtalsskilletegn.
            if comma > dot { t = t.replacingOccurrences(of: ".", with: "").replacingOccurrences(of: ",", with: ".") }
            else { t = t.replacingOccurrences(of: ",", with: "") }
        } else if t.contains(",") {
            t = t.replacingOccurrences(of: ",", with: ".")
        }
        guard let v = Double(t), v > 0 else { return nil }
        return v
    }

    /// "true", "1", "yes", "in stock", "på lager", et antal > 0 → true. "false", "0", "out of stock" → false.
    public static func parseStock(_ s: String) -> Bool? {
        let t = s.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if let n = Int(t) { return n > 0 }
        if ["true", "yes", "ja", "y", "in stock", "instock", "in_stock", "på lager", "available"].contains(t) { return true }
        if ["false", "no", "nej", "n", "out of stock", "outofstock", "out_of_stock", "ikke på lager", "unavailable", "preorder", "backorder"].contains(t) { return false }
        return nil
    }
}

// MARK: - Streamet parsing (JSON og XML)

public enum IMusicFeedParser {
    public enum Format { case json, xml }

    /// Gætter formatet ud fra første tegn, der ikke er mellemrum.
    public static func detectFormat(_ prefix: Data) -> Format? {
        for b in prefix where !(b == 0x20 || b == 0x0A || b == 0x0D || b == 0x09 || b == 0xEF || b == 0xBB || b == 0xBF) {
            if b == UInt8(ascii: "<") { return .xml }
            if b == UInt8(ascii: "{") || b == UInt8(ascii: "[") { return .json }
            return nil
        }
        return nil
    }

    /// Læser en feed-fil i bidder og kalder `emit` for hver musikvare. Filen læses aldrig hel ind i hukommelsen.
    /// Returnerer antal varer (musik), der blev fundet.
    @discardableResult
    public static func parse(fileAt url: URL, emit: (IMusicProduct) throws -> Void) throws -> Int {
        let handle = try FileHandle(forReadingFrom: url)
        let head = try handle.read(upToCount: 64) ?? Data()
        try handle.close()
        switch detectFormat(head) {
        case .xml?:
            guard let stream = InputStream(url: url) else { throw IMusicFeedError.unreadable }
            return try parseXML(stream: stream, emit: emit)
        case .json?:
            let h = try FileHandle(forReadingFrom: url)
            defer { try? h.close() }
            var scanner = JSONElementScanner()
            var count = 0
            while let chunk = try h.read(upToCount: 1 << 20), !chunk.isEmpty {
                try scanner.feed(chunk) { obj in
                    if let p = IMusicFields.product(from: flatten(obj)) { try emit(p); count += 1; return true }
                    return false
                }
            }
            return count
        case nil:
            throw IMusicFeedError.unknownFormat
        }
    }

    /// Til checks og små feeds: parser data i hukommelsen.
    public static func parse(data: Data) throws -> [IMusicProduct] {
        var out: [IMusicProduct] = []
        switch detectFormat(data.prefix(64)) {
        case .xml?:
            _ = try parseXML(stream: InputStream(data: data)) { out.append($0) }
        case .json?:
            var scanner = JSONElementScanner()
            // Bidder på 7 byte, så skillet mellem bidder også bliver afprøvet.
            var i = data.startIndex
            while i < data.endIndex {
                let j = data.index(i, offsetBy: 7, limitedBy: data.endIndex) ?? data.endIndex
                try scanner.feed(data[i..<j]) { obj in
                    if let p = IMusicFields.product(from: flatten(obj)) { out.append(p); return true }
                    return false
                }
                i = j
            }
        case nil:
            throw IMusicFeedError.unknownFormat
        }
        return out
    }

    /// Gør et JSON-objekt fladt: indlejrede objekter (fx product_info, update_info) lægges op på
    /// samme niveau. Nøgler gøres små; det første felt med et navn vinder.
    static func flatten(_ obj: [String: Any]) -> [String: String] {
        var out: [String: String] = [:]
        func walk(_ o: [String: Any]) {
            for (k, v) in o.sorted(by: { $0.key < $1.key }) {
                let key = k.lowercased()
                switch v {
                case let s as String: if out[key] == nil { out[key] = s }
                case let n as NSNumber:
                    if out[key] == nil {
                        out[key] = CFGetTypeID(n) == CFBooleanGetTypeID() ? (n.boolValue ? "true" : "false") : n.stringValue
                    }
                case let d as [String: Any]: walk(d)
                case let a as [Any]:
                    // Fx "ean": ["5099..."] eller kategorier som liste.
                    // Lister af objekter (fx images) springes over.
                    let strings = a.compactMap { $0 as? String }
                    if !strings.isEmpty, out[key] == nil { out[key] = strings.joined(separator: " ") }
                default: break
                }
            }
        }
        walk(obj)
        return out
    }

    // XML: hvert element med et af disse navne er én vare; alle blade under det samles fladt.
    static let xmlProductElements: Set<String> = ["product", "item", "record", "offer", "entry"]

    static func parseXML(stream: InputStream, emit: (IMusicProduct) throws -> Void) throws -> Int {
        var count = 0
        var failure: Error?
        var sawRecord = false
        try withoutActuallyEscaping(emit) { emit in
            // Hver vare gives videre, så snart dens slut-tag er læst; intet samles op i hukommelsen.
            let delegate = XMLProductCollector { record in
                sawRecord = true
                guard failure == nil, let p = IMusicFields.product(from: record) else { return }
                do { try emit(p); count += 1 } catch { failure = error }
            }
            let parser = XMLParser(stream: stream)
            parser.delegate = delegate
            parser.shouldResolveExternalEntities = false
            let ok = parser.parse()
            if let failure { throw failure }
            if !ok, !sawRecord { throw IMusicFeedError.unreadable }
        }
        return count
    }
}

public enum IMusicFeedError: LocalizedError {
    case unknownFormat, unreadable, badURL, http(Int), notApproved
    public var errorDescription: String? {
        switch self {
        case .unknownFormat: return "iMusic-feedet er hverken JSON eller XML. Vælg JSON eller XML, når du laver feed-URL'en hos Daisycon."
        case .unreadable: return "iMusic-feedet kunne ikke læses."
        case .badURL: return "Feed-URL'en ser ikke rigtig ud. Den skal starte med https://."
        case .http(let code): return "Daisycon svarede med en fejl (kode \(code)). Tjek feed-URL'en i Indstillinger."
        case .notApproved: return "Feedet er tomt. Er du godkendt til iMusic-kampagnen hos Daisycon endnu?"
        }
    }
}

/// Samler blad-elementer (navn → tekst) for hver vare og giver varen videre, så snart den er læst.
final class XMLProductCollector: NSObject, XMLParserDelegate {
    private let onRecord: ([String: String]) -> Void
    private var depthInProduct = 0
    private var current: [String: String] = [:]
    private var text = ""

    init(onRecord: @escaping ([String: String]) -> Void) {
        self.onRecord = onRecord
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        let n = name.lowercased()
        if depthInProduct == 0 {
            if IMusicFeedParser.xmlProductElements.contains(n) { depthInProduct = 1; current = [:] }
        } else {
            depthInProduct += 1
        }
        text = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if depthInProduct > 0 { text += string }
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        if depthInProduct > 0, let s = String(data: CDATABlock, encoding: .utf8) { text += s }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        guard depthInProduct > 0 else { return }
        depthInProduct -= 1
        if depthInProduct == 0 {
            onRecord(current)
            current = [:]
        } else {
            let key = name.lowercased()
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty, current[key] == nil { current[key] = t }
        }
        text = ""
    }
}

/// Finder JSON-objekter, der er elementer i en liste (fx varerne i "products": [...]), i en
/// strøm af bidder, uden at læse hele feedet ind. Objekter over `maxObjectBytes` (fx et
/// helt "program" med alle varerne) gives ikke videre; deres indhold bliver fundet i stedet.
struct JSONElementScanner {
    static let maxObjectBytes = 1 << 20

    private var buffer: [UInt8] = []
    /// Absolut position for buffer[0].
    private var bufferStart = 0
    private var position = 0
    private var inString = false
    private var escaped = false
    /// Containere fra yderst til inderst: true = liste, false = objekt.
    private var stack: [Bool] = []
    /// Åbne objekter, der er elementer i en liste: (dybde, startposition). Fjernes, hvis de bliver for store.
    private var candidates: [(depth: Int, start: Int)] = []
    /// Start på den seneste vare, der blev givet videre.
    private var lastProductStart: Int?

    /// `handle` returnerer true, hvis objektet var en vare (så dets indre ikke undersøges igen).
    mutating func feed<D: DataProtocol>(_ chunk: D, handle: ([String: Any]) throws -> Bool) throws {
        buffer.append(contentsOf: chunk)
        while position - bufferStart < buffer.count {
            let b = buffer[position - bufferStart]
            if inString {
                if escaped { escaped = false }
                else if b == 0x5C { escaped = true }          // \
                else if b == 0x22 { inString = false }        // "
            } else {
                switch b {
                case 0x22: inString = true
                case 0x7B:                                    // {
                    if stack.last == true { candidates.append((stack.count, position)) }
                    stack.append(false)
                case 0x5B: stack.append(true)                 // [
                case 0x7D, 0x5D:                              // } ]
                    let depth = stack.count
                    if !stack.isEmpty { stack.removeLast() }
                    // Et objekt, der var element i en liste, er slut.
                    if b == 0x7D, let last = candidates.last, last.depth == depth - 1 {
                        candidates.removeLast()
                        let from = last.start - bufferStart, to = position - bufferStart
                        // Et objekt, der indeholder varer, vi allerede har givet videre (fx et lille
                        // "program"), undersøges ikke igen.
                        let containsProduct = lastProductStart.map { $0 > last.start } ?? false
                        if from >= 0, to - from + 1 <= Self.maxObjectBytes, !containsProduct {
                            let bytes = Data(buffer[from...to])
                            if let obj = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
                               try handle(obj) {
                                lastProductStart = last.start
                            }
                        }
                    }
                default: break
                }
            }
            position += 1
            // Kandidater, der er blevet for store, opgives (deres indre elementer findes for sig).
            while let first = candidates.first, position - first.start > Self.maxObjectBytes {
                candidates.removeFirst()
            }
        }
        // Behold kun bytes fra den ældste åbne kandidat (eller intet).
        let keepFrom = candidates.first?.start ?? position
        let drop = keepFrom - bufferStart
        if drop > 0 {
            buffer.removeFirst(min(drop, buffer.count))
            bufferStart += drop
        }
    }
}

// MARK: - Cache-database (imusic.sqlite)

/// iMusic-varerne fra feedet. Ligger i ~/Library/Caches/VinylShelfFinder/imusic.sqlite, adskilt fra
/// brugerens rigtige database, og kan altid slettes og hentes igen.
public final class IMusicCache {
    public let db: SQLiteDatabase
    public let url: URL

    public static var defaultURL: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VinylShelfFinder", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("imusic.sqlite")
    }

    /// Feedet hentes højst én gang i døgnet.
    public static let refreshInterval: TimeInterval = 24 * 3600

    public init(url: URL = IMusicCache.defaultURL) throws {
        self.url = url
        db = try SQLiteDatabase(path: url.path)
        try db.execute("""
            CREATE TABLE IF NOT EXISTS products (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                ean TEXT,
                artist TEXT NOT NULL,
                title TEXT NOT NULL,
                search TEXT NOT NULL,
                format TEXT NOT NULL,
                price REAL,
                currency TEXT NOT NULL,
                in_stock INTEGER,
                delivery TEXT,
                link TEXT NOT NULL
            );
            CREATE INDEX IF NOT EXISTS products_ean ON products(ean);
            CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT);
            """)
    }

    public var lastFetched: Date? {
        (try? db.query("SELECT value FROM meta WHERE key = 'fetched_at'"))?.first?["value"]?.double
            .map(Date.init(timeIntervalSince1970:))
    }

    public var count: Int {
        Int((try? db.query("SELECT COUNT(*) AS n FROM products"))?.first?["n"]?.int ?? 0)
    }

    public static func needsRefresh(lastFetched: Date?, now: Date = Date()) -> Bool {
        guard let lastFetched else { return true }
        return now.timeIntervalSince(lastFetched) >= refreshInterval || lastFetched > now
    }

    /// Erstatter hele indholdet med varerne fra en feed-fil (i én transaktion; fejler noget,
    /// beholdes den gamle cache).
    @discardableResult
    public func replace(withFeedAt file: URL, now: Date = Date()) throws -> Int {
        try db.transaction {
            try db.run("DELETE FROM products")
            let n = try IMusicFeedParser.parse(fileAt: file) { try insert($0) }
            try db.run("INSERT INTO meta(key, value) VALUES('fetched_at', ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                       now.timeIntervalSince1970)
            return n
        }
    }

    /// Til checks: læg varer direkte i cachen.
    public func insert(_ p: IMusicProduct) throws {
        try db.run("""
            INSERT INTO products(ean, artist, title, search, format, price, currency, in_stock, delivery, link)
            VALUES(?,?,?,?,?,?,?,?,?,?)
            """, p.ean, p.artist, p.title, SearchIndex.normalize("\(p.artist) \(p.title)"), p.format, p.price, p.currency,
               p.inStock.map { $0 ? 1 : 0 }, p.delivery, p.link.absoluteString)
    }

    private func product(_ r: SQLRow) -> IMusicProduct? {
        guard let link = r["link"]?.text.flatMap(URL.init(string:)) else { return nil }
        return IMusicProduct(title: r["title"]?.text ?? "", artist: r["artist"]?.text ?? "", ean: r["ean"]?.text,
                             format: r["format"]?.text ?? "", price: r["price"]?.double,
                             currency: r["currency"]?.text ?? "DKK", inStock: r["in_stock"]?.int.map { $0 != 0 },
                             delivery: r["delivery"]?.text, link: link)
    }

    /// Bedste vare for en plade: først på stregkode, ellers på kunstner + titel (tåler små stavefejl),
    /// med vinyl foran andre formater, når `preferVinyl` er sat.
    public func match(barcodes: [String], artist: String, title: String, preferVinyl: Bool = true) -> IMusicProduct? {
        let eans = Set(barcodes.compactMap(Barcode.normalize))
        for ean in eans.sorted() {
            let rows = (try? db.query("SELECT * FROM products WHERE ean = ?", ean)) ?? []
            if let p = rows.compactMap(product).first { return p }
        }
        let wanted = SearchIndex.words("\(artist) \(title)").filter { $0.count >= 2 }
        guard !wanted.isEmpty else { return nil }
        // Kandidater: varer, hvis tekst indeholder det længste ord (hurtigt via LIKE), derefter scoring.
        let anchor = wanted.max { $0.count < $1.count }!
        let rows = (try? db.query("SELECT * FROM products WHERE search LIKE ? LIMIT 400", "%\(anchor)%")) ?? []
        let scored = rows.compactMap(product).compactMap { p -> (IMusicProduct, Int)? in
            guard let s = IMusicMatcher.score(wanted: wanted, product: p) else { return nil }
            return (p, s + (preferVinyl && p.isVinyl ? 5 : 0))
        }
        return scored.max { $0.1 < $1.1 }?.0
    }
}

/// Fuzzy-sammenligning af kunstner + titel. Bruger samme normalisering og stavefejl-afstand som
/// den lokale søgning (`SearchIndex`).
public enum IMusicMatcher {
    /// nil, hvis ikke alle ønskede ord findes i varen (tåler 1 stavefejl i ord på mindst 4 tegn).
    /// Ellers en score: flere præcise ord og færre ekstra ord er bedre.
    public static func score(wanted: [String], product p: IMusicProduct) -> Int? {
        // Samme ord to gange (fx kunstneren både i brand og titel) tæller kun én gang.
        var seen = Set<String>()
        let have = SearchIndex.words("\(p.artist) \(p.title)").filter { seen.insert($0).inserted }
        var score = 0
        for w in wanted {
            if have.contains(w) { score += 10; continue }
            guard w.count >= 4,
                  have.contains(where: { abs($0.count - w.count) <= 1 && SearchIndex.editDistance(w, $0, max: 1) <= 1 })
            else { return nil }
            score += 6
        }
        // Ekstra ord (fx "Deluxe Edition") trækker lidt ned, så den rene udgave vinder.
        score -= max(0, have.count - wanted.count)
        return score
    }
}

// MARK: - Hentning af feedet

public enum IMusicFeedUpdater {
    /// Kun https-adresser hos Daisycon godtages (feedet ligger på daisycon.io).
    public static func validate(_ text: String) -> URL? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: t), url.scheme == "https", let host = url.host?.lowercased(),
              host == "daisycon.io" || host.hasSuffix(".daisycon.io") || host.hasSuffix("daisycon.com") else { return nil }
        return url
    }

    /// Henter feedet til en midlertidig fil (aldrig hele feedet i hukommelsen) og lægger musikvarerne
    /// i cachen. Adressen indeholder brugerens media_id og logges aldrig.
    @discardableResult
    public static func refresh(feed: URL, cache: IMusicCache, session: URLSession = .shared, now: Date = Date()) async throws -> Int {
        var req = URLRequest(url: feed)
        req.setValue(DiscogsClient.userAgent, forHTTPHeaderField: "User-Agent")
        let (file, response) = try await session.download(for: req)
        defer { try? FileManager.default.removeItem(at: file) }
        guard let http = response as? HTTPURLResponse else { throw IMusicFeedError.unreadable }
        guard (200..<300).contains(http.statusCode) else { throw IMusicFeedError.http(http.statusCode) }
        // Daisycon svarer med X-Total-Count: 0, før man er godkendt til kampagnen.
        if http.value(forHTTPHeaderField: "X-Total-Count") == "0" { throw IMusicFeedError.notApproved }
        return try cache.replace(withFeedAt: file, now: now)
    }
}
