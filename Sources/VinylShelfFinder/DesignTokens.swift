import SwiftUI
import AppKit
import CoreImage
import VinylCore

// MARK: - Design-tokens (retning: moderne Liquid Glass)
//
// Ét fast afstandsskema, én skygge, få radier. Alt visuelt på "Find i reolen"
// henter sine værdier herfra, så afstande og farver er konsekvente.

enum Spacing {
    static let xxs: CGFloat = 4
    static let xs: CGFloat = 8
    static let s: CGFloat = 12
    static let m: CGFloat = 16
    static let l: CGFloat = 24
    static let xl: CGFloat = 32
    /// Indvendig margen i placeringsblokken (glas) – ens på alle pladeskærme.
    static let panelInset: CGFloat = 20
}

enum Radius {
    /// Fremhævede glasflader (placeringsblokken).
    static let panel: CGFloat = 20
    /// Små covers.
    static let coverSmall: CGFloat = 5
    /// Stort cover i toppen.
    static let coverLarge: CGFloat = 8
}

enum Typo {
    /// Små overskrifter på pladeskærmene, i almindelige bogstaver.
    static let eyebrow = Font.callout.weight(.semibold)
    /// Sektionsbogstavet på skillekortets fane: smal og kraftig, som en pladebutiks skillekort.
    static let dividerLetter = Font.system(size: 46, weight: .bold).width(.condensed)
    static let dividerLetterCompact = Font.system(size: 34, weight: .bold).width(.condensed)
    /// Antal og plads ("Nr. 7 af 15 fra venstre") i samme smalle skrift.
    static let count = Font.system(size: 20, weight: .medium).width(.condensed).monospacedDigit()
    /// Pladens titel. Smal som skillekortet i stilene (Indstillinger › Udseende).
    static var display: Font { .system(size: 34, weight: .heavy).width(AppAccent.style.condensedTitles ? .condensed : .standard) }
    static let location = Font.system(size: 26, weight: .semibold).width(.condensed)
    /// Placeringslinjen i en smal kolonne (plade-detaljen).
    static let locationCompact = Font.system(size: 21, weight: .semibold).width(.condensed)
}

/// Korte, bløde animationer. Med "Reducér bevægelse": ingen bevægelse – højst en kort fade.
enum Motion {
    /// Til ændringer, der flytter ting (lister, kort). `nil` = hårdt skift ved reduceret bevægelse.
    static func move(_ reduceMotion: Bool) -> Animation? { reduceMotion ? nil : .smooth(duration: 0.3) }
    /// Til krydsfade af farver og billeder. Fade er tilladt ved reduceret bevægelse, bare kortere.
    static func fade(_ reduceMotion: Bool) -> Animation { reduceMotion ? .easeInOut(duration: 0.15) : .smooth(duration: 0.35) }

    /// Tilstandsskift (tom tilstand ↔ liste, fejl, færdige trin).
    static func state(_ reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeInOut(duration: 0.15) : .smooth(duration: 0.28)
    }

    /// Pladeskærmenes baggrund (farvetone og sløret cover), når pladen skifter: en lang, blød
    /// overgang, så farven glider i stedet for at blinke. Kortere fade ved reduceret bevægelse.
    static func backdrop(_ reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeInOut(duration: 0.2) : .easeInOut(duration: 0.6)
    }

    /// Cover Flow: coverne falder på plads med en let fjedrende bevægelse (som på iPod'en).
    static func coverFlow(_ reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .interpolatingSpring(stiffness: 400, damping: 30)
    }

    /// Rækker, der kommer og går. Ingen animation med Reduce Motion: listen skifter bare.
    static func rows(_ reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .smooth(duration: 0.22)
    }

    /// Tal, der tæller op/ned. Med Reduce Motion skiftes tallet uden rul.
    static func number(_ reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .snappy(duration: 0.25)
    }

    static func numberTransition(_ reduceMotion: Bool) -> ContentTransition {
        reduceMotion ? .identity : .numericText()
    }

    /// Lille ikon, der skifter (fx tal → flueben).
    static func badgeTransition(_ reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .opacity : .scale(scale: 0.6).combined(with: .opacity)
    }
}

