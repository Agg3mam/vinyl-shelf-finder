import SwiftUI
import AppKit
import VinylCore

/// Udviklerværktøj: `--demo --snapshot <mappe>` renderer nøgleskærme til PNG og afslutter.
@MainActor
enum Snapshotter {
    static func runIfRequested(model: AppModel) {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count else { return }
        let dir = URL(fileURLWithPath: args[i + 1], isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        func find(_ title: String) -> Int64? {
            model.library.allItems.first { $0.title == title }?.id
        }

        model.query = "wish you"
        model.selection = find("Wish You Were Here")
        render(MainView().appRoot().environment(model), size: CGSize(width: 1280, height: 820), to: dir.appendingPathComponent("1-search.png"))

        let savedNeighborCount = model.neighborCount
        if let id = find("Station To Station") {
            renderSwiftUI(FindModeView(copyID: id).environment(model), size: CGSize(width: 640, height: 640), to: dir.appendingPathComponent("2-find.png"))
            // Kontrasttest: helt hvidt og helt sort cover (værste tilfælde for tone og tekst).
            renderSwiftUI(FindModeView(copyID: id, previewCover: solidCover(.white)).environment(model),
                          size: CGSize(width: 640, height: 640), to: dir.appendingPathComponent("2d-find-hvidt-cover.png"))
            renderSwiftUI(FindModeView(copyID: id, previewCover: solidCover(.black)).environment(model),
                          size: CGSize(width: 640, height: 640), to: dir.appendingPathComponent("2e-find-sort-cover.png"))
            // Demo-data har ingen covers. For at vise farve-udtrækket lånes et vilkårligt
            // cover fra den lokale cover-cache (kun læsning). Coveret passer ikke til pladen.
            if let cover = anyCachedCover() {
                renderSwiftUI(FindModeView(copyID: id, previewCover: cover).environment(model), size: CGSize(width: 640, height: 640),
                       to: dir.appendingPathComponent("2b-find-laant-cover.png"))
            }
        }
        // Anden kunstner → anden (deterministisk) farvetone uden cover.
        if let id = model.library.allItems.first(where: { $0.artist == "Bob Dylan" && model.library.location(of: $0.id) != nil })?.id {
            renderSwiftUI(FindModeView(copyID: id).environment(model), size: CGSize(width: 640, height: 640),
                          to: dir.appendingPathComponent("2c-find-anden-plade.png"))
        }
        // Den plade, der giver mest tekst på Find (hint-linjer, lange begrundelser):
        // arket skal vokse i højden i stedet for at klippe eller skubbe knapperne ud.
        let wordiest = model.library.globalOrder.max { a, b in findTextLength(a, model) < findTextLength(b, model) }
        if let id = wordiest {
            renderSwiftUI(FindModeView(copyID: id).environment(model), size: CGSize(width: 640, height: 0),
                          to: dir.appendingPathComponent("2f-find-mest-tekst.png"))
        }
        if let id = find("Wish You Were Here") {
            model.neighborCount = 3
            // Plade-detaljen renderes med ImageRenderer (viser glas), men Link, Menu og den
            // segmenterede Picker bliver gule pladsholdere dér. Derfor også en AppKit-version,
            // der viser kontrollerne, men ikke glasset.
            renderSwiftUI(RecordDetailView(copyID: id, scrolls: false).environment(model), size: CGSize(width: 700, height: 900), to: dir.appendingPathComponent("3-detail-3.png"))
            render(RecordDetailView(copyID: id).environment(model), size: CGSize(width: 700, height: 900), to: dir.appendingPathComponent("3-detail-3-appkit.png"))
            model.neighborCount = 5
            renderSwiftUI(RecordDetailView(copyID: id, scrolls: false).environment(model), size: CGSize(width: 700, height: 1250), to: dir.appendingPathComponent("3b-detail-5.png"))
            model.neighborCount = savedNeighborCount
        }
        if let id = model.library.locations.last.flatMap({ model.library.sections[$0.id]?.last }) {
            renderSwiftUI(RecordDetailView(copyID: id, scrolls: false).environment(model), size: CGSize(width: 700, height: 760), to: dir.appendingPathComponent("4b-last-in-section.png"))
        }
        if let id = model.library.unplaced.first {
            renderSwiftUI(RecordDetailView(copyID: id, scrolls: false).environment(model), size: CGSize(width: 700, height: 760), to: dir.appendingPathComponent("4c-unplaced.png"))
        }
        // Ark: Flyt, Kontrol og sync-rapport (systemets udseende, AppKit-kontroller).
        if let id = find("Wish You Were Here") {
            render(MoveSheet(copyID: id).environment(model), size: CGSize(width: 560, height: 560), to: dir.appendingPathComponent("10-move.png"))
        }
        if let loc = model.library.locations.first {
            render(CheckShelfView(locationID: loc.id).environment(model), size: CGSize(width: 620, height: 560), to: dir.appendingPathComponent("11-check.png"))
        }
        var report = ShelfStore.SyncReport()
        report.total = model.library.copies.count
        report.newCopies = Array(model.library.unplaced.prefix(3))
        report.removedCopies = Array(model.library.globalOrder.prefix(2))
        report.updatedReleases = 4
        let savedReport = model.lastReport
        model.lastReport = report
        render(SyncReportView().environment(model), size: CGSize(width: 520, height: 420), to: dir.appendingPathComponent("12-sync-report.png"))
        model.lastReport = savedReport
        if let id = model.library.locations.first.flatMap({ model.library.sections[$0.id]?.first }) {
            renderSwiftUI(RecordDetailView(copyID: id, scrolls: false).environment(model), size: CGSize(width: 700, height: 760), to: dir.appendingPathComponent("4-first-in-section.png"))
        }
        if let loc = model.library.locations.dropFirst().first {
            model.sidebar = .section(loc.id)
            render(MainView().appRoot().environment(model), size: CGSize(width: 1280, height: 820), to: dir.appendingPathComponent("5-section.png"))
            // Cover Flow midt i sektionen. Indstillingen sættes tilbage bagefter.
            let savedCoverFlow = model.showCoverFlow
            let ids = model.library.sections[loc.id] ?? []
            model.selection = ids.isEmpty ? nil : ids[ids.count / 2]
            model.showCoverFlow = true
            render(MainView().appRoot().environment(model), size: CGSize(width: 1280, height: 820), to: dir.appendingPathComponent("13-coverflow.png"))
            // Cover Flow alene med ImageRenderer: cacheDisplay tegner ikke 3D-drejningerne.
            renderSwiftUI(CoverFlowView(locationID: loc.id, catchesScroll: false).appRoot().environment(model), size: CGSize(width: 900, height: 620),
                          to: dir.appendingPathComponent("13b-coverflow-alene.png"))
            model.showCoverFlow = savedCoverFlow
        }
        model.sidebar = .value
        model.selection = find("Wish You Were Here")
        render(MainView().appRoot().environment(model), size: CGSize(width: 1280, height: 820), to: dir.appendingPathComponent("7-value.png"))
        // "Hvad skal jeg høre?" med en fast plade i stedet for `pickRecord()` (tilfældig),
        // så snapshottet er det samme hver gang.
        model.sidebar = .listen
        let listenID = find("Led Zeppelin IV") ?? model.library.globalOrder.first
        model.selection = listenID
        render(MainView().appRoot().environment(model), size: CGSize(width: 1280, height: 900), to: dir.appendingPathComponent("8-listen.png"))
        if let listenID {
            render(ListenView(previewPick: listenID).environment(model), size: CGSize(width: 720, height: 1000),
                   to: dir.appendingPathComponent("8b-listen-pick.png"))
        }
        model.sidebar = .plays
        render(MainView().appRoot().environment(model), size: CGSize(width: 1280, height: 820), to: dir.appendingPathComponent("9-plays.png"))
        // Sorteringslisten med to flueben. Fluebenene fjernes igen bagefter.
        let order = SortList.build(model.library, rules: model.rules).filter { $0.number != nil }
        for e in order.prefix(2) { model.setSortChecked(e.id, true) }
        model.sidebar = .sortList
        model.selection = order.dropFirst(2).first?.id
        render(MainView().appRoot().environment(model), size: CGSize(width: 1280, height: 820), to: dir.appendingPathComponent("15-sorteringsliste.png"))
        model.clearSortChecked()
        render(SortSettings().appRoot().environment(model), size: CGSize(width: 640, height: 900), to: dir.appendingPathComponent("16-sortering-indstillinger.png"))
        render(SurnameSheet().appRoot().environment(model), size: CGSize(width: 540, height: 600), to: dir.appendingPathComponent("16b-efternavn.png"))
        render(BackupSettings().appRoot().environment(model), size: CGSize(width: 640, height: 760), to: dir.appendingPathComponent("17-sikkerhedskopi.png"))
        try? LabelsPDF.write(ShelfLabel.labels(for: model.library), to: dir.appendingPathComponent("labels.pdf"))
        model.forceOnboarding = true
        render(ContentView().appRoot().environment(model), size: CGSize(width: 1000, height: 900), to: dir.appendingPathComponent("6-onboarding.png"))
        model.forceOnboarding = false

        // Cd-hylden: egne reoler, samme skærme. Skiftet sættes tilbage til pladerne bagefter.
        model.medium = .cd
        if let loc = model.library.locations.first {
            model.sidebar = .section(loc.id)
            model.selection = model.library.sections[loc.id]?.dropFirst().first
            render(MainView().appRoot().environment(model), size: CGSize(width: 1280, height: 820), to: dir.appendingPathComponent("14-cd-sektion.png"))
            if let id = model.selection {
                renderSwiftUI(FindModeView(copyID: id).environment(model), size: CGSize(width: 640, height: 640),
                              to: dir.appendingPathComponent("14b-cd-find.png"))
            }
        }
        model.forceOnboarding = true
        render(ContentView().appRoot().environment(model), size: CGSize(width: 1000, height: 900), to: dir.appendingPathComponent("14c-cd-opdeling.png"))
        model.medium = .vinyl
        NSApp.terminate(nil)
    }

    /// Ensfarvet testcover (kontrast ved hvidt/sort cover).
    private static func solidCover(_ color: NSColor) -> NSImage {
        let img = NSImage(size: NSSize(width: 300, height: 300))
        img.lockFocus()
        color.setFill()
        NSRect(x: 0, y: 0, width: 300, height: 300).fill()
        img.unlockFocus()
        return img
    }

    /// Groft mål for, hvor meget tekst Find-skærmen viser for en plade.
    private static func findTextLength(_ id: Int64, _ model: AppModel) -> Int {
        guard let adv = model.library.referenceAdvice(for: id), let n = model.library.neighbors(of: id) else { return 0 }
        var len = adv.primary.reason.count + (adv.secondary?.reason.count ?? 0) + (adv.artistBlockHint?.count ?? 0)
        if n.reachedSectionEnd || n.reachedSectionStart { len += 100 }
        if n.target.copy.status != .home { len += 60 }
        return len
    }

    /// Første store cover i cachen (sorteret, så valget er stabilt). Læser kun.
    private static func anyCachedCover() -> NSImage? {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VinylShelfFinder/covers", isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        guard let name = files.filter({ $0.hasSuffix("-l.jpg") }).sorted().first else { return nil }
        return NSImage(contentsOf: dir.appendingPathComponent(name))
    }

    /// Renderer med SwiftUI's egen `ImageRenderer`. Den tegner Liquid Glass
    /// (`.glassEffect`, glasknapper) – det gør `cacheDisplay` ikke: der forsvinder
    /// glasfladerne helt. Til gengæld kan `ImageRenderer` ikke tegne AppKit-baserede
    /// views (List, TextField, Table …), så den bruges kun til rene SwiftUI-skærme
    /// som "Find i reolen".
    /// `size.height == 0` betyder "så høj som indholdet" (ideal-højde).
    static func renderSwiftUI<V: View>(_ view: V, size: CGSize, to url: URL) {
        let fixedHeight: CGFloat? = size.height > 0 ? size.height : nil
        let renderer = ImageRenderer(content: view.frame(width: size.width, height: fixedHeight))
        renderer.proposedSize = ProposedViewSize(width: size.width, height: fixedHeight)
        renderer.scale = 1
        guard let cg = renderer.cgImage else { return }
        try? NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])?.write(to: url)
    }

    static func render<V: View>(_ view: V, size: CGSize, to url: URL) {
        let host = NSHostingView(rootView: view
            .frame(width: size.width, height: size.height)
            .background(Color(nsColor: .windowBackgroundColor)))
        host.appearance = NSAppearance(named: .aqua)
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        // Lad SwiftUI og AppKit nå at lægge lister mv. ud.
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
