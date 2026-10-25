import Foundation

/// Eksport, import og nulstilling af hele systemet (reoler, placeringer, historik, lyttelog og indstillinger).
/// Port af DataTransfer.cs: samme filnavne og samme forløb, så en eksport fra Windows kan importeres på
/// Mac og omvendt. En eksport er en almindelig, hel SQLite-fil (`VACUUM INTO`), samme slags som de daglige
/// sikkerhedskopier, så både eksporter og sikkerhedskopier kan importeres.
///
/// Import og nulstilling kan ikke ske, mens databasen er åben. De bestilles derfor her og udføres af
/// `applyPending` ved næste start, før databasen åbnes.
public enum DataTransfer {
    public static let fileExtension = "sqlite"

    public struct TransferError: LocalizedError, Equatable {
        public let message: String
        public init(message: String) { self.message = message }
        public var errorDescription: String? { message }
    }

    private static func stamp(_ format: String, _ now: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = format
        return f.string(from: now)
    }

    /// "Vinyl Shelf Finder 2026-10-17.sqlite"
    public static func exportFileName(_ now: Date = Date()) -> String {
        "Vinyl Shelf Finder \(stamp("yyyy-MM-dd", now)).\(fileExtension)"
    }

    /// Sikkerhedskopien, der tages lige før en import eller nulstilling: "før-nulstilling-2026-10-17-210500.sqlite".
    /// Navnet ligner ikke de daglige kopier, så den ryddes aldrig væk automatisk.
    public static func safetyFileName(_ reason: String, _ now: Date = Date()) -> String {
        "før-\(reason)-\(stamp("yyyy-MM-dd-HHmmss", now)).\(fileExtension)"
    }

    public static func resetFlag(_ dbPath: String) -> String { dbPath + ".reset-pending" }
    public static func importFile(_ dbPath: String) -> String { dbPath + ".import-pending" }
    /// Den kontrollerede import, før brugeren har bekræftet. Bruges aldrig ved start.
    public static func stagedImport(_ dbPath: String) -> String { dbPath + ".import-staged" }

    private static var fm: FileManager { .default }

