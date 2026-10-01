import Foundation

/// Konfigurerbare sorteringsregler. Ændrer aldrig det originale Discogs-navn –
/// de producerer kun en separat sorteringsværdi.
public struct SortRules: Equatable, Codable {
    public enum VariousPlacement: String, Codable, CaseIterable, Identifiable {
        case alphabetical, first, last
        public var id: String { rawValue }
        public var label: String {
            switch self {
            case .alphabetical: return "Alfabetisk under “Various”"
            case .first: return "Først i samlingen"
            case .last: return "Sidst i samlingen"
            }
        }
    }

    public enum WithinArtist: String, Codable, CaseIterable, Identifiable {
        case title, year
        public var id: String { rawValue }
        public var label: String { self == .title ? "Titel (alfabetisk)" : "Udgivelsesår (kronologisk)" }
    }

    /// Brug præcis den rækkefølge Discogs selv sorterer samlingen i (artist A–Z).
    /// De øvrige regler bruges så kun til plader uden Discogs-rækkefølge.
    public var useDiscogsOrder: Bool = true
    /// Artikler der ignoreres forrest i kunstnernavne ("The Beatles" → "Beatles").
    public var artistArticles: [String] = ["The"]
    /// Artikler der ignoreres forrest i titler. Tom som standard.
    public var titleArticles: [String] = []
    /// "AC/DC" → "ACDC", "A-ha" → "Aha".
    public var ignorePunctuation: Bool = true
    /// Æ, Ø, Å sorteres efter Z (ellers Æ=AE, Ø=O, Å=A).
    public var danishAlphabet: Bool = true
    public var various: VariousPlacement = .alphabetical
    public var withinArtist: WithinArtist = .title
    /// Kunstner (som vist) → sorteringsnavn, fx "Bob Dylan" → "Dylan, Bob".
    public var artistOverrides: [String: String] = [:]

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case useDiscogsOrder, artistArticles, titleArticles, ignorePunctuation, danishAlphabet, various, withinArtist
    }

    /// Tolerant dekodning, så gemte regler fra ældre versioner ikke går tabt.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = SortRules()
        useDiscogsOrder = try c.decodeIfPresent(Bool.self, forKey: .useDiscogsOrder) ?? d.useDiscogsOrder
        artistArticles = try c.decodeIfPresent([String].self, forKey: .artistArticles) ?? d.artistArticles
        titleArticles = try c.decodeIfPresent([String].self, forKey: .titleArticles) ?? d.titleArticles
        ignorePunctuation = try c.decodeIfPresent(Bool.self, forKey: .ignorePunctuation) ?? d.ignorePunctuation
        danishAlphabet = try c.decodeIfPresent(Bool.self, forKey: .danishAlphabet) ?? d.danishAlphabet
        various = try c.decodeIfPresent(VariousPlacement.self, forKey: .various) ?? d.various
        withinArtist = try c.decodeIfPresent(WithinArtist.self, forKey: .withinArtist) ?? d.withinArtist
    }

    // MARK: Sorteringsværdier

    public static func isVarious(_ artist: String) -> Bool {
        let a = artist.lowercased().trimmingCharacters(in: .whitespaces)
        return a == "various" || a == "various artists" || a.hasPrefix("various ")
    }

    /// Den menneskeligt læsbare sorteringsværdi for en kunstner, fx "Beatles".
    public func sortArtist(_ artist: String, override: String? = nil) -> String {
        if let o = override?.trimmingCharacters(in: .whitespaces), !o.isEmpty { return o }
        if let o = artistOverrides[artist], !o.isEmpty { return o }
        var s = artist.trimmingCharacters(in: .whitespaces)
        s = Self.stripArticles(s, articles: artistArticles)
        if ignorePunctuation { s = Self.removePunctuation(s) }
        return s
    }

    public func sortTitle(_ title: String, override: String? = nil) -> String {
        if let o = override?.trimmingCharacters(in: .whitespaces), !o.isEmpty { return o }
        var s = Self.stripArticles(title.trimmingCharacters(in: .whitespaces), articles: titleArticles)
        if ignorePunctuation { s = Self.removePunctuation(s) }
        return s
    }

    static func stripArticles(_ input: String, articles: [String]) -> String {
        var s = input
        for art in articles where !art.isEmpty {
            // "Beatles, The" → "Beatles"
            let suffix = ", " + art
            if s.lowercased().hasSuffix(suffix.lowercased()) {
                s = String(s.dropLast(suffix.count))
                break
            }
            // "The Beatles" → "Beatles" (men ikke "The" alene eller "Theatre")
            let prefix = art + " "
            if s.lowercased().hasPrefix(prefix.lowercased()), s.count > prefix.count {
                s = String(s.dropFirst(prefix.count))
                break
            }
        }
        return s
    }

    static func removePunctuation(_ s: String) -> String {
        let kept = s.unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0) || CharacterSet.whitespaces.contains($0)
        }
        let joined = String(String.UnicodeScalarView(kept))
        let collapsed = joined.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return collapsed.isEmpty ? s : collapsed
    }

    /// Maskin-nøgle til sammenligning: små bogstaver, diakritika foldet,
    /// og (i dansk tilstand) æ/ø/å placeret efter z.
    public func collationKey(_ s: String) -> String {
        var t = s.lowercased()
        if danishAlphabet {
            t = t.replacingOccurrences(of: "ä", with: "æ")
                 .replacingOccurrences(of: "ö", with: "ø")
                 .replacingOccurrences(of: "æ", with: "{")
                 .replacingOccurrences(of: "ø", with: "|")
                 .replacingOccurrences(of: "å", with: "}")
        } else {
            t = t.replacingOccurrences(of: "æ", with: "ae")
                 .replacingOccurrences(of: "ø", with: "o")
                 .replacingOccurrences(of: "ß", with: "ss")
        }
        return t.folding(options: [.diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    // MARK: Sammenligning

    public struct Key {
        public var discogsRank: Int     // Int.max hvis ukendt eller ikke i brug
        public var group: Int          // 0 = først, 1 = normal, 2 = sidst
        public var artist: String
        public var primary: String     // titel
        public var year: Int
        public var catalog: String
        public var releaseID: Int
        public var copyID: Int64
    }

    public func key(for item: RecordItem) -> Key {
        let artist = item.release.artist
        var group = 1
        if Self.isVarious(artist) {
            switch various {
            case .alphabetical: group = 1
            case .first: group = 0
            case .last: group = 2
            }
        }
        return Key(
            discogsRank: useDiscogsOrder ? (item.copy.discogsRank ?? Int.max) : Int.max,
            group: group,
            artist: collationKey(sortArtist(artist, override: item.copy.sortArtistOverride)),
            primary: collationKey(sortTitle(item.release.title, override: item.copy.sortTitleOverride)),
            year: item.release.year.flatMap { $0 > 0 ? $0 : nil } ?? 9999,
            catalog: collationKey(item.release.catalogNumber ?? ""),
            releaseID: item.release.id,
            copyID: item.copy.id
        )
    }

    public func areInIncreasingOrder(_ a: Key, _ b: Key) -> Bool {
        if a.discogsRank != b.discogsRank { return a.discogsRank < b.discogsRank }
        if a.group != b.group { return a.group < b.group }
        let c = Self.naturalCompare(a.artist, b.artist)
        if c != 0 { return c < 0 }
        if withinArtist == .year, a.year != b.year { return a.year < b.year }
        let t = Self.naturalCompare(a.primary, b.primary)
        if t != 0 { return t < 0 }
        if a.year != b.year { return a.year < b.year }
        let k = Self.naturalCompare(a.catalog, b.catalog)
        if k != 0 { return k < 0 }
        if a.releaseID != b.releaseID { return a.releaseID < b.releaseID }
        return a.copyID < b.copyID
    }

    public func sorted(_ items: [RecordItem]) -> [RecordItem] {
        items.map { ($0, key(for: $0)) }
            .sorted { areInIncreasingOrder($0.1, $1.1) }
            .map { $0.0 }
    }

    /// Ordinal sammenligning hvor tal-sekvenser sammenlignes numerisk ("2Pac" < "10cc").
    /// Mellemrum sorterer før bogstaver, så "Bob Dylan" < "Bobby".
    public static func naturalCompare(_ a: String, _ b: String) -> Int {
        let x = Array(a.unicodeScalars), y = Array(b.unicodeScalars)
        var i = 0, j = 0
        let digits = CharacterSet.decimalDigits
        while i < x.count && j < y.count {
            if digits.contains(x[i]) && digits.contains(y[j]) {
                var ei = i; while ei < x.count && digits.contains(x[ei]) { ei += 1 }
                var ej = j; while ej < y.count && digits.contains(y[ej]) { ej += 1 }
                let na = String(String.UnicodeScalarView(x[i..<ei])).drop(while: { $0 == "0" })
                let nb = String(String.UnicodeScalarView(y[j..<ej])).drop(while: { $0 == "0" })
                if na.count != nb.count { return na.count < nb.count ? -1 : 1 }
                if na != nb { return na < nb ? -1 : 1 }
                i = ei; j = ej
                continue
            }
            if x[i] != y[j] { return x[i].value < y[j].value ? -1 : 1 }
            i += 1; j += 1
        }
        if x.count - i == y.count - j { return 0 }
        return (x.count - i) < (y.count - j) ? -1 : 1
    }
}
