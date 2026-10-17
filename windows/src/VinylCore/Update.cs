using System.Text.Json;

namespace VinylShelfFinder.Core;

// Opdatering fra GitHub Releases (port af Update.swift). Appen spørger
// https://api.github.com/repos/Agg3mam/vinyl-shelf-finder/releases/latest højst én gang om dagen.
// Her ligger kun de rene dele (versioner, svaret fra GitHub, hvornår der skal tjekkes), så de kan
// testes uden net. Selve hentningen og udskiftningen af appen sker i appen (Updater.cs).

/// En version som "1.2.3". Et foranstillet "v" og alt efter "-" eller "+" ignoreres.
public sealed class AppVersion : IComparable<AppVersion>, IEquatable<AppVersion>
{
    public IReadOnlyList<int> Parts { get; }

    private AppVersion(List<int> parts) => Parts = parts;

    public static AppVersion? Parse(string? text)
    {
        var t = (text ?? "").Trim();
        if (t.StartsWith('v') || t.StartsWith('V')) t = t[1..];
        int cut = t.IndexOfAny(new[] { '-', '+' });
        if (cut >= 0) t = t[..cut];
        var parts = new List<int>();
        foreach (var p in t.Split('.'))
        {
            if (p.Length == 0 || !p.All(char.IsAsciiDigit) || !int.TryParse(p, out var n)) return null;
            parts.Add(n);
        }
        return parts.Count is >= 1 and <= 4 ? new AppVersion(parts) : null;
    }

    public override string ToString() => string.Join(".", Parts);

    public int CompareTo(AppVersion? other)
    {
        if (other is null) return 1;
        for (int i = 0; i < Math.Max(Parts.Count, other.Parts.Count); i++)
        {
            int x = i < Parts.Count ? Parts[i] : 0;
            int y = i < other.Parts.Count ? other.Parts[i] : 0;
            if (x != y) return x.CompareTo(y);
        }
        return 0;
    }

    public bool Equals(AppVersion? other) => CompareTo(other) == 0;
    public override bool Equals(object? obj) => obj is AppVersion v && Equals(v);
    public override int GetHashCode() => ToString().TrimEnd('0', '.').GetHashCode();
    public static bool operator <(AppVersion a, AppVersion b) => a.CompareTo(b) < 0;
    public static bool operator >(AppVersion a, AppVersion b) => a.CompareTo(b) > 0;
}

/// Den nyeste udgave på GitHub, som appen kan hente.
public sealed record UpdateRelease(AppVersion Version, string Tag, string Notes, Uri PageUrl, Uri DownloadUrl, long? Size);

public static class AppUpdate
{
    public const string Owner = "Agg3mam";
    public const string Repo = "vinyl-shelf-finder";
    public static readonly Uri LatestUrl = new($"https://api.github.com/repos/{Owner}/{Repo}/releases/latest");
    /// Navnet på Windows-appens zip i en udgivelse. Mac-zippen hedder VinylShelfFinder-macOS.zip.
    public const string WindowsAssetName = "VinylShelfFinder-Windows-x64.zip";

    /// Læser GitHubs svar fra /releases/latest. null, hvis der ikke er en brugbar udgave med
    /// den ønskede fil (fx en kladde, en prøveudgave eller en udgave uden Windows-zip).
    public static UpdateRelease? ParseLatest(string json, string assetName = WindowsAssetName)
    {
        try
        {
            using var doc = JsonDocument.Parse(json);
            var r = doc.RootElement;
            if (r.ValueKind != JsonValueKind.Object) return null;
            if (Bool(r, "draft") || Bool(r, "prerelease")) return null;
            var tag = Str(r, "tag_name");
            var version = AppVersion.Parse(tag);
            if (tag is null || version is null) return null;
            if (!Uri.TryCreate(Str(r, "html_url"), UriKind.Absolute, out var page)) return null;
            if (!r.TryGetProperty("assets", out var assets) || assets.ValueKind != JsonValueKind.Array) return null;
            foreach (var a in assets.EnumerateArray())
            {
                if (Str(a, "name") != assetName) continue;
                if (!Uri.TryCreate(Str(a, "browser_download_url"), UriKind.Absolute, out var url)
                    || url.Scheme != "https" || !IsTrustedHost(url.Host)) return null;
                long? size = a.TryGetProperty("size", out var s) && s.TryGetInt64(out var n) ? n : null;
                return new UpdateRelease(version, tag, (Str(r, "body") ?? "").Trim(), page, url, size);
            }
            return null;
        }
        catch (JsonException) { return null; }
    }

    /// Kun GitHubs egne adresser. Downloadet omdirigeres til objects.githubusercontent.com.
    public static bool IsTrustedHost(string? host)
    {
        if (string.IsNullOrEmpty(host)) return false;
        var h = host.ToLowerInvariant();
        return h == "github.com" || h == "api.github.com" || h.EndsWith(".githubusercontent.com");
    }

    /// Er udgaven nyere end den, der kører?
    public static bool IsNewer(UpdateRelease release, string current)
    {
        var cur = AppVersion.Parse(current);
        return cur is null || cur < release.Version;
    }

    /// Højst ét automatisk tjek pr. døgn.
    public static bool IsCheckDue(DateTimeOffset? last, DateTimeOffset now)
    {
        if (last is null) return true;
        return now - last.Value >= TimeSpan.FromHours(24) || now < last.Value;
    }

    static string? Str(JsonElement e, string name) =>
        e.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() : null;

    static bool Bool(JsonElement e, string name) =>
        e.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.True;
}