/// Den eneste skygge i designet. Bruges kun under covers (de "ligger" på fladen).
struct CoverShadow: ViewModifier {
    func body(content: Content) -> some View {
        content.shadow(color: .black.opacity(0.35), radius: 10, x: 0, y: 4)
    }
}

/// En farve med en lys og en mørk variant, der vælges efter systemets udseende
/// (lys/mørk tilstand). Pladeskærmene følger systemet ligesom resten af appen.
func adaptive(light: NSColor, dark: NSColor) -> Color {
    Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
    })
}

private func hsb(_ h: Double, _ s: Double, _ b: Double, _ a: Double = 1) -> NSColor {
    NSColor(hue: h, saturation: s, brightness: b, alpha: a)
}

/// Tekstfarver på pladeskærmenes scene. Eksplicitte værdier i stedet for `.secondary`,
/// så kontrasten er kendt: mørk tekst på den lyse, tonede flade i lys tilstand, hvid
/// tekst på den mørke flade i mørk tilstand (≥ 4,5:1 for alle tre niveauer).
enum Ink {
    static let primary = adaptive(light: .black.withAlphaComponent(0.87), dark: .white)
    static let secondary = adaptive(light: .black.withAlphaComponent(0.66), dark: .white.withAlphaComponent(0.82))
    static let tertiary = adaptive(light: .black.withAlphaComponent(0.56), dark: .white.withAlphaComponent(0.66))
    /// Svage streger, fx pladeryggene.
    static let faint = adaptive(light: .black.withAlphaComponent(0.2), dark: .white.withAlphaComponent(0.28))
    static let warning = adaptive(light: hsb(0.06, 0.9, 0.6), dark: hsb(0.09, 0.65, 1.0))
}

// MARK: - Farver fra coveret

/// Farvetone for én plade: mørk baggrundsflade + lys accent + mættet knap-tint.
/// Hentes fra coveret, eller – uden cover – deterministisk fra kunstnernavnet,
/// så samme kunstner altid får samme rolige farve.
struct CoverTone: Equatable {
    var hue: Double
    var saturation: Double

    /// Næsten gråt cover (sort, hvidt, gråt): tonen må ikke farves kunstigt op.
    var isNeutral: Bool { saturation < 0.12 }

    /// Baggrundsfladen. Lys tilstand: næsten hvid med et strejf af pladens farve, så
    /// skærmen flugter med resten af appen. Mørk tilstand: mørk og afdæmpet.
    var base: Color {
        adaptive(light: hsb(hue, isNeutral ? 0 : min(saturation, 0.4) * 0.22, 0.97),
                 dark: hsb(hue, min(saturation, 0.45), 0.24))
    }
    /// Uigennemsigtig flade til placeringsblokken, når "Reducér gennemsigtighed" er slået til.
    var solidPanel: Color {
        adaptive(light: hsb(hue, isNeutral ? 0 : min(saturation, 0.4) * 0.35, 0.91),
                 dark: hsb(hue, min(saturation, 0.40), 0.34))
    }
    /// Accent til markører, kanter og hovedknappens flade. Lys tilstand: mørk og mættet
    /// (læsbar på lys flade, hvid tekst ovenpå). Mørk tilstand: lys.
    var accent: Color {
        adaptive(light: hsb(hue, isNeutral ? 0 : min(max(saturation, 0.45), 0.75), 0.42),
                 dark: hsb(hue, isNeutral ? 0 : min(max(saturation, 0.25), 0.50), 0.95))
    }
    /// Kraftigere tint (mørkere end `accent` i lys tilstand).
    var strong: Color {
        adaptive(light: hsb(hue, isNeutral ? 0 : min(max(saturation, 0.5), 0.75), 0.34),
                 dark: hsb(hue, isNeutral ? 0 : min(max(saturation, 0.5), 0.7), 0.45))
    }
    /// Tekst oven på `accent` (hovedknappen): hvid i lys tilstand, mørk i mørk. ≥ 4,5:1.
    var onAccent: Color {
        adaptive(light: .white, dark: hsb(hue, isNeutral ? 0 : 0.55, 0.12))
    }

