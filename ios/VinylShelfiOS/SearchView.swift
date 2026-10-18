import SwiftUI
import VinylCore

/// Søgning i hele samlingen (tåler stavefejl). Uden søgning: de senest spillede plader.
struct SearchView: View {
    @Environment(PhoneModel.self) private var model
    let query: String

    var body: some View {
        let q = query.trimmingCharacters(in: .whitespaces)
        List {
            if q.isEmpty {
                let recent = recentlyPlayed
                if recent.isEmpty {
                    ContentUnavailableView("Søg i din samling", systemImage: "magnifyingglass",
                                           description: Text("Skriv kunstner, titel, pladeselskab eller katalognummer."))
                        .listRowBackground(Color.clear)
                } else {
                    Section("Senest spillet") { rows(recent) }
                }
            } else {
                let hits = model.search(q)
                if hits.isEmpty {
                    ContentUnavailableView.search(text: q).listRowBackground(Color.clear)
                } else {
                    rows(hits)
                }
            }
        }
        .navigationTitle("Søg")
    }

    private func rows(_ items: [(medium: Medium, item: RecordItem)]) -> some View {
        ForEach(items, id: \.item.id) { hit in
            NavigationLink(value: RecordRoute(medium: hit.medium, copyID: hit.item.id)) {
                RecordRow(item: hit.item, location: model.library(hit.medium).location(of: hit.item.id))
            }
        }
    }

    /// Op til 10 forskellige plader, nyeste først.
    private var recentlyPlayed: [(medium: Medium, item: RecordItem)] {
        var seen = Set<Int64>(), out: [(medium: Medium, item: RecordItem)] = []
        for p in model.stats.plays where !seen.contains(p.copyID) {
            seen.insert(p.copyID)
            for m in Medium.allCases {
                if let it = model.library(m).item(p.copyID) { out.append((m, it)); break }
            }
            if out.count == 10 { break }
        }
        return out
    }
}
