import Foundation

/// Lokal, hurtig søgning i hele samlingen (plader og sange). Tolererer stavefejl.
///
/// Bygget som de store søgemaskiner (Algolia, Meilisearch, Typesense): resultaterne sorteres efter en fast
/// rækkefølge af regler, hvor hver regel kun afgør det, de forrige lod stå lige – ikke efter en sum af point:
///  1. flest af søgningens ord fundet (artikler som "the" er valgfrie; i nødstilfælde må 1-2 ord mangle)
///  2. færrest stavefejl (0 under 4 tegn, 1 fra 4, 2 fra 6; ingen i ord med tal)
///  3. slags træf: plade på hele ord i kunstner/titel → sang, der hedder præcis søgningen → plade med påbegyndt
///     ord → anden sang → sang med påbegyndt ord → plade, der kun passer på katalognummer, selskab, år eller format
///  4. færrest fejl i første bogstav, så hele ord før påbegyndte
///  5. titlen er søgningen ("blue" → albummet Blue) → kunstneren er søgningen → titlen begynder med den →
///     kunstneren begynder med den (kortest navn først) → søgningen står samlet i titel/kunstner → resten
///  6. ordene står ved siden af hinanden i samme rækkefølge (eller kunstner efterfulgt af titel)
///  7. kunstner/titel før sang, katalognummer, pladeselskab og resten; tidligt i feltet før sent
///  8. reolens rækkefølge (en kunstners egne plader står altid i reolens rækkefølge)
/// Kun det sidste ord må være påbegyndt. Romertal ("iv" = 4), "og"/"and" og "aa"/"oe"/"ue" for å/ø/ü gælder i
/// kunstner, titel og sang. Hvert ord i samlingen sammenlignes højst én gang pr. søgning (ordlisten `vocab`).
/// Port: windows/src/VinylCore/Search.cs. De to skal give præcis samme rækkefølge (fælles checks).
/// Målt 19. okt 2026 på 360 + 246 søgninger: 98 % rigtigt øverst (før 93 %), ca. 10 ms pr. tastetryk.
public struct SearchIndex {
    /// Ét felt, klar til søgning: ordene, ordene uden skilletegn ("AC/DC" → "acdc") og hele feltet.
    struct Field {
        /// Ordene som numre i ordlisten (`vocab`), så hvert ord kun sammenlignes én gang pr. søgning.
        let words: [Int32]
        /// Ord skrevet med skilletegn inde i ordet, samlet: "AC/DC" → "acdc", "A-ha" → "aha", "R.E.M." → "rem",
        /// og hele feltet i ét ord ("okcomputer").
        let joined: [Int32]
        let full: String
        /// Uden en artikel forrest ("The Beatles" → "beatles").
        let bare: String

