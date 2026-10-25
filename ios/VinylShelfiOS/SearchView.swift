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
                                           description: Text("Skriv kunstner, titel, en sang, pladeselskab eller katalognummer."))
                        .listRowBackground(Color.clear)
                } else {
                    Section("Senest spillet") { rows(recent) }
                }
            } else {
                let hits = model.search(q)
                if hits.isEmpty {
                    ContentUnavailableView.search(text: q).listRowBackground(Color.clear)
                } else {
                    ForEach(hits, id: \.item.id) { hit in
                        NavigationLink(value: RecordRoute(medium: hit.medium, copyID: hit.item.id, track: hit.track)) {
                            VStack(alignment: .leading, spacing: 4) {
                                RecordRow(item: hit.item, location: model.library(hit.medium).location(of: hit.item.id))
                                if let t = hit.track {
                                    HStack(spacing: 4) {
                                        Image(systemName: "music.note")
                                        Text(t.position.isEmpty ? t.title : "\(t.title) · \(t.position)")
                                    }
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                        .padding(.leading, 60)
                                        .accessibilityLabel("Sangen \(t.title)")
                                }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Søg")
    }

    private func rows(_ items: [(medium: ShelfKind, item: RecordItem)]) -> some View {
        ForEach(items, id: \.item.id) { hit in
            NavigationLink(value: RecordRoute(medium: hit.medium, copyID: hit.item.id)) {
                RecordRow(item: hit.item, location: model.library(hit.medium).location(of: hit.item.id))
            }
        }
    }

    /// Op til 10 forskellige plader, nyeste først.
    private var recentlyPlayed: [(medium: ShelfKind, item: RecordItem)] {
        var seen = Set<Int64>(), out: [(medium: ShelfKind, item: RecordItem)] = []
        for p in model.stats.plays where !seen.contains(p.copyID) {
            seen.insert(p.copyID)
            for m in ShelfKind.all {
                if let it = model.library(m).item(p.copyID) { out.append((m, it)); break }
            }
            if out.count == 10 { break }
        }
        return out
    }
}
