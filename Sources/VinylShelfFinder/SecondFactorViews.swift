import SwiftUI
import AppKit
import VinylCore

// MARK: - Totrinslogin
//
// En kode fra en kode-app (Adgangskoder på iPhone, Google Authenticator m.fl.) ud over adgangskoden.
// Guiden har tre trin som på telefonen og i webappen: hvad det er, tilføj Vinyl Shelf i kode-appen, skriv koden.
// Supabase kræver koden, når supabase/mfa.sql er kørt.

/// Guiden, der slår totrinslogin til. Vises én gang efter login og fra Indstillinger › Konto.
struct SecondFactorGuide: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @ViewState private var step = 0
    @ViewState private var enrollment: TOTPEnrollment?
    @ViewState private var code = ""
    @ViewState private var error: String?
    @ViewState private var busy = false
    @ViewState private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            switch step {
            case 0: intro
            case 1: add
            case 2: enter
            default: done
            }
            Spacer(minLength: 0)
            if let error {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                StepDots(step: min(step, 2), count: 3)
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                buttons
            }
        }
        .padding(Spacing.l)
        .frame(width: 460, height: 540)
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            GuideIcon(systemName: "checkmark.shield")
            Text("Slå totrinslogin til").font(.title2.weight(.semibold))
            Text("Så kan ingen komme ind på din konto med kun din adgangskode eller din mail. Når du logger ind på en ny enhed, skal du også skrive en kode fra din telefon.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            GuideSteps()
                .padding(.top, Spacing.xs)
            Text("På iPhone kan du bruge appen Adgangskoder, som allerede er der. På Android kan du hente Google Authenticator gratis.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var add: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Text("Tilføj Vinyl Shelf i kode-appen").font(.title2.weight(.semibold))
            Text("Åbn kameraet eller kode-appen på telefonen, og scan koden. Vælg at tilføje den som en kode (bekræftelseskode).")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let e = enrollment {
                HStack {
                    Spacer()
                    if let qr = LabelsPDF.qrCode(e.uri) {
                        Image(decorative: qr, scale: 1).interpolation(.none).resizable()
                            .frame(width: 180, height: 180)
                            .padding(10).background(.white, in: .rect(cornerRadius: 12))
                            .accessibilityLabel("QR-kode til kode-appen")
                    }
                    Spacer()
                }
                Text("Kan du ikke scanne? Skriv denne kode i kode-appen:").font(.callout).foregroundStyle(.secondary)
                HStack {
                    Text(e.groupedSecret).font(.body.monospaced()).textSelection(.enabled)
                    Spacer()
                    Button(copied ? "Kopieret" : "Kopiér") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(e.secret, forType: .string)
                        copied = true
                    }
                }
            } else {
                HStack { Spacer(); ProgressView(); Spacer() }.frame(height: 200)
            }
        }
        .task {
            guard enrollment == nil else { return }
            do { enrollment = try await model.beginSecondFactor() } catch { self.error = error.localizedDescription }
        }
    }

    private var enter: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Text("Skriv koden").font(.title2.weight(.semibold))
            Text("Skriv de 6 tal, som kode-appen viser ud for Vinyl Shelf. Tallene skifter hvert 30. sekund – det er helt normalt.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextField("Kode", text: $code, prompt: Text("123 456"))
                .font(.system(size: 28, weight: .medium, design: .monospaced))
                .multilineTextAlignment(.center)
                .textFieldStyle(.roundedBorder)
                .onSubmit(confirm)
        }
    }

    private var done: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            GuideIcon(systemName: "checkmark.circle")
            Text("Totrinslogin er slået til").font(.title2.weight(.semibold))
            Text("Næste gang du logger ind på en ny enhed, skal du også skrive en kode fra kode-appen. Dine enheder, der allerede er logget ind, beder om koden én gang.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("Mister du telefonen, kan du slå totrinslogin fra på en computer, hvor du stadig er logget ind (Indstillinger › Konto).")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var buttons: some View {
        switch step {
        case 0:
            Button("Ikke nu") { dismiss() }
            Button("Kom i gang") { error = nil; step = 1 }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
        case 1:
            Button("Tilbage") { step = 0 }
            Button("Næste") { error = nil; step = 2 }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                .disabled(enrollment == nil)
        case 2:
            Button("Tilbage") { step = 1 }
            Button("Slå til", action: confirm).buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                .disabled(busy || code.filter(\.isNumber).count != 6)
        default:
            Button("Færdig") { dismiss() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
        }
    }

    private func confirm() {
        guard let e = enrollment, code.filter(\.isNumber).count == 6, !busy else { return }
        busy = true
        Task {
            error = await model.confirmSecondFactor(e, code: code)
            busy = false
            if error == nil { step = 3 }
        }
    }
}

