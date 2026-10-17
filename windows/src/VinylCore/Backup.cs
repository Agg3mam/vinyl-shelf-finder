using System.Globalization;

namespace VinylShelfFinder.Core;

// Port af Sources/VinylCore/Backup.swift. På Windows ligger kopierne i OneDrive (hvis den findes)
// i stedet for iCloud Drive.

/// Automatisk sikkerhedskopi af databasen: én fil pr. dag, de `Keep` nyeste beholdes.
/// Kopien laves med SQLites VACUUM INTO, så den altid er hel – også mens appen kører (WAL).
public static class DatabaseBackup
{
    /// Så mange daglige kopier gemmes.
    public const int Keep = 14;

    private const string Prefix = "vinyl-";
    private const string Suffix = ".sqlite";
    public const string FolderName = "Vinyl Shelf Finder backup";

    /// Mappen til kopierne: OneDrive, hvis den findes (så kopien også overlever, at pc'en
    /// går i stykker), ellers Dokumenter.
    public static string DefaultFolder()
    {
        var oneDrive = Environment.GetEnvironmentVariable("OneDrive");
        var baseDir = !string.IsNullOrEmpty(oneDrive) && Directory.Exists(oneDrive)
            ? oneDrive
            : Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments);
        return Path.Combine(baseDir, FolderName);
    }

    /// Ligger mappen i OneDrive? `oneDriveRoot` er som standard %OneDrive%.
    public static bool IsInOneDrive(string folder, string? oneDriveRoot = null)
    {
        var root = oneDriveRoot ?? Environment.GetEnvironmentVariable("OneDrive");
        if (string.IsNullOrEmpty(root)) return false;
        var f = Path.GetFullPath(folder).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
        var r = Path.GetFullPath(root).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
        return f.Equals(r, StringComparison.OrdinalIgnoreCase)
            || f.StartsWith(r + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase)
            || f.StartsWith(r + Path.AltDirectorySeparatorChar, StringComparison.OrdinalIgnoreCase);
    }

    /// "vinyl-2026-10-01.sqlite" (dagen i lokal tid).
    public static string FileName(DateTimeOffset date) =>
        Prefix + date.ToLocalTime().ToString("yyyy-MM-dd", CultureInfo.InvariantCulture) + Suffix;

    /// Dagen (lokal midnat) i et filnavn fra FileName; andre filer → null (de røres aldrig).
    public static DateTimeOffset? DateFromFileName(string name)
    {
        if (!name.StartsWith(Prefix, StringComparison.Ordinal) || !name.EndsWith(Suffix, StringComparison.Ordinal)) return null;
        var day = name[Prefix.Length..^Suffix.Length];
        if (day.Length != 10) return null;
        if (!DateTime.TryParseExact(day, "yyyy-MM-dd", CultureInfo.InvariantCulture, DateTimeStyles.None, out var d)) return null;
        var local = DateTime.SpecifyKind(d, DateTimeKind.Local);
        return new DateTimeOffset(local, TimeZoneInfo.Local.GetUtcOffset(local));
    }

    /// De filer, der skal slettes, så kun de `keep` nyeste kopier er tilbage.
    /// Filer, der ikke er appens egne kopier, røres aldrig.
    public static List<string> NamesToDelete(IEnumerable<string> names, int keep = Keep) =>
        names.Select(n => (Name: n, Date: DateFromFileName(n)))
             .Where(x => x.Date is not null)
             .OrderByDescending(x => x.Date)
             .Skip(Math.Max(0, keep))
             .Select(x => x.Name).ToList();

    /// Den nyeste kopi i mappen (ud fra filnavnet), eller null.
    public static DateTimeOffset? Latest(string folder)
    {
        string[] names;
        try { names = Directory.GetFiles(folder).Select(Path.GetFileName).OfType<string>().ToArray(); }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { return null; }
        return names.Select(DateFromFileName).Where(d => d is not null).Max();
    }

    /// Skal der tages en ny kopi? Ja, hvis der ingen er fra i dag (lokal tid).
    public static bool IsDue(DateTimeOffset? latest, DateTimeOffset? now = null)
    {
        if (latest is null) return true;
        var n = now ?? DateTimeOffset.Now;
        return latest.Value.ToLocalTime().Date != n.ToLocalTime().Date;
    }

    /// Tager en kopi nu (dagens fil erstattes) og rydder op i gamle kopier.
    /// Returnerer stien til den nye kopi.
    public static string Run(ShelfStore store, string folder, DateTimeOffset? now = null, int keep = Keep)
    {
        var n = now ?? DateTimeOffset.Now;
        Directory.CreateDirectory(folder);
        var target = Path.Combine(folder, FileName(n));
        // Først en midlertidig fil, så OneDrive aldrig ser en halv kopi.
        var partial = Path.Combine(folder, $".{FileName(n)}.partial");
        TryDelete(partial);
        try
        {
            store.Backup(partial);
            if (File.Exists(target)) File.Delete(target);
            File.Move(partial, target);
        }
        catch
        {
            TryDelete(partial);
            throw;
        }
        var names = Directory.GetFiles(folder).Select(Path.GetFileName).OfType<string>();
        foreach (var name in NamesToDelete(names, keep)) TryDelete(Path.Combine(folder, name));
        return target;
    }

    private static void TryDelete(string path)
    {
        try { if (File.Exists(path)) File.Delete(path); }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
    }
}

public sealed partial class ShelfStore
{
    /// Skriver en hel, konsistent kopi af databasen til `path` (filen må ikke findes i forvejen).
    public void Backup(string path)
    {
        var quoted = path.Replace("'", "''");
        try { Db.Execute($"VACUUM INTO '{quoted}'"); }
        catch (DatabaseException e) { throw new DatabaseException("Sikkerhedskopien kunne ikke gemmes.", userFacing: true, inner: e); }
    }
}
