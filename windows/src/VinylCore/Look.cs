namespace VinylShelfFinder.Core;

/// <summary>Udseende: tema og stil, som i webappen (web/app.css) og Look.swift. Valget gemmes kun på enheden.</summary>
public enum LookTheme { Auto, Light, Dark }

/// <summary>En stils farver i lys eller mørk tilstand (RGB som 0xRRGGBB).</summary>
public sealed record LookColors(uint Background, uint Cell, uint Label, uint Accent, uint AccentInk);

public enum LookStyle { Standard, Kasse, Cover, Fokus }

public static class Look
{
    public static string Id(this LookTheme t) => t switch { LookTheme.Light => "light", LookTheme.Dark => "dark", _ => "" };
    public static string Name(this LookTheme t) => t switch { LookTheme.Light => "Lys", LookTheme.Dark => "Mørk", _ => "Automatisk" };
    public static LookTheme ThemeFrom(string? id) => id switch { "light" => LookTheme.Light, "dark" => LookTheme.Dark, _ => LookTheme.Auto };

    public static string Id(this LookStyle s) => s switch { LookStyle.Kasse => "kasse", LookStyle.Cover => "cover", LookStyle.Fokus => "fokus", _ => "" };
    public static LookStyle StyleFrom(string? id) => id switch { "kasse" => LookStyle.Kasse, "cover" => LookStyle.Cover, "fokus" => LookStyle.Fokus, _ => LookStyle.Standard };

    public static string Name(this LookStyle s) => s switch
    {
        LookStyle.Kasse => "Hi-fi",
        LookStyle.Cover => "Farve fra coveret",
        LookStyle.Fokus => "Covers i fokus",
        _ => "Standard",
    };

    public static string Note(this LookStyle s) => s switch
    {
        LookStyle.Kasse => "Børstet aluminium og signalrøde knapper, som en forstærker",
        LookStyle.Cover => "Lys aluminium. Pladeskærmen farves af coveret",
        LookStyle.Fokus => "Lys aluminium. Store covers på pladeskærmen og i listerne",
        _ => "Rent og enkelt, som Windows' egne apps",
    };

    /// <summary>Farverne i lys og mørk tilstand. null for Standard (systemets egne farver).</summary>
    public static (LookColors Light, LookColors Dark)? Palette(this LookStyle s) => s switch
    {
        LookStyle.Kasse => (new LookColors(0xD9DBDC, 0xF3F4F4, 0x1C1F22, 0xB8321C, 0xA02A16),
                            new LookColors(0x131415, 0x202224, 0xE9EBEC, 0xD4442B, 0xFF8A73)),
        LookStyle.Cover or LookStyle.Fokus => (new LookColors(0xD9DBDC, 0xF3F4F4, 0x1C1F22, 0x1C6E66, 0x1C6E66),
                                               new LookColors(0x131415, 0x202224, 0xE9EBEC, 0x2E9D8F, 0x5EC4B6)),
        _ => null,
    };

    /// <summary>Smalle, fede overskrifter som på skillekortet (Bahnschrift; systemets smalle skrift på Mac).</summary>
    public static bool CondensedTitles(this LookStyle s) => s != LookStyle.Standard;
    /// <summary>Større covers på pladeskærmen og i listerne.</summary>
    public static bool BigCovers(this LookStyle s) => s == LookStyle.Fokus;

    /// <summary>Til små farveprøver i indstillingerne (baggrund, mørk baggrund, accent).</summary>
    public static uint[] Swatch(this LookStyle s) => s switch
    {
        LookStyle.Kasse => new uint[] { 0xD9DBDC, 0x131415, 0xB8321C },
        LookStyle.Cover => new uint[] { 0xD9DBDC, 0x6E2F45, 0xE58C6A },
        LookStyle.Fokus => new uint[] { 0xD9DBDC, 0xF3F4F4, 0x8A7560 },
        _ => new uint[] { 0xF2F2F7, 0xFFFFFF, 0x1C6E66 },
    };
}
