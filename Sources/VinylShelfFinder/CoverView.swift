import SwiftUI
import AppKit
import VinylCore

/// Coverbilleder caches på disken, så appen også viser covers offline.
actor CoverCache {
    static let shared = CoverCache()
    /// NSCache er trådsikker, så hukommelsescachen kan læses synkront fra et view
    /// (et cache-hit vises straks – uden pladesymbol i første frame og uden fade).
    nonisolated(unsafe) private let memory: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 300   // små thumbs + store covers; resten ligger på disken
        return c
    }()
    private var inFlight: [String: Task<NSImage?, Never>] = [:]

    private let dir: URL = {
        let d = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VinylShelfFinder/covers", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    /// Kun hukommelsescachen – synkront og billigt. `nil` betyder "ikke indlæst endnu".
    nonisolated func cachedImage(releaseID: Int, large: Bool) -> NSImage? {
        memory.object(forKey: "\(releaseID)-\(large ? "l" : "s")" as NSString)
    }

    func image(releaseID: Int, url: String, large: Bool) async -> NSImage? {
        let key = "\(releaseID)-\(large ? "l" : "s")"
        if let img = memory.object(forKey: key as NSString) { return img }
        let file = dir.appendingPathComponent("\(key).jpg")
        if let img = NSImage(contentsOf: file) {
            memory.setObject(img, forKey: key as NSString)
            return img
        }
        if let t = inFlight[key] { return await t.value }
        let task = Task<NSImage?, Never> {
            guard let u = URL(string: url) else { return nil }
            var req = URLRequest(url: u)
            req.setValue(DiscogsClient.userAgent, forHTTPHeaderField: "User-Agent")
            guard let (data, resp) = try? await URLSession.shared.data(for: req),
                  (resp as? HTTPURLResponse)?.statusCode == 200,
                  let img = NSImage(data: data) else { return nil }
            try? data.write(to: file)
            return img
        }
        inFlight[key] = task
        let img = await task.value
        inFlight[key] = nil
        if let img { memory.setObject(img, forKey: key as NSString) }
        return img
    }
}

struct CoverView: View {
    let release: Release
    let size: CGFloat
    /// Billedet *og* hvilken plade det hører til. Når samme view genbruges til en anden
    /// plade (Kontrol, "Hvad skal jeg høre?"), vises den forrige plades cover aldrig.
    @ViewState private var loaded: (id: Int, image: NSImage)?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var large: Bool { size > 80 }
    private var url: String? { large ? (release.coverURL ?? release.thumbURL) : (release.thumbURL ?? release.coverURL) }
    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: large ? Radius.coverLarge : Radius.coverSmall, style: .continuous)
    }

    var body: some View {
        // Ligger coveret allerede i hukommelsen, vises det med det samme. Kun en rigtig
        // indlæsning (disk/net) fader ind fra pladesymbolet.
        let image = loaded?.id == release.id ? loaded?.image
            : CoverCache.shared.cachedImage(releaseID: release.id, large: large)
        ZStack {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                    .transition(.opacity)
            } else {
                SleevePlaceholder(release: release, size: size)
            }
        }
        .frame(width: size, height: size)
        .clipShape(shape)
        .animation(Motion.fade(reduceMotion), value: image.map(ObjectIdentifier.init))
        .task(id: release.id) {
            let id = release.id
            if CoverCache.shared.cachedImage(releaseID: id, large: large) != nil { return }
            guard let url, let img = await CoverCache.shared.image(releaseID: id, url: url, large: large),
                  !Task.isCancelled else { return }
            loaded = (id, img)
        }
    }
}
