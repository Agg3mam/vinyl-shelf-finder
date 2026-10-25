using System.Globalization;

namespace VinylShelfFinder.Core;

/// Eksport, import og nulstilling af hele systemet (reoler, placeringer, historik, lyttelog og indstillinger).
/// En eksport er en almindelig, hel SQLite-fil (VACUUM INTO), samme slags som de daglige sikkerhedskopier,
/// så både eksporter og sikkerhedskopier kan importeres.
///
/// Import og nulstilling kan ikke ske, mens databasen er åben. De bestilles derfor her og udføres af
/// <see cref="ApplyPending"/> ved næste start, før databasen åbnes.
public static class DataTransfer
{
    public const string Extension = ".sqlite";

    /// "Vinyl Shelf Finder 2026-10-17.sqlite"
    public static string ExportFileName(DateTimeOffset now) =>
        $"Vinyl Shelf Finder {now.ToLocalTime().ToString("yyyy-MM-dd", CultureInfo.InvariantCulture)}{Extension}";

    /// Sikkerhedskopien, der tages lige før en import eller nulstilling: "før-nulstilling-2026-10-17-2105.sqlite".
    /// Navnet ligner ikke de daglige kopier, så den ryddes aldrig væk automatisk.
    public static string SafetyFileName(string reason, DateTimeOffset now) =>
        $"før-{reason}-{now.ToLocalTime().ToString("yyyy-MM-dd-HHmmss", CultureInfo.InvariantCulture)}{Extension}";

    public static string ResetFlag(string dbPath) => dbPath + ".reset-pending";
    public static string ImportFile(string dbPath) => dbPath + ".import-pending";
    /// Den kontrollerede import, før brugeren har bekræftet. Bruges aldrig ved start.
    public static string StagedImport(string dbPath) => dbPath + ".import-staged";

    /// Skriver en hel kopi af databasen til `target`. En eksisterende fil erstattes.
    public static void Export(ShelfStore store, string target)
    {
        var dir = Path.GetDirectoryName(Path.GetFullPath(target))!;
        Directory.CreateDirectory(dir);
        var partial = Path.Combine(dir, $".{Path.GetFileName(target)}.{Guid.NewGuid():N}.partial");
        try
        {
            store.Backup(partial);
            File.Move(partial, target, overwrite: true);
        }
        finally { TryDelete(partial); }
    }

    /// Gemmer en sikkerhedskopi i `folder` og returnerer stien.
    public static string SafetyCopy(ShelfStore store, string folder, string reason, DateTimeOffset? now = null)
    {
        var target = Path.Combine(folder, SafetyFileName(reason, now ?? DateTimeOffset.Now));
        Export(store, target);
        return target;
    }

    /// Kontrollerer, at `source` er en database fra appen, og lægger en ren kopi til side (StagedImport).
    /// Den bruges først, når <see cref="CommitImport"/> kaldes efter brugerens ja og sikkerhedskopien.
    /// Kaster DatabaseException med en dansk besked, hvis filen ikke kan bruges. `source` røres ikke.
    public static ImportSummary RequestImport(string dbPath, string source)
    {
        if (!File.Exists(source)) throw new DatabaseException("Filen findes ikke.", userFacing: true);
        if (SamePath(source, dbPath)) throw new DatabaseException("Det er appens egen database. Vælg en eksport eller en sikkerhedskopi.", userFacing: true);
        var check = dbPath + ".import-check";
        DeleteDatabaseFiles(check);
        ImportSummary summary;
        try
        {
            File.Copy(source, check, overwrite: true);
            ShelfStore store;
            try
            {
                store = new ShelfStore(check);
            }
            catch (Exception e)
            {
                throw new DatabaseException("Filen er ikke en eksport fra Vinyl Shelf Finder.", userFacing: true, inner: e);
            }
            using (store)
            {
                try
                {
                    var counts = store.MediumCounts();
                    var sections = ShelfKind.All.Sum(k => store.LoadLibrary(k).Locations.Count);
                    summary = new ImportSummary(counts.GetValueOrDefault(Medium.Vinyl), counts.GetValueOrDefault(Medium.Cd), sections);
                }
                catch (Exception e)
                {
                    throw new DatabaseException("Filen er ikke en eksport fra Vinyl Shelf Finder.", userFacing: true, inner: e);
                }
                // En tom fil (eller en anden SQLite-fil) får skemaet ved åbning og ligner en tom samling.
                if (summary.Vinyl == 0 && summary.Cds == 0 && summary.Sections == 0)
                    throw new DatabaseException("Filen indeholder ingen plader, cd'er eller reoler. Vælg en eksport eller en sikkerhedskopi.", userFacing: true);
                DeleteDatabaseFiles(StagedImport(dbPath));
                store.Backup(StagedImport(dbPath));
            }
        }
        finally { DeleteDatabaseFiles(check); }
        return summary;
    }

