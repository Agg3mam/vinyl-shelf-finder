import SwiftUI
import VinylCore

/// Kontoen: log ind med e-mail (samme konto som på Mac), og status for synkroniseringen.
struct AccountView: View {
    @Environment(PhoneModel.self) private var model
    /// Første skærm, før der er data på telefonen.
    let welcome: Bool
    @State private var email = ""
    @State private var code = ""
    @State private var codeSent = false
    @State private var busy = false
    @State private var password = ""
    /// Uden adgangskode: log ind med et link på mail.
    @State private var useMail = false
    @AppStorage("look_style") private var lookStyle = LookStyle.standard

    var body: some View {
        Form {
            if !welcome {
                Section {
                    NavigationLink { LookView().lookScreen() } label: {
                        LabeledContent { Text(lookStyle.name) } label: { Label("Udseende", systemImage: "paintpalette") }
                    }
                    if model.hasShelves {
                        NavigationLink { SortListView().lookScreen() } label: { Label("Sorteringsliste", systemImage: "checklist") }
                    }
                } header: {
                    Text("Indstillinger")
                } footer: {
                    if model.hasShelves {
                        Text("Sorteringslisten er hele rækkefølgen med flueben, så du kan have telefonen med, når du stiller reolen op. Fluebenene er de samme som på computeren.")
                    }
                }
            }
            if model.cloudLoggedIn { loggedIn } else { login }
        }
        .navigationTitle(welcome ? "Vinyl Shelf" : "Konto")
        .onAppear { if email.isEmpty { email = model.cloudEmail ?? "" } }
        .refreshable { if model.cloudLoggedIn { await model.syncCloud(userInitiated: true) } }
    }

    @ViewBuilder private var loggedIn: some View {
        Section {
            LabeledContent("Logget ind som", value: model.cloudEmail ?? "")
            LabeledContent("Senest synkroniseret") {
                if model.cloudPhase == .syncing {
                    ProgressView()
                } else {
                    Text(model.cloudLastSync.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "Ikke endnu")
                }
            }
            if case .failed(let message) = model.cloudPhase {
                Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
            }
        } footer: {
            Text("Reoler, placeringer og lyttelog er de samme som på din computer (Mac eller Windows). Appen synkroniserer selv, når den åbnes, kort efter \"Spillet\" og hvert 5. minut.")
        }
        Section {
            Button("Synkronisér nu", systemImage: "arrow.triangle.2.circlepath") { Task { await model.syncCloud(userInitiated: true) } }
                .disabled(model.cloudPhase == .syncing)
            Button("Log ud", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) { model.logOutCloud() }
        }
    }

    @ViewBuilder private var login: some View {
        if welcome {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Image(systemName: "books.vertical.fill").font(.largeTitle).foregroundStyle(AppAccent.color)
                    Text("Find dine plader i reolen").font(.title2.weight(.bold))
                    Text("Log ind med den samme e-mail og adgangskode som i appen på din computer. Så kommer dine reoler, placeringer og lyttelog hertil.")
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 6)
            }
        }
        Section {
            TextField("E-mail", text: $email, prompt: Text("dig@eksempel.dk"))
                .textContentType(.emailAddress)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .disabled(codeSent)
            if !useMail {
                SecureField("Adgangskode", text: $password)
                    .textContentType(.password)
                    .onSubmit(signIn)
            } else if codeSent {
                TextField("Linket eller koden fra mailen", text: $code, axis: .vertical)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .lineLimit(1...3)
                    .onSubmit(logIn)
            }
            if case .failed(let message) = model.cloudPhase {
                Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
            }
        } header: {
            Text("Log ind på din konto")
        } footer: {
            Text(!useMail
                 ? "Adgangskoden vælger du under Konto i appen på din computer, mens du er logget ind der."
                 : codeSent
                 ? "Vi har sendt en mail til \(email). Åbn mailen her på telefonen, og tryk på linket – så åbner appen og logger ind. Virker det ikke: hold fingeren på linket, vælg Kopiér, og sæt det ind ovenfor. Kun den nyeste mail virker."
                 : "Du får en mail med et link – ingen adgangskode. Der kan højst sendes 2 mails i timen.")
        }
        Section {
            if !useMail {
                Button(action: signIn) {
                    HStack {
                        Label("Log ind", systemImage: "person.crop.circle.badge.checkmark")
                        if busy { Spacer(); ProgressView() }
                    }
                }
                .disabled(busy || !email.contains("@") || password.isEmpty)
                Button("Har ingen adgangskode – send en mail i stedet", systemImage: "envelope") { useMail = true }
            } else if codeSent {
                Button(action: logIn) {
                    Label("Log ind", systemImage: "person.crop.circle.badge.checkmark")
                }
                .disabled(busy || code.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("Send en ny mail", systemImage: "envelope") { codeSent = false; code = "" }
            } else {
                Button {
                    busy = true
                    Task { codeSent = await model.requestCloudCode(email: email); busy = false }
                } label: {
                    HStack {
                        Label("Send mail", systemImage: "envelope")
                        if busy { Spacer(); ProgressView() }
                    }
                }
                .disabled(busy || !email.contains("@"))
            }
            if useMail {
                Button("Log ind med adgangskode i stedet", systemImage: "key") { useMail = false; codeSent = false; code = "" }
            }
        }
    }

    private func signIn() {
        guard !password.isEmpty else { return }
        busy = true
        Task {
            if await model.signInCloud(email: email, password: password) { password = "" }
            busy = false
        }
    }

    private func logIn() {
        busy = true
        Task {
            if await model.completeCloudInput(email: email, text: code) { code = "" }
            busy = false
        }
    }
}

/// Udseende: tema og stil, som i webappen og på Mac. Gælder kun på telefonen.
struct LookView: View {
    @AppStorage("look_theme") private var lookTheme = LookTheme.auto
    @AppStorage("look_style") private var lookStyle = LookStyle.standard

    var body: some View {
        Form {
            Section("Tema") {
                Picker("Tema", selection: $lookTheme) {
                    ForEach(LookTheme.allCases) { Text($0.name).tag($0) }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }
            Section {
                ForEach(LookStyle.allCases) { style in
                    Button { lookStyle = style } label: {
                        HStack(spacing: 12) {
                            HStack(spacing: 0) {
                                ForEach(style.swatch.indices, id: \.self) { Color(uiColor: AppAccent.rgb(style.swatch[$0])) }
                            }
                            .frame(width: 34, height: 34)
                            .clipShape(.rect(cornerRadius: 9))
                            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(.separator, lineWidth: 0.5))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(style.name).foregroundStyle(.primary)
                                Text(style.note).font(.footnote).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if style == lookStyle { Image(systemName: "checkmark").foregroundStyle(.tint) }
                        }
                    }
                    .sensoryFeedback(.selection, trigger: lookStyle)
                }
            } header: {
                Text("Stil")
            } footer: {
                Text("Hver stil har en lys og en mørk udgave. Valget gælder kun på denne telefon.")
            }
        }
        .navigationTitle("Udseende")
    }
}
