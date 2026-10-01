import Foundation

/// Lokal, hurtig søgning i hele samlingen. Tolererer små stavefejl.
public struct SearchIndex {
    struct Entry {
        let id: Int64
        let artistWords: [String]
        let titleWords: [String]
        let otherWords: [String]      // label, format, år
        let catalogWords: [String]
        let compactCatalog: String    // "shvl804"
        let compactArtist: String     // "acdc"
        let releaseID: String
        let full: String
        /// Plads i reolens rækkefølge (sektion, position). Uplacerede plader får `Int.max`.
        let shelfOrder: Int
    }

    private let entries: [Entry]

    public init(library: Library) {
        entries = library.allItems.map { it in
            let r = it.release
            let cat = Self.normalize(r.catalogNumber ?? "")
            return Entry(
                id: it.id,
                artistWords: Self.words(r.artist),
                titleWords: Self.words(r.title),
                otherWords: Self.words([r.label ?? "", r.year.map(String.init) ?? "", r.format ?? ""].joined(separator: " ")),
                catalogWords: Self.words(cat),
                compactCatalog: cat.filter { !$0.isWhitespace },
                compactArtist: Self.normalize(r.artist).filter { !$0.isWhitespace },
                releaseID: String(r.id),
                full: Self.normalize("\(r.artist) \(r.title) \(r.label ?? "") \(r.catalogNumber ?? "")"),
                shelfOrder: library.globalIndex[it.id] ?? Int.max)
        }
    }

    public static func normalize(_ s: String) -> String {
        let folded = s.lowercased()
            .replacingOccurrences(of: "æ", with: "ae")
            .replacingOccurrences(of: "ø", with: "o")
            .replacingOccurrences(of: "ß", with: "ss")
            .replacingOccurrences(of: "&", with: " and ")
            .folding(options: [.diacriticInsensitive, .widthInsensitive], locale: nil)
        let mapped = folded.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }
        return String(mapped).split(separator: " ").joined(separator: " ")
    }

    static func words(_ s: String) -> [String] {
        normalize(s).split(separator: " ").map(String.init)
    }

    /// Returnerer kopi-ID'er sorteret efter relevans. Ved samme relevans kommer pladerne i
    /// reolens rækkefølge (sektion, derefter position), og uplacerede plader til sidst.
    public func search(_ query: String, limit: Int = 60) -> [Int64] {
        let tokens = Self.words(query).filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return [] }
        let phrase = tokens.joined(separator: " ")
        let compactQuery = tokens.joined()

        var scored: [(id: Int64, score: Int, order: Int)] = []
        for e in entries {
            var total = 0
            var allMatched = true
            for t in tokens {
                let s = score(token: t, in: e)
                if s == 0 { allMatched = false; break }
                total += s
            }
            if !allMatched {
                // Katalognummer skrevet med/uden mellemrum: "shvl 804" / "shvl804".
                if compactQuery.count >= 3, e.compactCatalog.contains(compactQuery) {
                    scored.append((e.id, 25, e.shelfOrder))
                } else if tokens.count == 1, tokens[0] == e.releaseID {
                    scored.append((e.id, 100, e.shelfOrder))
                }
                continue
            }
            if e.full.contains(phrase) { total += 6 }
            if tokens.count == 1, tokens[0] == e.releaseID { total += 100 }
            scored.append((e.id, total, e.shelfOrder))
        }
        return scored.sorted { ($1.score, $0.order, $0.id) < ($0.score, $1.order, $1.id) }.prefix(limit).map(\.id)
    }

    private func score(token t: String, in e: Entry) -> Int {
        var best = 0
        func consider(_ words: [String], weight: Int) {
            for w in words {
                if w == t { best = max(best, 10 * weight) }
                else if w.hasPrefix(t) { best = max(best, 7 * weight) }
                else if t.count >= 3, w.contains(t) { best = max(best, 4 * weight) }
            }
        }
        consider(e.artistWords, weight: 3)
        consider(e.titleWords, weight: 3)
        consider(e.catalogWords, weight: 2)
        consider(e.otherWords, weight: 1)
        if t == e.releaseID { best = max(best, 30) }
        if best > 0 { return best }
        if t.count >= 3, e.compactCatalog.contains(t) { return 6 }
        // "acdc" → "AC/DC", "aha" → "A-ha"
        if t.count >= 3, e.compactArtist.hasPrefix(t) { return 18 }

        // Stavefejl: tillad 1 fejl (≥4 tegn) eller 2 fejl (≥7 tegn), også mod ord-præfikser.
        guard t.count >= 4 else { return 0 }
        let maxDist = t.count >= 7 ? 2 : 1
        for w in e.artistWords + e.titleWords + e.catalogWords + e.otherWords {
            if abs(w.count - t.count) <= maxDist, Self.editDistance(t, w, max: maxDist) <= maxDist { return 5 }
            if w.count > t.count, Self.editDistance(t, String(w.prefix(t.count)), max: maxDist) <= maxDist { return 3 }
        }
        return 0
    }

    /// Damerau-Levenshtein (optimal string alignment) med tidlig afbrydelse.
    static func editDistance(_ a: String, _ b: String, max limit: Int) -> Int {
        let x = Array(a), y = Array(b)
        if abs(x.count - y.count) > limit { return limit + 1 }
        if x.isEmpty { return y.count }
        if y.isEmpty { return x.count }
        var prev2 = [Int](repeating: 0, count: y.count + 1)
        var prev = Array(0...y.count)
        var cur = [Int](repeating: 0, count: y.count + 1)
        for i in 1...x.count {
            cur[0] = i
            var rowMin = cur[0]
            for j in 1...y.count {
                let cost = x[i - 1] == y[j - 1] ? 0 : 1
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
                if i > 1, j > 1, x[i - 1] == y[j - 2], x[i - 2] == y[j - 1] {
                    cur[j] = min(cur[j], prev2[j - 2] + 1)
                }
                rowMin = min(rowMin, cur[j])
            }
            if rowMin > limit { return limit + 1 }
            prev2 = prev; prev = cur
        }
        return prev[y.count]
    }
}
