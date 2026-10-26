import SwiftUI
import AppKit
import VinylCore

// MARK: - Find i reolen

/// Enkel, stor navigationsvisning: gå hertil, find først X, derefter Y.
///
/// Udtryk: pladens cover (sløret) eller en rolig farveflade afledt af pladen ligger
/// bagerst. Kun placeringsblokken og knapperne er glas ("chrome"); referencepladerne
/// og hint-linjerne er almindeligt indhold direkte på baggrunden.
///
/// Samme ark er også "Sæt tilbage"-guiden for en plade, der har været ude af reolen:
/// den viser præcis, hvor pladen skal stå, og først "Sat på plads" registrerer den som hjemme.
struct FindModeView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let copyID: Int64
    /// Kun til snapshot: vis dette billede som cover i stedet for at hente det.
    var previewCover: NSImage? = nil
    /// Åbn direkte som "Sæt tilbage"-guide (fra "På plads" eller "Sæt tilbage på plads").
    var putBack = false

    @ViewState private var loaded: CoverLook?
    /// Find-arket for en plade, der er ude, kan skifte til guiden uden at lukke ("Sæt den tilbage nu").
    @ViewState private var switchedToPutBack = false

    private var isPuttingBack: Bool { putBack || switchedToPutBack }

    var body: some View {
        let item = model.library.item(copyID)
        let look = previewCover.map(CoverLook.init) ?? loaded ?? item.flatMap { CoverLook.cached($0.release.id) }
        let tone = look?.tone ?? item.map { CoverTone.fallback(for: $0.release) } ?? CoverTone(hue: 0.6, saturation: 0.1)

        VStack(alignment: .leading, spacing: Spacing.l) {
            if let it = item {
                if !isPuttingBack, let away = it.awayMessage {
                    AwayBanner(text: away, symbol: it.copy.status.symbol)
                        .transition(.opacity)
                }
                FindHeader(item: it, image: look?.image, tone: tone, eyebrow: isPuttingBack ? "Sæt tilbage" : "Find")
                    .padding(.bottom, Spacing.xs)
                FindPlacement(copyID: copyID, item: it, tone: tone, putBack: isPuttingBack)
            }
            Spacer(minLength: 0)
            FindActions(mode: actionMode(item), dismiss: { dismiss() },
                        found: { choice in
                            dismiss()
                            switch choice {
                            case .listening:
                                model.logPlay(copyID)
                                model.setStatus(copyID, .playing)
                            case .wall: model.setStatus(copyID, .wall)
                            case .lent, .stored:
                                // Navn eller sted spørges der om i hovedvinduet, når arket er lukket.
                                Task { @MainActor in
                                    try? await Task.sleep(for: .milliseconds(400))
                                    model.chooseStatus(copyID, choice == .lent ? .lent : .stored)
                                }
                            case .stays: break
                            }
                        },
                        startPutBack: { withAnimation(Motion.state(reduceMotion)) { switchedToPutBack = true } },
                        confirmPutBack: {
                            model.finishReturn(copyID)
                            dismiss()
                        })
        }
        .padding(Spacing.xl)
        // Fast bredde, men højden vokser med indholdet (lange titler, mange hint-linjer),
        // så knapperne aldrig skubbes ud af arket.
        .frame(width: 640)
        .frame(minHeight: 640)
        .foregroundStyle(Ink.primary)
        .tint(tone.accent)
        .environment(\.coverTone, tone)
        .background { FindBackdrop(look: look, tone: tone) }
        // Esc lukker arket, selv om der ikke længere er en synlig "Luk"-knap.
        // I guiden er Esc "Annullér": intet ændres.
        .onExitCommand { dismiss() }
        .task(id: item?.release.id) {
            guard previewCover == nil, let r = item?.release,
                  let l = await CoverLook.load(for: r), !Task.isCancelled else { return }
            loaded = l
        }
    }

    private func actionMode(_ item: RecordItem?) -> FindActions.Mode {
        if isPuttingBack { return .putBack }
        guard let item, item.awayMessage != nil else { return .found }
        // Guiden kræver en plads i reolen; en uplaceret plade placeres fra plade-detaljen.
        return .away(canPutBack: model.library.locationOfCopy[item.id] != nil)
    }
}

/// Coveret plus det, der afledes af det: sløret baggrund, farvetone og dæmpning.
struct CoverLook {
    let image: NSImage
    let blurred: NSImage?
    let tone: CoverTone?
    /// Hvor meget det slørede cover dæmpes for at sikre tekstkontrasten (se `CoverBlur.scrim`).
    let scrim: Double

    /// Synkron variant (kun snapshot-preview).
    init(_ image: NSImage) {
        let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        let parts = cg.map(Self.derive)
        self.init(image: image, blurred: parts?.blurred, tone: parts?.tone, scrim: parts?.scrim ?? 0.9)
    }

    private init(image: NSImage, blurred: NSImage?, tone: CoverTone?, scrim: Double) {
        self.image = image
        self.blurred = blurred
        self.tone = tone
        self.scrim = scrim
    }

