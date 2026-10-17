using System.Globalization;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace VinylShelfFinder.Core;

// Port af Sources/VinylCore/DiscogsCatalog.swift.
// Søgning i hele Discogs' katalog, udgaver af et album og ønskelisten.
// Selve købet sker på Discogs' hjemmeside (API'et kan ikke købe), se MarketplaceUrl.

/// Et album fra Discogs' katalog: en master, eller en release uden master.
public sealed record DiscogsAlbum(
    int Id,                          // master-id hvis IsMaster, ellers release-id
    bool IsMaster,
    string Title,                    // albumtitel uden "Kunstner – "
    string Artist,                   // renset kunstnernavn (fx uden "(2)")
    int? Year,
    Uri? ThumbUrl,
    Uri? CoverUrl,
    IReadOnlyList<string> Formats,   // fx ["Vinyl", "LP", "Album"] – kan være tom for masters
    bool InCollection,               // fra søgeresultatets user_data
    bool InWantlist,
    /// Stregkoder fra søgeresultatet (findes oftest kun for enkelte udgaver, ikke masters).
    /// Bruges til at finde præcis samme vare hos iMusic.
    IReadOnlyList<string> Barcodes = null!)
{
    public IReadOnlyList<string> Barcodes { get; init; } = Barcodes ?? Array.Empty<string>();

    /// Sorterer søgeresultater, så album, der indeholder flere af søgeordene i kunstner og titel,
    /// kommer først ("blue latour" → "LaTour – Blue" før "LaTour – LaTour"). Ellers Discogs' rækkefølge.
    public static List<DiscogsAlbum> RankedForQuery(IReadOnlyList<DiscogsAlbum> albums, string query)
    {
        var words = FoldWords(query).ToHashSet();
        if (words.Count <= 1) return albums.ToList();
        int Score(DiscogsAlbum a)
        {
            var have = FoldWords($"{a.Artist} {a.Title}").ToHashSet();
            return words.Count(have.Contains);
        }
        return albums.Select((a, i) => (a, i, s: Score(a)))
            .OrderByDescending(x => x.s).ThenBy(x => x.i)
            .Select(x => x.a).ToList();
    }

    /// Små bogstaver uden accenter, delt ved alt andet end bogstaver og tal.
    private static IEnumerable<string> FoldWords(string s)
    {
        var d = s.ToLowerInvariant().Normalize(NormalizationForm.FormD);
        var sb = new StringBuilder(d.Length);
        foreach (var c in d)
            if (CharUnicodeInfo.GetUnicodeCategory(c) != UnicodeCategory.NonSpacingMark) sb.Append(c);
        var folded = sb.ToString().Normalize(NormalizationForm.FormC);
        var cur = new StringBuilder();
        foreach (var c in folded)
        {
            if (char.IsLetter(c) || char.IsNumber(c)) { cur.Append(c); continue; }
            if (cur.Length > 0) { yield return cur.ToString(); cur.Clear(); }
        }
        if (cur.Length > 0) yield return cur.ToString();
    }
}

/// Én udgave (release) af et album.
public sealed record DiscogsVersion(
    int Id,                // release-id
    string Title,
    string Format,         // læsbar tekst, fx "Vinyl, LP, Album, Reissue"
    string Label,
    string Catno,
    string Country,
    int? Year,
    Uri? ThumbUrl,
    bool InCollection,
    bool InWantlist,
    /// Hvor udbredt udgaven er: antal Discogs-brugere, der har den eller ønsker sig den.
    int Popularity = 0)
{
    /// De mest udbredte udgaver først (stabil: lige udbredte beholder Discogs' rækkefølge).
    public static List<DiscogsVersion> MostPopularFirst(IEnumerable<DiscogsVersion> list) =>
        list.OrderByDescending(v => v.Popularity).ToList();   // OrderBy er stabil i .NET
}

/// Én side søgeresultater.
public sealed record DiscogsSearchPage(IReadOnlyList<DiscogsAlbum> Albums, bool HasMore);

