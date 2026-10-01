import SwiftUI
import VinylCore

struct SettingsView: View {
    var body: some View {
        TabView {
            AccountSettings().tabItem { Label("Discogs", systemImage: "person.crop.circle") }
            SortSettings().tabItem { Label("Sortering", systemImage: "textformat.abc") }
            ShelfSettings().tabItem { Label("Reol", systemImage: "books.vertical") }
            BackupSettings().tabItem { Label("Sikkerhedskopi", systemImage: "clock.arrow.circlepath") }
        }
        .padding(Spacing.l)
    }
}

struct AccountSettings: View {
    @Environment(AppModel.self) private var model
    @ViewState private var token = ""
    @ViewState private var busy = false

    var body: some View {
        Form {
            LabeledContent("Konto", value: model.hasToken ? (model.username ?? "Ikke forbundet") : "Ikke forbundet")
            LabeledContent("Token", value: model.hasToken ? "Gemt i nøgleringen" : "Mangler")
            // Kun når der er forbindelse – ellers siger datoen ikke noget.
            if model.hasToken, model.username != nil, let d = model.lastSync {
                LabeledContent("Sidste synkronisering", value: d.danskDatoTid)
            }
            SecureField("Nyt token", text: $token)
            HStack {
                Button("Gem nyt token") {
                    busy = true
                    Task { if await model.connect(token: token) { token = "" }; busy = false }
                }
                .disabled(token.isEmpty || busy)
                if model.hasToken {
                    Button("Fjern token", role: .destructive) { model.disconnect() }
                }
            }
            Text("Tokenet vises aldrig, logges ikke og gemmes kun i macOS' nøglering.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }
}

struct SortSettings: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ViewState private var newArtist = ""
    @ViewState private var newSort = ""
    // Felterne har deres egen tekst. Bundet direkte til reglerne blev teksten
    // omskrevet ved hvert tastetryk, så et komma forsvandt, og man ikke kunne
    // skrive mere end én artikel.
    @ViewState private var artistArticlesText = ""
    @ViewState private var titleArticlesText = ""

    var body: some View {
        let rules = model.rules
        Form {
            Section {
                Toggle("Præcis samme rækkefølge som i Discogs-samlingen", isOn: Binding(
                    get: { rules.useDiscogsOrder }, set: { var r = rules; r.useDiscogsOrder = $0; model.updateRules(r) }))
            } footer: {
                Text("Pladerne står i den rækkefølge, Discogs selv sorterer samlingen (kunstner A–Z). Reglerne herunder bruges kun, når dette er slået fra.")
            }
            Section {
                TextField("Ignorerede artikler i kunstnernavne", text: $artistArticlesText, prompt: Text("The, Die, Les"))
                    .onChange(of: artistArticlesText) { _, new in
                        var r = model.rules
                        guard r.artistArticles != Self.list(new) else { return }
                        r.artistArticles = Self.list(new); model.updateRules(r)
                    }
                TextField("Ignorerede artikler i titler", text: $titleArticlesText, prompt: Text("(ingen)"))
                    .onChange(of: titleArticlesText) { _, new in
                        var r = model.rules
                        guard r.titleArticles != Self.list(new) else { return }
                        r.titleArticles = Self.list(new); model.updateRules(r)
                    }
                Toggle("Ignorér tegnsætning (AC/DC = ACDC, A-ha = Aha)", isOn: Binding(
                    get: { rules.ignorePunctuation }, set: { var r = rules; r.ignorePunctuation = $0; model.updateRules(r) }))
                Toggle("Dansk alfabet (Æ, Ø, Å efter Z)", isOn: Binding(
                    get: { rules.danishAlphabet }, set: { var r = rules; r.danishAlphabet = $0; model.updateRules(r) }))
                Picker("Opsamlinger (Various)", selection: Binding(
                    get: { rules.various }, set: { var r = rules; r.various = $0; model.updateRules(r) })) {
                    ForEach(SortRules.VariousPlacement.allCases) { Text($0.label).tag($0) }
                }
                Picker("Flere plader af samme kunstner", selection: Binding(
                    get: { rules.withinArtist }, set: { var r = rules; r.withinArtist = $0; model.updateRules(r) })) {
                    ForEach(SortRules.WithinArtist.allCases) { Text($0.label).tag($0) }
                }
            } footer: {
                Text("Reglerne bruges til første opdeling og til at foreslå pladser til nye plader. De flytter aldrig plader, der allerede står i reolen.")
            }

            Section {
                overrides(rules)
            } header: {
                Text("Sorteringsnavne for kunstnere")
            } footer: {
                Text("Skriv kunstneren, som navnet står i Discogs, og det navn, pladen skal sorteres under.")
            }
        }
        .formStyle(.grouped)
        // Sorteringsnavne, der tilføjes eller fjernes, glider ind/ud.
        .animation(Motion.rows(reduceMotion), value: rules.artistOverrides)
        .onAppear {
            artistArticlesText = model.rules.artistArticles.joined(separator: ", ")
            titleArticlesText = model.rules.titleArticles.joined(separator: ", ")
        }
    }

    /// Sorteringsnavne.
    @ViewBuilder private func overrides(_ rules: SortRules) -> some View {
        ForEach(rules.artistOverrides.keys.sorted(), id: \.self) { artist in
            HStack {
                Text(artist)
                Image(systemName: "arrow.right").foregroundStyle(.secondary)
                Text(rules.artistOverrides[artist] ?? "").fontWeight(.medium)
                Spacer()
                Button(role: .destructive) {
                    var r = rules; r.artistOverrides[artist] = nil; model.updateRules(r)
                } label: { Image(systemName: "minus.circle") }
                .buttonStyle(.borderless)
                .accessibilityLabel("Fjern sorteringsnavn for \(artist)")
                .help("Fjern")
            }
        }
        // Felterne har ingen etiket ved siden af (den brækkede over to linjer); i stedet
        // står en grå eksempeltekst inde i feltet, så den ligner et eksempel og ikke en værdi.
        HStack(spacing: Spacing.xs) {
            TextField("Kunstner", text: $newArtist, prompt: Text("Kunstner, fx Bob Dylan"))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
            Image(systemName: "arrow.right").foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("Sorteres som", text: $newSort, prompt: Text("Sorteres som, fx Dylan, Bob"))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
            Button("Tilføj") {
                let a = newArtist.trimmingCharacters(in: .whitespaces)
                let v = newSort.trimmingCharacters(in: .whitespaces)
                var r = rules; r.artistOverrides[a] = v; model.updateRules(r)
                newArtist = ""; newSort = ""
            }
            .disabled(newArtist.trimmingCharacters(in: .whitespaces).isEmpty
                      || newSort.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    static func list(_ s: String) -> [String] {
        s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}

struct ShelfSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section("Struktur") {
                ForEach(model.library.shelves, id: \.self) { shelf in
                    let secs = model.library.locations.filter { $0.shelf == shelf }
                    HStack {
                        Text("Reol \(shelf)")
                        Spacer()
                        Text(secs.map(\.section).joined(separator: ", ")).foregroundStyle(.secondary)
                        Button { model.addSection(shelf: shelf) } label: { Label("Sektion", systemImage: "plus") }
                    }
                }
                Button { model.addSection(shelf: (model.library.shelves.last ?? 0) + 1) } label: { Label("Ny reol", systemImage: "plus") }
            }
            Section {
                Button { model.exportLabels() } label: { Label("Udskriv reolskilte med QR-kode… (⌘P)", systemImage: "qrcode") }
                    .disabled(model.library.locations.isEmpty)
            } footer: {
                Text("Ét skilt pr. sektion med første og sidste kunstner. QR-koden åbner sektionen i appen.")
            }
            Section {
                Button("Opdel samlingen forfra…", role: .destructive) { model.forceOnboarding = true }
            } footer: {
                Text("Åbner opdelingen igen. Intet ændres, før du bekræfter “Opret reol”.")
            }
        }
        .formStyle(.grouped)
    }
}

struct BackupSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section {
                LabeledContent("Seneste kopi", value: model.lastBackup?.danskDato ?? "Ingen endnu")
                LabeledContent("Gemmes i", value: DatabaseBackup.isInICloud(model.backupFolder)
                               ? "iCloud Drive › Vinyl Shelf Finder backup"
                               : "Dokumenter › Vinyl Shelf Finder backup")
                if let error = model.backupError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Button("Tag en kopi nu") { model.backupNow() }
                        .disabled(model.isDemo)
                    Button("Vis i Finder") { model.showBackupsInFinder() }
                }
            } footer: {
                Text("Appen gemmer selv en kopi af reolen, placeringer, historik og lyttelog én gang om dagen og beholder de seneste \(DatabaseBackup.keep). Se README.md for, hvordan en kopi gendannes.")
            }
        }
        .formStyle(.grouped)
    }
}