    /// Brugeren har sagt ja, og sikkerhedskopien er taget: importen udføres ved næste start.
    public static void CommitImport(string dbPath)
    {
        if (!File.Exists(StagedImport(dbPath))) throw new DatabaseException("Importen er ikke klar. Vælg filen igen.", userFacing: true);
        TryDelete(ResetFlag(dbPath));
        DeleteDatabaseFiles(ImportFile(dbPath));
        File.Move(StagedImport(dbPath), ImportFile(dbPath));
    }

    /// Bestiller en nulstilling: ved næste start begynder appen med en tom database.
    public static void RequestReset(string dbPath)
    {
        DeleteDatabaseFiles(StagedImport(dbPath));
        DeleteDatabaseFiles(ImportFile(dbPath));
        File.WriteAllText(ResetFlag(dbPath), DateTimeOffset.Now.ToString("O", CultureInfo.InvariantCulture));
    }

    /// Fortryder en bestilt import eller nulstilling.
    public static void CancelPending(string dbPath)
    {
        TryDelete(ResetFlag(dbPath));
        DeleteDatabaseFiles(ImportFile(dbPath));
        DeleteDatabaseFiles(StagedImport(dbPath));
    }

    public enum Applied { None, Reset, Import }

    /// Kaldes ved start, før databasen åbnes. Venter lidt, hvis den gamle udgave af appen stadig lukker.
    public static Applied ApplyPending(string dbPath, int attempts = 40, int delayMs = 250)
    {
        // En import, der aldrig blev bekræftet (fx lukket midt i dialogen), bruges ikke.
        DeleteDatabaseFiles(StagedImport(dbPath));
        bool reset = File.Exists(ResetFlag(dbPath));
        bool import = File.Exists(ImportFile(dbPath));
        if (!reset && !import) return Applied.None;
        for (int i = 0; ; i++)
        {
            try
            {
                DeleteDatabaseFiles(dbPath, strict: true);
                if (import) File.Move(ImportFile(dbPath), dbPath);
                TryDelete(ResetFlag(dbPath));
                return import ? Applied.Import : Applied.Reset;
            }
            catch (Exception e) when ((e is IOException or UnauthorizedAccessException) && i + 1 < attempts)
            {
                Thread.Sleep(delayMs);
            }
        }
    }

    /// Databasen og dens WAL-filer.
    private static void DeleteDatabaseFiles(string path, bool strict = false)
    {
        foreach (var p in new[] { path, path + "-wal", path + "-shm", path + "-journal" })
        {
            if (strict) { if (File.Exists(p)) File.Delete(p); }
            else TryDelete(p);
        }
    }

    private static bool SamePath(string a, string b) =>
        string.Equals(Path.GetFullPath(a), Path.GetFullPath(b), StringComparison.OrdinalIgnoreCase);

    private static void TryDelete(string path)
    {
        try { if (File.Exists(path)) File.Delete(path); }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
    }
}

/// Det, en import indeholder (vises, før brugeren bekræfter).
public sealed record ImportSummary(int Vinyl, int Cds, int Sections);
