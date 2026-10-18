import Foundation

/// Et uforanderligt øjebliksbillede af hele samlingen, bygget fra databasen.
/// Al navigation (naboer, forslag, sektioner) beregnes herfra – `previous`/`next`
/// gemmes aldrig, de udledes af den fysiske rækkefølge.
public struct Library {
    public let releases: [Int: Release]
    public let copies: [Int64: Copy]
    /// Sektioner i fysisk rækkefølge.
    public let locations: [Location]
    /// Sektion → kopier i fysisk rækkefølge (venstre mod højre).
    public let sections: [Int64: [Int64]]
    /// Alle placerede kopier i global fysisk rækkefølge.
    public let globalOrder: [Int64]
    public let globalIndex: [Int64: Int]
    public let locationOfCopy: [Int64: Int64]
    public let indexInSection: [Int64: Int]
    /// Kopier uden fysisk placering (typisk nye fra Discogs).
    public let unplaced: [Int64]
    /// Plader eller cd'er. Styrer ordene i Find-teksterne ("din plade" / "din cd").
    public let medium: Medium

    public init(releases: [Int: Release], copies: [Int64: Copy], locations: [Location],
                placements: [(copyID: Int64, locationID: Int64, position: Int)], medium: Medium = .vinyl) {
        self.medium = medium
        self.releases = releases
        self.copies = copies
        let locs = locations.sorted { ($0.sortIndex, $0.id) < ($1.sortIndex, $1.id) }
        self.locations = locs

        var bySection: [Int64: [(Int, Int64)]] = [:]
        for p in placements { bySection[p.locationID, default: []].append((p.position, p.copyID)) }
        var sections: [Int64: [Int64]] = [:]
        var locOf: [Int64: Int64] = [:]
        var idxIn: [Int64: Int] = [:]
        var global: [Int64] = []
        for loc in locs {
            let ids = (bySection[loc.id] ?? []).sorted { $0.0 < $1.0 }.map { $0.1 }
            sections[loc.id] = ids
            for (i, c) in ids.enumerated() { locOf[c] = loc.id; idxIn[c] = i }
            global.append(contentsOf: ids)
        }
        self.sections = sections
        self.locationOfCopy = locOf
        self.indexInSection = idxIn
        self.globalOrder = global
        var gi: [Int64: Int] = [:]
        for (i, c) in global.enumerated() { gi[c] = i }
        self.globalIndex = gi
        self.unplaced = copies.keys.filter { locOf[$0] == nil }.sorted()
    }

    public static let empty = Library(releases: [:], copies: [:], locations: [], placements: [])

    public func item(_ copyID: Int64) -> RecordItem? {
        guard let c = copies[copyID], let r = releases[c.releaseID] else { return nil }
        return RecordItem(copy: c, release: r)
    }

    public var allItems: [RecordItem] { copies.keys.compactMap(item) }

    public func location(_ id: Int64?) -> Location? {
        guard let id else { return nil }
        return locations.first { $0.id == id }
    }

    public func location(of copyID: Int64) -> Location? { location(locationOfCopy[copyID]) }

    /// Sektionen bag en scannet QR-kode. Koden på et trykt skilt følger sektionen til alle enheder;
    /// ellers er tallet i koden enhedens eget sektionsnummer.
    public func location(forScanCode code: String) -> Location? {
        if let l = locations.first(where: { $0.scanCode == code }) { return l }
        guard let id = ShelfLabel.locationID(fromScanCode: code), let l = location(id), l.scanCode == nil else { return nil }
        return l
    }

    public func items(in locationID: Int64) -> [RecordItem] {
        (sections[locationID] ?? []).compactMap(item)
    }

    public var shelves: [Int] { Array(Set(locations.map(\.shelf))).sorted() }

    // MARK: - Fysisk nummerering

    // En plade, der er ude af reolen (på væggen, udlånt, opbevaret, mangler), beholder sin
    // plads i `placements`, men tæller ikke med, når reolen nummereres. Numrene beregnes
    // derfor altid her ud fra de plader, der står i reolen – placements flyttes aldrig.

    /// Står kopien i reolen lige nu?
    func isOnShelf(_ copyID: Int64) -> Bool {
        guard let c = copies[copyID], releases[c.releaseID] != nil else { return false }
        return c.status.isOnShelf
    }