    private static func derive(_ cg: CGImage) -> (blurred: NSImage?, tone: CoverTone?, scrim: Double) {
        let b = CoverBlur.blurred(cg)
        return (b.map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) },
                CoverTone.from(cg),
                b.map(CoverBlur.scrim) ?? 0.9)
    }

    // Lille cache pr. release, så samme plade ikke sløres og analyseres igen ved hvert
    // skift (plade-detalje, Find og "Hvad skal jeg høre?" deler den).
    @MainActor private static var cache: [Int: CoverLook] = [:]
    @MainActor private static var order: [Int] = []

    @MainActor static func cached(_ releaseID: Int) -> CoverLook? { cache[releaseID] }

    /// Henter coveret og laver slør/tone/dæmpning uden for main thread.
    @MainActor static func load(for release: Release) async -> CoverLook? {
        if let hit = cache[release.id] { return hit }
        guard let url = release.coverURL ?? release.thumbURL,
              let img = await CoverCache.shared.image(releaseID: release.id, url: url, large: true),
              !Task.isCancelled,
              let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let parts = await Task.detached(priority: .userInitiated) { derive(cg) }.value
        let look = CoverLook(image: img, blurred: parts.blurred, tone: parts.tone, scrim: parts.scrim)
        cache[release.id] = look
        order.append(release.id)
        if order.count > 40 { cache[order.removeFirst()] = nil }
        return look
    }
}

/// Bagerste lag: sløret cover over pladens farveflade, dæmpet med pladens egen tone
/// netop så meget, at hvid tekst står tydeligt. Uden cover (eller med
/// "Reducér gennemsigtighed") kun den rolige farveflade.
struct FindBackdrop: View {
    let look: CoverLook?
    let tone: CoverTone
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        // Lys tilstand: coveret anes svagt bag en lys, tonet flade (mørk tekst ovenpå).
        // Mørk tilstand: dæmpning efter coverets lysstyrke (se `CoverBlur.scrim`).
        let veil = colorScheme == .dark ? (look?.scrim ?? 0.9) : 0.86
        // Nyt cover/ny tone krydsfader i stedet for at hoppe.
        let key = look.map { ObjectIdentifier($0.image) }
        ZStack {
            tone.base
            if let look, let blurred = look.blurred, !reduceTransparency {
                ZStack {
                    Image(nsImage: blurred)
                        .resizable()
                        .scaledToFill()
                    tone.base.opacity(veil)
                }
                .id(key)
                .transition(.opacity)
            }
        }
        .animation(Motion.backdrop(reduceMotion), value: key)
        .animation(Motion.backdrop(reduceMotion), value: tone)
        .clipped()
        .accessibilityHidden(true)
    }
}

private struct FindHeader: View {
    let item: RecordItem
    let image: NSImage?
    let tone: CoverTone
    var eyebrow = "Find"

    var body: some View {
        HStack(alignment: .center, spacing: Spacing.m) {
            FindCoverArt(release: item.release, image: image, tone: tone, size: 88)
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Eyebrow(eyebrow)
                    .contentTransition(.opacity)
                Text(item.artist).font(.title2).foregroundStyle(Ink.secondary)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                Text(item.title).font(Typo.display).lineLimit(2).minimumScaleFactor(0.6)
                    .fixedSize(horizontal: false, vertical: true)
                    .layoutPriority(1)
                PressingLines(item: item)
            }
        }
    }
}

/// Selskab, katalognr. og år på én linje og formatet på den næste, i stedet for én lang linje med prikker.
struct PressingLines: View {
    let item: RecordItem
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !item.pressingLine.isEmpty { Text(item.pressingLine) }
            if let f = item.release.format, !f.isEmpty { Text(f).foregroundStyle(Ink.tertiary) }
        }
        .font(.callout).foregroundStyle(Ink.secondary).lineLimit(1)
    }
}

/// Stort cover i toppen. Uden billede: en flade i pladens tone med et pladesymbol.
struct FindCoverArt: View {
    let release: Release
    let image: NSImage?
    let tone: CoverTone
    let size: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.coverLarge, style: .continuous)
        ZStack {
            shape.fill(tone.solidPanel)
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                SleevePlaceholder(release: release, size: size)
            }
        }
        .frame(width: size, height: size)
        .clipShape(shape)
        .modifier(CoverShadow())
        .accessibilityHidden(true)
    }
}

private struct FindPlacement: View {
    @Environment(AppModel.self) private var model
    let copyID: Int64
    let item: RecordItem
    let tone: CoverTone
    /// "Sæt tilbage"-guiden: teksterne handler om at sætte pladen ind, ikke om at finde den.
    var putBack = false