/// Én side udgaver. Total er Discogs' samlede antal udgaver (med formatfilteret), ikke kun denne side.
public sealed record DiscogsVersionsPage(IReadOnlyList<DiscogsVersion> Versions, bool HasMore, int Total);

public sealed partial class DiscogsClient
{
    public const int SearchPageSize = 50;
    public const int VersionsPageSize = 100;
    /// Finder master-søgningen mindst så mange album, søges der ikke også efter enkelte udgaver.
    public const int ReleaseSearchBelow = 10;

    /// Søger efter album i hele Discogs (alle formater). Masters + releases uden master,
    /// uden dubletter. Kræver token (database/search).
    ///
    /// Først søges der kun efter masters (ét kald). Finder den mindst ReleaseSearchBelow album,
    /// er det nok. Ellers søges der også efter releases (type=release), så album uden master og
    /// søgninger på katalognummer eller stregkode stadig giver resultater. Releases med master vises
    /// via deres master; finder master-søgningen intet, vises releases som enkelte udgaver.
    /// format (fx "Vinyl", "CD", "Cassette") begrænser søgningen til udgivelser i det format;
    /// null = alle formater.
    public async Task<DiscogsSearchPage> SearchAlbumsAsync(string query, int page = 1, string? format = null, CancellationToken ct = default)
    {
        var q = query.Trim();
        if (q.Length == 0) return new DiscogsSearchPage(Array.Empty<DiscogsAlbum>(), false);
        if (!HasToken) throw DiscogsException.MissingToken();
        var common = new List<(string, string)> { ("q", q), ("page", Math.Max(1, page).ToString()), ("per_page", SearchPageSize.ToString()) };
        if (!string.IsNullOrEmpty(format)) common.Add(("format", format));
        var m = await GetAsync("/database/search", common.Append(("type", "master")), DiscogsPriority.Interactive, ct).ConfigureAwait(false);
        if (MastersOnly(m) is { } enough) return enough;
        var r = await GetAsync("/database/search", common.Append(("type", "release")), DiscogsPriority.Interactive, ct).ConfigureAwait(false);
        return CombineSearch(m, r);
    }

    /// Master-søgningen alene, hvis den fandt nok album (se ReleaseSearchBelow); ellers null.
    /// Afgørelsen bygger på det samlede antal, så alle sider af samme søgning behandles ens.
    public static DiscogsSearchPage? MastersOnly(byte[] masters)
    {
        var m = DecodeSearch(masters);
        if (m.Total < ReleaseSearchBelow) return null;
        return new DiscogsSearchPage(Albums(m.Results.Where(r => r.Type == "master"), keepReleasesWithMaster: false), m.HasMore);
    }

    /// Udgaver af et album: for en master /masters/{id}/versions (Discogs' standardsortering),
    /// for en release uden master én version (/releases/{id}).
    /// format filtrerer udgaverne (Discogs' eget filter på /masters/{id}/versions).
    public async Task<DiscogsVersionsPage> VersionsAsync(DiscogsAlbum album, int page = 1, string? format = null, CancellationToken ct = default)
    {
        if (album.IsMaster)
        {
            var query = new List<(string, string)> { ("page", Math.Max(1, page).ToString()), ("per_page", VersionsPageSize.ToString()) };
            if (!string.IsNullOrEmpty(format)) query.Add(("format", format));
            var data = await GetAsync($"/masters/{album.Id}/versions", query, DiscogsPriority.Interactive, ct).ConfigureAwait(false);
            return ParseVersions(data);
        }
        if (page > 1) return new DiscogsVersionsPage(Array.Empty<DiscogsVersion>(), false, 1);
        var rel = await GetAsync($"/releases/{album.Id}", priority: DiscogsPriority.Interactive, ct: ct).ConfigureAwait(false);
        var version = ParseReleaseVersion(rel, album.InCollection, album.InWantlist);
        return new DiscogsVersionsPage(new[] { version }, false, 1);
    }

