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

    var body: some View {
        Form {
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
            Text("Reoler, placeringer og lyttelog er de samme som på din Mac. Appen synkroniserer selv, når den åbnes, kort efter \"Spillet\" og hvert 5. minut.")
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
                    Text("Log ind med den samme e-mail som på din Mac. Så kommer dine reoler, placeringer og lyttelog hertil.")
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
            if codeSent {
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
            Text(codeSent
                 ? "Vi har sendt en mail til \(email). Åbn mailen her på telefonen, og tryk på linket – så åbner appen og logger ind. Virker det ikke: hold fingeren på linket, vælg Kopiér, og sæt det ind ovenfor. Kun den nyeste mail virker."
                 : "Du får en mail med et link – ingen adgangskode. Der kan højst sendes 2 mails i timen.")
        }
        Section {
            if codeSent {
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
