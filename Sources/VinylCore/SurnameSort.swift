import Foundation

/// Én kunstner i "Efternavn først": navnet, som det står i Discogs, det vendte sorteringsnavn
/// ("Bob Dylan" → "Dylan, Bob"), og appens gæt på, om det er en person.
public struct SurnameCandidate: Equatable, Identifiable {
    public let artist: String
    public let surname: String
    public let likelyPerson: Bool
    public var id: String { artist }
}

/// Sortering efter efternavn (port af SurnameSort.cs). Discogs siger ikke, om en kunstner er en
/// person eller et band, så appen gætter ud fra navnet, og brugeren krydser af. Valgene gemmes som
/// almindelige sorteringsnavne (`SortRules.artistOverrides`), så resten af sorteringen virker uændret.
public enum SurnameSort {
    // Ord, der næsten altid betyder et band eller et ensemble, ikke en person.
    private static let groupWords: Set<String> = [
        "band", "bands", "orchestra", "orkester", "orkestret", "quartet", "quintet", "trio", "kvartet", "ensemble",
        "brothers", "sisters", "brødre", "group", "gruppe", "experience", "project", "collective", "boys", "girls",
        "choir", "kor", "club", "society", "gang", "crew", "sound", "sounds", "system", "machine", "attack", "army",
        "family", "allstars", "all-stars", "singers", "players", "kids", "orchestre", "orquesta", "symphony",
        "philharmonic", "filharmoniske", "unit", "posse", "connection", "revival", "company", "jazzmen", "combo",
        "duo", "dolls", "stones", "heads", "beat", "beats", "riders", "rangers", "brigade", "foundation", "syndicate",
        "crue", "crüe", "floyd", "zeppelin", "maiden", "priest", "purple", "sabbath", "tull", "theory",
        "of", "airplane", "stompers", "senior",
    ]

    // Første ord, der næsten altid betyder et band ("Black Sabbath", "Blue Cheer", "Deep Purple", "Atomic Swing").
    private static let groupFirstWords: Set<String> = [
        "black", "blue", "big", "red", "white", "green", "deep", "atomic", "blind", "golden", "iron", "electric",
        "silver", "dead", "dire", "new", "pink", "rolling", "soft", "sonic", "talking", "velvet", "grateful",
        "steely", "thin", "def", "daft", "massive", "simple", "primal", "king", "blast", "heavy", "hot", "cold",
        "dark", "wild", "lucky", "dream", "magic", "mad", "crazy", "young", "savage", "spirit", "flying", "cream",
    ]

    private static let suffixes: Set<String> = ["jr", "jr.", "sr", "sr.", "ii", "iii", "iv"]

    /// Det vendte navn, eller nil hvis navnet ikke kan være en person (ét ord, "The …", "&", tal …).
    public static func reverse(_ artist: String) -> String? {
        let name = artist.trimmingCharacters(in: .whitespaces)
        if name.isEmpty || SortRules.isVarious(name) { return nil }
        if name.lowercased().hasPrefix("the ") || name.hasPrefix("A ") { return nil }
        if name.contains(" - ") { return nil } // "Beethoven - Schubert"
        if name.contains(where: { "&+,/()".contains($0) || $0.isNumber }) { return nil }
        var words = name.split(separator: " ").map(String.init)
        if words.contains(where: { ["and", "og", "feat.", "with"].contains($0.lowercased()) }) { return nil }

        var suffix = ""
        if words.count >= 3, suffixes.contains(words.last!.lowercased()) { suffix = " " + words.removeLast() }
        guard (2...3).contains(words.count) else { return nil }

        let last = words.removeLast()
        // "Ludwig van Beethoven": partiklen bliver hos fornavnene, som i biblioteker.
        return "\(last), \(words.joined(separator: " "))\(suffix)"
    }

    /// Gættet: ser navnet ud som en person? (Ingen ord, der typisk betyder et band.)
    public static func looksLikePerson(_ artist: String) -> Bool {
        guard reverse(artist) != nil else { return false }
        let words = artist.split(separator: " ").map { $0.lowercased() }
        return !groupFirstWords.contains(words[0])
            && !words.contains { groupWords.contains($0.trimmingCharacters(in: CharacterSet(charactersIn: ".!?"))) }
    }

    /// Alle kunstnere i samlingen, der kan vendes, sorteret efter navn. Hver kunstner én gang.
    /// Navnet beholdes præcis som i Discogs, for sorteringsnavnene slås op på det.
    public static func candidates(_ artists: [String]) -> [SurnameCandidate] {
        var seen = Set<String>()
        return artists.filter { seen.insert($0).inserted }
            .compactMap { a in reverse(a).map { SurnameCandidate(artist: a, surname: $0, likelyPerson: looksLikePerson(a)) } }
            .sorted { $0.artist.localizedStandardCompare($1.artist) == .orderedAscending }
    }

    /// Gemmer brugerens valg i reglerne: afkrydsede får efternavn først (et eget sorteringsnavn,
    /// som brugeren har skrevet, beholdes), de andre mister et vendt navn. Efternavn kræver appens
    /// egne regler, så Discogs' rækkefølge slås fra, når mindst én person er valgt.
    public static func apply(_ rules: SortRules, candidates: [SurnameCandidate], persons: Set<String>) -> SortRules {
        var r = rules
        for c in candidates {
            if persons.contains(c.artist) {
                let own = r.artistOverrides[c.artist]?.trimmingCharacters(in: .whitespaces) ?? ""
                if own.isEmpty { r.artistOverrides[c.artist] = c.surname }
            } else if r.artistOverrides[c.artist] == c.surname {
                r.artistOverrides[c.artist] = nil
            }
        }
        if !persons.isEmpty { r.useDiscogsOrder = false }
        return r
    }

    /// Er kunstneren allerede sat til efternavn først (et eget sorteringsnavn tæller også)?
    public static func isChosen(_ rules: SortRules, _ c: SurnameCandidate) -> Bool {
        rules.artistOverrides[c.artist] != nil
    }
}

extension ShelfStore {
    private static let notPersonsKey = "surname_not_persons"

    /// Kunstnere, brugeren har sagt ikke er personer (så de ikke foreslås som nye igen).
    public func surnameNotPersons() -> Set<String> {
        guard let data = setting(Self.notPersonsKey)?.data(using: .utf8),
              let list = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return Set(list)
    }

    public func saveSurnameNotPersons(_ artists: [String]) {
        let list = Array(Set(artists)).sorted()
        let json = (try? JSONEncoder().encode(list)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        setSetting(Self.notPersonsKey, json)
    }
}
