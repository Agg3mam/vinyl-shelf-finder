using System.Runtime.CompilerServices;
using VinylShelfFinder.Core;

namespace VinylShelfFinder.Checks;

/// Fælles hjælpere til alle checks.
public static class Check
{
    public static int Failures;
    public static int Passes;

    /// Tæller et bestået check, eller udskriver beskeden og linjen.
    public static void That(bool condition, string message, [CallerFilePath] string file = "", [CallerLineNumber] int line = 0)
    {
        if (condition) { Passes++; return; }
        Failures++;
        Console.WriteLine($"✗ {Path.GetFileName(file)}:{line}: {message}");
    }

    /// Kører en blok, og tæller en uventet undtagelse som en fejl.
    public static void Section(string name, Action body, [CallerFilePath] string file = "", [CallerLineNumber] int line = 0)
    {
        try { body(); }
        catch (Exception e)
        {
            Failures++;
            Console.WriteLine($"✗ {Path.GetFileName(file)}:{line}: {name}: {e.GetType().Name}: {e.Message}");
        }
    }

    /// En midlertidig mappe, der slettes bagefter. Checks må aldrig røre brugerens rigtige data.
    public static string TempDir()
    {
        var dir = Path.Combine(Path.GetTempPath(), "vsf-check-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(dir);
        return dir;
    }

    public static DiscogsCollectionItem Item(int instance, int release, string artist, string title,
                                             int? year = null, string? label = null, string? cat = null) =>
        new(instance, null, new Release(release, artist, title, year, label, cat, "Vinyl, LP"));
}

static class ModelChecks
{
    public static void Run() => Check.Section("modeller", () =>
    {
        Check.That(CopyStatus.Lent.RawValue() == "lent" && CopyStatusExtensions.FromRaw("wall") == CopyStatus.Wall
                   && CopyStatusExtensions.FromRaw("??") == null, "status gemmes som samme tekst som på Mac");
        Check.That(CopyStatus.Home.IsOnShelf() && !CopyStatus.Wall.IsOnShelf(), "kun 'på plads' står i reolen");
        Check.That(HistoryKind.StatusChanged.RawValue() == "statusChanged" && HistoryKindExtensions.FromRaw("layoutCreated") == HistoryKind.LayoutCreated,
                   "historik-typer som på Mac");
        var it = new RecordItem(new Copy(1, 1, 106), new Release(106, "Pink Floyd", "The Dark Side Of The Moon", 1973, "Harvest", "SHVL 804", "Vinyl, LP"));
        Check.That(it.DetailLine == "1973 • Harvest • SHVL 804 • Vinyl, LP" && it.FullName == "Pink Floyd – The Dark Side Of The Moon",
                   "detaljelinje og fulde navn");
        Check.That(new Location(1, 2, "B", 0).Name == "Reol 2 · Sektion B" && new Location(1, 2, "B", 0).ShortName == "2B", "sektionsnavne");
    });
}
