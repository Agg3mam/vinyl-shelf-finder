import SwiftUI
import VinylCore

/// Sorteringslisten: hele rækkefølgen for den valgte hylde (plader eller cd'er), sektion for sektion,
/// med flueben, så man kan stille reolen op i flere omgange. Discogs blander formaterne; her gør vi ikke.
struct SortListView: View {
    @Environment(AppModel.self) private var model
    @ViewState private var confirmRestart = false

    private struct Part: Identifiable {
        let id: String
        let title: String
        let note: String?
        let entries: [SortListEntry]
    }

    var body: some View {
        let entries = SortList.build(model.library, rules: model.rules)
        let m = model.medium
        Group {
            if entries.isEmpty {
                ContentUnavailableView("Ingen \(m.plural)", systemImage: "books.vertical",
                                       description: Text("Der er ingen \(m.plural) i samlingen endnu."))
            } else {
                list(entries)
            }
        }
        .navigationTitle("Sorteringsliste · \(model.shelfKind.title)")
        .confirmationDialog("Fjern fluebenene ved alle \(m.plural) på denne hylde?", isPresented: $confirmRestart) {
            Button("Fjern alle flueben", role: .destructive) { model.clearSortChecked() }
        }
    }

    private func list(_ entries: [SortListEntry]) -> some View {
        @Bindable var model = model
        return ScrollViewReader { proxy in
            List(selection: $model.selection) {
                header(entries, proxy: proxy)
                ForEach(groups(entries)) { g in
                    Section {
                        ForEach(g.entries) { e in
                            SortListRow(entry: e).tag(e.id).id(e.id)
                        }
                    } header: {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(g.title).font(.headline).foregroundStyle(.primary)
                            if let note = g.note { Text(note).font(.caption).foregroundStyle(.secondary) }
                        }
                        .padding(.top, Spacing.xxs)
                    }
                }
            }
            .listStyle(.inset)
        }
    }

    private func header(_ entries: [SortListEntry], proxy: ScrollViewProxy) -> some View {
        let m = model.medium
        let countable = entries.filter { $0.number != nil }
        let total = countable.count
        let done = countable.filter { model.sortChecked.contains($0.id) }.count
        return VStack(alignment: .leading, spacing: Spacing.s) {
            Text(model.shelfKind.category != nil
                 ? "Rækkefølgen for \(model.shelfKind.title.lowercased()), fra første til sidste \(m.singular). De andre hylder har deres egne lister."
                 : m == .vinyl
                 ? "Rækkefølgen for pladehylden, fra første til sidste plade. Cd'erne har deres egen liste."
                 : "Rækkefølgen for cd-hylden, fra første til sidste cd. Pladerne har deres egen liste.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if model.library.locations.isEmpty {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text("Der er ingen \(model.shelfKind.shelfWord.lowercased())er endnu, så listen viser bare hele rækkefølgen. Når reolerne er lavet, deles listen op i sektioner.")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Lav \(model.shelfKind.shelfWord.lowercased())er") { model.sidebar = .search }
                }
                .padding(Spacing.s)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
            }

            ProgressView(value: Double(done), total: Double(max(total, 1)))
            Text(done == total && total > 0 ? "Alle \(total) \(m.plural) står på plads" : "\(done) af \(total) sat på plads")
                .font(.callout).monospacedDigit().foregroundStyle(.secondary)
            HStack {
                Button {
                    if let next = SortList.nextUnchecked(entries, done: model.sortChecked) {
                        model.selection = next.id
                        withAnimation { proxy.scrollTo(next.id, anchor: .top) }
                    }
                } label: {
                    Label("Næste", systemImage: "chevron.right")
                }
                .buttonStyle(.borderedProminent)
                .help("Hop til den første \(m.singular) uden flueben")
                .disabled(done == total)

                Button { confirmRestart = true } label: {
                    Label("Start forfra", systemImage: "arrow.uturn.backward")
                }
                .help("Fjern alle flueben")
                .disabled(done == 0)
            }
        }
        .padding(.vertical, Spacing.xs)
        .selectionDisabled()
    }

    private func groups(_ entries: [SortListEntry]) -> [Part] {
        let m = model.medium
        var result: [Part] = []
        var current: [SortListEntry] = []
        var currentLoc: Location??
        func flush() {
            guard let loc = currentLoc, !current.isEmpty else { return }
            if let loc {
                let n = model.library.sections[loc.id]?.count ?? current.count
                result.append(Part(id: "loc-\(loc.id)", title: loc.name, note: n == 1 ? "1 \(m.singular)" : "\(n) \(m.plural)", entries: current))
            } else if model.library.locations.isEmpty {
                result.append(Part(id: "all", title: "Hele hylden", note: nil, entries: current))
            } else {
                result.append(Part(id: "unplaced", title: "Uden plads endnu",
                                    note: "Nye \(m.plural), der ikke har fået en plads. Rækkefølgen viser, hvor de hører til.",
                                    entries: current))
            }
        }
        for e in entries {
            if currentLoc == nil || currentLoc! != e.location {
                flush()
                current = []
                currentLoc = .some(e.location)
            }
            current.append(e)
        }
        flush()
        return result
    }
}

/// Én linje: flueben, nummer, kunstner – titel og år · format. Plader ude af reolen står nedtonet
/// på deres plads uden flueben, fordi de ikke skal stilles op nu.
struct SortListRow: View {
    @Environment(AppModel.self) private var model
    let entry: SortListEntry

    var body: some View {
        let it = entry.item
        let checked = model.sortChecked.contains(entry.id)
        HStack(spacing: Spacing.s) {
            if entry.number != nil {
                Toggle("", isOn: Binding(get: { checked }, set: { model.setSortChecked(entry.id, $0) }))
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                    .accessibilityLabel("\(entry.number ?? 0). \(it.fullName)")
            } else {
                Color.clear.frame(width: 14, height: 14)
            }
            Text(entry.number.map(String.init) ?? "–")
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(minWidth: 30, alignment: .trailing)
            VStack(alignment: .leading, spacing: 1) {
                Text(it.fullName).lineLimit(1)
                if !meta(it).isEmpty {
                    Text(meta(it)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        .opacity(entry.number == nil ? 0.5 : (checked ? 0.55 : 1))
        .contentShape(Rectangle())
    }

    private func meta(_ it: RecordItem) -> String {
        var parts: [String] = []
        if it.copy.status != .home { parts.append(it.copy.status.label) }
        if let y = it.release.year { parts.append(String(y)) }
        if let f = it.release.format, let first = f.split(separator: ",").first {
            parts.append(first.trimmingCharacters(in: .whitespaces))
        }
        return parts.joined(separator: " · ")
    }
}
