import Foundation

/// Hjælpere til den første opdeling af samlingen i reoler og sektioner.
public enum LayoutPlanner {
    public struct SectionPlan: Identifiable, Equatable {
        public var id = UUID()
        public var shelf: Int
        public var section: String
        public var count: Int

        public init(shelf: Int, section: String, count: Int) {
            self.shelf = shelf; self.section = section; self.count = count
        }
    }

    public static func sectionLetter(_ i: Int) -> String {
        let letters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
        return i < letters.count ? String(letters[i]) : "S\(i + 1)"
    }

    /// Fordeler `total` plader jævnt over sektionerne (reol for reol).
    public static func evenPlan(total: Int, sectionsPerShelf: [Int]) -> [SectionPlan] {
        var plans: [SectionPlan] = []
        for (s, n) in sectionsPerShelf.enumerated() {
            for i in 0..<max(1, n) { plans.append(SectionPlan(shelf: s + 1, section: sectionLetter(i), count: 0)) }
        }
        guard !plans.isEmpty else { return [] }
        let base = total / plans.count, extra = total % plans.count
        for i in plans.indices { plans[i].count = base + (i < extra ? 1 : 0) }
        return plans
    }

    /// Ændrer antallet i sektion `index` ved at flytte grænsen til næste sektion
    /// (eller forrige, hvis det er den sidste). Summen bevares.
    public static func adjust(_ plans: inout [SectionPlan], index: Int, to newCount: Int) {
        guard plans.indices.contains(index), plans.count > 1 else { return }
        let neighbor = index + 1 < plans.count ? index + 1 : index - 1
        let pool = plans[index].count + plans[neighbor].count
        let c = max(0, min(newCount, pool))
        plans[index].count = c
        plans[neighbor].count = pool - c
    }

    /// Opdeler en sorteret liste efter planen.
    public static func split<T>(_ items: [T], plan: [SectionPlan]) -> [[T]] {
        var out: [[T]] = []
        var i = 0
        for (n, p) in plan.enumerated() {
            let end = n == plan.count - 1 ? items.count : min(items.count, i + p.count)
            out.append(Array(items[i..<end]))
            i = end
        }
        return out
    }
}