    /// Sektionens plader, som de står fysisk (venstre mod højre): dem i reolen,
    /// plus `including`, hvis den er angivet (fx en plade, der skal sættes tilbage).
    func physicalOrder(in locationID: Int64, including copyID: Int64? = nil) -> [Int64] {
        (sections[locationID] ?? []).filter { $0 == copyID || isOnShelf($0) }
    }

    /// copyID → fysisk nummer (1…n) for de plader i sektionen, der står i reolen.
    /// Plader, der er ude, er ikke med.
    public func shelfNumbers(in locationID: Int64) -> [Int64: Int] {
        var numbers: [Int64: Int] = [:]
        for (i, id) in physicalOrder(in: locationID).enumerated() { numbers[id] = i + 1 }
        return numbers
    }

    /// Antal plader, der står i sektionen nu.
    public func onShelfCount(in locationID: Int64) -> Int { physicalOrder(in: locationID).count }

    // MARK: - Naboer

    public struct Neighbors {
        public let target: RecordItem
        public let location: Location?
        /// Fysisk plads i sektionen (1-baseret), talt blandt de plader, der står i reolen.
        /// Er målpladen selv ude, er det den plads, den får, når den sættes tilbage.
        public let position: Int?
        /// Antal plader i sektionen, der står i reolen – plus målpladen selv, hvis den er ude.
        public let sectionCount: Int
        /// Nærmeste først. Kun plader der faktisk står i reolen.
        public let before: [RecordItem]
        public let after: [RecordItem]
        /// Plader mellem target og referencerne, som midlertidigt er væk (udlånt osv.).
        public let absentBetweenBefore: [RecordItem]
        public let absentBetweenAfter: [RecordItem]
        /// true hvis der ikke er flere plader før/efter i sektionen.
        public let reachedSectionStart: Bool
        public let reachedSectionEnd: Bool
        /// Ved sektionsstart: forrige sektion og dens sidste plade.
        public let previousSection: (location: Location, last: RecordItem?)?
        /// Ved sektionsslut: næste sektion og dens første plade.
        public let nextSection: (location: Location, first: RecordItem?)?

        public var isPlaced: Bool { location != nil }
    }

    public func neighbors(of copyID: Int64, count: Int = 1) -> Neighbors? {
        guard let target = item(copyID) else { return nil }
        guard let locID = locationOfCopy[copyID], let loc = location(locID),
              let ids = sections[locID], let idx = indexInSection[copyID] else {
            return Neighbors(target: target, location: nil, position: nil, sectionCount: 0, before: [], after: [],
                             absentBetweenBefore: [], absentBetweenAfter: [], reachedSectionStart: false,
                             reachedSectionEnd: false, previousSection: nil, nextSection: nil)
        }

        func collect(_ range: [Int]) -> (present: [RecordItem], absentBetween: [RecordItem], reachedEnd: Bool) {
            var present: [RecordItem] = [], absent: [RecordItem] = []
            for i in range {
                guard let it = item(ids[i]) else { continue }
                if it.copy.status.isOnShelf {
                    present.append(it)
                    if present.count == count { return (present, absent, false) }
                } else if present.isEmpty {
                    absent.append(it)
                }
            }
            return (present, absent, true)
        }

        let b = collect(Array((0..<idx).reversed()))
        let a = collect(Array((idx + 1)..<ids.count))

        let locIdx = locations.firstIndex { $0.id == locID }!
        var prevSec: (Location, RecordItem?)? = nil
        var nextSec: (Location, RecordItem?)? = nil
        if b.reachedEnd, locIdx > 0 {
            let pl = locations[locIdx - 1]
            prevSec = (pl, (sections[pl.id] ?? []).reversed().lazy.compactMap(item).first { $0.copy.status.isOnShelf })
        }
        if a.reachedEnd, locIdx + 1 < locations.count {
            let nl = locations[locIdx + 1]
            nextSec = (nl, (sections[nl.id] ?? []).lazy.compactMap(item).first { $0.copy.status.isOnShelf })
        }

        // Fysiske tal: plader i reolen ∪ målpladen, i placements-rækkefølge.
        let shelf = physicalOrder(in: locID, including: copyID)
        return Neighbors(target: target, location: loc, position: shelf.firstIndex(of: copyID)! + 1, sectionCount: shelf.count,
                         before: b.present, after: a.present,
                         absentBetweenBefore: b.absentBetween, absentBetweenAfter: a.absentBetween,
                         reachedSectionStart: b.reachedEnd, reachedSectionEnd: a.reachedEnd,
                         previousSection: prevSec, nextSection: nextSec)
    }

