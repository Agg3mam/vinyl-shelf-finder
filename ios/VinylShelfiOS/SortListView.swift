import SwiftUI
import VinylCore

/// Sorteringslisten (som på Mac og Windows): hele rækkefølgen for én hylde, sektion for sektion, med flueben,
/// så man kan have telefonen med ved reolen og stille op i flere omgange. Et tryk på en linje sætter eller
/// fjerner fluebenet. Fluebenene følger med via kontoen (de samme som på computeren).
struct SortListView: View {
    @Environment(PhoneModel.self) private var model
    @State private var confirmRestart = false
    @State private var checkTick = 0

    private struct Part: Identifiable {
        let id: String
        let title: String
        let note: String?
        let entries: [SortListEntry]
    }

    var body: some View {
        @Bindable var model = model
        let m = model.medium
        let lib = model.library
        let entries = SortList.build(lib, rules: model.rules)
        let done = model.sortChecked[m] ?? []
        Group {
            if entries.isEmpty {
                ContentUnavailableView("Ingen \(m.plural)", systemImage: "books.vertical",
                                       description: Text("Der er ingen \(m.plural) i samlingen endnu."))
            } else {
                ScrollViewReader { proxy in
                    List {
                        if model.media.count > 1 {
                            Picker("Hylde", selection: $model.medium) {
                                ForEach(model.media) { Text($0.title).tag($0) }
                            }
                            .pickerStyle(.segmented)
                            .listRowBackground(Color.clear)
                        }
                        header(entries, done: done, proxy: proxy)
                        ForEach(groups(entries, lib)) { g in
                            Section {
                                ForEach(g.entries) { e in
                                    row(e, checked: done.contains(e.id)).id(e.id)
                                }
                            } header: {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(g.title).font(.headline).foregroundStyle(.primary)
                                    if let note = g.note { Text(note).font(.caption).foregroundStyle(.secondary) }
                                }
                                .textCase(nil)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Sorteringsliste")
        .navigationBarTitleDisplayMode(.inline)
        .sensoryFeedback(.selection, trigger: checkTick)
        .confirmationDialog("Fjern fluebenene ved alle \(m.plural) på denne hylde?", isPresented: $confirmRestart, titleVisibility: .visible) {
            Button("Fjern alle flueben", role: .destructive) { model.clearSortChecked(m) }
        }
    }

    private func header(_ entries: [SortListEntry], done: Set<Int64>, proxy: ScrollViewProxy) -> some View {
        let m = model.medium
        let countable = entries.filter { $0.number != nil }
        let total = countable.count
        let n = countable.filter { done.contains($0.id) }.count
        return Section {
            VStack(alignment: .leading, spacing: 10) {
                Text(m == .vinyl
                     ? "Rækkefølgen for pladehylden, fra første til sidste plade. Cd'erne har deres egen liste."
                     : "Rækkefølgen for cd-hylden, fra første til sidste cd. Pladerne har deres egen liste.")
                    .font(.callout).foregroundStyle(.secondary)
                ProgressView(value: Double(n), total: Double(max(total, 1)))
                Text(n == total && total > 0 ? "Alle \(total) \(m.plural) står på plads" : "\(n) af \(total) sat på plads")
                    .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                HStack {
                    Button {
                        if let next = SortList.nextUnchecked(entries, done: done) {
                            withAnimation { proxy.scrollTo(next.id, anchor: .center) }
                        }
                    } label: { Label("Næste", systemImage: "chevron.down") }
                    .buttonStyle(.borderedProminent)
                    .disabled(n == total)
                    Button { confirmRestart = true } label: { Label("Start forfra", systemImage: "arrow.uturn.backward") }
                        .buttonStyle(.bordered)
                        .disabled(n == 0)
                }
            }
            .padding(.vertical, 4)
        }
    }

    /// Én linje: flueben, nummer, kunstner – titel og år · format. Plader ude af reolen står nedtonet uden flueben.
    private func row(_ e: SortListEntry, checked: Bool) -> some View {
        let it = e.item
        return Button {
            guard e.number != nil else { return }
            model.setSortChecked(model.medium, e.id, !checked)
            checkTick += 1
        } label: {
            HStack(spacing: 12) {
                Image(systemName: e.number == nil ? "circle.dashed" : checked ? "checkmark.circle.fill" : "circle")
                    .font(.title2)
                    .foregroundStyle(checked ? AnyShapeStyle(AppAccent.color) : AnyShapeStyle(.tertiary))
                    .contentTransition(.symbolEffect(.replace))
                Text(e.number.map(String.init) ?? "–")
                    .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                    .frame(minWidth: 30, alignment: .trailing)
                VStack(alignment: .leading, spacing: 2) {
                    Text(it.fullName).lineLimit(2)
                    if !meta(it).isEmpty { Text(meta(it)).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                }
                Spacer(minLength: 0)
            }
            .opacity(e.number == nil ? 0.5 : (checked ? 0.55 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(e.number.map { "\($0). " } ?? "")\(it.fullName)")
        .accessibilityValue(e.number == nil ? "Ude af reolen" : checked ? "Sat på plads" : "Ikke sat på plads")
    }

    private func meta(_ it: RecordItem) -> String {
        var parts: [String] = []
        if it.copy.status != .home { parts.append(it.copy.status.label) }
        if let y = it.release.year { parts.append(String(y)) }
        if let f = it.release.format, let first = f.split(separator: ",").first { parts.append(first.trimmingCharacters(in: .whitespaces)) }
        return parts.joined(separator: " · ")
    }

    /// Samme opdeling som på Mac: én del pr. sektion, og til sidst dem uden plads endnu.
    private func groups(_ entries: [SortListEntry], _ lib: Library) -> [Part] {
        let m = model.medium
        var result: [Part] = []
        var current: [SortListEntry] = []
        var currentLoc: Location??
        func flush() {
            guard let loc = currentLoc, !current.isEmpty else { return }
            if let loc {
                let n = lib.sections[loc.id]?.count ?? current.count
                result.append(Part(id: "loc-\(loc.id)", title: loc.name, note: n == 1 ? "1 \(m.singular)" : "\(n) \(m.plural)", entries: current))
            } else if lib.locations.isEmpty {
                result.append(Part(id: "all", title: "Hele hylden", note: nil, entries: current))
            } else {
                result.append(Part(id: "unplaced", title: "Uden plads endnu",
                                   note: "Nye \(m.plural), der ikke har fået en plads. Rækkefølgen viser, hvor de hører til.", entries: current))
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
