import Foundation

// Opdatering fra GitHub Releases (projektet er offentligt, så der skal ingen adgangskode til).
// Appen spørger https://api.github.com/repos/Agg3mam/vinyl-shelf-finder/releases/latest højst
// én gang om dagen. Her ligger kun de rene dele (versioner, svaret fra GitHub, hvornår der skal
// tjekkes), så de kan testes uden net. Selve hentningen og udskiftningen af appen sker i appen.

/// En version som "1.2.3". Et foranstillet "v" og alt efter "-" eller "+" ignoreres.
public struct AppVersion: Comparable, CustomStringConvertible {
    public let parts: [Int]

    public init?(_ text: String) {
        var t = text.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("v") || t.hasPrefix("V") { t.removeFirst() }
        if let cut = t.firstIndex(where: { $0 == "-" || $0 == "+" }) { t = String(t[..<cut]) }
        let nums = t.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard !nums.isEmpty, nums.count <= 4, nums.allSatisfy({ $0 != nil && $0! >= 0 }) else { return nil }
        parts = nums.map { $0! }
    }

    public var description: String { parts.map(String.init).joined(separator: ".") }

    public static func < (a: AppVersion, b: AppVersion) -> Bool {
        for i in 0..<max(a.parts.count, b.parts.count) {
            let x = i < a.parts.count ? a.parts[i] : 0
            let y = i < b.parts.count ? b.parts[i] : 0
            if x != y { return x < y }
        }
        return false
    }

    public static func == (a: AppVersion, b: AppVersion) -> Bool { !(a < b) && !(b < a) }
}

/// Den nyeste udgave på GitHub, som appen kan hente.
public struct UpdateRelease: Equatable {
    public let version: AppVersion
    public let tag: String
    /// Udgivelsens tekst fra GitHub (hvad er nyt).
    public let notes: String
    public let pageURL: URL
    /// Zip-filen til denne platform.
    public let downloadURL: URL
    public let size: Int?

    public static func == (a: UpdateRelease, b: UpdateRelease) -> Bool { a.tag == b.tag && a.downloadURL == b.downloadURL }
}

public enum AppUpdate {
    public static let owner = "Agg3mam"
    public static let repo = "vinyl-shelf-finder"
    public static let latestURL = URL(string: "https://api.github.com/repos/\(owner)/\(repo)/releases/latest")!
    /// Navnet på Mac-appens zip i en udgivelse. Windows-zippen hedder VinylShelfFinder-Windows-x64.zip.
    public static let macAssetName = "VinylShelfFinder-macOS.zip"

    /// Læser GitHubs svar fra /releases/latest. `nil`, hvis der ikke er en brugbar udgave med
    /// den ønskede fil (fx en kladde, en prøveudgave eller en udgave uden Mac-zip).
    public static func parseLatest(_ data: Data, assetName: String = macAssetName) -> UpdateRelease? {
        struct Asset: Decodable { let name: String; let browser_download_url: String; let size: Int? }
        struct Release: Decodable {
            let tag_name: String
            let body: String?
            let html_url: String
            let draft: Bool?
            let prerelease: Bool?
            let assets: [Asset]?
        }
        guard let r = try? JSONDecoder().decode(Release.self, from: data),
              r.draft != true, r.prerelease != true,
              let version = AppVersion(r.tag_name),
              let page = URL(string: r.html_url),
              let asset = r.assets?.first(where: { $0.name == assetName }),
              let url = URL(string: asset.browser_download_url),
              url.scheme == "https", isTrustedHost(url.host)
        else { return nil }
        return UpdateRelease(version: version, tag: r.tag_name, notes: (r.body ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                             pageURL: page, downloadURL: url, size: asset.size)
    }

    /// Kun GitHubs egne adresser. Downloadet omdirigeres til objects.githubusercontent.com.
    public static func isTrustedHost(_ host: String?) -> Bool {
        guard let h = host?.lowercased() else { return false }
        return h == "github.com" || h == "api.github.com" || h.hasSuffix(".githubusercontent.com")
    }

    /// Er udgaven nyere end den, der kører?
    public static func isNewer(_ release: UpdateRelease, than current: String) -> Bool {
        guard let cur = AppVersion(current) else { return true }
        return cur < release.version
    }

    /// Højst ét automatisk tjek pr. døgn.
    public static func isCheckDue(last: Date?, now: Date = Date()) -> Bool {
        guard let last else { return true }
        return now.timeIntervalSince(last) >= 24 * 3600 || now < last
    }
}
