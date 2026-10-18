import SwiftUI
import AppKit
import VinylCore

@main
struct VinylShelfFinderApp: App {
    @ViewState private var model: AppModel

    init() {
        let model = AppModel()
        _model = ViewState(initialValue: model)
        // Snapshot-tilstand startes her i stedet for fra vinduets `.task`, så den også
        // kører, når skærmen er slukket/låst (så vises vinduet aldrig, og `.task` fyrer ikke).
        if CommandLine.arguments.contains("--snapshot") {
            DispatchQueue.main.async { MainActor.assumeIsolated { Snapshotter.runIfRequested(model: model) } }
        }
        // Nødvendigt hvis binæren køres direkte (swift run) i stedet for som .app.
        NSApplication.shared.setActivationPolicy(.regular)
        DispatchQueue.main.async { NSApp.activate(ignoringOtherApps: true) }
    }

    var body: some Scene {
        WindowGroup("Vinyl Shelf Finder") {
            ContentView()
                .environment(model)
                .frame(minWidth: 980, minHeight: 620)
        }
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Søg efter opdatering…") {
                    Task { await model.updater.checkFromMenu() }
                }
                .disabled(!model.updater.isEnabled)
            }
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .printItem) {
                Button("Udskriv reolskilte…") { model.exportLabels() }
                    .keyboardShortcut("p")
                    .disabled(model.library.locations.isEmpty)
            }
            CommandMenu("Plade") {
                Button("Søg") {
                    model.sidebar = .search
                    model.focusSearchRequest += 1
                }
                .keyboardShortcut("k")

                Button("Find i reolen") {
                    if let s = model.selection { model.findModeCopy = s }
                }
                .keyboardShortcut("f")
                .disabled(model.selection == nil)

                Button("Flyt plade…") {
                    if let s = model.selection { model.moveCopy = s }
                }
                .keyboardShortcut("m", modifiers: [.command, .shift])
                .disabled(model.selection == nil)

                Button("Registrér som spillet") {
                    if let s = model.selection { PlayFeedback.logPlay(model, s) }
                }
                .keyboardShortcut("l")
                .disabled(model.selection == nil)

                Button("Kontrollér sektion…") {
                    if let id = model.sectionToCheck { model.checkSection = id }
                }
                .keyboardShortcut("k", modifiers: [.command, .shift])
                .disabled(model.sectionToCheck == nil)

                Divider()

                Button("Synkronisér med Discogs") {
                    Task { await model.sync() }
                }
                .keyboardShortcut("r")
                .disabled(!model.hasToken)
            }
        }

        // Det indbyggede Discogs-vindue til køb (se DiscogsBrowser.swift). Ét vindue, der
        // genbruges; det åbnes kun fra "Find nye plader" og gendannes ikke ved start.
        Window("Discogs", id: DiscogsBrowser.windowID) {
            DiscogsBrowserView()
                .environment(model)
                .appRoot()
        }
        .defaultSize(width: 1100, height: 820)
        .windowToolbarStyle(.unified)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)

        Settings {
            SettingsView()
                .environment(model)
                .frame(width: 620, height: 560)
                .appRoot()
        }
    }
}

/// I macOS 27-SDK'et er `@State` en makro, hvis plugin kun følger med Xcode.
/// Aliaset peger direkte på property-wrapper-typen, så appen også kan bygges
/// med Command Line Tools alene.
typealias ViewState = SwiftUI.State