    // MARK: - Reference-mode

    public struct Reference {
        public enum Side { case before, after, sectionStart, sectionEnd }
        public let side: Side
        public let item: RecordItem?
        public let reason: String
    }

    public struct ReferenceAdvice {
        public let primary: Reference
        public let secondary: Reference?
        /// Pladens plads i en række af samme kunstner, når den står yderst i rækken,
        /// fx "Der står 3 Genesis-plader i træk, og din plade er den længst til venstre."
        /// `nil` når pladen står midt i rækken – så står tælleinstruktionen i `primary.reason`,
        /// så positionen ikke gentages.
        public let artistBlockHint: String?
        /// Kort: "Plade 14 af 15 fra venstre" (Find) eller "Plads 14 af 15 fra venstre"
        /// (sæt tilbage). Fysiske tal: kun plader i reolen tælles, plus pladen selv.
        public let placementHint: String
        /// Ved sektionens kant: hvad der står på den anden side af kanten, fx
        /// "Næste sektion (1B) begynder med Dire Straits – Brothers In Arms." Ellers `nil`.
        public let sectionEdgeHint: String?
    }

    /// Vælger de bedste fysiske referencepunkter og forklarer hvorfor (bruges til Find).
    /// Alle tekster er skrevet set fra målpladen ("din plade") og bruger venstre/højre,
    /// aldrig "før"/"efter", så det er entydigt, hvilken vej man skal gå.
    public func referenceAdvice(for copyID: Int64) -> ReferenceAdvice? {
        advice(for: copyID, putBack: false)
    }

    /// Som `referenceAdvice`, men til at SÆTTE pladen tilbage i reolen, fx
    /// "Sæt den lige til højre for Aurora – All My Demons Greeting Me as a Friend." Samme valg
    /// af referencer; kun plader, der står i reolen, nævnes. `placementHint` er fx
    /// "Plads 7 af 15 fra venstre", hvor pladen selv er talt med. `nil` uden placering.
    public func returnAdvice(for copyID: Int64) -> ReferenceAdvice? {
        advice(for: copyID, putBack: true)
    }

