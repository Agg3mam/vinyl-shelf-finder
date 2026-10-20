import Foundation

/// Placering af covers i Cover Flow (som på en iPod classic). Ren matematik, så den kan tjekkes.
/// `o` er afstanden fra midten i antal plader: 0 = coveret i midten, -1 = lige til venstre osv.
/// `o` må gerne være et kommatal (under en trackpad-bevægelse glider coverne mellem pladserne).
/// Tallene ligger mellem to åbne genskabelser af iPod'ens Cover Flow (iPlayr og ipod-classic-js).
public enum CoverFlowGeometry {
    /// Så mange covers vises på hver side af midten.
    public static let visible = 6
    /// Hvor skråt sidecoverne står (grader om den lodrette akse).
    public static let tilt = 65.0
    /// Perspektiv til `rotation3DEffect` (svagt, så sidecoverne ikke forvrænges).
    public static let perspective = 0.4
    /// Sidecovers' størrelse i forhold til midtercoveret.
    public static let sideScale = 0.9
    /// Spejlingen under coveret: højde (andel af coveret) og synlighed ved kanten.
    public static let reflectionHeight = 0.28
    public static let reflectionOpacity = 0.25
    /// Afstand fra midten til første sidecover og mellem de næste (i forhold til coverets side).
    static let firstGap = 0.62
    static let stackGap = 0.25

    /// Coverets side ud fra den plads, der er. Der skal være plads til spejlingen under coveret,
    /// og det bliver aldrig over 360 pt.
    public static func side(width: Double, height: Double) -> Double {
        max(80, min(height * 0.62, width * 0.36, 360))
    }

    private static func clamped(_ o: Double) -> Double { min(max(o, -1), 1) }

    /// Vandret forskydning fra midten.
    public static func x(_ o: Double, side: Double) -> Double {
        let c = clamped(o)
        return side * (firstGap * c + stackGap * (o - c))
    }

    /// Drejning: midten vender lige frem; siderne vender ind mod midten, så deres yderkant er
    /// nærmest (som væggene i en gang). Med SwiftUI's `rotation3DEffect` om y-aksen flytter en
    /// positiv vinkel højre kant væk, derfor negativ vinkel til højre for midten.
    public static func angle(_ o: Double) -> Double { -tilt * clamped(o) }

    public static func scale(_ o: Double) -> Double { 1 - (1 - sideScale) * abs(clamped(o)) }

    /// Covers tættest på midten ligger øverst.
    public static func zIndex(_ o: Double) -> Double { -abs(o) }

    public static func x(_ d: Int, side: Double) -> Double { x(Double(d), side: side) }
    public static func angle(_ d: Int) -> Double { angle(Double(d)) }
    public static func scale(_ d: Int) -> Double { scale(Double(d)) }
    public static func zIndex(_ d: Int) -> Double { zIndex(Double(d)) }

    /// De plader (indeks), der skal tegnes omkring `center`.
    public static func visibleRange(center: Int, count: Int) -> Range<Int> {
        guard count > 0 else { return 0..<0 }
        let c = min(max(center, 0), count - 1)
        return max(0, c - visible)..<min(count, c + visible + 1)
    }

    /// Glid under en trackpad- eller musebevægelse. `shift` er, hvor langt rækken er skubbet
    /// (i plader, positiv = mod næste plade). Når den passerer en halv plade, skifter midten,
    /// og `shift` rykkes tilsvarende, så intet hopper. I enderne kan man kun skubbe lidt (gummibånd).
    public static func glide(center: Int, shift: Double, count: Int) -> (center: Int, shift: Double) {
        guard count > 0 else { return (0, 0) }
        var c = min(max(center, 0), count - 1), s = shift
        while s > 0.5 && c < count - 1 { s -= 1; c += 1 }
        while s < -0.5 && c > 0 { s += 1; c -= 1 }
        if c == 0 { s = max(s, -0.3) }
        if c == count - 1 { s = min(s, 0.3) }
        return (c, s)
    }

    /// Et kraftigt stryg fortsætter med farten og bremser jævnt op (som at scrolle på iPhone). `position` er midten plus
    /// skub, `velocity` er fingerens fart, når den slipper (plader pr. sekund, positiv = mod næste plade). Giver pladen,
    /// rækken lander på, og hvor længe glidet varer – eller nil, når stryget var for langsomt til at fortsætte.
    public static func fling(from position: Double, velocity: Double, count: Int) -> (target: Int, duration: Double)? {
        guard count > 0, abs(velocity) > flingMinVelocity else { return nil }
        let v = min(max(velocity, -flingMaxVelocity), flingMaxVelocity)
        let target = min(max(Int((position + v * 0.45).rounded()), 0), count - 1)
        let total = Double(target) - position
        guard abs(total) >= 0.5 else { return nil }
        // Kurven starter med samme fart som fingeren (ease-out i fjerde potens starter med 4 × afstand / tid).
        return (target, min(2.5, max(0.35, 4 * abs(total) / abs(v))))
    }

    /// Langsommere stryg end dette (plader pr. sekund) falder bare på plads.
    public static let flingMinVelocity = 2.5
    /// Højeste fart, et stryg kan give (en trackpad kan måle meget høje farter).
    public static let flingMaxVelocity = 60.0

    /// Lykkehjulet i "Hvad skal jeg høre?": længere afstande tager lidt længere tid, men aldrig over 2,7 sekunder.
    public static func spinDuration(distance: Double) -> Double { 1.3 + min(1.4, abs(distance) * 0.035) }

    /// Glidets kurve fra 0 til 1: hurtigt først, bremser jævnt op (ease-out i fjerde potens).
    public static func easeOut(_ t: Double) -> Double {
        let u = min(max(t, 0), 1)
        return 1 - pow(1 - u, 4)
    }
}

/// Lægger rullebevægelser sammen til hele trin (én plade pr. trin).
/// Trackpad giver mange små, præcise bevægelser; et musehjul giver få, grove hak.
public struct ScrollStepper: Sendable {
    /// Punkter pr. plade på trackpad.
    public var preciseStep = 28.0
    /// Hak pr. plade på musehjul.
    public var wheelStep = 1.0
    private var accumulated = 0.0

    public init() {}

    /// Lægger `delta` til og returnerer antal hele trin (negativt = mod venstre).
    public mutating func add(_ delta: Double, precise: Bool) -> Int {
        let step = precise ? preciseStep : wheelStep
        accumulated += delta
        let steps = Int(accumulated / step)
        accumulated -= Double(steps) * step
        return steps
    }

    public mutating func reset() { accumulated = 0 }
}