    /// PUT /users/{username}/wants/{release_id}
    public async Task AddToWantlistAsync(string username, int releaseId, CancellationToken ct = default)
    {
        if (!HasToken) throw DiscogsException.MissingToken();
        await PerformAsync(WantlistRequest(username, releaseId), DiscogsPriority.Interactive, ct).ConfigureAwait(false);
    }

    /// Forespørgslen bag AddToWantlistAsync – bygges uden netværk, så den kan tjekkes.
    public DiscogsRequest WantlistRequest(string username, int releaseId) =>
        MakeRequest("PUT", $"/users/{EscapePath(username)}/wants/{releaseId}");

    /// https://www.discogs.com/sell/release/{id} – Discogs' liste over sælgere af præcis den udgave.
    public static Uri MarketplaceUrl(int releaseId) => new($"https://www.discogs.com/sell/release/{releaseId}");

    /// Discogs' markedsplads for et helt album (alle udgaver af en master), evt. kun i ét format:
    /// https://www.discogs.com/sell/list?master_id={id}&amp;format={Vinyl|CD|Cassette} (uden format = alle).
    public static Uri MarketplaceUrl(int masterId, string? format)
    {
        var s = $"https://www.discogs.com/sell/list?master_id={masterId}";
        if (!string.IsNullOrEmpty(format)) s += "&format=" + Uri.EscapeDataString(format);
        return new Uri(s);
    }

    /// GET /masters/{id}: laveste pris og antal til salg for hele albummet (alle formater samlet)
    /// og albummets hovedudgave. Prisen er i brugerens Discogs-valuta (se UserCurrencyAsync).
    public async Task<MasterOffer> MasterOfferAsync(int id, CancellationToken ct = default) =>
        ParseMasterOffer(await GetAsync($"/masters/{id}", ct: ct).ConfigureAwait(false));

    /// GET /users/{username} → curr_abbr: valutaen, Discogs viser brugerens priser i.
    /// null, hvis Discogs ikke oplyser den.
    public async Task<string?> UserCurrencyAsync(string username, CancellationToken ct = default) =>
        ParseUserCurrency(await GetAsync($"/users/{EscapePath(username)}", ct: ct).ConfigureAwait(false));

    /// https://www.discogs.com/release/{id}
    public static Uri ReleasePageUrl(int releaseId) => new($"https://www.discogs.com/release/{releaseId}");

    // MARK: Rene parsere

    /// Ét svar fra /database/search → album. Masters og releases uden master; releases med master
    /// vises via deres master. Artister, labels og dubletter springes over.
    public static DiscogsSearchPage ParseSearch(byte[] data)
    {
        var page = DecodeSearch(data);
        return new DiscogsSearchPage(Albums(page.Results, keepReleasesWithMaster: false), page.HasMore);
    }

    /// Samler master- og release-søgningen til én side album (se SearchAlbumsAsync).
    public static DiscogsSearchPage CombineSearch(byte[] masters, byte[] releases)
    {
        var m = DecodeSearch(masters);
        var r = DecodeSearch(releases);
        // Ingen masters overhovedet → søgningen ramte konkrete udgaver (katalognr., stregkode …).
        var fallback = m.Total == 0;
        var all = m.Results.Where(x => x.Type == "master").Concat(r.Results.Where(x => x.Type == "release"));
        return new DiscogsSearchPage(Albums(all, keepReleasesWithMaster: fallback), m.HasMore || r.HasMore);
    }