    var body: some View {
        let lib = model.library
        if let loc = lib.location(of: copyID),
           let adv = putBack ? lib.returnAdvice(for: copyID) : lib.referenceAdvice(for: copyID),
           let n = lib.neighbors(of: copyID) {
            // Står pladen ikke i reolen, er navigationen kun til orientering: nedtonet
            // og med en overskrift, der siger det. I guiden er den hovedsagen.
            let away = !item.copy.status.isOnShelf
            let position = n.position ?? 1
            VStack(alignment: .leading, spacing: Spacing.l) {
                LocationPanel(location: loc, position: position, count: n.sectionCount,
                              title: putBack ? "Sæt den her" : (away ? "Her plejer den at stå" : "Gå til"),
                              hint: putBack ? adv.placementHint
                                  : "\(away ? "Plads" : "Nr.") \(position) af \(n.sectionCount) fra venstre",
                              tone: tone)
                HStack(alignment: .top, spacing: Spacing.l) {
                    ReferenceBlock(title: "Start ved", ref: adv.primary)
                    if let s = adv.secondary {
                        ReferenceBlock(title: "Så", ref: s)
                    }
                }
                FindHints(advice: adv, neighbors: n)
            }
            .opacity(away && !putBack ? 0.55 : 1)
        } else {
            Label("Pladen har endnu ingen fysisk placering.", systemImage: "questionmark.square.dashed")
                .font(.title3)
                .padding(Spacing.l)
                .frame(maxWidth: .infinity, alignment: .leading)
                .modifier(GlassPanel(tone: tone))
        }
    }
}

/// Den fremhævede glasblok: reol, sektion og plads i sektionen.
private struct LocationPanel: View {
    let location: Location
    let position: Int
    let count: Int
    let title: String
    /// "Plade 7 af 15 fra venstre" / "Plads 7 af 15 fra venstre".
    let hint: String
    let tone: CoverTone

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Eyebrow(title)
                .contentTransition(.opacity)
            PlacementLine(location: location, tone: tone)
            ShelfSpines(position: position, count: count, accent: DividerColors(location: location, tone: tone).fill)
            PlacementCount(text: hint, percent: Library.percentHint(position: position, count: count))
        }
        .padding(Spacing.panelInset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(GlassPanel(tone: tone))
    }
}

/// Sektionen tegnet som pladerygge set forfra: én streg pr. plade, målet fremhævet.
/// Ved meget store sektioner falder den tilbage til en jævn linje med markør.
struct ShelfSpines: View {
    let position: Int
    let count: Int
    let accent: Color

    var body: some View {
        Canvas { ctx, size in
            let n = max(count, 1)
            let idx = min(max(position - 1, 0), n - 1)
            let slot = size.width / CGFloat(n)
            if slot >= 3 {
                // Rygge i forskellig tykkelse og en anelse forskellig højde, som rigtige plader i en kasse.
                // Fast mønster ud fra pladsen, så samme sektion altid ser ens ud.
                let maxW = min(max(slot * 0.8, 2), 14)
                for i in 0..<n {
                    let r = Double((i &* 2654435761) % 1000) / 1000
                    let isTarget = i == idx
                    let w = isTarget ? maxW : maxW * (0.45 + 0.55 * r)
                    let h: CGFloat = isTarget ? size.height : size.height * (0.72 + 0.16 * (1 - r))
                    let x = slot * (CGFloat(i) + 0.5) - w / 2
                    let rect = CGRect(x: x, y: size.height - h, width: w, height: h)
                    ctx.fill(Path(roundedRect: rect, cornerRadius: 1),
                             with: .color(isTarget ? accent : Ink.faint))
                }
            } else {
                let track = CGRect(x: 0, y: size.height - 6, width: size.width, height: 6)
                ctx.fill(Path(roundedRect: track, cornerRadius: 3), with: .color(Ink.faint))
                let x = n > 1 ? CGFloat(idx) / CGFloat(n - 1) * (size.width - 6) : 0
                ctx.fill(Path(roundedRect: CGRect(x: x, y: 0, width: 6, height: size.height), cornerRadius: 2),
                         with: .color(accent))
            }
        }
        .frame(height: 30)
        .help("Pladens plads i sektionen, set fra venstre")
        .accessibilityLabel("Plade \(position) af \(count) i sektionen")
    }
}

