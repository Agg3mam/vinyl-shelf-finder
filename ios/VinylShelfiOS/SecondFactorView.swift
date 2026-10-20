import SwiftUI
import CoreImage
import VinylCore

// MARK: - Totrinslogin (som på Mac, SecondFactorViews.swift)
//
// En kode fra en kode-app ud over adgangskoden. Guiden har tre trin: hvad det er, tilføj Vinyl Shelf i kode-appen
// (på telefonen med ét tryk, der åbner Adgangskoder), og skriv koden.

/// Guiden, der slår totrinslogin til. Vises én gang efter login og fra Konto › Totrinslogin.
struct SecondFactorGuide: View {
    @Environment(PhoneModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var step = 0
    @State private var enrollment: TOTPEnrollment?
    @State private var code = ""
    @State private var error: String?
    @State private var busy = false
    @State private var copied = false
    @FocusState private var codeFocused: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    switch step {
                    case 0: intro
                    case 1: add
                    case 2: enter
                    default: done
                    }
                    if let error {
                        Label(error, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.secondary)
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .safeAreaBar(edge: .bottom) {
                VStack(spacing: 10) {
                    primary
                    StepDots(step: min(step, 2), count: 3)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 8)
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if step == 1 || step == 2 { Button("Tilbage", systemImage: "chevron.left") { error = nil; step -= 1 } }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if step < 3 { Button("Ikke nu") { dismiss() } }
                }
            }
            .sensoryFeedback(.success, trigger: step == 3)
        }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: "checkmark.shield").font(.system(size: 44)).foregroundStyle(.tint)
            Text("Slå totrinslogin til").font(.title.weight(.bold))
            Text("Så kan ingen komme ind på din konto med kun din adgangskode eller din mail. Når du logger ind på en ny enhed, skal du også skrive en kode fra telefonen. Det tager et par minutter.")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(["Find en kode-app på telefonen", "Tilføj Vinyl Shelf i appen", "Skriv de 6 tal, appen viser"].enumerated()), id: \.offset) { i, t in
                    HStack(spacing: 12) {
                        Text("\(i + 1)").font(.callout.weight(.semibold)).foregroundStyle(.tint)
                            .frame(width: 28, height: 28).background(.tint.opacity(0.15), in: .circle)
                        Text(t)
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background.secondary, in: .rect(cornerRadius: 16))
            Text("På iPhone kan du bruge appen Adgangskoder, som allerede er der. På Android kan du hente Google Authenticator gratis.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private var add: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Tilføj Vinyl Shelf").font(.title.weight(.bold))
            if let e = enrollment {
                Text("Tryk på knappen, så åbner Adgangskoder (eller din kode-app) og tilføjer koden.").foregroundStyle(.secondary)
                Button {
                    if let url = URL(string: e.uri) { openURL(url) }
                } label: {
                    Label("Åbn i kode-appen", systemImage: "key").frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
                .controlSize(.large)
                Text("Fra en anden telefon").font(.headline).padding(.top, 8)
                if let qr = QRImage.make(e.uri) {
                    Image(decorative: qr, scale: 1).interpolation(.none).resizable()
                        .frame(width: 170, height: 170)
                        .padding(10).background(.white, in: .rect(cornerRadius: 12))
                        .frame(maxWidth: .infinity)
                        .accessibilityLabel("QR-kode til kode-appen")
                }
                Text("Kan du ikke scanne? Skriv denne kode i kode-appen:").font(.footnote).foregroundStyle(.secondary)
                HStack {
                    Text(e.groupedSecret).font(.body.monospaced()).textSelection(.enabled)
                    Spacer()
                    Button(copied ? "Kopieret" : "Kopiér") { UIPasteboard.general.string = e.secret; copied = true }
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, minHeight: 200)
            }
        }
        .task {
            guard enrollment == nil else { return }
            do { enrollment = try await model.beginSecondFactor() } catch { self.error = error.localizedDescription }
        }
    }

    private var enter: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Skriv koden").font(.title.weight(.bold))
            Text("Skriv de 6 tal, som kode-appen viser ud for Vinyl Shelf. Tallene skifter hvert 30. sekund – det er helt normalt.")
                .foregroundStyle(.secondary)
            TextField("123 456", text: $code)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                .font(.system(size: 32, weight: .medium, design: .monospaced))
                .multilineTextAlignment(.center)
                .padding(.vertical, 12)
                .background(.background.secondary, in: .rect(cornerRadius: 14))
                .focused($codeFocused)
                .onAppear { codeFocused = true }
        }
    }

    private var done: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: "checkmark.circle").font(.system(size: 44)).foregroundStyle(.tint)
            Text("Totrinslogin er slået til").font(.title.weight(.bold))
            Text("Næste gang du logger ind på en ny enhed, skal du også skrive en kode fra kode-appen. Dine enheder, der allerede er logget ind, beder om koden én gang.")
                .foregroundStyle(.secondary)
            Text("Mister du telefonen, kan du slå totrinslogin fra på en computer, hvor du stadig er logget ind.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var primary: some View {
        let label: String = ["Kom i gang", "Næste", "Slå til", "Færdig"][min(step, 3)]
        Button {
            switch step {
            case 0, 1: error = nil; step += 1
            case 2: confirm()
            default: dismiss()
            }
        } label: {
            HStack {
                Text(label)
                if busy { ProgressView().tint(.white) }
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.glassProminent)
        .controlSize(.large)
        .disabled(busy || (step == 1 && enrollment == nil) || (step == 2 && code.filter(\.isNumber).count != 6))
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

/// QR-kode (CoreImage) til kode-appen.
enum QRImage {
    static func make(_ text: String) -> CGImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let out = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)) else { return nil }
        return CIContext().createCGImage(out, from: out.extent)
    }
}

