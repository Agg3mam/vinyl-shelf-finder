import SwiftUI
import VinylCore

/// "Efternavn først" (som SurnameDialog.cs på Windows): appen foreslår, hvilke kunstnere der er
/// personer ("Bob Dylan" → "Dylan, Bob"), og brugeren retter gættet. Valgene bliver almindelige
/// sorteringsnavne (Indstillinger › Sortering).
struct SurnameSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @ViewState private var candidates: [SurnameCandidate] = []
    @ViewState private var checked: Set<String> = []
    @ViewState private var fresh: Set<String> = []
    @ViewState private var filter = ""

    /// Antal nye forslag (kunstnere, der hverken er valgt eller fravalgt endnu) – til knappernes tekst.
    static func newCount(_ model: AppModel) -> Int {
        let no = model.store.surnameNotPersons()
        return candidates(model).filter { !SurnameSort.isChosen(model.rules, $0) && !no.contains($0.artist) }.count
    }

    private static func candidates(_ model: AppModel) -> [SurnameCandidate] {
        SurnameSort.candidates(model.library.releases.values.map(\.artist))
    }

    private var visible: [SurnameCandidate] {
        let q = filter.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? candidates : candidates.filter { $0.artist.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Text("Efternavn først").font(.title2.weight(.semibold))
            if candidates.isEmpty {
                Text("Der er ingen kunstnere i samlingen, hvis navn kan vendes.").foregroundStyle(.secondary)
                HStack { Spacer(); Button("OK") { dismiss() }.keyboardShortcut(.defaultAction) }
            } else {
                Text("Kryds af de kunstnere, der er personer. De sorteres efter efternavn: Bob Dylan står under D. Bands som Pink Floyd lader du være. Appen har gættet ud fra navnet – ret de forkerte.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if model.rules.useDiscogsOrder {
                    Label("Discogs sorterer efter fornavn, så appen bruger sine egne regler, når du gemmer (“The” ignoreres, Æ Ø Å efter Z).",
                          systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    TextField("Find kunstner", text: $filter).frame(width: 220)
                    Button("Brug gættet") { for c in visible { set(c.artist, c.likelyPerson) } }
                        .help("Kryds af ud fra navnet: personer til, bands fra")
                    Button("Ingen") { for c in visible { set(c.artist, false) } }
                }
                Text(countText).font(.caption).foregroundStyle(.secondary)
                List(visible) { c in
                    Toggle(isOn: Binding(get: { checked.contains(c.artist) }, set: { set(c.artist, $0) })) {
                        HStack {
                            Text(c.artist).lineLimit(1)
                            Spacer()
                            Text("→ \(shown(c))\(fresh.contains(c.artist) ? " · ny" : "")")
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .toggleStyle(.checkbox)
                    .accessibilityLabel("\(c.artist) sorteres som \(shown(c))")
                }
                .listStyle(.inset)
                .frame(minHeight: 300)
                HStack {
                    Spacer()
                    Button("Annullér") { dismiss() }.keyboardShortcut(.cancelAction)
                    Button("Gem", action: save).keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(Spacing.l)
        .frame(width: 540, height: candidates.isEmpty ? nil : 600)
        .onAppear(perform: load)
    }

    private var countText: String {
        "\(checked.count) af \(candidates.count) sorteres efter efternavn"
            + (fresh.isEmpty ? "" : " · \(fresh.count) nye forslag, hvor fluebenet er appens gæt")
    }

    private func shown(_ c: SurnameCandidate) -> String {
        SurnameSort.isChosen(model.rules, c) ? (model.rules.artistOverrides[c.artist] ?? c.surname) : c.surname
    }

    private func set(_ artist: String, _ on: Bool) {
        if on { checked.insert(artist) } else { checked.remove(artist) }
    }

    private func load() {
        let notPersons = model.store.surnameNotPersons()
        candidates = Self.candidates(model)
        checked = []
        fresh = []
        for c in candidates {
            let chosen = SurnameSort.isChosen(model.rules, c)
            let isNew = !chosen && !notPersons.contains(c.artist)
            if isNew { fresh.insert(c.artist) }
            if chosen || (isNew && c.likelyPerson) { checked.insert(c.artist) }
        }
    }

    private func save() {
        model.updateRules(SurnameSort.apply(model.rules, candidates: candidates, persons: checked))
        model.store.saveSurnameNotPersons(candidates.map(\.artist).filter { !checked.contains($0) })
        dismiss()
    }
}