private struct FindHints: View {
    let advice: Library.ReferenceAdvice
    let neighbors: Library.Neighbors

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            if let hint = advice.artistBlockHint {
                Label(hint, systemImage: "rectangle.stack")
            }
            // Kun det, referenceteksterne ikke allerede siger: hvad der står på den anden side af kanten.
            if let edge = advice.sectionEdgeHint {
                Label(edge, systemImage: neighbors.reachedSectionEnd ? "arrow.right.to.line" : "arrow.left.to.line")
            }
        }
        .font(.callout)
        .foregroundStyle(Ink.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct FindActions: View {
    enum Mode: Equatable {
        /// Pladen står i reolen: "Fundet".
        case found
        /// Pladen står ikke i reolen – så giver "Fundet" ikke mening; knappen hedder "OK".
        /// Har den en plads, kan man gå direkte til "Sæt tilbage"-guiden.
        case away(canPutBack: Bool)
        /// "Sæt tilbage"-guiden: "Sat på plads" registrerer pladen som hjemme.
        case putBack
    }
    /// Efter "Fundet": hvad der sker med pladen nu (samme valg på Windows, FindOverlay.cs).
    enum FoundChoice { case listening, wall, lent, stored, stays }

    let mode: Mode
    let dismiss: () -> Void
    let found: (FoundChoice) -> Void
    let startPutBack: () -> Void
    let confirmPutBack: () -> Void

    var body: some View {
        GlassEffectContainer(spacing: Spacing.s) {
            HStack(spacing: Spacing.s) {
                Spacer()
                    .confirmationDialog("Hvad sker der med pladen nu?", isPresented: $askFound, titleVisibility: .visible) {
                        Button("Jeg lytter til den") { found(.listening) }
                        Button("Den kommer på væggen") { found(.wall) }
                        Button("Jeg låner den ud …") { found(.lent) }
                        Button("Den skal et andet sted hen …") { found(.stored) }
                        Button("Den bliver i reolen") { found(.stays) }
                        Button("Annullér", role: .cancel) {}
                    } message: {
                        Text("\"Jeg lytter til den\" registrerer pladen som spillet og lægger den under Ude af reolen, til du sætter den på plads.")
                    }
                switch mode {
                case .found: foundButtons
                case .away(let canPutBack): awayButtons(canPutBack)
                case .putBack: putBackButtons
                }
            }
        }
        .controlSize(.large)
    }

    /// Usynlig: giver Esc som genvej til at lukke arket.
    private var hiddenClose: some View {
        Button("Luk", action: dismiss)
            .keyboardShortcut(.cancelAction)
            .opacity(0)
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
    }

    @State private var askFound = false

    @ViewBuilder private var foundButtons: some View {
        hiddenClose
        Button { askFound = true } label: {
            Label("Fundet", systemImage: "checkmark").padding(.horizontal, Spacing.xs)
        }
        .keyboardShortcut(.defaultAction)
        .buttonStyle(.stagePrimary)
    }

    @ViewBuilder private func awayButtons(_ canPutBack: Bool) -> some View {
        hiddenClose
        if canPutBack {
            Button(action: startPutBack) {
                Label("Sæt den tilbage nu", systemImage: "arrow.uturn.backward")
            }
            .buttonStyle(.stageSecondary)
            .help("Vis præcis, hvor pladen skal stå, når du sætter den tilbage")
        }
        Button(action: dismiss) {
            Text("OK").padding(.horizontal, Spacing.s)
        }
        .keyboardShortcut(.defaultAction)
        .buttonStyle(.stagePrimary)
    }

    @ViewBuilder private var putBackButtons: some View {
        Button("Annullér", action: dismiss)
            .keyboardShortcut(.cancelAction)
            .buttonStyle(.stageSecondary)
            .help("Luk uden at ændre noget (esc)")
        Button(action: confirmPutBack) {
            Label("Sat på plads", systemImage: "checkmark").padding(.horizontal, Spacing.xs)
        }
        .keyboardShortcut(.defaultAction)
        .buttonStyle(.stagePrimary)
        .help("Registrér pladen som på plads i reolen (↩)")
    }
}

/// Tydelig besked øverst på Find, når pladen ikke står i reolen.
private struct AwayBanner: View {
    let text: String
    let symbol: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
            Image(systemName: symbol)
                .foregroundStyle(Ink.warning)
                .accessibilityHidden(true)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.title3.weight(.semibold))
        .foregroundStyle(Ink.primary)
        .padding(.horizontal, Spacing.m)
        .padding(.vertical, Spacing.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Ink.warning.opacity(0.18), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Ink.warning.opacity(0.6), lineWidth: 1))
        .accessibilityElement(children: .combine)
    }
}

/// Lille overskrift ("Gå til", "Start ved") i almindelige bogstaver.
struct Eyebrow: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(Typo.eyebrow)
            .foregroundStyle(Ink.secondary)
            .accessibilityAddTraits(.isHeader)
    }
}

