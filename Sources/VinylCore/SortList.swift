import Foundation

/// Én linje i sorteringslisten. `number` er pladsen i hele hylden (1, 2, 3 …); kopier, der er ude
/// af reolen, har ingen plads og intet nummer. `location` er nil for kopier uden plads endnu.
public struct SortListEntry: Identifiable, Equatable {
    public let number: Int?
    public let item: RecordItem
    public let location: Location?
    public var id: Int64 { item.id }
}

/// Sorteringslisten: hele rækkefølgen for én hylde (plader eller cd'er), så man kan stille den op
/// derhjemme. Discogs blander plader og cd'er; her står hver hylde for sig.
public enum SortList {
    /// Med reoler: den fysiske rækkefølge, sektion for sektion, og til sidst kopierne uden plads (sorteret).
    /// Uden reoler: hele hylden sorteret efter reglerne (eller Discogs' rækkefølge).
    public static func build(_ lib: Library, rules: SortRules) -> [SortListEntry] {
        var entries: [SortListEntry] = []
        var n = 0
        func add(_ it: RecordItem, _ loc: Location?) {
            var number: Int?
            if it.copy.status.isOnShelf { n += 1; number = n }
            entries.append(SortListEntry(number: number, item: it, location: loc))
        }
        for loc in lib.locations {
            for id in lib.sections[loc.id] ?? [] {
                if let it = lib.item(id) { add(it, loc) }
            }
        }
        for it in rules.sorted(lib.unplaced.compactMap(lib.item)) { add(it, nil) }
        return entries
    }

    /// Kun linjer, der kan sættes flueben ved (dem, der står på hylden).
    public static func countable(_ entries: [SortListEntry]) -> Int {
        entries.filter { $0.number != nil }.count
    }

    /// Den første linje uden flueben (til "Næste").
    public static func nextUnchecked(_ entries: [SortListEntry], done: Set<Int64>) -> SortListEntry? {
        entries.first { $0.number != nil && !done.contains($0.item.id) }
    }
}

extension ShelfStore {
    /// "sort_checked_vinyl", "sort_checked_cd", "sort_checked_vinyl.jazz" …
    static func sortCheckedKey(_ k: ShelfKind) -> String { "sort_checked_\(k.rawValue)" }

    /// Kopierne, der er sat flueben ved i sorteringslisten for én hylde.
    public func sortChecked(_ kind: ShelfKind) -> Set<Int64> {
        let raw = setting(Self.sortCheckedKey(kind)) ?? ""
        return Set(raw.split(separator: ",").compactMap { Int64($0.trimmingCharacters(in: .whitespaces)) })
    }

    public func setSortChecked(_ kind: ShelfKind, copyID: Int64, checked: Bool) {
        var set = sortChecked(kind)
        let changed = checked ? set.insert(copyID).inserted : set.remove(copyID) != nil
        if changed { saveSortChecked(kind, set) }
    }

    public func clearSortChecked(_ kind: ShelfKind) { saveSortChecked(kind, []) }

    private func saveSortChecked(_ kind: ShelfKind, _ set: Set<Int64>) {
        setSetting(Self.sortCheckedKey(kind), set.sorted().map(String.init).joined(separator: ","))
    }
}