    /// Svar fra /masters/{id}/versions → udgaver.
    public static DiscogsVersionsPage ParseVersions(byte[] data)
    {
        var versions = new List<DiscogsVersion>();
        bool hasMore;
        int? total;
        try
        {
            using var doc = JsonDocument.Parse(data);
            var root = doc.RootElement;
            if (root.ValueKind != JsonValueKind.Object) throw new FormatException();
            var list = Json.Prop(root, "versions");
            if (list is not { ValueKind: JsonValueKind.Array } arr) throw new FormatException();
            (hasMore, total) = Pagination(root);
            foreach (var v in arr.EnumerateArray())
            {
                if (v.ValueKind != JsonValueKind.Object || Json.Int(Json.Prop(v, "id")) is not int id) continue;
                var stats = Json.Prop(v, "stats");
                var user = stats is { ValueKind: JsonValueKind.Object } s ? Json.Prop(s, "user") : null;
                var community = stats is { ValueKind: JsonValueKind.Object } s2 ? Json.Prop(s2, "community") : null;
                var label = Json.Str(Json.Prop(v, "label"));
                versions.Add(new DiscogsVersion(
                    id,
                    Json.Str(Json.Prop(v, "title")) ?? "",
                    VersionFormat(Json.StrArray(Json.Prop(v, "major_formats")) ?? new List<string>(), Json.Str(Json.Prop(v, "format")) ?? ""),
                    label == null ? "" : CleanDiscogsName(label),
                    CleanCatno(Json.Str(Json.Prop(v, "catno"))),
                    Json.Str(Json.Prop(v, "country")) ?? "",
                    YearValue(Json.FlexString(Json.Prop(v, "released"))),
                    ImageUrl(Json.Str(Json.Prop(v, "thumb"))),
                    Flag(user, "in_collection"),
                    Flag(user, "in_wantlist"),
                    Count(community, "in_collection") + Count(community, "in_wantlist")));
            }
        }
        catch (Exception e) when (e is JsonException or FormatException)
        {
            throw DiscogsException.Decoding("udgaverne");
        }
        return new DiscogsVersionsPage(versions, hasMore, total ?? versions.Count);

        static bool Flag(JsonElement? o, string name) =>
            o is { ValueKind: JsonValueKind.Object } x && Json.FlexBool(Json.Prop(x, name)) == true;
        static int Count(JsonElement? o, string name) =>
            o is { ValueKind: JsonValueKind.Object } x ? Json.FlexInt(Json.Prop(x, name)) ?? 0 : 0;
    }

    /// Svar fra /releases/{id} → én udgave (bruges for releases uden master).
    /// /releases har ingen brugerdata, så de kommer fra søgeresultatet.
    public static DiscogsVersion ParseReleaseVersion(byte[] data, bool inCollection, bool inWantlist)
    {
        try
        {
            using var doc = JsonDocument.Parse(data);
            var r = doc.RootElement;
            if (r.ValueKind != JsonValueKind.Object || Json.Int(Json.Prop(r, "id")) is not int id) throw new FormatException();
            var formats = Json.Array(Json.Prop(r, "formats")).Where(f => f.ValueKind == JsonValueKind.Object).Select(f =>
            {
                var parts = new List<string>();
                var name = Json.Str(Json.Prop(f, "name")) ?? "";
                var qty = Json.Str(Json.Prop(f, "qty"));
                if (qty != null && int.TryParse(qty, NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture, out var n) && n > 1) parts.Add($"{n}×{name}");
                else if (name.Length > 0) parts.Add(name);
                parts.AddRange(Json.StrArray(Json.Prop(f, "descriptions")) ?? new List<string>());
                if (Json.Str(Json.Prop(f, "text")) is { Length: > 0 } t) parts.Add(t);
                return string.Join(", ", parts.Where(p => p.Length > 0));
            }).Where(s => s.Length > 0);
            var label = Json.Array(Json.Prop(r, "labels")).FirstOrDefault();
            var hasLabel = label.ValueKind == JsonValueKind.Object;
            var labelName = hasLabel ? Json.Str(Json.Prop(label, "name")) : null;
            var y = Json.FlexInt(Json.Prop(r, "year"));
            var year = y > 0 ? y : YearValue(Json.FlexString(Json.Prop(r, "released")));
            var firstImage = Json.Array(Json.Prop(r, "images")).FirstOrDefault();
            var uri150 = firstImage.ValueKind == JsonValueKind.Object ? Json.Str(Json.Prop(firstImage, "uri150")) : null;
            return new DiscogsVersion(
                id, Json.Str(Json.Prop(r, "title")) ?? "", string.Join(" + ", formats),
                labelName == null ? "" : CleanDiscogsName(labelName),
                CleanCatno(hasLabel ? Json.Str(Json.Prop(label, "catno")) : null),
                Json.Str(Json.Prop(r, "country")) ?? "", year,
                ImageUrl(Json.Str(Json.Prop(r, "thumb"))) ?? ImageUrl(uri150),
                inCollection, inWantlist);
        }
        catch (Exception e) when (e is JsonException or FormatException)
        {
            throw DiscogsException.Decoding("udgaven");
        }
    }