/// De tre trin i en nummereret liste (første side af guiden).
private struct GuideSteps: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            ForEach(Array(["Find en kode-app på telefonen", "Tilføj Vinyl Shelf i appen", "Skriv de 6 tal, appen viser"].enumerated()), id: \.offset) { i, t in
                HStack(spacing: Spacing.s) {
                    Text("\(i + 1)").font(.callout.weight(.semibold)).foregroundStyle(.tint)
                        .frame(width: 24, height: 24).background(.tint.opacity(0.15), in: .circle)
                    Text(t)
                }
            }
        }
    }
}

private struct GuideIcon: View {
    let systemName: String
    var body: some View {
        Image(systemName: systemName).font(.system(size: 36)).foregroundStyle(.tint).padding(.bottom, Spacing.xxs)
    }
}

private struct StepDots: View {
    let step: Int
    let count: Int
    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<count, id: \.self) { i in
                Capsule().fill(i == step ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary))
                    .frame(width: i == step ? 16 : 6, height: 6)
            }
        }
        .accessibilityLabel("Trin \(step + 1) af \(count)")
    }
}

/// Indstillinger › Konto: totrinslogin til/fra, og feltet til koden, når kontoen kræver den.
struct SecondFactorSettings: View {
    @Environment(AppModel.self) private var model
    @ViewState private var code = ""
    @ViewState private var note: String?
    @ViewState private var busy = false
    @ViewState private var guide = false
    @ViewState private var confirmOff = false

    var body: some View {
        if model.cloudNeedsCode != nil {
            Section {
                TextField("Kode fra kode-appen", text: $code, prompt: Text("123 456"))
                    .onSubmit(submit)
                if let note { Label(note, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary) }
                Button("Fortsæt", action: submit)
                    .buttonStyle(.borderedProminent)
                    .disabled(busy || code.filter(\.isNumber).count != 6)
            } header: {
                Text("Skriv koden")
            } footer: {
                Text("Din konto har totrinslogin. Åbn kode-appen, og skriv de 6 tal ud for Vinyl Shelf. Så synkroniserer denne Mac igen.")
            }
        }
        Section {
            LabeledContent("Totrinslogin", value: model.cloudSecondFactorOn == true ? "Til" : model.cloudSecondFactorOn == false ? "Fra" : "…")
            if model.cloudSecondFactorOn == true {
                Button("Slå totrinslogin fra…") { confirmOff = true }
                    .disabled(busy || model.cloudNeedsCode != nil)
            } else if model.cloudSecondFactorOn == false {
                Button("Slå totrinslogin til…") { guide = true }
            }
        } header: {
            Text("Totrinslogin")
        } footer: {
            Text("Med totrinslogin skal du også skrive en kode fra din telefon, når du logger ind på en ny enhed. Så kan ingen komme ind med kun din adgangskode eller din mail.")
        }
        .task { await model.refreshSecondFactorStatus() }
        .sheet(isPresented: $guide) { SecondFactorGuide() }
        .confirmationDialog("Slå totrinslogin fra?", isPresented: $confirmOff) {
            Button("Slå fra", role: .destructive) {
                busy = true
                Task { note = await model.disableSecondFactor(); busy = false }
            }
        } message: {
            Text("Så er en adgangskode eller et mail-link igen nok til at logge ind på kontoen.")
        }
    }

    private func submit() {
        guard code.filter(\.isNumber).count == 6, !busy else { return }
        busy = true
        Task {
            note = await model.submitSecondFactorCode(code)
            if note == nil { code = "" }
            busy = false
        }
    }
}
