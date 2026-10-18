import SwiftUI
import AppKit
import VinylCore

// "Ny version klar": appen tjekker GitHub én gang om dagen, viser versionen og henter den på
// et tryk. Den nye app pakkes ud, signeres som den gamle (så nøgleringen stadig genkender den),
// lægges i stedet for den gamle, og appen åbner sig selv igen.

@MainActor
@Observable
final class Updater {
    enum Phase: Equatable {
        case idle
        case checking
        case upToDate
        case available(UpdateRelease)
        case downloading
        case installing
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    /// Den udgave, der spørges om ved start (nulstilles af "Senere").
    var prompt: UpdateRelease?
    /// Svar på "Søg efter opdatering…" i menuen, når der ikke er en ny version.
    var notice: String?
    private(set) var lastChecked: Date?

    /// Versionen, der kører nu (fra Info.plist).
    let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    @ObservationIgnored private let enabled: Bool
    @ObservationIgnored private let defaults = UserDefaults.standard

    /// Slået fra i demo- og snapshot-tilstand, og når appen ikke kører som .app (fx `swift run`).
    init(enabled: Bool) {
        self.enabled = enabled && Bundle.main.bundlePath.hasSuffix(".app")
        lastChecked = defaults.object(forKey: "update_last_checked") as? Date
    }

    var isEnabled: Bool { enabled }

    /// Ved start: tjek, hvis det er over et døgn siden. En ny version vises som et spørgsmål.
    func start() {
        guard enabled, AppUpdate.isCheckDue(last: lastChecked) else { return }
        Task { await check(askUser: true) }
    }