    /// Svar fra /masters/{id} → markedstal for hele albummet. curr_abbr er ikke dokumenteret
    /// for masters, men læses, hvis Discogs sender den.
    public static MasterOffer ParseMasterOffer(byte[] data)
    {
        try
        {
            using var doc = JsonDocument.Parse(data);
            var m = doc.RootElement;
            if (m.ValueKind != JsonValueKind.Object || Json.Int(Json.Prop(m, "id")) is null) throw new FormatException();
            var main = Json.FlexInt(Json.Prop(m, "main_release"));
            return new MasterOffer(
                Json.Double(Json.Prop(m, "lowest_price")),
                CurrencyCode(Json.Str(Json.Prop(m, "curr_abbr"))),
                Json.FlexInt(Json.Prop(m, "num_for_sale")),
                main > 0 ? main : null);
        }
        catch (Exception e) when (e is JsonException or FormatException)
        {
            throw DiscogsException.Decoding("albummets priser");
        }
    }

    /// Svar fra /users/{username} → brugerens valuta (curr_abbr). Tom eller manglende → null.
    public static string? ParseUserCurrency(byte[] data)
    {
        try
        {
            using var doc = JsonDocument.Parse(data);
            if (doc.RootElement.ValueKind != JsonValueKind.Object) throw new FormatException();
            return CurrencyCode(Json.Str(Json.Prop(doc.RootElement, "curr_abbr")));
        }
        catch (Exception e) when (e is JsonException or FormatException)
        {
            throw DiscogsException.Decoding("din valuta");
        }
    }

    /// "eur " → "EUR". Kun tre bogstaver godtages; alt andet → null.
    internal static string? CurrencyCode(string? s)
    {
        var c = s?.Trim().ToUpperInvariant();
        if (c == null || c.Length != 3 || !c.All(ch => ch is >= 'A' and <= 'Z')) return null;
        return c;
    }

    // MARK: Hjælpere

    /// Deler "Kunstner - Titel" (Discogs bruger " - "; " – " accepteres også) ved første skilletegn.
    internal static (string Artist, string Title) SplitSearchTitle(string s)
    {
        int best = -1, len = 0;
        foreach (var sep in new[] { " - ", " – ", " — " })
        {
            var i = s.IndexOf(sep, StringComparison.Ordinal);
            if (i >= 0 && (best < 0 || i < best)) { best = i; len = sep.Length; }
        }
        if (best < 0) return ("", s.Trim());
        return (CleanSearchArtist(s[..best]), s[(best + len)..].Trim());
    }

    private static readonly Regex SearchNumberSuffix = new(@"\s\(\d+\)(?=$|\s|,)", RegexOptions.CultureInvariant);
    private static readonly Regex AnvStar = new(@"(?<=\S)\*(?=$|\s|,)", RegexOptions.CultureInvariant);

    /// "Nirvana (2)" → "Nirvana", også inde i "A (2) &amp; B (3)". ANV-stjerner ("Simon*") fjernes.
    internal static string CleanSearchArtist(string s)
    {
        var noNumbers = SearchNumberSuffix.Replace(s, "");
        var noStars = AnvStar.Replace(noNumbers, "");
        return CleanDiscogsName(noStars.Trim());
    }