    /// Rolige nuancer til plader uden cover. Ingen tilfældige farver: valget afhænger
    /// kun af kunstnernavnet. 24 jævnt fordelte nuancer × 2 mætninger = 48 toner, så
    /// forskellige kunstnere sjældent får samme farve.
    private static let fallbackHueSteps: UInt64 = 24
    private static let fallbackSaturations: [Double] = [0.30, 0.42]

    static func fallback(for release: Release) -> CoverTone {
        // FNV-1a – stabil på tværs af kørsler (i modsætning til `hashValue`).
        var h: UInt64 = 0xcbf29ce484222325
        for b in release.artist.lowercased().utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        let hue = Double(h % fallbackHueSteps) / Double(fallbackHueSteps)
        let sat = fallbackSaturations[Int((h / fallbackHueSteps) % UInt64(fallbackSaturations.count))]
        return CoverTone(hue: hue, saturation: sat)
    }

    static func from(_ image: NSImage) -> CoverTone? {
        image.cgImage(forProposedRect: nil, context: nil, hints: nil).flatMap(from)
    }

    /// Nedskalerer coveret til 8×8 og vælger den mest farverige af de 64 pixels
    /// (vægtet mod gennemsnittet), så tonen ikke bliver mudret grå.
    /// Ren CoreGraphics – kan køre uden for main thread.
    static func from(_ cg: CGImage) -> CoverTone? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let n = 8
        var px = [UInt8](repeating: 0, count: n * n * 4)
        let ok: Bool = px.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: n, height: n, bitsPerComponent: 8,
                                      bytesPerRow: n * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.interpolationQuality = .high
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: n, height: n))
            return true
        }
        guard ok else { return nil }

        var best: (score: Double, h: Double, s: Double)? = nil
        var sumR = 0.0, sumG = 0.0, sumB = 0.0
        for i in 0..<(n * n) {
            let r = Double(px[i * 4]) / 255, g = Double(px[i * 4 + 1]) / 255, b = Double(px[i * 4 + 2]) / 255
            sumR += r; sumG += g; sumB += b
            let c = NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
            let s = Double(c.saturationComponent), v = Double(c.brightnessComponent)
            let score = s * (0.3 + v)
            if v > 0.15, best == nil || score > best!.score { best = (score, Double(c.hueComponent), s) }
        }
        let count = Double(n * n)
        let avg = NSColor(srgbRed: sumR / count, green: sumG / count, blue: sumB / count, alpha: 1)
        // Næsten gråt cover → neutral tone i stedet for en tilfældig nuance.
        guard let pick = best, pick.s > 0.12 else {
            return CoverTone(hue: Double(avg.hueComponent), saturation: 0.06)
        }
        return CoverTone(hue: pick.h, saturation: pick.s)
    }
}

// MARK: - Sløret cover (CoreImage)

enum CoverBlur {
    /// Én delt CoreImage-kontekst – at oprette en pr. cover er dyrt.
    private static let context = CIContext(options: [.cacheIntermediates: false])

    /// Slører coveret én gang med CoreImage i stedet for med `.blur()` pr. frame.
    /// Billedet skaleres ned først (sløret alligevel), så det er billigt.
    /// Ren CoreImage – kan køre uden for main thread.
    static func blurred(_ cg: CGImage, radius: Double = 12) -> CGImage? {
        let side = 160.0
        let scale = side / Double(max(cg.width, cg.height))
        let input = CIImage(cgImage: cg)
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .clampedToExtent()
        let extent = CGRect(x: 0, y: 0, width: Double(cg.width) * scale, height: Double(cg.height) * scale)
        let output = input.applyingGaussianBlur(sigma: radius).cropped(to: extent)
        return context.createCGImage(output, from: extent)
    }