struct ReferenceBlock: View {
    let title: String
    let ref: Library.Reference

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Eyebrow(title)
            HStack(spacing: Spacing.s) {
                if let it = ref.item {
                    CoverView(release: it.release, size: 48).modifier(CoverShadow())
                    VStack(alignment: .leading, spacing: 2) {
                        Text(it.artist).font(.callout).foregroundStyle(Ink.secondary)
                            .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                        Text(it.title).font(.title3.weight(.bold)).lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    Text(ref.side == .sectionStart ? "Sektionens venstre kant" : "Sektionens højre kant")
                        .font(.title3.weight(.bold))
                }
            }
            // Ingen pil: retningen står entydigt i teksten, set fra målpladen
            // ("… står lige til venstre for din plade"). En pil alene var tvetydig.
            Text(ref.reason)
                .font(.callout)
                .foregroundStyle(Ink.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Flyt plade

struct MoveSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let copyID: Int64

    enum Mode: Hashable { case suggested, start, end, after }
    @ViewState private var locationID: Int64 = 0
    @ViewState private var mode: Mode = .suggested
    @ViewState private var afterID: Int64?

    private var sectionIDs: [Int64] { (model.library.sections[locationID] ?? []).filter { $0 != copyID } }

    private var targetIndex: Int {
        switch mode {
        case .suggested:
            return model.library.suggestPlacement(for: copyID, rules: model.rules, restrictTo: locationID)?.index ?? sectionIDs.count
        case .start: return 0
        case .end: return sectionIDs.count
        case .after: return afterID.flatMap { sectionIDs.firstIndex(of: $0) }.map { $0 + 1 } ?? sectionIDs.count
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            if let it = model.library.item(copyID) {
                Text("Flyt \(it.medium.singular)").font(.title2.weight(.bold))
                Text(it.fullName).font(.headline)
                if let from = model.library.location(of: copyID), let pos = model.library.neighbors(of: copyID)?.position {
                    // Fysisk nummer, som i sektionslisten (plader, der er ude, tæller ikke med).
                    Text(model.isAway(copyID)
                         ? "Hører til: \(from.name), plads \(pos) fra venstre (står ikke i reolen nu)"
                         : "Står nu: \(from.name), \(from.medium.singular) \(pos) fra venstre").foregroundStyle(.secondary)
                } else {
                    Text("Står nu: ikke placeret i reolen").foregroundStyle(.secondary)
                }

                Form {
                    Picker("Til sektion", selection: $locationID) {
                        ForEach(model.library.locations) { loc in
                            Text(loc.name).tag(loc.id)
                        }
                    }
                    Picker("Placering", selection: $mode) {
                        Text("Sorteret plads i sektionen (foreslået)").tag(Mode.suggested)
                        Text("Først i sektionen").tag(Mode.start)
                        Text("Sidst i sektionen").tag(Mode.end)
                        Text("Lige efter en bestemt plade…").tag(Mode.after)
                    }
                    .pickerStyle(.radioGroup)
                    if mode == .after {
                        Picker("Efter", selection: $afterID) {
                            ForEach(sectionIDs, id: \.self) { id in
                                Text(model.library.item(id)?.fullName ?? "?").tag(Int64?.some(id))
                            }
                        }
                    }
                }

                let i = targetIndex
                let before = i > 0 ? sectionIDs[i - 1] : nil
                let after = i < sectionIDs.count ? sectionIDs[i] : nil
                GroupBox("Pladen kommer til at stå mellem") {
                    Grid(alignment: .leading, horizontalSpacing: Spacing.s, verticalSpacing: Spacing.xxs) {
                        GridRow {
                            Text("Til venstre").foregroundStyle(.secondary)
                            Text(before.flatMap { model.library.item($0)?.fullName } ?? "sektionens venstre kant")
                        }
                        GridRow {
                            Text("Din plade").foregroundStyle(.secondary)
                            Text(it.title).fontWeight(.bold)
                        }
                        GridRow {
                            Text("Til højre").foregroundStyle(.secondary)
                            Text(after.flatMap { model.library.item($0)?.fullName } ?? "sektionens højre kant")
                        }
                    }
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Spacing.xxs)
                }
            }
            Spacer(minLength: 0)
            if model.library.locationOfCopy[copyID] != nil {
                Text("“Fjern fra reolen” sletter kun pladens plads – naboerne rykker sammen. Pladen findes stadig i samlingen og kan placeres igen fra “Nye plader” i sidepanelet.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if model.library.locationOfCopy[copyID] != nil {
                    Button("Fjern fra reolen", role: .destructive) {
                        model.unplace(copyID)
                        dismiss()
                    }
                    .help("Pladen mister sin plads i reolen, men bliver i samlingen")
                }
                Spacer()
                Button("Annullér") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Flyt") {
                    model.move(copyID, to: locationID, index: targetIndex)
                    dismiss()
                }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
                .disabled((mode == .after && afterID == nil) || model.library.location(locationID) == nil)
            }
        }
        .padding(Spacing.l)
        .frame(width: 560, height: 560)
        .onAppear {
            locationID = model.library.locationOfCopy[copyID]
                ?? model.library.suggestPlacement(for: copyID, rules: model.rules)?.locationID
                ?? model.library.locations.first?.id ?? 0
        }
        .onChange(of: locationID) { afterID = nil }
    }
}

// MARK: - Kontroller reol