    /// Skriver en hel kopi af databasen til `target`. En eksisterende fil erstattes.
    public static func export(_ store: ShelfStore, to target: String) throws {
        let url = URL(fileURLWithPath: target)
        let dir = url.deletingLastPathComponent()
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let partial = dir.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).partial").path
        defer { tryDelete(partial) }
        try store.backup(to: partial)
        if fm.fileExists(atPath: target) { try fm.removeItem(atPath: target) }
        try fm.moveItem(atPath: partial, toPath: target)
    }

    /// Gemmer en sikkerhedskopi i `folder` og returnerer stien.
    @discardableResult
    public static func safetyCopy(_ store: ShelfStore, folder: URL, reason: String, now: Date = Date()) throws -> String {
        let target = folder.appendingPathComponent(safetyFileName(reason, now)).path
        try export(store, to: target)
        return target
    }

    /// Kontrollerer, at `source` er en database fra appen, og lægger en ren kopi til side (`stagedImport`).
    /// Den bruges først, når `commitImport` kaldes efter brugerens ja og sikkerhedskopien.
    /// Kaster `TransferError` med en dansk besked, hvis filen ikke kan bruges. `source` røres ikke.
    public static func requestImport(dbPath: String, source: String) throws -> ImportSummary {
        guard fm.fileExists(atPath: source) else { throw TransferError(message: "Filen findes ikke.") }
        if URL(fileURLWithPath: source).standardizedFileURL.path == URL(fileURLWithPath: dbPath).standardizedFileURL.path {
            throw TransferError(message: "Det er appens egen database. Vælg en eksport eller en sikkerhedskopi.")
        }
        let check = dbPath + ".import-check"
        deleteDatabaseFiles(check)
        defer { deleteDatabaseFiles(check) }
        try fm.copyItem(atPath: source, toPath: check)
        let notExport = TransferError(message: "Filen er ikke en eksport fra Vinyl Shelf Finder.")
        let summary: ImportSummary
        do {
            let store: ShelfStore
            do { store = try ShelfStore(path: check) } catch { throw notExport }
            do {
                let counts = try store.mediumCounts()
                let sections = try ShelfKind.all.reduce(0) { $0 + (try store.loadLibrary(kind: $1).locations.count) }
                summary = ImportSummary(vinyl: counts[.vinyl] ?? 0, cds: counts[.cd] ?? 0, sections: sections)
            } catch { throw notExport }
            // En tom fil (eller en anden SQLite-fil) får skemaet ved åbning og ligner en tom samling.
            if summary.vinyl == 0 && summary.cds == 0 && summary.sections == 0 {
                throw TransferError(message: "Filen indeholder ingen plader, cd'er eller reoler. Vælg en eksport eller en sikkerhedskopi.")
            }
            deleteDatabaseFiles(stagedImport(dbPath))
            try store.backup(to: stagedImport(dbPath))
        }
        return summary
    }

    /// Brugeren har sagt ja, og sikkerhedskopien er taget: importen udføres ved næste start.
    public static func commitImport(dbPath: String) throws {
        guard fm.fileExists(atPath: stagedImport(dbPath)) else { throw TransferError(message: "Importen er ikke klar. Vælg filen igen.") }
        tryDelete(resetFlag(dbPath))
        deleteDatabaseFiles(importFile(dbPath))
        try fm.moveItem(atPath: stagedImport(dbPath), toPath: importFile(dbPath))
    }

    /// Bestiller en nulstilling: ved næste start begynder appen med en tom database.
    public static func requestReset(dbPath: String) throws {
        deleteDatabaseFiles(stagedImport(dbPath))
        deleteDatabaseFiles(importFile(dbPath))
        try Data(ISO8601DateFormatter().string(from: Date()).utf8).write(to: URL(fileURLWithPath: resetFlag(dbPath)))
    }

    /// Fortryder en bestilt import eller nulstilling.
    public static func cancelPending(dbPath: String) {
        tryDelete(resetFlag(dbPath))
        deleteDatabaseFiles(importFile(dbPath))
        deleteDatabaseFiles(stagedImport(dbPath))
    }

    public enum Applied: Equatable { case unchanged, reset, imported }

    /// Kaldes ved start, før databasen åbnes.
    public static func applyPending(dbPath: String) throws -> Applied {
        // En import, der aldrig blev bekræftet (fx lukket midt i dialogen), bruges ikke.
        deleteDatabaseFiles(stagedImport(dbPath))
        let reset = fm.fileExists(atPath: resetFlag(dbPath))
        let imported = fm.fileExists(atPath: importFile(dbPath))
        guard reset || imported else { return .unchanged }
        for p in databaseFiles(dbPath) where fm.fileExists(atPath: p) { try fm.removeItem(atPath: p) }
        if imported { try fm.moveItem(atPath: importFile(dbPath), toPath: dbPath) }
        tryDelete(resetFlag(dbPath))
        return imported ? .imported : .reset
    }

    /// Databasen og dens WAL-filer.
    private static func databaseFiles(_ path: String) -> [String] {
        [path, path + "-wal", path + "-shm", path + "-journal"]
    }

    private static func deleteDatabaseFiles(_ path: String) {
        databaseFiles(path).forEach(tryDelete)
    }

    private static func tryDelete(_ path: String) {
        if fm.fileExists(atPath: path) { try? fm.removeItem(atPath: path) }
    }
}

/// Det, en import indeholder (vises, før brugeren bekræfter).
public struct ImportSummary: Equatable {
    public let vinyl: Int
    public let cds: Int
    public let sections: Int
    public init(vinyl: Int, cds: Int, sections: Int) { self.vinyl = vinyl; self.cds = cds; self.sections = sections }
}