    private func advice(for copyID: Int64, putBack: Bool) -> ReferenceAdvice? {
        guard let n = neighbors(of: copyID, count: 1), let loc = n.location, let position = n.position else { return nil }
        let target = n.target
        let targetArtist = target.artist
        let before = n.before.first, after = n.after.first
        let word = medium.singular, words = medium.plural
        let capWord = medium.singular.prefix(1).uppercased() + medium.singular.dropFirst()

        // Kunstnerblok: hvor mange plader af samme kunstner står i træk omkring målet?
        // Der tælles kun plader, der fysisk står i reolen (plus målet selv), ellers bliver
        // "tæl N plader" forkert, når en plade i blokken er udlånt, og landmærket kan være væk.
        let shelf = physicalOrder(in: loc.id, including: copyID)
        let sIdx = position - 1
        var blockStart = sIdx, blockEnd = sIdx
        while blockStart > 0, item(shelf[blockStart - 1])?.artist == targetArtist { blockStart -= 1 }
        while blockEnd + 1 < shelf.count, item(shelf[blockEnd + 1])?.artist == targetArtist { blockEnd += 1 }
        let blockSize = blockEnd - blockStart + 1

        func ref(_ side: Reference.Side, _ it: RecordItem?, _ why: String) -> Reference {
            Reference(side: side, item: it, reason: why)
        }
        /// Navnet på en nabo i en sætning. Et andet eksemplar af samme plade nævnes som sådan.
        /// Når pladen skal sættes tilbage, nævnes en anden kunstner med fuldt navn, så den er
        /// let at finde på ryggen i reolen.
        func called(_ it: RecordItem, first: Bool = false) -> String {
            if it.artist == targetArtist && it.title == target.title {
                return "\(first ? "Et" : "et") andet eksemplar af \(it.title)"
            }
            return putBack && it.artist != targetArtist ? it.fullName : it.title
        }
        // leftOf: pladen står til venstre for målet. rightOf: til højre for målet.
        func leftOf(_ it: RecordItem) -> String {
            putBack ? "Sæt den lige til højre for \(Self.sentenceEnd(called(it)))"
                    : "\(called(it, first: true)) står lige til venstre for din \(word)."
        }
        func rightOf(_ it: RecordItem) -> String {
            putBack ? "Sæt den lige til venstre for \(Self.sentenceEnd(called(it)))"
                    : "\(called(it, first: true)) står lige til højre for din \(word)."
        }
        let atLeftEdge = putBack ? "Sæt den yderst til venstre i sektionen." : "Din \(word) står yderst til venstre i sektionen."
        let atRightEdge = putBack ? "Sæt den yderst til højre i sektionen." : "Din \(word) står yderst til højre i sektionen."
        let otherArtist = "Det er en anden kunstner, så den er let at få øje på."

        var primary: Reference
        var secondary: Reference?
        var countsInPrimary = false

        if n.reachedSectionStart && before == nil {
            primary = ref(.sectionStart, nil, atLeftEdge)
            secondary = after.map { ref(.after, $0, rightOf($0)) }
        } else if n.reachedSectionEnd && after == nil {
            primary = ref(.sectionEnd, nil, atRightEdge)
            secondary = before.map { ref(.before, $0, leftOf($0)) }
        } else if let b = before, let a = after {
            let bDiff = b.artist != targetArtist, aDiff = a.artist != targetArtist
            if bDiff && !aDiff {
                primary = ref(.before, b, "\(leftOf(b)) \(otherArtist)")
                secondary = ref(.after, a, rightOf(a))
            } else if aDiff && !bDiff {
                primary = ref(.after, a, "\(rightOf(a)) \(otherArtist)")
                secondary = ref(.before, b, leftOf(b))
            } else if !bDiff && !aDiff && blockSize > 2 {
                // Midt i en stor blok af samme kunstner: tæl fra den nærmeste blokkant
                // (en anden kunstner eller sektionens kant). Det er den eneste tælleinstruktion.
                countsInPrimary = true
                let fromStart = sIdx - blockStart, fromEnd = blockEnd - sIdx
                let among = putBack ? "Din \(word) skal stå blandt \(blockSize) \(targetArtist)-\(words) i træk."
                                    : "Din \(word) står blandt \(blockSize) \(targetArtist)-\(words) i træk."
                func count(_ nr: Int, _ side: String, _ it: RecordItem) -> String {
                    putBack ? "din \(word) skal stå som nr. \(nr), lige til \(side) for \(Self.sentenceEnd(called(it)))"
                            : "din \(word) er nr. \(nr), lige til \(side) for \(Self.sentenceEnd(called(it)))"
                }
                if fromStart <= fromEnd {
                    let start = blockStart > 0
                        ? item(shelf[blockStart - 1]).map { "Find \($0.fullName), som står lige til venstre for dem" }
                        : nil
                    primary = ref(.before, b, "\(among) \(start ?? "Start ved sektionens venstre kant"), og tæl mod højre: \(count(fromStart + 1, "højre", b))")
                    secondary = ref(.after, a, rightOf(a))
                } else {
                    let start = blockEnd + 1 < shelf.count
                        ? item(shelf[blockEnd + 1]).map { "Find \($0.fullName), som står lige til højre for dem" }
                        : nil
                    primary = ref(.after, a, "\(among) \(start ?? "Start ved sektionens højre kant"), og tæl mod venstre: \(count(fromEnd + 1, "venstre", a))")
                    secondary = ref(.before, b, leftOf(b))
                }
            } else {
                primary = ref(.before, b, leftOf(b))
                secondary = ref(.after, a, rightOf(a))
            }
        } else {
            primary = ref(.before, before, before.map(leftOf) ?? atLeftEdge)
            secondary = after.map { ref(.after, $0, rightOf($0)) }
        }

        // Kunstnerblokken nævnes kun, når pladen står yderst i den – står den midt i, er tællingen
        // allerede i `primary`, og står den ved sektionens kant, siger `primary` det.
        var blockHint: String? = nil
        let atSectionEdge = primary.side == .sectionStart || primary.side == .sectionEnd
        if blockSize > 1 && !countsInPrimary && !atSectionEdge {
            let side = sIdx == blockStart ? "venstre" : sIdx == blockEnd ? "højre" : nil
            if let side {
                blockHint = putBack
                    ? "Din \(word) skal stå længst til \(side) blandt \(blockSize) \(targetArtist)-\(words) i træk."
                    : "Der står \(blockSize) \(targetArtist)-\(words) i træk, og din \(word) er den længst til \(side)."
            }
        }

        var edge: [String] = []
        if n.reachedSectionStart, let prev = n.previousSection, let last = prev.last {
            edge.append("Forrige sektion (\(prev.location.shortName)) slutter med \(Self.sentenceEnd(last.fullName))")
        }
        if n.reachedSectionEnd, let next = n.nextSection, let first = next.first {
            edge.append("Næste sektion (\(next.location.shortName)) begynder med \(Self.sentenceEnd(first.fullName))")
        }
        let edgeHint: String? = edge.isEmpty ? nil : edge.joined(separator: " ")

        // Fysiske tal: talt blandt pladerne i reolen, med målpladen selv.
        let placementHint = "\(putBack ? "Plads" : capWord) \(position) af \(n.sectionCount) fra venstre"
        return ReferenceAdvice(primary: primary, secondary: secondary, artistBlockHint: blockHint,
                               placementHint: placementHint, sectionEdgeHint: edgeHint)
    }