    /// Hvor meget det slørede cover skal dæmpes (0…1), så hvid tekst ovenpå altid
    /// har god kontrast: de lyseste 10 % af billedet bringes ned under ~8 % luminans.
    /// Mørke covers dæmpes kun lidt (coveret ses tydeligt), lyse covers meget.
    static func scrim(for cg: CGImage) -> Double {
        let n = 16
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return 0.9 }
        var px = [UInt8](repeating: 0, count: n * n * 4)
        let ok: Bool = px.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: n, height: n, bitsPerComponent: 8,
                                      bytesPerRow: n * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: n, height: n))
            return true
        }
        guard ok else { return 0.9 }
        func lin(_ v: UInt8) -> Double {
            let c = Double(v) / 255
            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        var lums: [Double] = []
        lums.reserveCapacity(n * n)
        for i in 0..<(n * n) {
            lums.append(0.2126 * lin(px[i * 4]) + 0.7152 * lin(px[i * 4 + 1]) + 0.0722 * lin(px[i * 4 + 2]))
        }
        lums.sort()
        let bright = lums[Int(Double(lums.count - 1) * 0.9)]
        // Sammensat luminans ≈ (1 − o)·L + o·L_base; L_base ≈ 0,03 (toneflade).
        let target = 0.08, base = 0.03
        guard bright > target else { return 0.15 }
        return min(max((bright - target) / (bright - base), 0.15), 0.95)
    }
}

// MARK: - Glas

/// Fremhævet flade: Liquid Glass. Med "Reducér gennemsigtighed" bliver den en
/// uigennemsigtig flade i pladens tone (garanteret kontrast).
struct GlassPanel: ViewModifier {
    let tone: CoverTone
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: Radius.panel, style: .continuous)
        if reduceTransparency {
            content.background(tone.solidPanel, in: shape)
        } else {
            content.glassEffect(.regular, in: shape)
        }
    }
}

// MARK: - Pladeskærme (mørk scene med cover)

extension CoverTone {
    /// Cover Flow har hvid baggrund; knappen får appens grønne accent (#1C6E66).
    static let coverFlow = CoverTone(hue: 0.485, saturation: 0.75)
}

private struct CoverToneKey: EnvironmentKey {
    static let defaultValue = CoverTone(hue: 0.6, saturation: 0.1)
}

extension EnvironmentValues {
    /// Farvetonen for den plade, en pladeskærm viser. Sættes af `RecordStage`.
    var coverTone: CoverTone {
        get { self[CoverToneKey.self] }
        set { self[CoverToneKey.self] = newValue }
    }
}

/// Gør en skærm til en "pladeskærm" som Find i reolen: tonet i pladens farve (lys eller
/// mørk efter systemet), med pladens sløret
/// cover (eller en rolig farveflade uden cover) bagved og accent fra coveret.
/// Børn kan læse tonen via `@Environment(\.coverTone)` (fx til `GlassPanel`).
struct RecordStage: ViewModifier {
    let release: Release?
    /// Det udseende, baggrunden viser lige nu. Skiftes pladen, bliver det forrige stående,
    /// indtil det nye er klar, og toner så over i én bevægelse. (Før sprang farven først til en
    /// reservefarve og derefter til coverets farve: to skift i stedet for ét.)
    @ViewState private var shown: CoverLook?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        // Første visning (og snapshots): et cover, der allerede er indlæst, vises med det samme.
        let look = shown ?? release.flatMap { CoverLook.cached($0.id) }
        let tone = look?.tone ?? release.map { CoverTone.fallback(for: $0) } ?? CoverToneKey.defaultValue
        content
            .tint(tone.accent)
            .environment(\.coverTone, tone)
            .background { FindBackdrop(look: look, tone: tone).ignoresSafeArea() }
            // Ingen lys værktøjslinje-flade over den mørke scene (det hvide bånd i toppen).
            .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
            .task(id: release?.id) {
                guard let r = release else { show(nil); return }
                if let hit = CoverLook.cached(r.id) { show(hit); return }
                // Når man bladrer hurtigt (fx Cover Flow), skiftes baggrunden først, når man
                // holder pause, så den ikke blinker gennem hver plade.
                try? await Task.sleep(for: .milliseconds(120))
                guard !Task.isCancelled else { return }
                let look = await CoverLook.load(for: r)
                guard !Task.isCancelled else { return }
                show(look)
            }
    }

    /// Altid med sin egen animation, også når skiftet af plade sker uden animation
    /// (fx mens Cover Flow følger fingrene på trackpad'en).
    private func show(_ look: CoverLook?) {
        guard look.map({ ObjectIdentifier($0.image) }) != shown.map({ ObjectIdentifier($0.image) }) else { return }
        withAnimation(Motion.backdrop(reduceMotion)) { shown = look }
    }
}