    /// "Vinyl" + "LP, Album, Stereo" → "Vinyl, LP, Album, Stereo" (uden gentagelser).
    internal static string VersionFormat(IEnumerable<string> major, string format)
    {
        var seen = new HashSet<string>();
        var output = new List<string>();
        foreach (var raw in major.Concat(format.Split(',')))
        {
            var p = raw.Trim();
            if (p.Length > 0 && seen.Add(p.ToLowerInvariant())) output.Add(p);
        }
        return string.Join(", ", output);
    }

    /// "1969", "1969-09-26", 1969 → 1969. "0", "" og null → null.
    internal static int? YearValue(string? s)
    {
        if (s == null) return null;
        var head = s.Length > 4 ? s[..4] : s;
        return int.TryParse(head, NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture, out var y) && y > 0 ? y : null;
    }

    internal static string CleanCatno(string? s)
    {
        var t = s?.Trim();
        if (t == null || t.ToLowerInvariant() == "none") return "";
        return t;
    }

    internal static Uri? ImageUrl(string? s)
    {
        if (string.IsNullOrEmpty(s) || s.Contains("spacer.gif")) return null;
        return Uri.TryCreate(s, UriKind.Absolute, out var u) ? u : null;
    }

    internal sealed record SearchResult(int Id, string? Type, int? MasterId, string? Title, string? Year, string? Thumb,
                                        string? CoverImage, List<string>? Format, bool InCollection, bool InWantlist, List<string>? Barcode);

    internal static List<DiscogsAlbum> Albums(IEnumerable<SearchResult> results, bool keepReleasesWithMaster)
    {
        var seen = new HashSet<string>();
        var output = new List<DiscogsAlbum>();
        foreach (var r in results)
        {
            bool isMaster;
            switch (r.Type)
            {
                case "master": isMaster = true; break;
                case "release":
                    if (r.MasterId is int m && m > 0 && !keepReleasesWithMaster) continue;
                    isMaster = false;
                    break;
                default: continue;   // artist, label …
            }
            if (!seen.Add($"{(isMaster ? "m" : "r")}{r.Id}")) continue;
            var (artist, title) = SplitSearchTitle(r.Title ?? "");
            var formats = new List<string>();
            foreach (var f in r.Format ?? new List<string>())
                if (f.Length > 0 && !formats.Contains(f)) formats.Add(f);
            output.Add(new DiscogsAlbum(
                r.Id, isMaster, title, artist, YearValue(r.Year), ImageUrl(r.Thumb), ImageUrl(r.CoverImage),
                formats, r.InCollection, r.InWantlist, r.Barcode ?? new List<string>()));
        }
        return output;
    }

    internal static (List<SearchResult> Results, bool HasMore, int Total) DecodeSearch(byte[] data)
    {
        try
        {
            using var doc = JsonDocument.Parse(data);
            var root = doc.RootElement;
            if (root.ValueKind != JsonValueKind.Object) throw new FormatException();
            var list = Json.Prop(root, "results");
            if (list is not { ValueKind: JsonValueKind.Array } arr) throw new FormatException();
            var (hasMore, total) = Pagination(root);
            var results = new List<SearchResult>();
            foreach (var r in arr.EnumerateArray())
            {
                // Et element, der ikke kan læses, springes over i stedet for at vælte hele siden.
                if (r.ValueKind != JsonValueKind.Object || Json.Int(Json.Prop(r, "id")) is not int id) continue;
                var ud = Json.Prop(r, "user_data");
                bool Flag(string n) => ud is { ValueKind: JsonValueKind.Object } u && Json.FlexBool(Json.Prop(u, n)) == true;
                results.Add(new SearchResult(
                    id, Json.Str(Json.Prop(r, "type")), Json.FlexInt(Json.Prop(r, "master_id")), Json.Str(Json.Prop(r, "title")),
                    Json.FlexString(Json.Prop(r, "year")), Json.Str(Json.Prop(r, "thumb")), Json.Str(Json.Prop(r, "cover_image")),
                    Json.StrArray(Json.Prop(r, "format")), Flag("in_collection"), Flag("in_wantlist"), Json.StrArray(Json.Prop(r, "barcode"))));
            }
            return (results, hasMore, total ?? results.Count);
        }
        catch (Exception e) when (e is JsonException or FormatException)
        {
            throw DiscogsException.Decoding("søgeresultaterne");
        }
    }