    /// Afslutter en sætning, der ender med et navn: "Low" → "Low.", men "Morning Glory?" forbliver uændret.
    static func sentenceEnd(_ name: String) -> String {
        guard let last = name.last, !".!?…".contains(last) else { return name }
        return name + "."
    }

    // MARK: - Forslag til placering af nye plader

    public struct PlacementSuggestion: Equatable {
        public let locationID: Int64
        /// 0-baseret indeks i sektionen, hvor pladen skal indsættes.
        public let index: Int
        public let before: Int64?
        public let after: Int64?
    }

    /// Finder hvor en (uplaceret eller flyttet) plade burde stå ud fra sorteringsreglerne,
    /// relativt til den *faktiske* fysiske rækkefølge: pladen sættes lige efter den placerede
    /// plade med den største sorteringsnøgle ≤ pladens egen.
    public func suggestPlacement(for copyID: Int64, rules: SortRules, restrictTo locationID: Int64? = nil) -> PlacementSuggestion? {
        guard let target = item(copyID), !locations.isEmpty else { return nil }
        let tk = rules.key(for: target)
        let candidates: [Int64] = {
            if let l = locationID { return (sections[l] ?? []).filter { $0 != copyID } }
            return globalOrder.filter { $0 != copyID }
        }()

        var bestPred: (id: Int64, key: SortRules.Key)? = nil
        for id in candidates {
            guard let it = item(id) else { continue }
            let k = rules.key(for: it)
            if !rules.areInIncreasingOrder(tk, k) {  // k <= tk
                if bestPred == nil || rules.areInIncreasingOrder(bestPred!.key, k) { bestPred = (id, k) }
            }
        }

        if let pred = bestPred {
            let loc = locationOfCopy[pred.id]!
            let ids = (sections[loc] ?? []).filter { $0 != copyID }
            let pi = ids.firstIndex(of: pred.id)!
            let next: Int64? = pi + 1 < ids.count ? ids[pi + 1] : nil
            return PlacementSuggestion(locationID: loc, index: pi + 1, before: pred.id, after: next)
        }
        // Ingen forgænger: først i den første (evt. valgte) sektion.
        let loc = locationID ?? locations.first!.id
        let ids = (sections[loc] ?? []).filter { $0 != copyID }
        return PlacementSuggestion(locationID: loc, index: 0, before: nil, after: ids.first)
    }

    // MARK: - Sortering vs. virkelighed

    /// Kopier i en sektion, der ikke står i forventet rækkefølge (uden for den længste
    /// korrekt sorterede delsekvens). Bruges til at markere mulige fejlplaceringer.
    public func outOfOrder(in locationID: Int64, rules: SortRules) -> Set<Int64> {
        let ids = sections[locationID] ?? []
        let keys = ids.compactMap { id in item(id).map { rules.key(for: $0) } }
        guard keys.count == ids.count, ids.count > 1 else { return [] }
        // Longest non-decreasing subsequence, O(n log n).
        var tailsIdx: [Int] = []
        var prev = Array(repeating: -1, count: ids.count)
        for i in 0..<ids.count {
            var lo = 0, hi = tailsIdx.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if !rules.areInIncreasingOrder(keys[i], keys[tailsIdx[mid]]) { lo = mid + 1 } else { hi = mid }
            }
            if lo > 0 { prev[i] = tailsIdx[lo - 1] }
            if lo == tailsIdx.count { tailsIdx.append(i) } else { tailsIdx[lo] = i }
        }
        var keep = Set<Int>()
        var k = tailsIdx.last ?? -1
        while k >= 0 { keep.insert(k); k = prev[k] }
        return Set(ids.indices.filter { !keep.contains($0) }.map { ids[$0] })
    }
}
