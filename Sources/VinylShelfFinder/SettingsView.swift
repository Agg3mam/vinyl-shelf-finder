import SwiftUI
import VinylCore

struct SettingsView: View {
    var body: some View {
        TabView {
            CloudSettings().tabItem { Label("Konto", systemImage: "icloud") }
            AccountSettings().tabItem { Label("Discogs", systemImage: "person.crop.circle") }
            SortSettings().tabItem { Label("Sortering", systemImage: "textformat.abc") }
            ShelfSettings().tabItem { Label("Reol", systemImage: "books.vertical") }
            IMusicSettings().tabItem { Label("iMusic", systemImage: "bag") }
            BackupSettings().tabItem { Label("Sikkerhedskopi og data", systemImage: "clock.arrow.circlepath") }
            UpdateSettings().tabItem { Label("Opdatering", systemImage: "arrow.down.circle") }
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
    @ViewState private var showSurname = false

    var body: some View {
        let rules = model.rules
        Form {
            Section {
                Toggle("Præcis samme rækkefølge som i Discogs-samlingen", isOn: Binding(
                    get: { rules.useDiscogsOrder }, set: { var r = rules; r.useDiscogsOrder = $0; model.updateRules(r) }))
                Text("Pladerne står i den rækkefølge, Discogs selv sorterer samlingen (kunstner A–Z). Reglerne herunder bruges kun, når dette er slået fra.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Kunstnere, der starter med et tal, står sidst", isOn: Binding(
                    get: { rules.numbersLast }, set: { var r = rules; r.numbersLast = $0; model.updateRules(r) }))
            } footer: {
                Text("10cc, 2Pac og The 1975 står efter Z og Æ Ø Å. Gælder også med Discogs' rækkefølge, hvor tallene ellers står først.")
            }
            Section {
                let fresh = SurnameSheet.newCount(model)
                Button(fresh > 0 ? "Vælg personer… (\(fresh) nye forslag)" : "Vælg personer…") { showSurname = true }
            } header: {
                Text("Efternavn først")
            } footer: {
                Text("Personer sorteres efter efternavn: Bob Dylan under D, Leonard Cohen under C. Appen foreslår, hvem der er personer, og du retter gættet. Bands som Pink Floyd røres ikke.")
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
        .sheet(isPresented: $showSurname) { SurnameSheet().environment(model) }
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
        @Bindable var model = model
        Form {
            if model.showsMediumPicker {
                Section {
                    Picker("Hylde", selection: $model.medium) {
                        ForEach(Medium.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                } footer: {
                    Text("Plader og cd'er har hver deres reoler. Ændringerne herunder gælder den valgte hylde.")
                }
            }
            Section("Struktur") {
                ForEach(model.library.shelves, id: \.self) { shelf in
                    let secs = model.library.locations.filter { $0.shelf == shelf }
                    HStack {
                        Text("\(model.medium.shelfWord) \(shelf)")
                        Spacer()
                        Text(secs.map(\.section).joined(separator: ", ")).foregroundStyle(.secondary)
                        Button { model.addSection(shelf: shelf) } label: { Label("Sektion", systemImage: "plus") }
                    }
                }
                Button { model.addSection(shelf: (model.library.shelves.last ?? 0) + 1) } label: { Label(model.medium == .vinyl ? "Ny reol" : "Ny cd-reol", systemImage: "plus") }
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
    @ViewState private var exportedTo: URL?
    @ViewState private var pendingImport: (name: String, summary: ImportSummary)?
    @ViewState private var confirmReset = false
    @ViewState private var removeToken = false

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
                Text("Appen gemmer selv en kopi af reolen, placeringer, historik og lyttelog én gang om dagen og beholder de seneste \(DatabaseBackup.keep).")
            }
            Section {
                Button("Eksportér…", action: exportFile)
            } header: { Text("Eksportér") } footer: {
                Text("Gemmer hele dit system i én fil: plader og cd'er, reoler, sektioner, placeringer, flueben, historik, lyttelog og indstillinger. Discogs-tokenet kommer ikke med. Filen kan også åbnes i Windows-udgaven.")
            }
            Section {
                Button("Importér…", action: importFile)
            } header: { Text("Importér") } footer: {
                Text("Henter et system fra en eksport eller en af de daglige sikkerhedskopier. Det nuværende system gemmes først som en kopi, og appen åbner igen.")
            }
            Section {
                Button("Nulstil appen…") { removeToken = false; confirmReset = true }
            } header: { Text("Start helt forfra") } footer: {
                Text("Sletter reoler, placeringer, historik og lyttelog, så appen starter forfra. Det nuværende system gemmes først som en kopi, som kan importeres igen.")
            }
        }
        .formStyle(.grouped)
        .alert("Eksporteret", isPresented: Binding(get: { exportedTo != nil }, set: { if !$0 { exportedTo = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Dit system er gemt i:\n\(exportedTo?.path ?? "")\n\nGem filen et sikkert sted. Den kan importeres igen under Indstillinger › Sikkerhedskopi og data.")
        }
        .alert("Importér dette system?", isPresented: Binding(get: { pendingImport != nil }, set: { if !$0 { pendingImport = nil } }),
               presenting: pendingImport) { _ in
            Button("Importér og åbn igen") { model.applyAndRestart(reset: false, removeToken: false) }
            Button("Annullér", role: .cancel) { model.cancelPendingChange() }
        } message: { p in
            Text("\(p.name) indeholder \(Self.count(p.summary.vinyl, "plade", "plader")) og \(Self.count(p.summary.cds, "cd", "cd'er")) fordelt på \(Self.count(p.summary.sections, "sektion", "sektioner")).\n\nDet nuværende system erstattes. Det gemmes først som en kopi i mappen med sikkerhedskopier, så du kan komme tilbage til det. Appen lukker og åbner igen.")
        }
        .sheet(isPresented: $confirmReset) { resetSheet }
    }

    private var resetSheet: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Text("Start helt forfra?").font(.title2.weight(.semibold))
            Text("Alle reoler, sektioner, placeringer, flueben, historik og lyttelog slettes for både plader og cd'er. Bagefter henter appen samlingen fra Discogs igen, og du laver reolerne forfra.")
                .fixedSize(horizontal: false, vertical: true)
            Text("Det nuværende system gemmes først som en kopi i mappen med sikkerhedskopier, så du kan importere det igen. Appen lukker og åbner igen.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Toggle("Fjern også forbindelsen til Discogs (tokenet)", isOn: $removeToken)
                .toggleStyle(.checkbox)
                .disabled(model.isDemo || !model.hasToken)
            HStack {
                Spacer()
                Button("Annullér") { confirmReset = false }.keyboardShortcut(.cancelAction)
                Button("Nulstil og åbn igen", role: .destructive) {
                    confirmReset = false
                    model.applyAndRestart(reset: true, removeToken: removeToken)
                }
            }
        }
        .padding(Spacing.l)
        .frame(width: 460)
    }

    private static func count(_ n: Int, _ one: String, _ many: String) -> String { n == 1 ? "1 \(one)" : "\(n) \(many)" }

    private func exportFile() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = DataTransfer.exportFileName()
        panel.allowedContentTypes = [.init(filenameExtension: DataTransfer.fileExtension) ?? .data]
        panel.directoryURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if model.export(to: url) { exportedTo = url }
    }

    private func importFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.init(filenameExtension: DataTransfer.fileExtension) ?? .data]
        panel.allowsMultipleSelection = false
        panel.directoryURL = model.backupFolder
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if let s = model.prepareImport(url) { pendingImport = (url.lastPathComponent, s) }
    }
}

/// Kontoen i skyen: samme reoler, placeringer, flueben og lyttelog på Mac, Windows og iPhone.
struct CloudSettings: View {
    @Environment(AppModel.self) private var model
    @ViewState private var email = ""
    @ViewState private var code = ""
    @ViewState private var codeSent = false
    @ViewState private var busy = false

    var body: some View {
        Form {
            if !model.cloudEnabled {
                Section { Text("Kontoen er slået fra i demo-tilstand.").foregroundStyle(.secondary) }
            } else if model.cloudLoggedIn {
                loggedIn
            } else {
                login
            }
        }
        .formStyle(.grouped)
        .onAppear { if email.isEmpty { email = model.cloudEmail ?? "" } }
    }

    @ViewBuilder private var loggedIn: some View {
        Section {
            LabeledContent("Logget ind som", value: model.cloudEmail ?? "")
            LabeledContent("Senest synkroniseret") {
                switch model.cloudPhase {
                case .syncing: Text("Synkroniserer …").foregroundStyle(.secondary)
                default: Text(model.cloudLastSync.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "Ikke endnu")
                }
            }
            if case .failed(let message) = model.cloudPhase {
                Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
            }
            HStack {
                Button("Synkronisér nu") { Task { await model.syncCloud(userInitiated: true) } }
                    .disabled(model.cloudPhase == .syncing)
                Button("Log ud") { model.logOutCloud() }
            }
        } footer: {
            Text("Reoler, placeringer, flueben, lyttelog og sorteringsregler er de samme på alle dine enheder. Appen synkroniserer selv ved start, kort efter hver ændring og hvert 5. minut. Discogs-tokenet og iMusic-adressen bliver på denne Mac.")
        }
    }

    private func logIn() {
        busy = true
        Task {
            if await model.completeCloudInput(email: email, text: code) { code = "" }
            busy = false
        }
    }

    @ViewBuilder private var login: some View {
        Section {
            TextField("E-mail", text: $email, prompt: Text("dig@eksempel.dk"))
                .textContentType(.emailAddress)
                .disabled(codeSent)
            if codeSent {
                TextField("Linket fra mailen", text: $code, prompt: Text("Højreklik på linket i mailen › Kopiér link, og indsæt her"))
                    .onSubmit(logIn)
            }
            if case .failed(let message) = model.cloudPhase {
                Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
            }
            HStack {
                if codeSent {
                    Button("Log ind", action: logIn)
                        .buttonStyle(.borderedProminent)
                        .disabled(busy || code.trimmingCharacters(in: .whitespaces).isEmpty)
                    Button("Ny mail") { codeSent = false; code = "" }
                } else {
                    Button("Send mail") {
                        busy = true
                        Task { codeSent = await model.requestCloudCode(email: email); busy = false }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(busy || !email.contains("@"))
                }
                if busy { ProgressView().controlSize(.small) }
            }
        } header: {
            Text("Log ind på din konto")
        } footer: {
            Text(codeSent
                 ? "Vi har sendt en mail til \(email). Klik IKKE på linket – så bliver det brugt op. Højreklik på det i stedet, vælg Kopiér link, og indsæt det ovenfor. Kun den nyeste mail virker. Står der en kode i mailen, kan du også skrive den. Tjek uønsket post, hvis mailen ikke kommer."
                 : "Brug den samme e-mail på Mac, Windows og iPhone. Du får en mail med et link – ingen adgangskode. Første gang oprettes kontoen.")
        }
    }
}
