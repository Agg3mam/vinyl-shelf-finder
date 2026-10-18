import Foundation

/// Automatisk sikkerhedskopi af databasen: én fil pr. dag, de `keep` nyeste beholdes.
/// Kopien laves med SQLites `VACUUM INTO`, så den altid er hel – også mens appen kører (WAL).
public enum DatabaseBackup {
    /// Så mange daglige kopier gemmes.
    public static let keep = 14

    static let prefix = "vinyl-"
    static let suffix = ".sqlite"

    /// Mappen til kopierne: iCloud Drive, hvis den findes (så kopien også overlever, at Mac'en
    /// går i stykker), ellers Dokumenter.
    public static func defaultFolder(fileManager fm: FileManager = .default) -> URL {
        #if os(macOS)
        let home = fm.homeDirectoryForCurrentUser
        #else
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true) // iPhone: appens egen mappe
        #endif
        let iCloud = home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        var isDir: ObjCBool = false
        let base = fm.fileExists(atPath: iCloud.path, isDirectory: &isDir) && isDir.boolValue
            ? iCloud
            : home.appendingPathComponent("Documents", isDirectory: true)
        return base.appendingPathComponent("Vinyl Shelf Finder backup", isDirectory: true)
    }

    /// Ligger mappen i iCloud Drive?
    public static func isInICloud(_ folder: URL) -> Bool {
        folder.path.contains("/Mobile Documents/com~apple~CloudDocs/")
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        f.isLenient = true   // ellers kan en dag, hvor uret springer ved midnat, ikke læses
        return f
    }()

    /// "vinyl-2026-10-01.sqlite"
    public static func fileName(for date: Date) -> String {
        prefix + dayFormatter.string(from: date) + suffix
    }

    /// Dagen i et filnavn fra `fileName(for:)`; andre filer → nil (de røres aldrig).
    public static func date(fromFileName name: String) -> Date? {
        guard name.hasPrefix(prefix), name.hasSuffix(suffix) else { return nil }
        let day = name.dropFirst(prefix.count).dropLast(suffix.count)
        guard day.count == 10 else { return nil }
        return dayFormatter.date(from: String(day))
    }

    /// De filer, der skal slettes, så kun de `keep` nyeste kopier er tilbage.
    /// Filer, der ikke er appens egne kopier, røres aldrig.
    public static func namesToDelete(_ names: [String], keep: Int = DatabaseBackup.keep) -> [String] {
        let ours = names.compactMap { n in date(fromFileName: n).map { (n, $0) } }
            .sorted { $0.1 > $1.1 }
        return ours.dropFirst(max(0, keep)).map(\.0)
    }

    /// Den nyeste kopi i mappen (ud fra filnavnet), eller nil.
    public static func latest(in folder: URL, fileManager fm: FileManager = .default) -> Date? {
        let names = (try? fm.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.compactMap(date(fromFileName:)).max()
    }

    /// Skal der tages en ny kopi? Ja, hvis der ingen er fra i dag.
    public static func isDue(latest: Date?, now: Date = Date(), calendar: Calendar = .current) -> Bool {
        guard let latest else { return true }
        return !calendar.isDate(latest, inSameDayAs: now)
    }

    /// Tager en kopi nu (dagens fil erstattes) og rydder op i gamle kopier.
    /// Returnerer stien til den nye kopi.
    @discardableResult
    public static func run(store: ShelfStore, to folder: URL, now: Date = Date(),
                           keep: Int = DatabaseBackup.keep, fileManager fm: FileManager = .default) throws -> URL {
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let target = folder.appendingPathComponent(fileName(for: now))
        // Først en midlertidig fil, så iCloud aldrig ser en halv kopi.
        let partial = folder.appendingPathComponent(".\(fileName(for: now)).partial")
        try? fm.removeItem(at: partial)
        do {
            try store.backup(to: partial.path)
            if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
            try fm.moveItem(at: partial, to: target)
        } catch {
            try? fm.removeItem(at: partial)
            throw error
        }
        let names = (try? fm.contentsOfDirectory(atPath: folder.path)) ?? []
        for name in namesToDelete(names, keep: keep) {
            try? fm.removeItem(at: folder.appendingPathComponent(name))
        }
        return target
    }
}

extension ShelfStore {
    /// Skriver en hel, konsistent kopi af databasen til `path` (filen må ikke findes i forvejen).
    public func backup(to path: String) throws {
        let quoted = path.replacingOccurrences(of: "'", with: "''")
        do { try db.execute("VACUUM INTO '\(quoted)'") }
        catch { throw SQLiteError(message: "Sikkerhedskopien kunne ikke gemmes.", userFacing: true) }
    }
}