struct CheckShelfView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let locationID: Int64

    enum Verdict { case ok, elsewhere, missing, unknown }
    @ViewState private var ids: [Int64] = []
    @ViewState private var index = 0
    @ViewState private var verdicts: [Int64: Verdict] = [:]
    /// Plader fra "Står et andet sted", der er flyttet herfra (vises med flueben).
    @ViewState private var moved: Set<Int64> = []
    /// Flyt-arket åbnes oven på kontrollen, så svarene ikke går tabt.
    @ViewState private var moveID: Int64?
    /// Pladens plads, da Flyt-arket blev åbnet (så vi kan se, om den faktisk blev flyttet).
    @ViewState private var placeBeforeMove: [Int?] = []
    @ViewState private var confirmClose = false

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            HStack {
                Text("Kontroller \(model.library.location(locationID)?.name ?? "")").font(.title2.weight(.bold))
                Spacer()
                Text("\(min(index + 1, ids.count)) / \(ids.count)").monospacedDigit().foregroundStyle(.secondary)
            }
            ProgressView(value: Double(index), total: Double(max(ids.count, 1)))

            if index < ids.count, let it = model.library.item(ids[index]) {
                CheckStep(ids: ids, index: index, item: it, answer: answer, back: { if index > 0 { index -= 1 } })
            } else {
                summary
            }
        }
        .padding(Spacing.l)
        .frame(width: 620, height: 560)
        // Kun plader, der står i reolen: plader på væggen, udlånte osv. er ikke på hylden
        // og tæller ikke med i den fysiske rækkefølge.
        .onAppear { ids = (model.library.sections[locationID] ?? []).filter { !model.isAway($0) } }
        .sheet(item: Binding(get: { moveID.map(IDBox.init) }, set: { moveID = $0?.id })) { box in
            MoveSheet(copyID: box.id)
                .onDisappear {
                    if place(box.id) != placeBeforeMove { moved.insert(box.id) }
                }
        }
    }

    private func place(_ id: Int64) -> [Int?] {
        [model.library.locationOfCopy[id].map(Int.init), model.library.indexInSection[id]]
    }

    private func answer(_ v: Verdict) {
        // Hurtige/gentagne tastetryk kan nå at komme, før knapperne forsvinder.
        guard ids.indices.contains(index) else { return }
        verdicts[ids[index]] = v
        index += 1
    }

    /// Svar, der går tabt, hvis man lukker uden at gemme.
    private var hasUnsavedAnswers: Bool {
        verdicts.values.contains { $0 == .missing || $0 == .elsewhere }
    }

    private var summary: some View {
        let elsewhere = ids.filter { verdicts[$0] == .elsewhere }
        let missing = ids.filter { verdicts[$0] == .missing }
        let unknown = ids.filter { verdicts[$0] == .unknown }
        let ok = ids.filter { verdicts[$0] == .ok }.count
        return VStack(alignment: .leading, spacing: Spacing.s) {
            Text("Kontrol færdig").font(.title3.weight(.bold))
            if ids.isEmpty {
                Text("Sektionen er tom – der er ingen plader at kontrollere.").foregroundStyle(.secondary)
            }
            HStack(spacing: Spacing.m) {
                Label("\(ok) står rigtigt", systemImage: "checkmark.circle")
                Label("\(elsewhere.count) står et andet sted", systemImage: "exclamationmark.triangle")
                Label("\(missing.count) mangler", systemImage: CopyStatus.missing.symbol)
                Label("\(unknown.count) ved ikke", systemImage: "questionmark.circle")
            }
            .font(.callout)
            List {
                if !elsewhere.isEmpty {
                    Section("Står et andet sted – flyt dem her, eller sæt dem på plads i reolen") {
                        ForEach(elsewhere, id: \.self) { id in
                            HStack {
                                Text(model.library.item(id)?.fullName ?? "").lineLimit(1)
                                Spacer()
                                if moved.contains(id) {
                                    Label("Flyttet", systemImage: "checkmark").foregroundStyle(.secondary)
                                } else {
                                    Button("Flyt…") { placeBeforeMove = place(id); moveID = id }
                                }
                            }
                        }
                    }
                }
                if !missing.isEmpty {
                    Section("Mangler – markeres som “Mangler” (appen husker pladens plads)") {
                        ForEach(missing, id: \.self) { id in Text(model.library.item(id)?.fullName ?? "").lineLimit(1) }
                    }
                }
                if !unknown.isEmpty {
                    Section("Ved ikke – ingen ændring") {
                        ForEach(unknown, id: \.self) { id in
                            Text(model.library.item(id)?.fullName ?? "").lineLimit(1).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            HStack {
                Button {
                    index = max(ids.count - 1, 0)
                } label: {
                    Label("Tilbage", systemImage: "chevron.left")
                }
                .keyboardShortcut(.leftArrow, modifiers: [])
                .disabled(ids.isEmpty)
                Spacer()
                Button("Luk") {
                    if hasUnsavedAnswers { confirmClose = true } else { dismiss() }
                }
                .keyboardShortcut(.cancelAction)
                Button(missing.isEmpty ? "Færdig" : "Markér manglende og luk") {
                    for id in missing { model.setStatus(id, .missing) }
                    dismiss()
                }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
            }
            .confirmationDialog("Luk uden at gemme?", isPresented: $confirmClose) {
                Button("Luk og glem svarene", role: .destructive) { dismiss() }
                Button("Bliv i kontrollen", role: .cancel) {}
            } message: {
                Text(missing.isEmpty
                     ? "Dine svar fra kontrollen bliver ikke gemt."
                     : "\(missing.count) \(missing.count == 1 ? "plade" : "plader") bliver ikke markeret som “Mangler”, og dine svar bliver ikke gemt.")
            }
        }
    }
}

/// Ét trin i kontrollen: den forventede plade med naboerne før og efter.
private struct CheckStep: View {
    @Environment(AppModel.self) private var model
    let ids: [Int64]
    let index: Int
    let item: RecordItem
    let answer: (CheckShelfView.Verdict) -> Void
    let back: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            Text("Forventet næste plade i reolen:").foregroundStyle(.secondary)
            if index > 0, let prev = model.library.item(ids[index - 1]) {
                NeighborHint(label: "Efter", item: prev)
            }
            HStack(spacing: Spacing.m) {
                CoverView(release: item.release, size: 96)
                    .modifier(CoverShadow())
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    Text(item.artist).font(.title3).lineLimit(2)
                    Text(item.title).font(.title.weight(.bold)).lineLimit(2).layoutPriority(1)
                    Text(item.detailLine).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .padding(.vertical, Spacing.xs)
            if index + 1 < ids.count, let nx = model.library.item(ids[index + 1]) {
                NeighborHint(label: "Derefter", item: nx)
            }
            Spacer(minLength: 0)
            HStack {
                Button { answer(.ok) } label: { Label("Står rigtigt", systemImage: "checkmark.circle") }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
                Button { answer(.elsewhere) } label: { Label("Står et andet sted", systemImage: "exclamationmark.triangle") }
                    .keyboardShortcut("s", modifiers: [])
                Button { answer(.missing) } label: { Label("Mangler", systemImage: CopyStatus.missing.symbol) }
                    .keyboardShortcut("m", modifiers: [])
                Button { answer(.unknown) } label: { Label("Ved ikke", systemImage: "questionmark.circle") }
                    .keyboardShortcut(.space, modifiers: [])
                Spacer()
                Button("Tilbage", action: back).disabled(index == 0)
                    .keyboardShortcut(.leftArrow, modifiers: [])
            }
            .controlSize(.large)
            Text("Genveje: ↩ rigtigt · S andet sted · M mangler · mellemrum ved ikke · ← tilbage")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// "Efter: ABBA – Arrival" – læsbar sekundær tekst (ikke den svage tertiære).
private struct NeighborHint: View {
    let label: String
    let item: RecordItem

    var body: some View {
        Text("\(Text("\(label): ").foregroundStyle(.secondary))\(Text(item.fullName).foregroundStyle(.primary))")
            .font(.callout)
            .lineLimit(1)
    }
}

// MARK: - Sync-rapport

struct SyncReportView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let r = model.lastReport ?? ShelfStore.SyncReport()
        VStack(alignment: .leading, spacing: Spacing.m) {
            Text("Synkronisering færdig").font(.title2.weight(.bold))
            Text("\(r.total) plader i din Discogs Collection.").foregroundStyle(.secondary)
            if r.newCopies.isEmpty && r.removedCopies.isEmpty && r.updatedReleases == 0 && r.returnedCopies.isEmpty {
                Label("Ingen ændringer.", systemImage: "checkmark.circle")
            }
            if !r.newCopies.isEmpty {
                Label {
                    Text(r.newCopies.count == 1 ? "1 ny plade venter på en plads" : "\(r.newCopies.count) nye plader venter på en plads").fontWeight(.semibold)
                } icon: {
                    Image(systemName: "sparkles").foregroundStyle(.orange)
                }
                ForEach(r.newCopies.prefix(6), id: \.self) { id in
                    if let s = model.library.suggestPlacement(for: id, rules: model.rules), let it = model.library.item(id) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(it.fullName).fontWeight(.medium)
                            Text("mellem \(s.before.flatMap { model.library.item($0)?.fullName } ?? "start") og \(s.after.flatMap { model.library.item($0)?.fullName } ?? "slut")")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            if !r.removedCopies.isEmpty {
                Label {
                    Text("\(r.removedCopies.count) plader er fjernet fra Discogs. Deres fysiske placering er bevaret – se “Fjernet fra Discogs”.")
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
            }
            if !r.returnedCopies.isEmpty {
                Label("\(r.returnedCopies.count) plader er tilbage i Discogs Collection.", systemImage: "arrow.uturn.backward")
            }
            if r.updatedReleases > 0 {
                Label("Oplysninger fra Discogs er opdateret for \(r.updatedReleases) plader. Ingen plader er flyttet.", systemImage: "pencil")
            }
            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button("OK") { dismiss() }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Spacing.l)
        .frame(width: 520)
        .frame(minHeight: 260)
    }
}

// MARK: - Historik

struct HistoryView: View {
    @Environment(AppModel.self) private var model
    @ViewState private var entries: [HistoryEntry] = []

    var body: some View {
        let undo = HistoryUndo(entries)
        List(entries) { e in
            HistoryRow(entry: e, canUndo: undo.undoable.contains(e.id), wasUndone: undo.undone.contains(e.id)) {
                model.undo(e)
                load()
            }
        }
        .listStyle(.inset)
        .navigationTitle("Historik")
        .onAppear(perform: load)
        .onChange(of: model.library.globalOrder) { load() }
    }

    private func load() { entries = (try? model.store.history()) ?? [] }
}

/// Hvilke poster kan fortrydes? Kun den seneste flytning af hver plade – og kun hvis
/// ingen senere flytning (eller en ny opdeling af reolen) har overhalet den. En flytning,
/// der selv er en fortrydelse af den forrige, kan ikke fortrydes igen.
struct HistoryUndo {
    private(set) var undoable: Set<Int64> = []
    private(set) var undone: Set<Int64> = []

    private static let placementKinds: Set<HistoryEntry.Kind> = [.moved, .placed, .unplaced, .deleted]

    init(_ entries: [HistoryEntry]) {   // nyeste først
        var seen: Set<Int64> = []
        for (i, e) in entries.enumerated() {
            if e.kind == .layoutCreated { break }   // alt før en ny opdeling er overhalet
            guard Self.placementKinds.contains(e.kind), let copy = e.copyID, !seen.contains(copy) else { continue }
            seen.insert(copy)
            guard e.kind == .moved, e.fromLocationID != nil else { continue }
            let older = entries[(i + 1)...].prefix { $0.kind != .layoutCreated }
                .first { $0.copyID == copy && Self.placementKinds.contains($0.kind) }
            if let o = older, o.kind == .moved || o.kind == .placed,
               e.toLocationID == o.fromLocationID, e.toPosition == o.fromPosition, e.fromLocationID == o.toLocationID {
                undone.insert(o.id)       // e er en fortrydelse af o
            } else {
                undoable.insert(e.id)
            }
        }
    }
}

private struct HistoryRow: View {
    @Environment(AppModel.self) private var model
    let entry: HistoryEntry
    let canUndo: Bool
    let wasUndone: Bool
    let undo: () -> Void

    var body: some View {
        let text = HistoryText(entry: entry, library: model.library)
        HStack(alignment: .top, spacing: Spacing.s) {
            Image(systemName: text.symbol)
                .foregroundStyle(.secondary)
                .frame(width: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(text.title).fontWeight(.medium).lineLimit(2)
                if let detail = text.detail {
                    Text(detail).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(DanishDate.dateTime(entry.at)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: Spacing.s)
            if canUndo {
                Button("Fortryd", action: undo)
                    .controlSize(.small)
                    .help("Sæt pladen tilbage, hvor den stod før")
            } else if wasUndone {
                Text("Fortrudt").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

/// Historikpostens tekst i appens almindelige format ("Reol 1 · Sektion A, plade 3"),
/// uden emoji (ældre poster i databasen kan indeholde 🏠📦👤❓).
struct HistoryText {
    let title: String
    let detail: String?
    let symbol: String

    init(entry e: HistoryEntry, library: Library) {
        let summary = Self.clean(e.summary)
        let name = e.copyID.flatMap { library.item($0)?.fullName }
            ?? Self.recordName(in: summary)

        func place(_ loc: Int64?, _ pos: Int?) -> String? {
            guard let loc, let l = library.location(loc) else { return nil }
            return pos.map { "\(l.name), \(l.medium.singular) \($0)" } ?? l.name
        }
        let from = place(e.fromLocationID, e.fromPosition), to = place(e.toLocationID, e.toPosition)

        switch e.kind {
        case .moved where from != nil && to != nil:
            (title, detail, symbol) = (name ?? summary, "Flyttet fra \(from!) til \(to!)", "arrow.left.arrow.right")
        case .placed where to != nil:
            (title, detail, symbol) = (name ?? summary, "Placeret i \(to!)", "tray.and.arrow.down")
        case .unplaced where from != nil:
            (title, detail, symbol) = (name ?? summary, "Fjernet fra \(from!)", "tray.and.arrow.up")
        case .statusChanged:
            let status = CopyStatus.allCases.first { e.summary.contains($0.emoji) }
                ?? CopyStatus.allCases.first { summary.contains(": \($0.label)") }
                ?? CopyStatus.allCases.first { summary.contains("“\($0.label)”") }
            (title, detail, symbol) = Self.split(summary, name: name, symbol: status?.symbol ?? "tag")
        default:
            let s: String
            switch e.kind {
            case .moved: s = "arrow.left.arrow.right"
            case .placed: s = "tray.and.arrow.down"
            case .unplaced: s = "tray.and.arrow.up"
            case .deleted: s = "trash"
            case .addedFromDiscogs: s = "sparkles"
            case .removedFromDiscogs: s = "exclamationmark.triangle"
            case .metadataUpdated: s = "arrow.triangle.2.circlepath"
            case .layoutCreated: s = "books.vertical"
            case .statusChanged: s = "tag"
            }
            (title, detail, symbol) = Self.split(summary, name: name, symbol: s)
        }
    }

    /// "Ny i Discogs: A – T" → titel "A – T", detalje "Ny i Discogs".
    private static func split(_ summary: String, name: String?, symbol: String) -> (String, String?, String) {
        guard let name, let r = summary.range(of: name) else { return (summary, nil, symbol) }
        var rest = summary
        rest.removeSubrange(r)
        rest = rest.trimmingCharacters(in: CharacterSet(charactersIn: ":– ").union(.whitespaces))
        guard !rest.isEmpty else { return (name, nil, symbol) }
        return (name, rest.prefix(1).uppercased() + rest.dropFirst(), symbol)
    }

    /// "Kunstner – Titel" i starten af en ældre tekst (før ":" eller " flyttet"/" placeret"/…).
    private static func recordName(in summary: String) -> String? {
        for marker in [":", " flyttet", " placeret", " fjernet", " slettet", " er ikke længere"] {
            if let r = summary.range(of: marker), summary[..<r.lowerBound].contains(" – ") {
                return String(summary[..<r.lowerBound])
            }
        }
        return nil
    }

    /// Fjerner emoji og dobbelte mellemrum.
    static func clean(_ s: String) -> String {
        let scalars = s.unicodeScalars.filter { !($0.properties.isEmojiPresentation || $0.properties.isEmoji && $0.value > 0x2000 && $0 != "–") }
        return String(String.UnicodeScalarView(scalars))
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }
}
