import SwiftUI
import VinylCore

@main
struct VinylApp: App {
    @State private var model = PhoneModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .tint(AppAccent.color)
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

/// Appens accentfarve: samme rolige blågrønne som på Mac (ContentView.swift).
enum AppAccent {
    static let color = Color(uiColor: dynamic(light: 0x1C6E66, dark: 0x2E9D8F))
    /// Til tekst på en svag accentflade (fx placeringsmærket "2A").
    static let ink = Color(uiColor: dynamic(light: 0x1C6E66, dark: 0x5EC4B6))

    private static func dynamic(light: UInt32, dark: UInt32) -> UIColor {
        UIColor { $0.userInterfaceStyle == .dark ? rgb(dark) : rgb(light) }
    }
    private static func rgb(_ v: UInt32) -> UIColor {
        UIColor(red: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }
}