    func check(askUser: Bool = false) async {
        guard enabled else { return }
        if phase == .downloading || phase == .installing || phase == .checking { return }
        phase = .checking
        do {
            var request = URLRequest(url: AppUpdate.latestURL, timeoutInterval: 20)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("VinylShelfFinder/\(currentVersion)", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            lastChecked = Date()
            defaults.set(lastChecked, forKey: "update_last_checked")
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            // 404: der er endnu ingen udgivelse på GitHub.
            guard status == 200 || status == 404 else {
                phase = .failed("GitHub svarede ikke som ventet (\(status)). Prøv igen senere.")
                return
            }
            guard status == 200, let release = AppUpdate.parseLatest(data),
                  AppUpdate.isNewer(release, than: currentVersion) else {
                phase = .upToDate
                return
            }
            phase = .available(release)
            if askUser, defaults.string(forKey: "update_skipped") != release.tag { prompt = release }
        } catch {
            phase = .failed("Kunne ikke tjekke for en ny version. Tjek internetforbindelsen, og prøv igen.")
        }
    }

    /// "Søg efter opdatering…" i appens menu: tjekker nu og svarer altid, også når der ikke er noget nyt.
    func checkFromMenu() async {
        await check()
        switch phase {
        case .available(let release): prompt = release
        case .upToDate: notice = "Du har den nyeste version (\(currentVersion))."
        case .failed(let message): notice = message
        default: break
        }
    }

    /// "Senere": spørg ikke igen ved start om netop denne version.
    func postpone(_ release: UpdateRelease) {
        defaults.set(release.tag, forKey: "update_skipped")
        prompt = nil
    }

    /// Henter, pakker ud, signerer og udskifter appen, og åbner den igen.
    func install(_ release: UpdateRelease) {
        guard enabled else { return }
        prompt = nil
        phase = .downloading
        Task {
            do {
                let work = FileManager.default.temporaryDirectory
                    .appendingPathComponent("vsf-update-\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
                let zip = work.appendingPathComponent("app.zip")
                try await download(release.downloadURL, to: zip)
                phase = .installing
                let newApp = try await Task.detached { try Self.unpack(zip, in: work) }.value
                try Self.relaunch(replacing: URL(fileURLWithPath: Bundle.main.bundlePath), with: newApp)
                NSApp.terminate(nil)
            } catch {
                phase = .failed((error as? UpdateError)?.message ?? "Opdateringen mislykkedes. Den gamle version er uændret.")
            }
        }
    }

    // MARK: - Hentning

    private func download(_ url: URL, to file: URL) async throws {
        var request = URLRequest(url: url, timeoutInterval: 120)
        request.setValue("VinylShelfFinder/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        let (tmp, response) = try await URLSession.shared.download(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200, AppUpdate.isTrustedHost(response.url?.host) else {
            try? FileManager.default.removeItem(at: tmp)
            throw UpdateError("Kunne ikke hente den nye version fra GitHub.")
        }
        try FileManager.default.moveItem(at: tmp, to: file)
    }

    // MARK: - Udpakning og udskiftning

    struct UpdateError: Error {
        let message: String
        init(_ message: String) { self.message = message }
    }

    /// Pakker zippen ud og tjekker, at det er Vinyl Shelf Finder. Signerer med brugerens faste
    /// udviklercertifikat, hvis det findes (som build-app.sh), så nøgleringen genkender appen.
    nonisolated private static func unpack(_ zip: URL, in work: URL) throws -> URL {
        let out = work.appendingPathComponent("ny", isDirectory: true)
        try run("/usr/bin/ditto", ["-x", "-k", zip.path, out.path])
        guard let app = (try? FileManager.default.contentsOfDirectory(at: out, includingPropertiesForKeys: nil))?
                .first(where: { $0.pathExtension == "app" }),
              let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
              info["CFBundleIdentifier"] as? String == "dk.vinylshelffinder.app" else {
            throw UpdateError("Den hentede fil er ikke Vinyl Shelf Finder. Intet er ændret.")
        }
        let identity = "Vinyl Shelf Finder Udvikler"
        if (try? run("/usr/bin/security", ["find-certificate", "-c", identity])) != nil {
            try? run("/usr/bin/codesign", ["--force", "--sign", identity, "--identifier", "dk.vinylshelffinder.app", app.path])
        }
        try? run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", app.path])
        return app
    }

    /// Et lille skript venter, til appen er lukket, lægger den nye app på samme sted og åbner den.
    private static func relaunch(replacing old: URL, with new: URL) throws {
        let parent = old.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: parent.path) else {
            throw UpdateError("Appen ligger et sted, hvor den ikke kan skrive (\(parent.path)). Flyt den til Programmer, og prøv igen.")
        }
        let script = """
        while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done
        rm -rf "$OLD.gammel"
        mv "$OLD" "$OLD.gammel" && /usr/bin/ditto "$NEW" "$OLD" && rm -rf "$OLD.gammel" || { rm -rf "$OLD"; mv "$OLD.gammel" "$OLD"; }
        /usr/bin/open "$OLD"
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-c", script]
        p.environment = ["OLD": old.path, "NEW": new.path, "PATH": "/usr/bin:/bin"]
        try p.run()
    }

    @discardableResult
    nonisolated private static func run(_ tool: String, _ args: [String]) throws -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw UpdateError("\(tool) fejlede.") }
        return p.terminationStatus
    }
}

// MARK: - Spørgsmålet ved start og fanen i Indstillinger

/// "Version 1.2 er klar" ved start, når der er en ny version.
struct UpdatePrompt: ViewModifier {
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        let updater = model.updater
        content.alert(updater.prompt.map { "Version \($0.version) er klar" } ?? "",
                      isPresented: Binding(get: { updater.prompt != nil }, set: { if !$0 { updater.prompt = nil } }),
                      presenting: updater.prompt) { release in
            Button("Opdatér nu") { updater.install(release) }
            Button("Senere", role: .cancel) { updater.postpone(release) }
        } message: { release in
            Text(Self.message(release, current: updater.currentVersion))
        }
        .alert(updater.notice ?? "",
               isPresented: Binding(get: { updater.notice != nil }, set: { if !$0 { updater.notice = nil } })) {
            Button("OK", role: .cancel) {}
        }
    }

    static func message(_ r: UpdateRelease, current: String) -> String {
        var text = "Du har version \(current). Appen henter den nye version fra GitHub, lukker og åbner sig selv igen. Dine plader og placeringer røres ikke."
        if !r.notes.isEmpty { text += "\n\nNyt:\n" + String(r.notes.prefix(600)) }
        return text
    }
}

struct UpdateSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let updater = model.updater
        Form {
            Section {
                LabeledContent("Denne version", value: updater.currentVersion)
                if let d = updater.lastChecked {
                    LabeledContent("Sidst tjekket", value: d.danskDatoTid)
                }
                switch updater.phase {
                case .idle:
                    EmptyView()
                case .checking:
                    HStack(spacing: Spacing.xs) {
                        ProgressView().controlSize(.small)
                        Text("Tjekker GitHub …").foregroundStyle(.secondary)
                    }
                case .upToDate:
                    Label("Du har den nyeste version.", systemImage: "checkmark.circle").foregroundStyle(.secondary)
                case .available(let r):
                    LabeledContent("Ny version", value: r.version.description)
                    if !r.notes.isEmpty {
                        Text(r.notes).font(.callout).foregroundStyle(.secondary).lineLimit(8)
                    }
                    Button("Opdatér nu") { updater.install(r) }
                        .buttonStyle(.borderedProminent)
                case .downloading:
                    HStack(spacing: Spacing.xs) {
                        ProgressView().controlSize(.small)
                        Text("Henter den nye version …").foregroundStyle(.secondary)
                    }
                case .installing:
                    HStack(spacing: Spacing.xs) {
                        ProgressView().controlSize(.small)
                        Text("Installerer og åbner igen …").foregroundStyle(.secondary)
                    }
                case .failed(let message):
                    Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
                }
                Button("Søg efter opdatering") { Task { await updater.check() } }
                    .disabled(!updater.isEnabled || [.checking, .downloading, .installing].contains(updater.phase))
            } footer: {
                Text(updater.isEnabled
                     ? "Appen tjekker selv én gang om dagen og spørger, før den opdaterer. Nye versioner hentes fra projektets side på GitHub."
                     : "Opdatering er slået fra i demo-tilstand og når appen ikke er installeret som en app.")
            }
        }
        .formStyle(.grouped)
    }
}
