import Foundation

/// Placering af covers i Cover Flow (som på en iPod classic). Ren matematik, så den kan tjekkes.
/// `d` er afstanden fra midten i antal plader: 0 = coveret i midten, -1 = lige til venstre osv.
public enum CoverFlowGeometry {
    /// Så mange covers vises på hver side af midten.
    public static let visible = 6
    /// Hvor skråt sidecoverne står (grader om den lodrette akse).
    public static let tilt = 60.0
    /// Afstand fra midten til første sidecover og mellem de næste (i forhold til coverets side).
    static let firstGap = 0.62
    static let stackGap = 0.2

    /// Coverets side ud fra den plads, der er (stort, men aldrig over 360 pt).
    public static func side(width: Double, height: Double) -> Double {
        max(80, min(height * 0.8, width * 0.36, 360))
    }

    /// Vandret forskydning fra midten.
    public static func x(_ d: Int, side: Double) -> Double {
        guard d != 0 else { return 0 }
        let sign: Double = d > 0 ? 1 : -1
        return sign * (side * firstGap + Double(abs(d) - 1) * side * stackGap)
    }

    /// Drejning: midten vender lige frem; siderne vender ind mod midten, så deres yderkant er
    /// nærmest (som væggene i en gang). Med SwiftUI's `rotation3DEffect` om y-aksen flytter en
    /// positiv vinkel højre kant væk, derfor negativ vinkel til højre for midten.
    public static func angle(_ d: Int) -> Double {
        d == 0 ? 0 : (d > 0 ? -tilt : tilt)
    }

    public static func scale(_ d: Int) -> Double { d == 0 ? 1 : 0.86 }

    /// Covers tættest på midten ligger øverst.
    public static func zIndex(_ d: Int) -> Double { Double(-abs(d)) }

    /// De plader (indeks), der skal tegnes omkring `center`.
    public static func visibleRange(center: Int, count: Int) -> Range<Int> {
        guard count > 0 else { return 0..<0 }
        let c = min(max(center, 0), count - 1)
        return max(0, c - visible)..<min(count, c + visible + 1)
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