extension View {
    func recordStage(_ release: Release?) -> some View { modifier(RecordStage(release: release)) }
}

// MARK: - Status som SF Symbols (erstatter emoji fra VinylCore)

extension CopyStatus {
    var symbol: String {
        switch self {
        case .home: return "house.fill"
        case .wall: return "photo.artframe"
        case .stored: return "shippingbox.fill"
        case .lent: return "person.fill"
        case .missing: return "circle.dashed"
        }
    }
}

extension RecordItem {
    /// Én tydelig sætning, når pladen ikke står i reolen – fx
    /// "Udlånt til min bror Jens – står ikke i reolen". `nil` når pladen står på plads.
    var awayMessage: String? {
        let note = copy.statusNote?.trimmingCharacters(in: .whitespaces)
        let hasNote = !(note ?? "").isEmpty
        switch copy.status {
        case .home: return nil
        case .wall: return "Hænger på væggen – står ikke i reolen"
        case .lent: return hasNote ? "Udlånt til \(note!) – står ikke i reolen" : "Udlånt – står ikke i reolen"
        case .stored: return hasNote ? "Opbevaret andet sted (\(note!)) – står ikke i reolen" : "Opbevaret andet sted – står ikke i reolen"
        case .missing: return "Mangler – står ikke i reolen"
        }
    }
}

// MARK: - Datoer på dansk

enum DanishDate {
    static let locale = Locale(identifier: "da_DK")

    /// "1. okt. 2026 kl. 10.26"
    static func dateTime(_ d: Date) -> String {
        "\(d.formatted(.dateTime.day().month(.abbreviated).year().locale(locale))) kl. \(d.formatted(.dateTime.hour().minute().locale(locale)))"
    }

    /// "for 3 dage siden"
    static func relative(_ d: Date) -> String {
        d.formatted(.relative(presentation: .named).locale(locale))
    }
}

// MARK: - Knapper på den mørke scene

/// Knaphierarki på pladeskærmene. Den vigtigste knap har en lys, uigennemsigtig flade
/// i pladens accentfarve med mørk tekst (tydeligst på den mørke scene). Sekundære knapper
/// er neutrale: tekst i `Ink.primary` på glas – de arver ikke accentfarven, så de aldrig ser
/// vigtigere ud end hovedknappen.
struct StageButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary }
    let kind: Kind

    func makeBody(configuration: Configuration) -> some View {
        StageButtonBody(configuration: configuration, kind: kind)
    }
}

private struct StageButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let kind: StageButtonStyle.Kind
    @Environment(\.coverTone) private var tone
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.controlSize) private var controlSize
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        let shape = Capsule()
        let large = controlSize == .large || controlSize == .extraLarge
        let primary = kind == .primary
        configuration.label
            .font(large ? .body.weight(primary ? .semibold : .medium) : .callout.weight(primary ? .semibold : .medium))
            .foregroundStyle(primary ? tone.onAccent : Ink.primary)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, large ? 14 : 10)
            .padding(.vertical, large ? 8 : 5)
            .frame(minHeight: large ? 34 : 26)
            .background {
                if primary {
                    shape.fill(tone.accent)
                } else if reduceTransparency {
                    shape.fill(tone.solidPanel)
                }
            }
            .overlay { if configuration.isPressed { shape.fill(Color.black.opacity(primary ? 0.14 : 0.2)) } }
            .glassEffect(.regular.interactive(), in: shape)
            .contentShape(shape)
            .opacity(isEnabled ? 1 : 0.45)
    }
}

extension ButtonStyle where Self == StageButtonStyle {
    /// Den vigtigste handling på en pladeskærm (fx "Find i reolen", "Fundet").
    static var stagePrimary: StageButtonStyle { StageButtonStyle(kind: .primary) }
    /// Øvrige handlinger: neutral glasknap med hvid tekst.
    static var stageSecondary: StageButtonStyle { StageButtonStyle(kind: .secondary) }
}