        init(_ text: String, _ vocab: inout Vocabulary) {
            let w = SearchIndex.words(SearchIndex.spellSymbols(text))
            words = w.map { vocab.id($0) }
            full = w.joined(separator: " ")
            bare = SearchIndex.articles.contains(w.first ?? "") && w.count > 1 ? w.dropFirst().joined(separator: " ") : full
            var j: [Int32] = []
            // Kun ord med et skilletegn inde i sig ("AC/DC"); for ren ASCII tjekkes det hurtigt på bytes.
            let ascii = text.utf8.allSatisfy { $0 < 128 }
            let hasInnerMark = ascii ? text.utf8.contains { !($0 == 32 || ($0 >= 48 && $0 <= 57) || ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122)) } : true
            for part in hasInnerMark ? text.split(whereSeparator: { $0.isWhitespace }) : []
            where part.contains(where: { !$0.isLetter && !$0.isNumber }) {
                let pw = SearchIndex.words(String(part))
                if pw.count > 1 { j.append(vocab.id(pw.joined())) }
            }
            if w.count > 1 { j.append(vocab.id(w.joined())) }
            joined = j
        }
    }

    /// Alle forskellige ord i samlingen.
    struct Vocabulary {
        private(set) var words: [String] = []
        private var ids: [String: Int32] = [:]
        mutating func id(_ w: String) -> Int32 {
            if let i = ids[w] { return i }
            let i = Int32(words.count)
            words.append(w); ids[w] = i
            return i
        }
    }

    struct Entry {
        let id: Int64
        let artist: Field
        let title: Field
        let catalog: Field
        let label: Field
        let other: Field          // år og format
        let compactCatalog: String
        let releaseID: String
        /// Plads i reolens rækkefølge (sektion, position). Uplacerede plader får `Int.max`.
        let shelfOrder: Int
        let tracks: [(track: Track, field: Field)]
    }

    /// Et søgeresultat. `track` er sat, når det er en sang på pladen, der passer (ikke pladen selv).
    public struct Hit: Equatable {
        public let id: Int64
        public let track: Track?
    }

    private let entries: [Entry]
    private let vocab: [String]
    /// Ordlisten som tegn (til stavefejl-sammenligningen uden at lave nye tekster hver gang).
    private let vocabChars: [[Unicode.Scalar]]
    /// Ordet indeholder et tal (så må det ikke rettes for stavefejl).
    private let vocabHasDigit: [Bool]

    public init(library: Library) {
        var v = Vocabulary()
        entries = library.allItems.map { it in
            let r = it.release
            return Entry(
                id: it.id,
                artist: Field(r.artist, &v),
                title: Field(r.title, &v),
                catalog: Field(r.catalogNumber ?? "", &v),
                label: Field(r.label ?? "", &v),
                other: Field([r.year.map(String.init) ?? "", r.format ?? ""].joined(separator: " "), &v),
                compactCatalog: Self.normalize(r.catalogNumber ?? "").filter { !$0.isWhitespace },
                releaseID: String(r.id),
                shelfOrder: library.globalIndex[it.id] ?? Int.max,
                tracks: r.tracks.map { ($0, Field($0.title, &v)) })
        }
        vocab = v.words
        vocabChars = v.words.map { Array($0.unicodeScalars) }
        vocabHasDigit = v.words.map(Self.hasDigit)
    }

    // MARK: Normalisering (bruges også af iMusic-matcheren – må ikke ændres uden at tjekke den)

    public static func normalize(_ s: String) -> String {
        // Hurtig vej for ren ASCII (langt de fleste titler): samme resultat som nedenfor.
        if s.utf8.allSatisfy({ $0 < 128 }) {
            var out: [UInt8] = []
            out.reserveCapacity(s.utf8.count + 8)
            var space = true
            func put(_ c: UInt8) {
                if c == 32 { if !space { out.append(32); space = true } } else { out.append(c); space = false }
            }
            for var c in s.utf8 {
                if c >= 65 && c <= 90 { c += 32 }
                if c == 38 { put(32); for x in "and".utf8 { put(x) }; put(32) }
                else if (c >= 97 && c <= 122) || (c >= 48 && c <= 57) { put(c) }
                else { put(32) }
            }
            if out.last == 32 { out.removeLast() }
            return String(decoding: out, as: UTF8.self)
        }
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

    /// Et tal 0-9 (samme regel på Windows).
    static func hasDigit(_ s: String) -> Bool { s.unicodeScalars.contains { $0.value >= 48 && $0.value <= 57 } }

    /// Titler af bare tegn ("÷", "★") kan ellers ikke findes: tegnet skrives også som ord.
    static func spellSymbols(_ s: String) -> String {
        guard s.unicodeScalars.contains(where: { symbolScalars.contains($0.value) }) else { return s }
        return s + " " + s.compactMap { symbolNames[$0] }.joined(separator: " ")
    }
    private static let symbolScalars: Set<UInt32> = Set(symbolNames.keys.flatMap { $0.unicodeScalars.map(\.value) })
    private static let symbolNames: [Character: String] = ["÷": "divide", "×": "multiply", "+": "plus", "★": "blackstar", "=": "equals", "−": "minus"]

    /// Artikler, der ikke behøver at stå i søgningen ("beatles" finder "The Beatles", og omvendt).
    static let articles: Set<String> = ["the", "a", "an", "de", "det", "den", "en", "et", "le", "la", "les", "die", "der", "das"]

    /// Ord, der betyder det samme: romertal og tal, forkortelser og "og"/"and".
    static func synonyms(_ t: String) -> [String] {
        if let n = Int(t), let r = romanByNumber[n] { return [r] }
        if let n = numberByRoman[t] { return [String(n)] }
        switch t {
        case "pt": return ["part"]
        case "part": return ["pt"]
        case "vol": return ["volume"]
        case "volume": return ["vol"]
        case "st": return ["saint"]
        case "saint": return ["st"]
        case "og": return ["and"]
        case "and": return ["og"]
        default:
            // Skrevet uden særlige tegn: "saa" = så, "huesker" = hüsker ("oe" = ø og "ae" = æ klares allerede).
            var alt: [String] = []
            for (from, to) in [("aa", "a"), ("oe", "o"), ("ue", "u")] where t.contains(from) {
                alt.append(t.replacingOccurrences(of: from, with: to))
            }
            return alt
        }
    }
    private static let romans = ["i", "ii", "iii", "iv", "v", "vi", "vii", "viii", "ix", "x",
                                 "xi", "xii", "xiii", "xiv", "xv", "xvi", "xvii", "xviii", "xix", "xx"]
    private static let romanByNumber: [Int: String] = Dictionary(uniqueKeysWithValues: romans.enumerated().map { ($0.offset + 1, $0.element) })
    private static let numberByRoman: [String: Int] = Dictionary(uniqueKeysWithValues: romans.enumerated().map { ($0.element, $0.offset + 1) })

    // MARK: Søgning

    public func search(_ query: String, limit: Int = 60) -> [Int64] {
        hits(query, limit: limit).map(\.id)
    }

    /// Som `search`, men fortæller også, hvilken sang der passede, når det er en sang og ikke pladen.
    public func hits(_ query: String, limit: Int = 60) -> [Hit] {
        // Højst 10 ord: en lang indsat tekst må ikke få appen til at hænge.
        let tokens = Array(Self.words(Self.spellSymbols(query)).prefix(10))
        guard !tokens.isEmpty else { return [] }
        var found = rank(tokens, allPrefix: false, mayMiss: 0)
        // Intet fundet: prøv igen, hvor alle ord må være påbegyndte ("abb road"),
        // og ellers hvor ét ord må mangle ("jimmy hendrix", "dark side of the mon").
        if found.isEmpty, tokens.count > 1 { found = rank(tokens, allPrefix: true, mayMiss: 0) }
        if found.isEmpty, tokens.count > 1 { found = rank(tokens, allPrefix: true, mayMiss: tokens.count >= 5 ? 2 : 1) }
        return found.prefix(limit).map { Hit(id: $0.id, track: $0.track) }
    }

    /// Sorteringsnøgle: mindst først, felt for felt (se reglerne øverst).
    typealias Key = [Int]

    private func rank(_ tokens: [String], allPrefix: Bool, mayMiss: Int) -> [(id: Int64, track: Track?, key: Key)] {
        let q = Query(tokens: tokens, allPrefix: allPrefix, mayMiss: mayMiss, vocab: vocab, vocabChars: vocabChars,
                      vocabHasDigit: vocabHasDigit)
        var out: [(id: Int64, track: Track?, key: Key)] = []
        for e in entries {
            var best: (track: Track?, key: Key)?
            // Kunstneren regnes ud én gang og bruges både til pladen og alle dens sange.
            let artist = q.bests(e.artist)
            if let k = q.albumKey(e, artist: artist) { best = (nil, k) }
            for t in e.tracks {
                let song = q.bests(t.field)
                guard song.contains(where: { $0 != nil }) else { continue } // ingen af ordene i sangens titel
                if let k = q.songKey(e, t.field, artist: artist, song: song),
                   best.map({ k.lexicographicallyPrecedes($0.key) }) ?? true { best = (t.track, k) }
            }
            if let best { out.append((e.id, best.track, best.key)) }
        }
        return out.sorted { $0.key.lexicographicallyPrecedes($1.key) }
    }

    /// Én søgning: ordene og en hukommelse for ord, der allerede er sammenlignet (samme ord går igen i mange plader).
    private final class Query {
        let tokens: [String]
        let phrase: String
        /// Uden en artikel forrest.
        let barePhrase: String
        let compact: String
        let allPrefix: Bool
        /// Så mange ord (ud over artikler) må mangle.
        let mayMiss: Int
        /// Ordet er en artikel og må mangle.
        let optional: [Bool]
        private let vocab: [String]
        private let vocabChars: [[Unicode.Scalar]]
        private let tokenChars: [[Unicode.Scalar]]
        private let vocabHasDigit: [Bool]
        private let tokenSynonyms: [[String]]
        private let tokenBudget: [Int]
        private var dist = EditDistance()
        /// Pr. søgeord og ord i ordlisten: -2 ikke regnet ud, -1 passer ikke, ellers stavefejl × 2 + (påbegyndt ? 1 : 0).
        private var cache: [[Int16]]

        struct Match {
            /// Antal stavefejl (et ord, der kun står inde i et andet ord, tæller 2).
            let cost: Int
            /// Kun begyndelsen af ordet passer.
            let prefix: Bool
            /// Et ord, der betyder det samme (romertal, "og"/"and", "aa"/"å") – gælder kun i kunstner, titel og sang.
            var synonym = false
            /// Første bogstav er forkert (tæller med i hvor mange fejl der må være, men afgør først senere).
            var firstLetter = false
        }

        init(tokens: [String], allPrefix: Bool, mayMiss: Int, vocab: [String], vocabChars: [[Unicode.Scalar]], vocabHasDigit: [Bool]) {
            self.vocab = vocab
            self.vocabChars = vocabChars
            self.vocabHasDigit = vocabHasDigit
            tokenSynonyms = tokens.map(SearchIndex.synonyms)
            tokenBudget = tokens.map(Query.budget)
            tokenChars = tokens.map { Array($0.unicodeScalars) }
            self.tokens = tokens
            self.allPrefix = allPrefix
            self.mayMiss = mayMiss
            phrase = tokens.joined(separator: " ")
            barePhrase = SearchIndex.articles.contains(tokens[0]) && tokens.count > 1 ? tokens.dropFirst().joined(separator: " ") : phrase
            compact = tokens.joined()
            optional = tokens.indices.map { i in tokens.count > 1 && i < tokens.count - 1 && SearchIndex.articles.contains(tokens[i]) }
            cache = Array(repeating: Array(repeating: -2, count: vocab.count), count: tokens.count)
        }

        /// `needle` står et sted i `hay`.
        static func containsRun(_ hay: [Unicode.Scalar], _ needle: [Unicode.Scalar]) -> Bool {
            guard !needle.isEmpty, needle.count <= hay.count else { return false }
            for start in 0...(hay.count - needle.count) where hay[start] == needle[0] {
                var ok = true
                for k in 1..<needle.count where hay[start + k] != needle[k] { ok = false; break }
                if ok { return true }
            }
            return false
        }

        /// Hvor mange stavefejl et ord må have.
        /// Længder tælles i Unicode-tegn (skalarer), ligesom på Windows.
        static func budget(_ t: String) -> Int {
            if SearchIndex.hasDigit(t) { return 0 }
            let n = t.unicodeScalars.count
            return n >= 6 ? 2 : n >= 4 ? 1 : 0
        }

        /// Søgeordet nr. `i` mod ét ord fra pladen.
        func match(_ i: Int, _ id: Int32) -> Match? {
            var c = cache[i][Int(id)]
            if c == -2 {
                let m = computeMatch(i, Int(id))
                c = m.map { Int16($0.cost * 8 + ($0.prefix ? 4 : 0) + ($0.synonym ? 2 : 0) + ($0.firstLetter ? 1 : 0)) } ?? -1
                cache[i][Int(id)] = c
            }
            return c < 0 ? nil : Match(cost: Int(c) / 8, prefix: c & 4 != 0, synonym: c & 2 != 0, firstLetter: c & 1 != 0)
        }

        private func computeMatch(_ i: Int, _ id: Int) -> Match? {
            let t = tokens[i], w = vocab[id]
            let tc = tokenChars[i], wc = vocabChars[id]
            let last = allPrefix || i == tokens.count - 1
            if w == t { return Match(cost: 0, prefix: false) }
            // Et enkelt bogstav, der stadig skrives, er ikke et romertal ("back i" → Back In Black, ikke "1").
            if !(last && tc.count == 1 && !SearchIndex.hasDigit(t)), tokenSynonyms[i].contains(w) { return Match(cost: 0, prefix: false, synonym: true) }
            if last, wc.count > tc.count, wc[..<tc.count].elementsEqual(tc) { return Match(cost: 0, prefix: true) }
            let budget = tokenBudget[i]
            if budget > 0, !vocabHasDigit[id] {
                let first = tc.first == wc.first ? 0 : 1
                if abs(wc.count - tc.count) <= budget {
                    let d = dist.distance(tc[...], wc[...], max: budget) + first
                    if d <= budget { return Match(cost: d - first, prefix: false, firstLetter: first == 1) }
                }
                if last, wc.count > tc.count {
                    let d = dist.distance(tc[...], wc[..<tc.count], max: budget) + first
                    if d <= budget { return Match(cost: d - first, prefix: true, firstLetter: first == 1) }
                }
            }
            // Sidste udvej: ordet står inde i et længere ord (danske sammensatte ord, "sommer" i "sommerfugl").
            if tc.count >= 4, wc.count > tc.count, Self.containsRun(wc, tc) { return Match(cost: 2, prefix: true) }
            return nil
        }

        /// Bedste træf for ét søgeord i ét felt.
        struct Best {
            let match: Match
            /// Ordets plads i feltet.
            let position: Int
        }

        /// Bedste træf i feltet for hvert søgeord (nil = ordet står ikke i feltet).
        func bests(_ f: Field, synonyms: Bool = true) -> [Best?] {
            tokens.indices.map { i in
                var best: Best?
                func consider(_ m: Match?, _ pos: Int) {
                    guard let m, synonyms || !m.synonym else { return }
                    if let b = best, (b.match.cost, b.match.prefix ? 1 : 0, b.position) <= (m.cost, m.prefix ? 1 : 0, pos) { return }
                    best = Best(match: m, position: pos)
                }
                for (p, w) in f.words.enumerated() { consider(match(i, w), p) }
                // Sammentrukne ord ("acdc", "okcomputer") kun helt eller påbegyndt – ikke med stavefejl ("imagine" ≠ "imemine").
                for w in f.joined { if let m = match(i, w), m.cost == 0 { consider(m, 0) } }
                return best
            }
        }

        /// Fælles for plader og sange: hvert søgeord mod felterne (med vægt = rang, lavest bedst).
        /// `exactness` regnes kun ud, når pladen/sangen faktisk passer (det er tekstsammenligninger og koster tid).
        private func key(fields: [(bests: [Best?], rank: Int)], entity: Int, exactness: () -> (level: Int, length: Int),
                         requireRank: Int?, shelf: Int, id: Int64) -> Key? {
            var allInArtist = true
            var realMatched = 0
            var matched = 0, typos = 0, firstLetters = 0, lastPrefix = 0, bestRank = Int.max, worstRank = 0, firstPos = Int.max
            var placed: [(field: Int, pos: Int)?] = []
            var hitRequired = requireRank == nil
            var missing = 0
            for i in tokens.indices {
                var best: (match: Match, position: Int, field: Int, rank: Int)?
                for (fi, f) in fields.enumerated() {
                    guard let b = f.bests[i] else { continue }
                    if let cur = best, (cur.match.cost, cur.match.prefix ? 1 : 0, cur.rank, cur.position)
                        <= (b.match.cost, b.match.prefix ? 1 : 0, f.rank, b.position) { continue }
                    best = (b.match, b.position, fi, f.rank)
                }
                guard let b = best else {
                    if optional[i] { placed.append(nil); continue }
                    missing += 1
                    if missing > mayMiss { return nil }
                    placed.append(nil); continue
                }
                matched += 1
                if !optional[i] { realMatched += 1 }
                typos += b.match.cost
                if b.match.firstLetter { firstLetters += 1 }
                if b.match.prefix { lastPrefix = 1 }
                bestRank = min(bestRank, b.rank)
                worstRank = max(worstRank, b.rank)
                if b.field != 0 { allInArtist = false }
                firstPos = min(firstPos, b.position)
                if b.rank == requireRank { hitRequired = true }
                placed.append((b.field, b.position))
            }
            // Mindst ét rigtigt ord (ikke kun en artikel som "the") skal passe.
            guard hitRequired, realMatched > 0 else { return nil }
            // Ord, der står ved siden af hinanden i samme rækkefølge (eller kunstner efterfulgt af titel).
            var adjacent = 0
            for i in placed.indices.dropFirst() {
                guard let a = placed[i - 1], let b = placed[i] else { continue }
                // Samme felt og lige efter hinanden, eller kunstner (felt 0) efterfulgt af titel/sang (felt 1).
                if a.field == b.field ? b.pos == a.pos + 1 : (a.field == 0 && b.field == 1) { adjacent += 1 }
            }
            let ex = exactness()
            // Plade eller sang, og hvor godt den passer:
            // 0 plade fundet på hele ord i kunstner/titel, 1 sang, der hedder præcis søgningen ("heart"),
            // 2 plade, hvor sidste ord kun er påbegyndt, 3 anden sang (hele ord), 4 sang med påbegyndt ord,
            // 5 plade, der kun passer på katalognummer, pladeselskab, år eller format ("1999" som år).
            let tier: Int
            if entity == 0 { tier = worstRank > 0 ? 5 : lastPrefix == 0 ? 0 : 2 }
            else { tier = ex.level == 0 ? 1 : lastPrefix == 0 ? 3 : 4 }
            // Kunstnerens egne plader står i reolens rækkefølge, også når titlen indeholder navnet ("Beatles For Sale").
            // (også med stavefejl: "beetles"), så længe alle ord er fundet i kunstnerens navn.
            let position = entity == 0 && (ex.level <= 1 || allInArtist) ? 0 : firstPos
            return [-matched, typos, tier, firstLetters, lastPrefix, ex.level, ex.length, -adjacent, bestRank, position, shelf, Int(truncatingIfNeeded: id)]
        }

        func albumKey(_ e: Entry, artist: [Best?]) -> Key? {
            // Katalognummer med eller uden mellemrum ("shvl 804" / "shvl804") og Discogs-nummeret.
            // Kun når søgningen ligner et katalognummer (har et tal) – ellers ville "rad" finde "RAD 3" før Radiohead.
            if compact.unicodeScalars.count >= 3, SearchIndex.hasDigit(compact), !e.compactCatalog.isEmpty, e.compactCatalog.hasPrefix(compact) {
                let exact = e.compactCatalog == compact ? 0 : 1
                return [-tokens.count, 0, exact == 0 ? 0 : 2, 0, exact, exact, 0, 0, 2, 0, e.shelfOrder, Int(truncatingIfNeeded: e.id)]
            }
            if tokens.count == 1, tokens[0] == e.releaseID {
                return [-1, 0, 0, 0, 0, 0, 0, 0, 0, 0, e.shelfOrder, Int(truncatingIfNeeded: e.id)]
            }
            // 0 titlen er søgningen (også "kunstner titel"), 1 kunstneren er søgningen, 2 titlen begynder med den,
            // 3 kunstneren begynder med den, 4 søgningen står samlet i titel eller kunstner, 5 resten.
            func equals(_ f: Field) -> Bool { f.full == phrase || f.bare == barePhrase || f.full == barePhrase }
            func starts(_ f: Field) -> Bool { f.full.hasPrefix(phrase) || f.bare.hasPrefix(barePhrase) }
            func contains(_ f: Field) -> Bool { " \(f.full) ".contains(" \(barePhrase)") }
            // Niveau, og længden af det felt, der afgjorde det (kortere først: "kim" → Kim Larsen før Kim Larsen & Kjukken).
            func exactness() -> (level: Int, length: Int) {
                if equals(e.title) || "\(e.artist.bare) \(e.title.bare)" == barePhrase || "\(e.artist.full) \(e.title.full)" == phrase { return (0, 0) }
                if equals(e.artist) { return (1, 0) }
                if starts(e.title) { return (2, 0) }
                if starts(e.artist) { return (3, e.artist.words.count) }
                if contains(e.title) || contains(e.artist) { return (4, 0) }
                return (5, 0)
            }
            // Ét bogstav: kun begyndelsen af kunstner og titel (ikke katalognummer "K 50628" eller pladeselskab).
            if phrase.unicodeScalars.count == 1 {
                // ... og kun når kunstner eller titel begynder med bogstavet ("t" ikke via "Haven't").
                guard starts(e.artist) || starts(e.title) else { return nil }
                return key(fields: [(artist, 0), (bests(e.title), 0)],
                           entity: 0, exactness: exactness, requireRank: nil, shelf: e.shelfOrder, id: e.id)
            }
            return key(fields: [(artist, 0), (bests(e.title), 0), (bests(e.catalog, synonyms: false), 2), (bests(e.label, synonyms: false), 3), (bests(e.other, synonyms: false), 4)],
                       entity: 0, exactness: exactness, requireRank: nil, shelf: e.shelfOrder, id: e.id)
        }

        /// En sang: alle ord i sangens titel eller kunstneren, og mindst ét i sangens titel.
        func songKey(_ e: Entry, _ songField: Field, artist: [Best?], song: [Best?]) -> Key? {
            let song_ = songField
            if phrase.unicodeScalars.count == 1, !(song_.full.hasPrefix(phrase) || song_.bare.hasPrefix(barePhrase)) { return nil }
            func exactness() -> (level: Int, length: Int) {
                song_.full == phrase || song_.bare == barePhrase ? (0, 0) : song_.full.hasPrefix(phrase) ? (2, 0)
                    : " \(song_.full) ".contains(" \(barePhrase)") ? (4, 0) : (5, 0)
            }
            return key(fields: [(artist, 0), (song, 1)], entity: 1, exactness: exactness, requireRank: 1,
                       shelf: e.shelfOrder, id: e.id)
        }
    }

    /// Damerau-Levenshtein (optimal string alignment) med tidlig afbrydelse. Bruges også af iMusic-matcheren.
    static func editDistance(_ a: String, _ b: String, max limit: Int) -> Int {
        var d = EditDistance()
        return d.distance(Array(a.unicodeScalars)[...], Array(b.unicodeScalars)[...], max: limit)
    }

    /// Genbruger sine rækker, så en søgning ikke laver nye lister for hvert ord.
    struct EditDistance {
        private var prev2: [Int] = [], prev: [Int] = [], cur: [Int] = []

        mutating func distance(_ x: ArraySlice<Unicode.Scalar>, _ y: ArraySlice<Unicode.Scalar>, max limit: Int) -> Int {
            let x = Array(x), y = Array(y)
            if abs(x.count - y.count) > limit { return limit + 1 }
            if x.isEmpty { return y.count }
            if y.isEmpty { return x.count }
            let n = y.count + 1
            if prev.count < n { prev2 = Array(repeating: 0, count: n); prev = prev2; cur = prev2 }
            for j in 0..<n { prev[j] = j; prev2[j] = 0 }
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
                swap(&prev2, &prev); swap(&prev, &cur)
            }
            return prev[y.count]
        }
    }
}