/// Konto: totrinslogin til/fra, og feltet til koden, når kontoen kræver den.
struct SecondFactorSection: View {
    @Environment(PhoneModel.self) private var model
    @State private var code = ""
    @State private var note: String?
    @State private var busy = false
    @State private var guide = false
    @State private var confirmOff = false

    var body: some View {
        if model.cloudNeedsCode != nil {
            Section {
                TextField("Kode fra kode-appen", text: $code, prompt: Text("123 456"))
                    .keyboardType(.numberPad)
                    .textContentType(.oneTimeCode)
                if let note { Label(note, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary) }
                Button(action: submit) {
                    HStack { Label("Fortsæt", systemImage: "checkmark.shield"); if busy { Spacer(); ProgressView() } }
                }
                .disabled(busy || code.filter(\.isNumber).count != 6)
            } header: {
                Text("Skriv koden")
            } footer: {
                Text("Din konto har totrinslogin. Åbn kode-appen (fx Adgangskoder › Koder), og skriv de 6 tal ud for Vinyl Shelf.")
            }
        }
        Section {
            LabeledContent("Totrinslogin", value: model.cloudSecondFactorOn == true ? "Til" : model.cloudSecondFactorOn == false ? "Fra" : "…")
            if model.cloudSecondFactorOn == true {
                Button("Slå totrinslogin fra", role: .destructive) { confirmOff = true }
                    .disabled(busy || model.cloudNeedsCode != nil)
            } else if model.cloudSecondFactorOn == false {
                Button("Slå totrinslogin til", systemImage: "checkmark.shield") { guide = true }
            }
        } footer: {
            Text("Med totrinslogin skal du også skrive en kode fra telefonen, når du logger ind på en ny enhed.")
        }
        .task { await model.refreshSecondFactorStatus() }
        .sheet(isPresented: $guide) { SecondFactorGuide() }
        .confirmationDialog("Slå totrinslogin fra?", isPresented: $confirmOff, titleVisibility: .visible) {
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