    /// pagination: flere sider, hvis page &lt; pages; items er det samlede antal.
    private static (bool HasMore, int? Total) Pagination(JsonElement root)
    {
        var p = Json.Prop(root, "pagination");
        if (p == null) return (false, null);
        if (p.Value.ValueKind != JsonValueKind.Object) throw new FormatException();
        var page = Json.FlexInt(Json.Prop(p.Value, "page"));
        var pages = Json.FlexInt(Json.Prop(p.Value, "pages"));
        return (page != null && pages != null && page < pages, Json.FlexInt(Json.Prop(p.Value, "items")));
    }
}

/// Tolerante JSON-hjælpere: manglende eller forkerte felter giver null, ikke fejl.
internal static class Json
{
    /// Feltet, hvis det findes og ikke er null.
    public static JsonElement? Prop(JsonElement o, string name) =>
        o.ValueKind == JsonValueKind.Object && o.TryGetProperty(name, out var v) && v.ValueKind != JsonValueKind.Null ? v : null;

    public static IEnumerable<JsonElement> Array(JsonElement? e) =>
        e is { ValueKind: JsonValueKind.Array } a ? a.EnumerateArray() : Enumerable.Empty<JsonElement>();

    /// Kun tekst.
    public static string? Str(JsonElement? e) => e is { ValueKind: JsonValueKind.String } s ? s.GetString() : null;

    /// Liste af tekster (en liste med andet end tekst → null).
    public static List<string>? StrArray(JsonElement? e)
    {
        if (e is not { ValueKind: JsonValueKind.Array } a) return null;
        var output = new List<string>();
        foreach (var x in a.EnumerateArray())
        {
            if (x.ValueKind != JsonValueKind.String) return null;
            output.Add(x.GetString()!);
        }
        return output;
    }

    /// Kun et heltal.
    public static int? Int(JsonElement? e) =>
        e is { ValueKind: JsonValueKind.Number } n && n.TryGetInt32(out var i) ? i : null;

    /// Kun et tal.
    public static double? Double(JsonElement? e) =>
        e is { ValueKind: JsonValueKind.Number } n && n.TryGetDouble(out var d) ? d : null;

    /// Tal, der kan komme som 1973 eller "1973".
    public static int? FlexInt(JsonElement? e)
    {
        if (Int(e) is int i) return i;
        if (Str(e) is string s && int.TryParse(s.Trim(), NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture, out var v)) return v;
        return null;
    }

    /// Beløb, der kan komme som 3.36 eller "3.36".
    public static double? FlexDouble(JsonElement? e)
    {
        if (Double(e) is double d) return d;
        if (Str(e) is string s && double.TryParse(s.Trim(), NumberStyles.AllowLeadingSign | NumberStyles.AllowDecimalPoint | NumberStyles.AllowExponent,
                CultureInfo.InvariantCulture, out var v)) return v;
        return null;
    }

    /// Tekst, der kan komme som "1969-09-26" eller 1969.
    public static string? FlexString(JsonElement? e)
    {
        if (Str(e) is string s) return s;
        if (e is { ValueKind: JsonValueKind.Number } n && n.TryGetInt64(out var i)) return i.ToString(CultureInfo.InvariantCulture);
        return null;
    }

    /// Ja/nej, der kan komme som true/false eller 1/0.
    public static bool? FlexBool(JsonElement? e) => e?.ValueKind switch
    {
        JsonValueKind.True => true,
        JsonValueKind.False => false,
        JsonValueKind.Number when e.Value.TryGetInt64(out var i) => i != 0,
        _ => null,
    };
}
