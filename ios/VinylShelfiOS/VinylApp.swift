import SwiftUI
import VinylCore

@main
struct VinylApp: App {
    @State private var model = PhoneModel()
    @Environment(\.scenePhase) private var scenePhase
    /// Konto › Indstillinger › Udseende (kun på telefonen, som i webappen).
    @AppStorage("look_theme") private var lookTheme = LookTheme.auto
    @AppStorage("look_style") private var lookStyle = LookStyle.standard

    init() { AppAccent.apply(AppAccent.style) }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .tint(AppAccent.color)
                .preferredColorScheme(lookTheme == .light ? .light : lookTheme == .dark ? .dark : nil)
                // En ny stil tegner farverne og navigationslinjerne forfra.
                .id(lookStyle)
                .onChange(of: lookStyle) { _, s in AppAccent.apply(s) }
                // QR-koder fra Kamera-appen og linket i login-mailen (vinylshelf://…).
                .onOpenURL { model.open($0) }
                .task(id: scenePhase) {
                    // Synkronisér, når appen kommer frem, og hvert 5. minut, mens den er fremme.
                    guard scenePhase == .active else { return }
                    while !Task.isCancelled {
                        await model.syncCloud()
                        try? await Task.sleep(for: .seconds(300))
                    }
                }
        }
    }
}

/// Appens accentfarve: samme rolige blågrønne som på Mac (ContentView.swift). Med en anden stil end Standard
/// (Konto › Indstillinger › Udseende) kommer farverne fra stilen (`LookStyle`, samme som Mac og webappen).
enum AppAccent {
    static let color = Color(uiColor: dynamic(light: 0x1C6E66, dark: 0x2E9D8F) { $0.accent })
    /// Til tekst på en svag accentflade (fx placeringsmærket "2A").
    static let ink = Color(uiColor: dynamic(light: 0x1C6E66, dark: 0x5EC4B6) { $0.accentInk })
    /// Stilens baggrund bag lister og skærme (kun med en anden stil end Standard).
    static let background = Color(uiColor: dynamic(light: 0xF2F2F7, dark: 0x000000) { $0.background })

    /// Den valgte stil. Læses, når farverne tegnes.
    nonisolated(unsafe) static var style = LookStyle(rawValue: UserDefaults.standard.string(forKey: "look_style") ?? "") ?? .standard

    /// Skifter stil: farverne og overskrifterne i navigationslinjen (smalle som skillekortet i stilene).
    @MainActor static func apply(_ s: LookStyle) {
        style = s
        let bar = UINavigationBar.appearance()
        if s.condensedTitles {
            bar.largeTitleTextAttributes = [.font: UIFont.systemFont(ofSize: 34, weight: .bold, width: .condensed)]
            bar.titleTextAttributes = [.font: UIFont.systemFont(ofSize: 17, weight: .semibold, width: .condensed)]
        } else {
            bar.largeTitleTextAttributes = nil
            bar.titleTextAttributes = nil
        }
    }

    private static func dynamic(light: UInt32, dark: UInt32, _ pick: @escaping @Sendable (LookColors) -> UInt32) -> UIColor {
        UIColor { t in
            let isDark = t.userInterfaceStyle == .dark
            if let p = style.palette { return rgb(pick(isDark ? p.dark : p.light)) }
            return rgb(isDark ? dark : light)
        }
    }
    static func rgb(_ v: UInt32) -> UIColor {
        UIColor(red: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }
}

extension View {
    /// Stilens baggrund bag lister og skærme (Konto › Indstillinger › Udseende). Standard bruger systemets egne.
    func lookScreen() -> some View { modifier(LookScreen()) }
}

private struct LookScreen: ViewModifier {
    @AppStorage("look_style") private var lookStyle = LookStyle.standard

    func body(content: Content) -> some View {
        if lookStyle.palette != nil {
            content
                .scrollContentBackground(.hidden)
                .containerBackground(AppAccent.background, for: .navigation)
        } else {
            content
        }
    }
}
