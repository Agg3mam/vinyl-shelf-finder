using VinylShelfFinder.Core;

namespace VinylShelfFinder.Checks;

/// Opdatering fra GitHub Releases, uden net (port af samme afsnit i VinylCoreChecks/main.swift).
static class UpdateChecks
{
    const string Json = """{"tag_name":"v1.1.0","html_url":"https://github.com/Agg3mam/vinyl-shelf-finder/releases/tag/v1.1.0","draft":false,"prerelease":false,"body":"Cd'er får deres egen hylde.\r\n","assets":[{"name":"VinylShelfFinder-Windows-x64.zip","size":66000000,"browser_download_url":"https://github.com/Agg3mam/vinyl-shelf-finder/releases/download/v1.1.0/VinylShelfFinder-Windows-x64.zip"},{"name":"VinylShelfFinder-macOS.zip","size":9000000,"browser_download_url":"https://github.com/Agg3mam/vinyl-shelf-finder/releases/download/v1.1.0/VinylShelfFinder-macOS.zip"}]}""";

    public static void Run() => Check.Section("opdatering", () =>
    {
        AppVersion V(string s) => AppVersion.Parse(s)!;
        Check.That(V("v1.2.3") > V("1.2") && V("1.10") > V("1.9") && V("1.0").Equals(V("1.0.0")),
                   "versioner sammenlignes tal for tal");
        Check.That(AppVersion.Parse("v2.0.0-beta.1")?.ToString() == "2.0.0" && AppVersion.Parse("abc") == null
                   && AppVersion.Parse("") == null && AppVersion.Parse("1..2") == null && AppVersion.Parse("1.-2") == null,
                   "versionstekst renses, og affald afvises");

        var r = AppUpdate.ParseLatest(Json);
        Check.That(r?.Version.ToString() == "1.1.0" && r.DownloadUrl.Segments[^1] == "VinylShelfFinder-Windows-x64.zip"
                   && r.Notes == "Cd'er får deres egen hylde." && r.Size == 66000000,
                   "udgivelse læses: version, Windows-zip og tekst");
        Check.That(AppUpdate.ParseLatest(Json, "VinylShelfFinder-macOS.zip")?.Size == 9000000, "Mac-zippen findes også");
        Check.That(r != null && AppUpdate.IsNewer(r, "1.0.0") && !AppUpdate.IsNewer(r, "1.1") && !AppUpdate.IsNewer(r, "2.0"),
                   "kun nyere versioner tilbydes");
        Check.That(AppUpdate.ParseLatest(Json.Replace("\"prerelease\":false", "\"prerelease\":true")) == null,
                   "prøveudgaver tilbydes ikke");
        Check.That(AppUpdate.ParseLatest(Json.Replace("VinylShelfFinder-Windows-x64.zip", "andet.zip")) == null,
                   "udgave uden Windows-zip springes over");
        var evil = Json.Replace("https://github.com/Agg3mam/vinyl-shelf-finder/releases/download/v1.1.0/VinylShelfFinder-Windows-x64.zip",
                                "https://example.com/VinylShelfFinder-Windows-x64.zip");
        Check.That(AppUpdate.ParseLatest(evil) == null, "kun filer fra GitHub");
        Check.That(AppUpdate.IsTrustedHost("objects.githubusercontent.com") && !AppUpdate.IsTrustedHost("github.com.example.com")
                   && !AppUpdate.IsTrustedHost(null), "GitHubs downloadadresser");
        Check.That(AppUpdate.ParseLatest("ikke json") == null && AppUpdate.ParseLatest("[]") == null, "affald giver ingen opdatering");

        var now = DateTimeOffset.Now;
        Check.That(AppUpdate.IsCheckDue(null, now) && !AppUpdate.IsCheckDue(now.AddHours(-1), now)
                   && AppUpdate.IsCheckDue(now.AddHours(-25), now), "højst ét tjek pr. døgn");
    });
}
