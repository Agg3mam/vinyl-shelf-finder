using System.Net;
using System.Text;
using System.Text.Json;
using VinylShelfFinder.Core;

namespace VinylShelfFinder.Checks;

/// Falsk netværk til checks: svarer ud fra metode + sti (+ type=) og husker forespørgslerne.
/// Status 0 = ingen forbindelse. Rammer aldrig det rigtige netværk.
sealed class StubDiscogs : HttpMessageHandler
{
    public sealed record Seen(string Method, Uri Url, Dictionary<string, string> Headers, long? ContentLength)
    {
        public string? Header(string name) => Headers.TryGetValue(name, out var v) ? v : null;
        public List<(string Name, string Value)> Query => NetChecks.QueryItems(Url);
    }

    private readonly object _lock = new();
    private readonly List<Seen> _seen = new();
    public Dictionary<string, (int Status, string Body)> Routes = new();

    public List<Seen> SeenRequests { get { lock (_lock) return _seen.ToList(); } }
    public void ClearSeen() { lock (_lock) _seen.Clear(); }

    public static string Key(string method, Uri url)
    {
        var type = NetChecks.QueryItems(url).FirstOrDefault(q => q.Name == "type").Value;
        return $"{method} {url.AbsolutePath}" + (type == null ? "" : $"?type={type}");
    }

    protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken ct)
    {
        var headers = request.Headers.ToDictionary(h => h.Key, h => string.Join(",", h.Value));
        (int Status, string Body) route;
        lock (_lock)
        {
            _seen.Add(new Seen(request.Method.Method, request.RequestUri!, headers, request.Content?.Headers.ContentLength));
            route = Routes.TryGetValue(Key(request.Method.Method, request.RequestUri!), out var r) ? r : (404, "{}");
        }
        if (route.Status == 0) throw new HttpRequestException("Ingen forbindelse (stub)");
        var resp = new HttpResponseMessage((HttpStatusCode)route.Status)
        {
            Content = new ByteArrayContent(Encoding.UTF8.GetBytes(route.Body)),
            RequestMessage = request,
        };
        return Task.FromResult(resp);
    }
}

/// Checks for Discogs, kø, cache, priser og iMusic (port af de tilsvarende afsnit i VinylCoreChecks/main.swift).
static class NetChecks
{
    static byte[] B(string s) => Encoding.UTF8.GetBytes(s);

    /// Checks må ikke vente på den rigtige grænse (45 kald/min); denne kø er praktisk talt ubegrænset.
    static readonly DiscogsRateLimiter FastLimiter = new(100_000, 6_000_000);

    /// Kører async kode færdig og giver resultatet eller fejlen.
    static (T? Value, Exception? Error) Blocking<T>(Func<Task<T>> op)
    {
        try { return (Task.Run(op).GetAwaiter().GetResult(), null); }
        catch (Exception e) { return (default, e); }
    }

    static Exception? Blocking(Func<Task> op)
    {
        try { Task.Run(op).GetAwaiter().GetResult(); return null; }
        catch (Exception e) { return e; }
    }

    static string? ErrorText(Exception? e) => e?.Message;

    public static List<(string Name, string Value)> QueryItems(Uri url)
    {
        var q = url.Query.TrimStart('?');
        if (q.Length == 0) return new();
        return q.Split('&').Select(p =>
        {
            var i = p.IndexOf('=');
            return i < 0 ? (Uri.UnescapeDataString(p), "") : (Uri.UnescapeDataString(p[..i]), Uri.UnescapeDataString(p[(i + 1)..]));
        }).ToList();
    }

    static DiscogsClient StubClient(StubDiscogs stub, string token = "TEST-token", DiscogsResponseCache? cache = null) =>
        new(token, new HttpClient(stub), FastLimiter, cache);

    static DiscogsAlbum Album(int id, bool isMaster, string title = "", string artist = "", int? year = null,
                              IReadOnlyList<string>? formats = null, bool inCollection = false, bool inWantlist = false) =>
        new(id, isMaster, title, artist, year, null, null, formats ?? Array.Empty<string>(), inCollection, inWantlist);

    public static void Run()
    {
        DiscogsJson();
        Value();
        Catalog();
        Kroner();
        MarketStats();
        Cheapest();
        MasterCard();
        QueueAndCache();
        Secrets();
        IMusic();
    }

    // MARK: Discogs JSON (samlingen)
    static void DiscogsJson() => Check.Section("Discogs JSON", () =>
    {
        var json = """
        {"pagination":{"page":1,"pages":3,"per_page":100,"items":250,"urls":{}},
         "releases":[{"id":1873013,"instance_id":45123,"date_added":"2024-01-02T10:00:00-08:00","rating":0,
           "basic_information":{"id":1873013,"master_id":10362,"title":"The Dark Side Of The Moon","year":1973,
             "resource_url":"https://api.discogs.com/releases/1873013",
             "thumb":"https://i.discogs.com/t.jpg","cover_image":"https://i.discogs.com/c.jpg",
             "formats":[{"name":"Vinyl","qty":"1","descriptions":["LP","Album"]}],
             "labels":[{"name":"Harvest","catno":"SHVL 804","entity_type":"1","id":1}],
             "artists":[{"name":"Pink Floyd","anv":"","join":"","role":"","tracks":"","id":45467}],
             "genres":["Rock"],"styles":["Psychedelic Rock"]}},
          {"id":2,"instance_id":2,"basic_information":{"id":2,"title":"Bookends","year":0,
             "thumb":"","cover_image":"https://s.discogs.com/images/spacer.gif",
             "formats":[{"name":"Vinyl","qty":"2","descriptions":[]}],
             "labels":[{"name":"CBS (2)","catno":"none"}],
             "artists":[{"name":"Simon (4)","anv":"Simon","join":"&"},{"name":"Garfunkel","anv":"","join":""}]}}]}
        """;
        var parsed = DiscogsClient.ParseCollectionPage(B(json));
        Check.That(parsed.Pages == 3 && parsed.Total == 250 && parsed.Items.Count == 2, "pagination");
        var a = parsed.Items[0];
        var b = parsed.Items[1];
        Check.That(a.InstanceId == 45123 && a.Release.Id == 1873013 && a.Release.CatalogNumber == "SHVL 804", "release/instance id + catno");
        Check.That(a.Release.Format == "Vinyl, LP, Album", $"format: {a.Release.Format}");
        Check.That(a.Release.Year == 1973 && a.Release.Genres == "Rock" && a.Release.CoverUrl == "https://i.discogs.com/c.jpg"
                   && a.DateAdded == "2024-01-02T10:00:00-08:00", "år, genre, cover og dato");
        Check.That(b.Release.Artist == "Simon & Garfunkel", $"kunstner-join: {b.Release.Artist}");
        // Nye instance_id'er er større end int.MaxValue (2.147.483.647). Før gav det "samlingen kunne ikke læses".
        var big = DiscogsClient.ParseCollectionPage(B("""{"pagination":{"pages":1,"items":1},"releases":[{"id":5,"instance_id":2400000123,"basic_information":{"id":5,"title":"T","artists":[{"name":"A"}]}}]}"""));
        Check.That(big.Items.Count == 1 && big.Items[0].InstanceId == 2_400_000_123L, "instance_id over int.MaxValue");
        Check.That(b.Release.Year == null && b.Release.CatalogNumber == null && b.Release.CoverUrl == null && b.Release.ThumbUrl == null,
                   "manglende år/katalognr./cover");
        Check.That(b.Release.Label == "CBS" && b.Release.Format == "2×Vinyl", $"label uden (2), 2×Vinyl: {b.Release.Format}");
        try { DiscogsClient.ParseCollectionValue(B("ikke json")); Check.That(false, "ugyldig værdi-JSON skal fejle"); }
        catch (DiscogsException e) { Check.That(e.Message == "Svaret fra Discogs kunne ikke læses (samlingens værdi).", $"Discogs-fejl på dansk: {e.Message}"); }
        try { DiscogsClient.ParseCollectionPage(B("""{"pagination":{"pages":1,"items":1}}""")); Check.That(false, "samling uden releases skal fejle"); }
        catch (DiscogsException e) { Check.That(e.Kind == DiscogsErrorKind.Decoding, "samling uden releases → læsefejl"); }
        Check.That(DiscogsException.Offline().Message.StartsWith("Kunne ikke få forbindelse til Discogs"), "netværksfejl på dansk");
        Check.That(DiscogsClient.CleanDiscogsName("Nirvana (2)") == "Nirvana" && DiscogsClient.CleanDiscogsName("Area (51) Band") == "Area (51) Band",
                   "kun \" (2)\" til sidst fjernes");
    });

    // MARK: Værdi
    static void Value() => Check.Section("Værdi", () =>
    {
        var rel = """{"id":1,"title":"X","lowest_price":24.99,"num_for_sale":17,"community":{"have":5120,"want":1830,"rating":{"count":1}}}""";
        var m = DiscogsClient.ParseMarketInfo(B(rel), "EUR");
        Check.That(m.LowestPrice == 24.99 && m.NumForSale == 17 && m.Have == 5120 && m.Want == 1830 && m.Currency == "EUR", "markedsdata parses");
        var none = DiscogsClient.ParseMarketInfo(B("""{"id":2,"lowest_price":null,"num_for_sale":0}"""), "EUR");
        Check.That(none.LowestPrice == null && none.NumForSale == 0 && none.Demand == null, "ingen pris til salg");
        var v = DiscogsClient.ParseCollectionValue(B("""{"maximum":"€2,310.40","median":"€1,105.00","minimum":"€512.30"}"""));
        Check.That(v.Median == "€1,105.00" && v.Minimum == "€512.30" && v.Maximum == "€2,310.40", "samlingsværdi parses");
    });

    // MARK: Discogs-katalog: søg, udgaver, ønskeliste (offline)
    // Testdata: versions-siderne og releasen er rigtige, forkortede svar hentet uden login fra
    // api.discogs.com (/masters/10362/versions?per_page=5&page=1 og &page=309, /releases/249504?curr_abbr=EUR).
    // /database/search kræver login, så søgesvarene er bygget efter Discogs' dokumenterede format.
    const string FxVersionsP1 = """{"pagination":{"page":1,"pages":309,"per_page":5,"items":1542,"urls":{"last":"https://api.discogs.com/masters/10362/versions?per_page=5&page=309","next":"https://api.discogs.com/masters/10362/versions?per_page=5&page=2"}},"filters":{"applied":{},"available":{}},"versions":[{"id":10255816,"label":"Harvest","country":"Netherlands","title":"The Dark Side Of The Moon","major_formats":["Vinyl"],"format":"LP, Album, Stereo","catno":"5C062-05 249, 5C 062-05249","released":"1973","status":"Accepted","resource_url":"https://api.discogs.com/releases/10255816","thumb":"https://i.discogs.com/ltUm8Ofo-qRZ4W8FuGsF-fpCDZGKk2ARV58degIaY-8/rs:fit/g:sm/q:40/h:150/w:150/czM6Ly9kaXNjb2dz/LWRhdGFiYXNlLWlt/YWdlcy9SLTEwMjU1/ODE2LTE1NTI0OTUy/NzctNjI1Ni5qcGVn.jpeg","stats":{"community":{"in_wantlist":1703,"in_collection":1421}}},{"id":24571544,"label":"Harvest","country":"UK","title":"The Dark Side Of The Moon","major_formats":["Vinyl"],"format":"LP, Album, Misprint, Repress","catno":"SHVL 804","released":"1973","status":"Accepted","resource_url":"https://api.discogs.com/releases/24571544","thumb":"https://i.discogs.com/goIH_cO9e581t1wyAuf3qcXU2YrK1uQvVu4ip3H3zvs/rs:fit/g:sm/q:40/h:150/w:150/czM6Ly9kaXNjb2dz/LWRhdGFiYXNlLWlt/YWdlcy9SLTI0NTcx/NTQ0LTE2NjM4NDM4/MjgtNzkzMC5qcGVn.jpeg","stats":{"community":{"in_wantlist":908,"in_collection":1188}}},{"id":13655729,"label":"EMI","country":"Peru","title":"El Lado Oscuro De La Luna","major_formats":["Vinyl"],"format":"LP, Album, Stereo","catno":"ELD 02.21.257","released":"1973","status":"Accepted","resource_url":"https://api.discogs.com/releases/13655729","thumb":"https://i.discogs.com/b4sU_wDut_xdcXKCd3RDSMwwvTbYC6QuG5Gyf6yWmds/rs:fit/g:sm/q:40/h:150/w:150/czM6Ly9kaXNjb2dz/LWRhdGFiYXNlLWlt/YWdlcy9SLTEzNjU1/NzI5LTE2MDIwNzA5/MDktNDM5NS5qcGVn.jpeg","stats":{"community":{"in_wantlist":1127,"in_collection":122}}},{"id":3422671,"label":"Harvest","country":"New Zealand","title":"The Dark Side Of The Moon","major_formats":["Cassette"],"format":"Album","catno":"TC-SHVL.804","released":"1973","status":"Accepted","resource_url":"https://api.discogs.com/releases/3422671","thumb":"https://i.discogs.com/oLk77L77ChTuwzLRN0F0HoqfUdsWHNINhxaM9QHOjL4/rs:fit/g:sm/q:40/h:150/w:150/czM6Ly9kaXNjb2dz/LWRhdGFiYXNlLWlt/YWdlcy9SLTM0MjI2/NzEtMTM2MDY0ODE0/Ni05NTQxLmpwZWc.jpeg","stats":{"community":{"in_wantlist":1293,"in_collection":66}}},{"id":23773439,"label":"Harvest","country":"US","title":"The Dark Side Of The Moon","major_formats":["8-Track Cartridge"],"format":"Album","catno":"8XW-11163, 8XW 11163","released":"1973","status":"Accepted","resource_url":"https://api.discogs.com/releases/23773439","thumb":"https://i.discogs.com/o3v_psko0B87ic-VLJzLqzlvEAF67uFwtk7dhofu1L0/rs:fit/g:sm/q:40/h:150/w:150/czM6Ly9kaXNjb2dz/LWRhdGFiYXNlLWlt/YWdlcy9SLTIzNzcz/NDM5LTE2NTY4Nzk5/NjAtMTgwNi5qcGVn.jpeg","stats":{"community":{"in_wantlist":256,"in_collection":44}}}]}""";
    const string FxVersionsP309 = """{"pagination":{"page":309,"pages":309,"per_page":5,"items":1542,"urls":{"first":"https://api.discogs.com/masters/10362/versions?per_page=5&page=1","prev":"https://api.discogs.com/masters/10362/versions?per_page=5&page=308"}},"filters":{"applied":{},"available":{}},"versions":[{"id":36479455,"label":"Harvest (2)","country":"Philippines","title":"The Dark Side Of The Moon","major_formats":["Vinyl"],"format":"LP, Album, Limited Edition, Repress, Unofficial Release, Stereo","catno":"SHVL 804","released":"0","status":"Accepted","resource_url":"https://api.discogs.com/releases/36479455","thumb":"https://i.discogs.com/spw4RItF4Km09JdtExjEvTVbpJuqyXOjXLWOlnjFUgk/rs:fit/g:sm/q:40/h:150/w:150/czM6Ly9kaXNjb2dz/LWRhdGFiYXNlLWlt/YWdlcy9SLTM2NDc5/NDU1LTE3NzA4ODM0/NTYtMzY5MC5qcGVn.jpeg","stats":{"community":{"in_wantlist":121,"in_collection":2}}},{"id":37007961,"label":"Jugoton","country":"Yugoslavia","title":"The Dark Side Of The Moon","major_formats":["Vinyl"],"format":"LP, Album, Quadraphonic","catno":"LQEMI 73009, Q4SHVL 804","released":"0","status":"Accepted","resource_url":"https://api.discogs.com/releases/37007961","thumb":"https://i.discogs.com/X8TPmgKG-8JP6q7E5aDs08RQ81Oaayn00XFKebcCMoY/rs:fit/g:sm/q:40/h:150/w:150/czM6Ly9kaXNjb2dz/LWRhdGFiYXNlLWlt/YWdlcy9SLTM3MDA3/OTYxLTE3NzU2NDIx/NzktNzE0MC5qcGVn.jpeg","stats":{"community":{"in_wantlist":94,"in_collection":3}}}]}""";
    const string FxRelease249504 = """{"id":249504,"status":"Accepted","year":1987,"title":"Never Gonna Give You Up","country":"UK","released":"1987-07-00","released_formatted":"Jul 1987","master_id":96559,"labels":[{"name":"RCA","catno":"PB 41447","entity_type":"1","id":895}],"formats":[{"name":"Vinyl","qty":"1","descriptions":["7\"","45 RPM","Single","Stereo"]}],"thumb":"https://i.discogs.com/HG2xChKN-rIHHSfgL53W9z2vJWeFknfevpOMwSHtIaM/rs:fit/g:sm/q:40/h:150/w:150/czM6Ly9kaXNjb2dz/LWRhdGFiYXNlLWlt/YWdlcy9SLTI0OTUw/NC0xMzM0NTkyMjEy/LmpwZWc.jpeg","lowest_price":0.67,"num_for_sale":118,"community":{"have":4126,"want":589}}""";

    static void Catalog() => Check.Section("Discogs-katalog", () =>
    {
        // ParseSearch: masters + releases uden master, dubletter, split af kunstner/titel, user_data
        var search = """
        {"pagination":{"page":1,"pages":4,"per_page":50,"items":180,"urls":{"last":"https://api.discogs.com/database/search?q=x&page=4","next":"https://api.discogs.com/database/search?q=x&page=2"}},
         "results":[
          {"id":45467,"type":"artist","title":"Pink Floyd","thumb":"","cover_image":"","uri":"/artist/45467-Pink-Floyd","resource_url":"https://api.discogs.com/artists/45467","user_data":{"in_wantlist":false,"in_collection":false}},
          {"id":10362,"type":"master","master_id":10362,"master_url":"https://api.discogs.com/masters/10362","uri":"/master/10362-Pink-Floyd-The-Dark-Side-Of-The-Moon",
           "title":"Pink Floyd - The Dark Side Of The Moon","country":"UK","year":"1973","format":["Vinyl","LP","Album","Vinyl","LP"],"label":["Harvest"],
           "genre":["Electronic","Rock"],"style":["Prog Rock"],"catno":"SHVL 804","barcode":[],"community":{"want":1,"have":2},
           "thumb":"https://i.discogs.com/t10362.jpeg","cover_image":"https://i.discogs.com/c10362.jpeg",
           "user_data":{"in_wantlist":false,"in_collection":true},"resource_url":"https://api.discogs.com/masters/10362"},
          {"id":1873013,"type":"release","master_id":10362,"title":"Pink Floyd - The Dark Side Of The Moon","year":"1973","format":["Vinyl","LP","Album"],"user_data":{"in_wantlist":true,"in_collection":false}},
          {"id":10362,"type":"master","master_id":10362,"title":"Pink Floyd - The Dark Side Of The Moon","year":"1973"},
          {"id":5555001,"type":"release","master_id":0,"master_url":null,"title":"Nirvana (2) - Live At The Paramount","year":"2019","format":["Vinyl","LP"],
           "thumb":"","cover_image":"https://s.discogs.com/images/spacer.gif","user_data":{"in_wantlist":true,"in_collection":false}},
          {"id":5555002,"type":"release","master_id":null,"title":"Simon* & Garfunkel - Bookends - Live 1969","year":1969},
          {"id":5555003,"type":"release","title":"Kim Larsen – Midt Om Natten","format":["Vinyl","LP","Album"],"user_data":{"in_wantlist":false,"in_collection":false}},
          {"type":"release","title":"Uden id - springes over"},
          {"id":5555004,"type":"label","title":"Harvest"},
          {"id":5555005,"type":"release","master_id":0,"year":"","user_data":{"in_collection":1}}
         ]}
        """;
        var s = DiscogsClient.ParseSearch(B(search));
        Check.That(s.HasMore, "søgning: side 1 af 4 → hasMore");
        Check.That(s.Albums.Select(a => a.Id).SequenceEqual(new[] { 10362, 5555001, 5555002, 5555003, 5555005 }),
                   $"søgning: artist/label/uden id droppes, release med master vises via masteren, ingen dubletter: {string.Join(",", s.Albums.Select(a => a.Id))}");
        var m = s.Albums[0];
        Check.That(m.IsMaster && m.Artist == "Pink Floyd" && m.Title == "The Dark Side Of The Moon" && m.Year == 1973,
                   $"søgning: master + split af kunstner/titel: {m.Artist} / {m.Title}");
        Check.That(m.InCollection && !m.InWantlist, "søgning: user_data på masteren (ikke releasens)");
        Check.That(m.Formats.SequenceEqual(new[] { "Vinyl", "LP", "Album" }) && m.ThumbUrl?.AbsoluteUri == "https://i.discogs.com/t10362.jpeg"
                   && m.CoverUrl?.AbsoluteUri == "https://i.discogs.com/c10362.jpeg", "søgning: formater uden gentagelser + billeder");
        var nirvana = s.Albums[1];
        Check.That(!nirvana.IsMaster && nirvana.Artist == "Nirvana" && nirvana.Title == "Live At The Paramount" && nirvana.InWantlist
                   && nirvana.ThumbUrl == null && nirvana.CoverUrl == null, "søgning: release uden master, (2) fjernet, tomme billeder → null");
        var bookends = s.Albums[2];
        Check.That(bookends.Artist == "Simon & Garfunkel" && bookends.Title == "Bookends - Live 1969" && bookends.Year == 1969
                   && !bookends.InCollection && !bookends.InWantlist && bookends.Formats.Count == 0,
                   $"søgning: deles ved første \" - \", år som tal, manglende user_data → false: {bookends.Artist} / {bookends.Title}");
        Check.That(s.Albums[3].Artist == "Kim Larsen" && s.Albums[3].Title == "Midt Om Natten" && s.Albums[3].Year == null,
                   "søgning: \" – \" accepteres, manglende år → null");
        var bare = s.Albums[4];
        Check.That(bare.Artist == "" && bare.Title == "" && bare.Year == null && bare.InCollection && bare.ThumbUrl == null,
                   "søgning: manglende titel/år giver tomme felter, in_collection som tal");
        Check.That(m.Barcodes.Count == 0, "søgning: tom stregkodeliste");

        var empty = DiscogsClient.ParseSearch(B("""{"pagination":{"page":1,"pages":0,"per_page":50,"items":0,"urls":{}},"results":[]}"""));
        Check.That(empty.Albums.Count == 0 && !empty.HasMore, "søgning: tom liste");
        var last = DiscogsClient.ParseSearch(B("""{"pagination":{"page":4,"pages":4,"items":180},"results":[]}"""));
        Check.That(!last.HasMore, "søgning: sidste side → ingen flere");
        var noPagination = DiscogsClient.ParseSearch(B("""{"results":[{"id":7,"type":"master","title":"A - B"}]}"""));
        Check.That(noPagination.Albums.Count == 1 && !noPagination.HasMore, "søgning: manglende pagination → ingen flere");
        try { DiscogsClient.ParseSearch(B("ikke json")); Check.That(false, "ugyldig søge-JSON skal fejle"); }
        catch (DiscogsException e) { Check.That(e.Message == "Svaret fra Discogs kunne ikke læses (søgeresultaterne).", $"søgning: fejl på dansk: {e.Message}"); }
        var withBarcode = DiscogsClient.ParseSearch(B("""{"results":[{"id":8,"type":"release","title":"A - B","barcode":["5 099902 987613"]}]}"""));
        Check.That(withBarcode.Albums[0].Barcodes.SequenceEqual(new[] { "5 099902 987613" }), "søgning: stregkoder fra søgeresultatet");

        // CombineSearch: to opslag (type=master + type=release) til én side
        var mastersJson = """{"pagination":{"page":1,"pages":1,"items":1},"results":[{"id":10362,"type":"master","title":"Pink Floyd - The Dark Side Of The Moon","year":"1973"}]}""";
        var releasesJson = """{"pagination":{"page":1,"pages":3,"items":150},"results":[{"id":1873013,"type":"release","master_id":10362,"title":"Pink Floyd - The Dark Side Of The Moon"},{"id":777,"type":"release","master_id":0,"title":"Pink Floyd - Rare Acetate"}]}""";
        var c = DiscogsClient.CombineSearch(B(mastersJson), B(releasesJson));
        Check.That(c.Albums.Select(a => a.Id).SequenceEqual(new[] { 10362, 777 }) && c.Albums.Select(a => a.IsMaster).SequenceEqual(new[] { true, false }) && c.HasMore,
                   "søgning: masters først, så releases uden master; hasMore hvis en af delene har flere");
        var noMasters = """{"pagination":{"page":1,"pages":0,"items":0},"results":[]}""";
        var catno = DiscogsClient.CombineSearch(B(noMasters), B(releasesJson));
        Check.That(catno.Albums.Select(a => a.Id).SequenceEqual(new[] { 1873013, 777 }) && catno.Albums.All(a => !a.IsMaster),
                   "søgning: ingen masters (fx katalognr.) → de fundne udgaver vises som enkelte releases");

        // ParseVersions: rigtige data
        var p1 = DiscogsClient.ParseVersions(B(FxVersionsP1));
        Check.That(p1.Versions.Count == 5 && p1.HasMore, "udgaver: 5 på side 1 af 309");
        var nl = p1.Versions[0];
        Check.That(nl.Id == 10255816 && nl.Title == "The Dark Side Of The Moon" && nl.Format == "Vinyl, LP, Album, Stereo"
                   && nl.Label == "Harvest" && nl.Catno == "5C062-05 249, 5C 062-05249" && nl.Country == "Netherlands" && nl.Year == 1973,
                   $"udgaver: år/land/label/format/katalognr.: {nl.Format}");
        Check.That(nl.ThumbUrl != null && !nl.InCollection && !nl.InWantlist, "udgaver: billede, ingen brugerdata uden login → false");
        Check.That(p1.Versions[3].Format == "Cassette, Album" && p1.Versions[4].Format == "8-Track Cartridge, Album", "udgaver: andre formater end vinyl");
        var p309 = DiscogsClient.ParseVersions(B(FxVersionsP309));
        Check.That(p309.Versions.Count == 2 && !p309.HasMore, "udgaver: sidste side → ingen flere");
        Check.That(p309.Versions[0].Label == "Harvest" && p309.Versions[0].Year == null, "udgaver: \"Harvest (2)\" → Harvest, released \"0\" → intet år");

        // ParseVersions: brugerdata og manglende felter
        var versionsJson = """
        {"pagination":{"page":2,"pages":2,"per_page":50,"items":52},"versions":[
         {"id":1,"status":"Accepted","stats":{"user":{"in_collection":1,"in_wantlist":0},"community":{"in_collection":2,"in_wantlist":1}},
          "thumb":"https://i.discogs.com/t1.jpeg","format":"Vinyl, 12\", 33 ⅓ RPM","country":"Belgium","title":"Stardiver",
          "label":"Bonzai Records (2)","released":"1969-09-26","major_formats":["Vinyl"],"catno":"BR-1234","resource_url":"https://api.discogs.com/releases/1"},
         {"id":2,"stats":{"user":{"in_collection":false,"in_wantlist":true}},"catno":"none","released":null},
         {"title":"uden id"}
        ]}
        """;
        var v = DiscogsClient.ParseVersions(B(versionsJson));
        Check.That(v.Versions.Select(x => x.Id).SequenceEqual(new[] { 1, 2 }) && !v.HasMore && v.Total == 52, "udgaver: element uden id springes over");
        var v1 = v.Versions[0];
        Check.That(v1.Format == "Vinyl, 12\", 33 ⅓ RPM" && v1.Label == "Bonzai Records" && v1.Year == 1969 && v1.Catno == "BR-1234",
                   $"udgaver: \"1969-09-26\" → 1969, Vinyl gentages ikke: {v1.Format}");
        Check.That(v1.InCollection && !v1.InWantlist, "udgaver: stats.user.in_collection (tal)");
        var v2 = v.Versions[1];
        Check.That(v2.Title == "" && v2.Format == "" && v2.Label == "" && v2.Catno == "" && v2.Country == "" && v2.Year == null
                   && v2.ThumbUrl == null && !v2.InCollection && v2.InWantlist, "udgaver: manglende felter → tomme/null, in_wantlist som bool");
        try { DiscogsClient.ParseVersions(B("""{"pagination":{}}""")); Check.That(false, "udgaver uden versions skal fejle"); }
        catch (DiscogsException e) { Check.That(e.Message == "Svaret fra Discogs kunne ikke læses (udgaverne).", "udgaver: fejl på dansk"); }

        // Release uden master → én udgave (rigtige data), og prisen fra samme svar
        var rel = DiscogsClient.ParseReleaseVersion(B(FxRelease249504), inCollection: false, inWantlist: true);
        Check.That(rel.Id == 249504 && rel.Title == "Never Gonna Give You Up" && rel.Format == "Vinyl, 7\", 45 RPM, Single, Stereo"
                   && rel.Label == "RCA" && rel.Catno == "PB 41447" && rel.Country == "UK" && rel.Year == 1987 && rel.ThumbUrl != null && rel.InWantlist,
                   $"release → udgave: {rel.Format}");
        var price = DiscogsClient.ParseMarketInfo(B(FxRelease249504), "EUR");
        Check.That(price.LowestPrice == 0.67 && price.NumForSale == 118, "pris pr. udgave via ParseMarketInfo");
        var multi = """{"id":9,"title":"X","year":0,"released":"1975-03-00","labels":[{"name":"Atlantic (3)","catno":"none"}],"thumb":"","images":[{"uri150":"https://i.discogs.com/150.jpeg"}],"formats":[{"name":"Vinyl","qty":"2","descriptions":["LP","Album"],"text":"Gatefold"},{"name":"CD","qty":"1"}]}""";
        var mv = DiscogsClient.ParseReleaseVersion(B(multi), false, false);
        Check.That(mv.Format == "2×Vinyl, LP, Album, Gatefold + CD" && mv.Label == "Atlantic" && mv.Catno == "" && mv.Year == 1975
                   && mv.ThumbUrl?.AbsoluteUri == "https://i.discogs.com/150.jpeg", $"release: flere formater, år fra released, billede fra images: {mv.Format}");
        try { DiscogsClient.ParseReleaseVersion(B("""{"title":"uden id"}"""), false, false); Check.That(false, "release uden id skal fejle"); }
        catch (DiscogsException e) { Check.That(e.Message == "Svaret fra Discogs kunne ikke læses (udgaven).", "release: fejl på dansk"); }

        // URL'er til Discogs' hjemmeside
        Check.That(DiscogsClient.MarketplaceUrl(249504).AbsoluteUri == "https://www.discogs.com/sell/release/249504", "MarketplaceUrl");
        Check.That(DiscogsClient.ReleasePageUrl(249504).AbsoluteUri == "https://www.discogs.com/release/249504", "ReleasePageUrl");

        // PUT-forespørgsel bygges uden netværk; tokenet sendes, men vises aldrig
        const string fakeToken = "TEST-token-ikke-rigtig-123";
        var client = new DiscogsClient(fakeToken);
        var put = client.WantlistRequest("holger", 249504);
        Check.That(put.Method == HttpMethod.Put && put.Url.AbsoluteUri == "https://api.discogs.com/users/holger/wants/249504",
                   $"PUT: metode og sti: {put.Url.AbsoluteUri}");
        Check.That(put.Header("Authorization") == $"Discogs token={fakeToken}" && put.Header("User-Agent") == DiscogsClient.UserAgent
                   && put.Header("Accept") == "application/vnd.discogs.v2.discogs+json", "PUT: Authorization, User-Agent og Accept sættes");
        Check.That(DiscogsClient.UserAgent == "VinylShelfFinder/1.0 +https://github.com/local/vinyl-shelf-finder", "User-Agent som på Mac");
        var shown = new[]
        {
            put.Url.AbsoluteUri, put.ToString(), $"{put}", client.ToString(), $"{client}",
            JsonSerializer.Serialize(client), JsonSerializer.Serialize(put),
            DiscogsException.Unauthorized().Message, DiscogsException.Unauthorized().ToString(),
        };
        Check.That(!shown.Any(x => x.Contains(fakeToken)), "tokenet optræder aldrig i URL, beskrivelser, JSON eller fejltekst");
        var get = client.MakeRequest(path: "/masters/10362/versions", query: new[] { ("page", "2") });
        Check.That(get.Method == HttpMethod.Get && get.Url.AbsoluteUri == "https://api.discogs.com/masters/10362/versions?page=2", "GET-forespørgsel");
        Check.That(client.HasToken && !new DiscogsClient("  ").HasToken, "HasToken uden at vise tokenet");

        // Danske fejltekster
        Check.That(DiscogsException.Unauthorized().Message.StartsWith("Discogs-tokenet blev afvist"), "401: dansk fejltekst");
        Check.That(DiscogsException.Http(404).Message == "Pladen findes ikke længere på Discogs." && DiscogsException.Http(404).IsNotFound, "404: dansk fejltekst");
        Check.That(DiscogsException.Http(500).Message.Contains("kode 500") && !DiscogsException.Http(500).IsNotFound, "andre koder: generel tekst");
        Check.That(DiscogsException.Offline().Message.StartsWith("Kunne ikke få forbindelse til Discogs"), "offline: dansk fejltekst");
        Check.That(DiscogsException.MissingToken().Message == "Der er ikke gemt noget Discogs-token."
                   && DiscogsException.RateLimited().Message == "Discogs begrænser antallet af forespørgsler. Prøv igen om et øjeblik.",
                   "manglende token og rate limit: dansk fejltekst");

        // Ende-til-ende mod et falsk netværk (ingen rigtige kald)
        var stubNet = new StubDiscogs
        {
            Routes = new()
            {
                ["PUT /users/holger/wants/249504"] = (201, """{"id":249504,"rating":0}"""),
                ["PUT /users/holger/wants/1"] = (404, """{"message":"Release not found."}"""),
                ["PUT /users/andre/wants/249504"] = (401, """{"message":"You must authenticate to access this resource."}"""),
                ["GET /database/search?type=master"] = (200, mastersJson),
                ["GET /database/search?type=release"] = (200, releasesJson),
                ["GET /masters/10362/versions"] = (200, FxVersionsP1),
                ["GET /releases/249504"] = (200, FxRelease249504),
                ["GET /masters/999/versions"] = (0, ""),
            },
        };
        var stub = StubClient(stubNet, fakeToken);
        var added = Blocking(() => stub.AddToWantlistAsync("holger", 249504));
        var sentPut = stubNet.SeenRequests.LastOrDefault();
        Check.That(added == null && sentPut?.Method == "PUT" && sentPut.Url.AbsolutePath == "/users/holger/wants/249504"
                   && sentPut.Header("Authorization") == $"Discogs token={fakeToken}" && sentPut.Header("User-Agent") == DiscogsClient.UserAgent
                   && sentPut.ContentLength == 0, "AddToWantlistAsync sender PUT med token og tom krop");
        var e404 = Blocking(() => stub.AddToWantlistAsync("holger", 1));
        Check.That(ErrorText(e404) == "Pladen findes ikke længere på Discogs." && (e404 as DiscogsException)?.IsNotFound == true, "PUT 404 → dansk tekst");
        var e401 = Blocking(() => stub.AddToWantlistAsync("andre", 249504));
        Check.That(ErrorText(e401)?.StartsWith("Discogs-tokenet blev afvist") == true && !ErrorText(e401)!.Contains(fakeToken), "PUT 401 → dansk tekst");
        var offline = Blocking(() => stub.VersionsAsync(Album(999, true)));
        Check.That(ErrorText(offline.Error)?.StartsWith("Kunne ikke få forbindelse til Discogs") == true
                   && (offline.Error as DiscogsException)?.Kind == DiscogsErrorKind.Offline, "ingen forbindelse → offline på dansk");

        stubNet.ClearSeen();
        var found = Blocking(() => stub.SearchAlbumsAsync("  pink floyd  "));
        var searchQueries = stubNet.SeenRequests.Select(r => r.Query).ToList();
        Check.That(found.Value?.Albums.Select(a => a.Id).SequenceEqual(new[] { 10362, 777 }) == true && found.Value.HasMore,
                   "SearchAlbumsAsync samler masters og releases");
        Check.That(searchQueries.Count == 2 && searchQueries.All(q => q.Contains(("q", "pink floyd")) && q.Contains(("page", "1")) && q.Contains(("per_page", "50")))
                   && searchQueries.Select(q => q.FirstOrDefault(x => x.Name == "type").Value).ToHashSet().SetEquals(new[] { "master", "release" }),
                   "SearchAlbumsAsync: to opslag, trimmet søgning");
        Check.That(stubNet.SeenRequests.All(r => r.Url.AbsoluteUri.Contains("q=pink%20floyd") && !r.Url.AbsoluteUri.Contains(fakeToken)),
                   "søgningen URL-kodes, og tokenet er aldrig i URL'en");
        stubNet.ClearSeen();
        var none = Blocking(() => stub.SearchAlbumsAsync("   "));
        Check.That(none.Value?.Albums.Count == 0 && stubNet.SeenRequests.Count == 0, "tom søgning → intet kald");
        var noToken = Blocking(() => StubClient(stubNet, "").SearchAlbumsAsync("abba"));
        Check.That(ErrorText(noToken.Error) == DiscogsException.MissingToken().Message, "søgning uden token → MissingToken");
        Check.That(ErrorText(Blocking(() => StubClient(stubNet, "").AddToWantlistAsync("holger", 1))) == DiscogsException.MissingToken().Message,
                   "ønskeliste uden token → MissingToken");

        var master = Album(10362, true, "The Dark Side Of The Moon", "Pink Floyd", 1973);
        var mvers = Blocking(() => stub.VersionsAsync(master, page: 2));
        var versionsQuery = stubNet.SeenRequests.LastOrDefault()?.Query ?? new();
        Check.That(mvers.Value?.Versions.Count == 5 && versionsQuery.Contains(("page", "2")) && versionsQuery.Contains(("per_page", "100")),
                   "VersionsAsync(master) henter /masters/{id}/versions med side");
        var single = Album(249504, false, "Never Gonna Give You Up", "Rick Astley", 1987, new[] { "Vinyl" }, inCollection: true);
        var svers = Blocking(() => stub.VersionsAsync(single));
        Check.That(svers.Value?.Versions.Select(x => x.Id).SequenceEqual(new[] { 249504 }) == true && svers.Value.HasMore == false && svers.Value.Versions[0].InCollection,
                   "VersionsAsync(release) → én udgave med albummets brugerdata");
        stubNet.ClearSeen();
        var page2 = Blocking(() => stub.VersionsAsync(single, page: 2));
        Check.That(page2.Value?.Versions.Count == 0 && stubNet.SeenRequests.Count == 0, "release uden master har kun én side");

        // Formatfilter: Discogs' eget format-filter sendes med både til søgning og udgaver.
        stubNet.ClearSeen();
        Blocking(() => stub.SearchAlbumsAsync("dark side", format: "CD"));
        Check.That(stubNet.SeenRequests.Count == 2 && stubNet.SeenRequests.All(r => r.Query.Contains(("format", "CD"))),
                   "SearchAlbumsAsync(format) sender format=CD i begge søgeopslag");
        stubNet.ClearSeen();
        Blocking(() => stub.SearchAlbumsAsync("dark side"));
        Check.That(stubNet.SeenRequests.All(r => !r.Query.Any(q => q.Name == "format")), "uden format: intet formatfilter (alle formater)");
        stubNet.ClearSeen();
        Blocking(() => stub.VersionsAsync(master, page: 1, format: "Vinyl"));
        Check.That(stubNet.SeenRequests.LastOrDefault()?.Query.Contains(("format", "Vinyl")) == true,
                   "VersionsAsync(format) sender format=Vinyl til /masters/{id}/versions");

        // Samlingen: alle sider hentes, og fremskridtet meldes
        var page1Json = """{"pagination":{"page":1,"pages":1,"items":1},"releases":[{"id":5,"instance_id":50,"basic_information":{"id":5,"title":"T","artists":[{"name":"A"}]}}]}""";
        stubNet.Routes["GET /users/holger/collection/folders/0/releases"] = (200, page1Json);
        stubNet.Routes["GET /oauth/identity"] = (200, """{"id":1,"username":"holger","resource_url":"x"}""");
        stubNet.ClearSeen();
        var progress = new List<(int, int)>();
        var coll = Blocking(() => stub.FetchCollectionAsync("holger", (n, t) => progress.Add((n, t))));
        var collQuery = stubNet.SeenRequests.LastOrDefault()?.Query ?? new();
        Check.That(coll.Value?.Count == 1 && coll.Value[0].InstanceId == 50 && coll.Value[0].Release.Artist == "A" && progress.SequenceEqual(new[] { (1, 1) })
                   && collQuery.Contains(("sort", "artist")) && collQuery.Contains(("per_page", "100")), "FetchCollectionAsync henter samlingen sorteret efter kunstner");
        Check.That(Blocking(() => stub.IdentityAsync()).Value == "holger", "IdentityAsync giver brugernavnet");
        stubNet.Routes["GET /users/holger/collection/folders/0/releases"] = (200, """{"pagination":{"pages":1,"items":1}}""");
        Check.That(ErrorText(Blocking(() => stub.FetchCollectionAsync("holger")).Error) == "Svaret fra Discogs kunne ikke læses (samlingen, side 1).",
                   "samling, der ikke kan læses → dansk fejl med sidetal");
        stubNet.Routes["GET /oauth/identity"] = (500, "{}");
        Check.That(ErrorText(Blocking(() => stub.IdentityAsync()).Error) == "Discogs svarede med en fejl (kode 500). Prøv igen senere.", "500 → dansk tekst");
    });

    // MARK: Danske kroner (omregnet fra euro)
    static void Kroner() => Check.Section("Danske kroner", () =>
    {
        var eur = new MarketInfo(10, "EUR", 3, 5, 7);
        var dkk = MarketCurrency.Converted(eur, "DKK");
        Check.That(dkk.Currency == "DKK" && dkk.LowestPrice == 74.6 && dkk.NumForSale == 3 && dkk.Have == 5,
                   $"10 € → 74,60 kr. (kurs {MarketCurrency.DkkPerEur}); antal til salg uændret");
        var back = MarketCurrency.Converted(new MarketInfo(3.36, "DKK", 1, null, null), "EUR");
        Check.That(back.Currency == "EUR" && back.LowestPrice == 0.45, "3,36 kr. → 0,45 € (samme kurs baglæns)");
        Check.That(MarketCurrency.Converted(new MarketInfo(3.36, "DKK", 1, null, null), "DKK").LowestPrice == 3.36,
                   "kroner til kroner regnes aldrig om (fejlen fra før 1. okt: ×7,46)");
        Check.That(MarketCurrency.Converted(eur, "EUR") == eur, "EUR omregnes ikke");
        Check.That(MarketCurrency.Converted(new MarketInfo(null, "EUR", 0, null, null), "DKK").LowestPrice == null, "ingen pris → stadig ingen pris");
        Check.That(MarketCurrency.AllCases[0] == "DKK", "DKK står først i valutavalget");
    });

    // MARK: Priser med oplyst valuta (/marketplace/stats) – rettelse 1. okt 2026
    // Målt mod det rigtige Discogs for en bruger med DKK som valuta, release 6496:
    // /marketplace/stats?curr_abbr=EUR → 0.45 EUR, ?curr_abbr=DKK → 3.36 DKK,
    // /releases/6496 med curr_abbr=EUR, USD eller uden → altid 3.36 (brugerens valuta).
    const string FxStats6496DKK = """{"lowest_price":{"currency":"DKK","value":3.36},"num_for_sale":36,"blocked_from_sale":false}""";

    static void MarketStats() => Check.Section("priser med oplyst valuta", () =>
    {
        var m = DiscogsClient.ParseMarketStats(B(FxStats6496DKK), "DKK");
        Check.That(m.LowestPrice == 3.36 && m.Currency == "DKK" && m.NumForSale == 36, "stats: pris og valuta læses fra svaret");
        var str = DiscogsClient.ParseMarketStats(B("""{"lowest_price":{"currency":"eur","value":"0.45"},"num_for_sale":"36"}"""), "DKK");
        Check.That(str.LowestPrice == 0.45 && str.Currency == "EUR" && str.NumForSale == 36, "stats: beløb og antal som tekst");
        var none = DiscogsClient.ParseMarketStats(B("""{"lowest_price":null,"num_for_sale":0,"blocked_from_sale":false}"""), "DKK");
        Check.That(none.LowestPrice == null && none.NumForSale == 0, "stats: intet til salg → ingen pris");
        var noCur = DiscogsClient.ParseMarketStats(B("""{"lowest_price":{"value":3.36},"num_for_sale":2}"""), "DKK");
        Check.That(noCur.LowestPrice == null && noCur.NumForSale == 2, "stats: pris uden valuta → ingen pris (aldrig gættet)");
        try { DiscogsClient.ParseMarketStats(B("[]"), "DKK"); Check.That(false, "stats som liste skal fejle"); }
        catch (DiscogsException e) { Check.That(e.Message == "Svaret fra Discogs kunne ikke læses (markedspriser).", "stats: fejl på dansk"); }

        var net = new StubDiscogs
        {
            Routes = new()
            {
                ["GET /marketplace/stats/6496"] = (200, FxStats6496DKK),
                ["GET /releases/6496"] = (200, """{"id":6496,"lowest_price":3.36,"num_for_sale":36,"community":{"have":900,"want":40}}"""),
                ["GET /users/holger/collection/value"] = (200, """{"maximum":"2.310,40 kr.","median":"1.105,00 kr.","minimum":"512,30 kr."}"""),
            },
        };
        var stub = StubClient(net, "TEST-ikke-rigtig");
        var price = Blocking(() => stub.MarketInfoAsync(6496, "DKK")).Value!;
        var q = net.SeenRequests.LastOrDefault();
        Check.That(price.LowestPrice == 3.36 && price.Currency == "DKK" && q?.Url.AbsolutePath == "/marketplace/stats/6496"
                   && q.Query.SequenceEqual(new[] { ("curr_abbr", "DKK") }), "MarketInfoAsync: ét kald til /marketplace/stats med curr_abbr=DKK; 3,36 kr. forbliver 3,36 kr.");

        net.ClearSeen();
        var v = Blocking(() => stub.ReleaseMarketInfoAsync(6496, "DKK", "DKK")).Value!;
        Check.That(v.LowestPrice == 3.36 && v.Currency == "DKK" && v.Have == 900 && v.Want == 40 && net.SeenRequests.Count == 1,
                   "Værdi: /releases-pris i brugerens Discogs-valuta (DKK) bruges uomregnet; ét kald");
        var ve = Blocking(() => stub.ReleaseMarketInfoAsync(6496, "DKK", "EUR")).Value!;
        Check.That(ve.LowestPrice == 0.45 && ve.Currency == "EUR", "Værdi: kroner fra Discogs vises som 0,45 € i en euroapp");
        net.ClearSeen();
        var vs = Blocking(() => stub.ReleaseMarketInfoAsync(6496, "DKK", "SEK")).Value!;
        Check.That(vs.Currency == "DKK" && net.SeenRequests.LastOrDefault()?.Url.AbsolutePath == "/marketplace/stats/6496" && vs.Have == 900,
                   "Værdi: kan valutaen ikke regnes om, hentes prisen fra stats (her svarer stubben i DKK)");
        net.ClearSeen();
        var vu = Blocking(() => stub.ReleaseMarketInfoAsync(6496, null, "DKK")).Value!;
        Check.That(vu.LowestPrice == 3.36 && vu.Currency == "DKK" && net.SeenRequests.Count == 2, "Værdi: ukendt Discogs-valuta → pris fra stats");
        var cv = Blocking(() => stub.CollectionValueAsync("holger"));
        Check.That(cv.Value?.Median == "1.105,00 kr." && net.SeenRequests.LastOrDefault()?.Url.AbsolutePath == "/users/holger/collection/value",
                   "CollectionValueAsync henter /users/{name}/collection/value");
    });

    // MARK: Billigste køb: udbredte udgaver først, søgning der rammer flere ord
    static void Cheapest() => Check.Section("billigste køb", () =>
    {
        var page = DiscogsClient.ParseVersions(B(FxVersionsP1)).Versions;
        Check.That(page.Select(x => x.Popularity).SequenceEqual(new[] { 3124, 2096, 1249, 1359, 300 }), "udgaver: udbredelse = har + ønsker (stats.community)");
        Check.That(DiscogsVersion.MostPopularFirst(page).Select(x => x.Id).SequenceEqual(new[] { 10255816, 24571544, 3422671, 13655729, 23773439 }),
                   "MostPopularFirst sorterer de mest udbredte først");
        var tie = new[]
        {
            new DiscogsVersion(1, "", "", "", "", "", null, null, false, false, 5),
            new DiscogsVersion(2, "", "", "", "", "", null, null, false, false, 5),
        };
        Check.That(DiscogsVersion.MostPopularFirst(tie).Select(x => x.Id).SequenceEqual(new[] { 1, 2 }), "lige udbredte beholder Discogs' rækkefølge");

        DiscogsAlbum Al(int id, string artist, string title) => Album(id, true, title, artist);
        // Målt 1. okt 2026: Discogs gav "LaTour – LaTour" før "LaTour – Blue" for "blue latour".
        var found = new[] { Al(133599, "LaTour", "LaTour"), Al(133594, "LaTour", "Blue"), Al(133592, "LaTour", "E") };
        Check.That(DiscogsAlbum.RankedForQuery(found, "blue latour").Select(a => a.Id).SequenceEqual(new[] { 133594, 133599, 133592 }), "\"blue latour\" → LaTour – Blue først");
        Check.That(DiscogsAlbum.RankedForQuery(found, "latour").Select(a => a.Id).SequenceEqual(new[] { 133599, 133594, 133592 }), "ét søgeord: Discogs' rækkefølge bevares");
        Check.That(DiscogsAlbum.RankedForQuery(new[] { Al(1, "Björk", "Post"), Al(2, "Bjork Tribute", "Debut") }, "bjork debut").Select(a => a.Id).SequenceEqual(new[] { 2, 1 }),
                   "rangering ser bort fra store bogstaver og accenter");
    });

    // MARK: Albumkortet: pris for hele albummet (master), brugerens valuta og markedsplads
    // Testdata: forkortede, rigtige svar hentet uden login fra api.discogs.com:
    // /masters/10362 (har lowest_price, num_for_sale og main_release, men ingen curr_abbr) og
    // /users/susan.salkeld (curr_abbr er tom uden login).
    const string FxMaster10362 = """{"id":10362,"main_release":1873013,"most_recent_release":38452401,"resource_url":"https://api.discogs.com/masters/10362","uri":"https://www.discogs.com/master/10362-_-The-Dark-Side-Of-The-Moon","versions_url":"https://api.discogs.com/masters/10362/versions","main_release_url":"https://api.discogs.com/releases/1873013","most_recent_release_url":"https://api.discogs.com/releases/38452401","num_for_sale":8395,"lowest_price":0.01,"genres":["Electronic","Rock"],"year":1973,"title":"The Dark Side Of The Moon","data_quality":"Correct"}""";
    const string FxUserNoCurrency = """{"id":2443307,"username":"susan.salkeld","resource_url":"https://api.discogs.com/users/susan.salkeld","curr_abbr":"","num_for_sale":0,"activated":true,"marketplace_suspended":false}""";

    static void MasterCard() => Check.Section("albumkortet", () =>
    {
        var m = DiscogsClient.ParseMasterOffer(B(FxMaster10362));
        Check.That(m.LowestPrice == 0.01 && m.NumForSale == 8395 && m.MainRelease == 1873013 && m.Currency == null,
                   "master: lowest_price, num_for_sale og main_release læses; ingen curr_abbr → null");
        var withCur = DiscogsClient.ParseMasterOffer(B("""{"id":1,"lowest_price":12.5,"num_for_sale":"3","main_release":7,"curr_abbr":"eur"}"""));
        Check.That(withCur.Currency == "EUR" && withCur.NumForSale == 3 && withCur.MainRelease == 7, "master: curr_abbr læses, hvis Discogs sender den");
        var bare = DiscogsClient.ParseMasterOffer(B("""{"id":2,"lowest_price":null,"main_release":0}"""));
        Check.That(bare.LowestPrice == null && bare.NumForSale == null && bare.MainRelease == null, "master uden pris/antal/hovedudgave → null");
        try { DiscogsClient.ParseMasterOffer(B("{}")); Check.That(false, "master uden id skal fejle"); }
        catch (DiscogsException e) { Check.That(e.Message == "Svaret fra Discogs kunne ikke læses (albummets priser).", "master: fejl på dansk"); }

        Check.That(DiscogsClient.ParseUserCurrency(B(FxUserNoCurrency)) == null, "brugerens valuta: tom curr_abbr → null (ukendt)");
        Check.That(DiscogsClient.ParseUserCurrency(B("""{"username":"holger","curr_abbr":"EUR"}""")) == "EUR", "brugerens valuta: EUR");
        Check.That(DiscogsClient.ParseUserCurrency(B("""{"username":"holger","curr_abbr":" usd"}""")) == "USD", "brugerens valuta: renses til USD");
        Check.That(DiscogsClient.ParseUserCurrency(B("""{"username":"holger"}""")) == null, "brugerens valuta: mangler → null");
        Check.That(DiscogsClient.ParseUserCurrency(B("""{"username":"holger","curr_abbr":"€"}""")) == null, "brugerens valuta: ugyldig kode → null");
        try { DiscogsClient.ParseUserCurrency(B("ikke json")); Check.That(false, "ugyldig bruger-JSON skal fejle"); }
        catch (DiscogsException e) { Check.That(e.Message == "Svaret fra Discogs kunne ikke læses (din valuta).", "brugerens valuta: fejl på dansk"); }

        Check.That(DiscogsClient.MarketplaceUrl(masterId: 10362, format: "Vinyl").AbsoluteUri == "https://www.discogs.com/sell/list?master_id=10362&format=Vinyl",
                   "markedsplads for hele albummet i Vinyl");
        Check.That(DiscogsClient.MarketplaceUrl(masterId: 10362, format: "Cassette").AbsoluteUri == "https://www.discogs.com/sell/list?master_id=10362&format=Cassette",
                   "markedsplads for hele albummet på kassette");
        Check.That(DiscogsClient.MarketplaceUrl(masterId: 10362, format: null).AbsoluteUri == "https://www.discogs.com/sell/list?master_id=10362"
                   && DiscogsClient.MarketplaceUrl(masterId: 10362, format: "").AbsoluteUri == "https://www.discogs.com/sell/list?master_id=10362",
                   "markedsplads uden format = alle formater");

        // Valuta: kun EUR → DKK regnes om; ellers vises Discogs' egen valuta. Ingen opfundne kurser.
        var offer = new MasterOffer(10, null, 37, 5);
        var eurToDkk = offer.Market("EUR", "DKK");
        Check.That(eurToDkk.Currency == "DKK" && eurToDkk.LowestPrice == 74.6 && eurToDkk.NumForSale == 37, "master: EUR-pris vises i kr. (omregnet)");
        var same = offer.Market("SEK", "SEK");
        Check.That(same.Currency == "SEK" && same.LowestPrice == 10, "master: samme valuta som appen → vises direkte");
        var usdInDkkApp = offer.Market("USD", "DKK");
        Check.That(usdInDkkApp.Currency == "USD" && usdInDkkApp.LowestPrice == 10, "master: USD i en kroneapp vises i USD (ingen opfundet kurs)");
        var gbpInEurApp = offer.Market("GBP", "EUR");
        Check.That(gbpInEurApp.Currency == "GBP" && gbpInEurApp.LowestPrice == 10, "master: GBP i en euroapp vises i GBP");
        var unknown = offer.Market(null, "DKK");
        Check.That(unknown.LowestPrice == null && unknown.NumForSale == 37, "master: ukendt valuta → ingen pris, kun antal til salg");
        var own = new MasterOffer(10, "EUR", 1, null).Market("USD", "DKK");
        Check.That(own.Currency == "DKK" && own.LowestPrice == 74.6, "master: svarets egen valuta går forud for brugerens");
        Check.That(MarketCurrency.Converted(new MarketInfo(10, "USD", 1, null, null), "DKK").Currency == "USD"
                   && MarketCurrency.Converted(new MarketInfo(10, "SEK", 1, null, null), "DKK").LowestPrice == 10,
                   "Converted: kun mellem EUR og DKK, aldrig USD/SEK → DKK");

        // Ende-til-ende mod falsk netværk
        var net = new StubDiscogs
        {
            Routes = new()
            {
                ["GET /masters/10362"] = (200, FxMaster10362),
                ["GET /users/holger"] = (200, """{"username":"holger","curr_abbr":"EUR"}"""),
                ["GET /masters/10362/versions"] = (200, FxVersionsP1),
            },
        };
        var stub = StubClient(net);
        var mo = Blocking(() => stub.MasterOfferAsync(10362));
        Check.That(mo.Value?.MainRelease == 1873013 && net.SeenRequests.LastOrDefault()?.Url.AbsolutePath == "/masters/10362"
                   && net.SeenRequests.LastOrDefault()?.Method == "GET", "MasterOfferAsync henter GET /masters/{id}");
        var uc = Blocking(() => stub.UserCurrencyAsync("holger"));
        Check.That(uc.Value == "EUR" && net.SeenRequests.LastOrDefault()?.Url.AbsolutePath == "/users/holger", "UserCurrencyAsync henter GET /users/{username}");
        Check.That(Blocking(() => stub.VersionsAsync(Album(10362, true))).Value?.Total == 1542, "versions: samlet antal udgaver fra pagination.items");
    });

    // MARK: Fælles kø (rate limit) og cache for Discogs
    sealed class FakeClock
    {
        private readonly object _lock = new();
        private double _t = 1000;
        public double Now { get { lock (_lock) return _t; } }
        public void Advance(double s) { lock (_lock) _t += s; }
    }

    static void QueueAndCache() => Check.Section("kø og cache", () =>
    {
        // Token-bucket: 15 kald i et hug, derefter 45 i minuttet (højst 60 i ét minut).
        var b = new TokenBucket(15, 45, 0);
        var taken = 0;
        while (b.Take(0) == 0) taken++;
        Check.That(taken == 15, $"token-bucket: 15 kald i et hug ({taken})");
        var wait = b.Take(0);
        Check.That(Math.Abs(wait - 60.0 / 45) < 0.001, $"token-bucket: derefter ét kald pr. 1,33 s ({wait})");
        Check.That(b.Take(1.4) == 0 && b.Take(1.4) > 0, "token-bucket: efter ventetiden må ét kald sendes");
        var perMinute = 0;
        var t = 0.0;
        var fresh = new TokenBucket(15, 45, 0);
        while (t < 60) { if (fresh.Take(t) == 0) perMinute++; else t += 0.01; }
        Check.That(perMinute <= 60, $"token-bucket: højst 60 kald i det første minut ({perMinute})");
        var p = new TokenBucket(15, 45, 0);
        p.Pause(3, 10);
        Check.That(Math.Abs(p.Take(11) - 2) < 0.001, "pause: ingen kald i 3 sekunder");
        Check.That(p.Take(13) > 0, "pause: spanden starter tom efter pausen");
        Check.That(p.Take(13 + 1.4) == 0, "pause: derefter normalt tempo");
        var copy = new TokenBucket(15, 45, 0);
        Check.That(copy.Equals(new TokenBucket(15, 45, 0)), "token-bucket er en ren værdi");

        var fastQueue = Blocking(async () =>
        {
            var q = new DiscogsRateLimiter(3, 60_000);
            for (int i = 0; i < 10; i++) await q.AcquireAsync(DiscogsPriority.Interactive);
            return true;
        });
        Check.That(fastQueue.Value, "køen slipper kald igennem");
        var cancelled = Blocking(async () =>
        {
            var q = new DiscogsRateLimiter(1, 1);
            await q.AcquireAsync(DiscogsPriority.Background);
            using var cts = new CancellationTokenSource();
            var waiting = q.AcquireAsync(DiscogsPriority.Background, cts.Token);
            cts.Cancel();
            try { await waiting; return false; } catch (OperationCanceledException) { return true; }
        });
        Check.That(cancelled.Value, "en annulleret ventende opgave kaster OperationCanceledException");
        var paused = Blocking(async () =>
        {
            var clock = new FakeClock();
            var q = new DiscogsRateLimiter(100, 6000, () => clock.Now, maxSleep: 0.05);
            q.Observe(2);
            var waiting = q.AcquireAsync(DiscogsPriority.Interactive);
            await Task.Delay(150);
            var blocked = !waiting.IsCompleted;
            clock.Advance(3.1);
            await waiting.WaitAsync(TimeSpan.FromSeconds(5));
            q.Observe(10);
            await q.AcquireAsync(DiscogsPriority.Interactive).WaitAsync(TimeSpan.FromSeconds(5));
            return blocked;
        });
        Check.That(paused.Value && paused.Error == null, "under 3 kald tilbage → pause for alle i 3 sekunder");
        var priority = Blocking(async () =>
        {
            var clock = new FakeClock();
            var q = new DiscogsRateLimiter(1, 60, () => clock.Now, maxSleep: 0.05);
            await q.AcquireAsync(DiscogsPriority.Interactive);          // spanden er nu tom
            var interactive = q.AcquireAsync(DiscogsPriority.Interactive);
            await Task.Delay(30);
            var background = q.AcquireAsync(DiscogsPriority.Background);
            await Task.Delay(30);
            clock.Advance(1.0);                                         // plads til præcis ét kald
            await interactive.WaitAsync(TimeSpan.FromSeconds(5));
            await Task.Delay(200);
            var backgroundWaited = !background.IsCompleted;
            clock.Advance(1.0);
            await background.WaitAsync(TimeSpan.FromSeconds(5));
            return backgroundWaited;
        });
        Check.That(priority.Value && priority.Error == null, "interaktive kald går foran baggrundskald");

        // Cache: samme nøgle hentes kun én gang, også når to kald kører samtidig.
        var fake = new FakeClock();
        var cache = new DiscogsResponseCache(2, 600, () => fake.Now);
        var calls = 0;
        Func<Task<byte[]>> load = async () =>
        {
            Interlocked.Increment(ref calls);
            await Task.Delay(50);
            return B("svar");
        };
        var together = Blocking(async () =>
        {
            var x = cache.DataAsync("a", load);
            var y = cache.DataAsync("a", load);
            return await Task.WhenAll(x, y);
        });
        Check.That(together.Value?.All(d => Encoding.UTF8.GetString(d) == "svar") == true && together.Value.Length == 2 && calls == 1,
                   $"cache: to samtidige ens kald → ét kald ({calls})");
        Blocking(() => cache.DataAsync("a", load));
        Check.That(calls == 1, "cache: gentaget kald tages fra cachen");
        fake.Advance(601);
        Blocking(() => cache.DataAsync("a", load));
        Check.That(calls == 2, "cache: efter 10 minutter hentes svaret igen");
        Blocking(() => cache.DataAsync("b", load));
        Blocking(() => cache.DataAsync("a", load));   // a er nu senest brugt
        Blocking(() => cache.DataAsync("c", load));   // b smides ud
        Check.That(cache.Count == 2, "cache: højst MaxEntries svar");
        var before = calls;
        Blocking(() => cache.DataAsync("a", load));
        Check.That(calls == before, "cache: det senest brugte svar bliver liggende");
        Blocking(() => cache.DataAsync("b", load));
        Check.That(calls == before + 1, "cache: det ældst brugte svar er smidt ud");
        Func<Task<byte[]>> failingLoad = () => { Interlocked.Increment(ref calls); throw DiscogsException.Offline(); };
        var failing = Blocking(() => cache.DataAsync("fejl", failingLoad));
        var afterFail = calls;
        Blocking(() => cache.DataAsync("fejl", failingLoad));
        Check.That(ErrorText(failing.Error) != null && failing.Error is DiscogsException && calls == afterFail + 1, "cache: fejl gemmes ikke");
        cache.RemoveAll();
        Check.That(cache.Count == 0, "cache: RemoveAll tømmer cachen");

        // Søgning: mange masters → ét kald; få masters → også releases (album uden master).
        var manyMasters = """{"pagination":{"page":1,"pages":2,"items":60},"results":[{"id":10362,"type":"master","title":"Pink Floyd - The Dark Side Of The Moon","year":"1973"},{"id":1,"type":"release","title":"X - Y"}]}""";
        var only = DiscogsClient.MastersOnly(B(manyMasters));
        Check.That(only?.Albums.Select(a => a.Id).SequenceEqual(new[] { 10362 }) == true && only.HasMore, "MastersOnly: nok masters → kun masters");
        var few = DiscogsClient.MastersOnly(B("""{"pagination":{"page":1,"pages":1,"items":3},"results":[]}"""));
        Check.That(few == null, "MastersOnly: få masters → søg også releases");

        var net = new StubDiscogs
        {
            Routes = new()
            {
                ["GET /database/search?type=master"] = (200, manyMasters),
                ["GET /database/search?type=release"] = (200, """{"pagination":{"page":1,"pages":1,"items":0},"results":[]}"""),
                ["GET /masters/10362/versions"] = (200, FxVersionsP1),
                ["GET /marketplace/stats/6496"] = (200, FxStats6496DKK),
            },
        };
        var plain = StubClient(net);
        var one = Blocking(() => plain.SearchAlbumsAsync("pink floyd"));
        Check.That(one.Value?.Albums.Select(a => a.Id).SequenceEqual(new[] { 10362 }) == true && net.SeenRequests.Count == 1,
                   $"SearchAlbumsAsync: mange masters → kun ét kald ({net.SeenRequests.Count})");

        var cached = StubClient(net, cache: new DiscogsResponseCache());
        var master = Album(10362, true);
        net.ClearSeen();
        Blocking(() => cached.SearchAlbumsAsync("pink floyd"));
        Blocking(() => cached.SearchAlbumsAsync("pink floyd"));
        Blocking(() => cached.VersionsAsync(master));
        Blocking(() => cached.VersionsAsync(master));
        Check.That(net.SeenRequests.Count == 2, $"cache: samme søgning og samme udgaver hentes kun én gang ({net.SeenRequests.Count} kald)");
        Blocking(() => cached.SearchAlbumsAsync("pink floyd", format: "Vinyl"));
        Check.That(net.SeenRequests.Count == 3, "cache: et andet format er en ny søgning");
        net.ClearSeen();
        Blocking(() => cached.MarketInfoAsync(6496, "DKK"));
        Blocking(() => cached.MarketInfoAsync(6496, "DKK"));
        Check.That(net.SeenRequests.Count == 2, "cache: priser hentes altid frisk");

        // 429: køen holder pause og prøver igen (kort pause via falsk ur).
        var clock429 = new FakeClock();
        var limiter429 = new DiscogsRateLimiter(100, 6000, () => clock429.Now, maxSleep: 0.05);
        var seq = new SequenceHandler(new[] { 429, 200 });
        var retry = new DiscogsClient("TEST-token", new HttpClient(seq), limiter429);
        var retried = Blocking(async () =>
        {
            var task = retry.MarketInfoAsync(6496, "DKK");
            await Task.Delay(150);
            clock429.Advance(6);
            return await task.WaitAsync(TimeSpan.FromSeconds(5));
        });
        Check.That(retried.Value?.LowestPrice == 3.36 && seq.Calls == 2, "429 → pause og nyt forsøg");
    });

    /// Svarer med statuskoderne i rækkefølge (det sidste gentages), altid med stats-svaret.
    sealed class SequenceHandler : HttpMessageHandler
    {
        private readonly int[] _codes;
        private int _n;
        public int Calls => _n;
        public SequenceHandler(int[] codes) => _codes = codes;
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken ct)
        {
            var i = Interlocked.Increment(ref _n) - 1;
            var code = _codes[Math.Min(i, _codes.Length - 1)];
            return Task.FromResult(new HttpResponseMessage((HttpStatusCode)code) { Content = new StringContent(FxStats6496DKK) });
        }
    }

    // MARK: Hemmeligheder (abstraktion; Windows Credential Manager ligger i appen)
    static void Secrets() => Check.Section("hemmeligheder", () =>
    {
        ISecretStore s = new InMemorySecretStore();
        Check.That(!s.Exists && s.Load() == null, "tom hemmelighed");
        s.Save("hemmeligt-token");
        Check.That(s.Exists && s.Load() == "hemmeligt-token" && !s.ToString()!.Contains("hemmeligt"), "gemt og læst, men vises aldrig");
        s.Save("nyt");
        Check.That(s.Load() == "nyt", "udskiftes uden at slette først");
        s.Delete();
        Check.That(!s.Exists, "slettet");
        Check.That(SecretNames.Discogs == "dk.vinylshelffinder.discogs" && SecretNames.IMusicFeed == "dk.vinylshelffinder.imusicfeed",
                   "samme navne som nøgleringen på Mac");
    });

    // MARK: iMusic (Daisycon-feed, separat cache)
    // Små lokale eksempel-feeds i Daisycons struktur (datafeed › programs › products › product_info / update_info).
    // Det rigtige feed og imusic.dk hentes aldrig i checks.
    const string FxIMusicJson = """
    {"datafeed":{"info_array":{"generated":"2026-10-02"},"programs":[{"program_info":{"id":19392,"name":"iMusic DK","url":"https://imusic.dk"},
     "products":[
      {"product_info":{"title":"Pink Floyd - Animals (LP)","link":"https://lt45.net/c/?si=19392&li=1&wi=1&ws=&dl=animals","price":"249.00","ean":"5099902987613","category_path":"Musik > Vinyl","in_stock":true,"delivery_time":"1-2 hverdage","images":[{"location":"https://img/1.jpg","size":"large","tag":"","type":"front"}]},
       "update_info":{"daisycon_unique_id":"a1","status":"active"}},
      {"product_info":{"title":"Pink Floyd - Animals","brand":"Pink Floyd","link":"https://lt45.net/c/?si=19392&li=1&wi=1&ws=&dl=animals-cd","price":"99,95","ean":"0 77774 64612 5","category":"CD","in_stock":"false","delivery_description":"Bestillingsvare"},
       "update_info":{"daisycon_unique_id":"a2","status":"active"}},
      {"product_info":{"title":"Alien (DVD)","link":"https://lt45.net/c/?dl=alien","price":"59","category_path":"Film > DVD","in_stock":true},
       "update_info":{"status":"active"}},
      {"product_info":{"title":"David Bowie - Low (LP)","link":"https://lt45.net/c/?dl=low","price":"229","category_path":"Musik > Vinyl","in_stock":true},
       "update_info":{"status":"deleted"}},
      {"product_info":{"title":"Kim Larsen - Værsgo \"Remastered\" {LP}","link":"https://lt45.net/c/?dl=vaersgo","price":"1.249,95","keywords":"vinyl dansk rock","in_stock_amount":"3"},
       "update_info":{"status":"active"}}
     ]}]}}
    """;
    const string FxIMusicXml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <datafeed><programs><program><program_info><id>19392</id><name>iMusic DK</name></program_info>
    <products>
     <product><product_info><title>Pink Floyd - Animals (LP)</title><link>https://lt45.net/c/?si=19392&amp;dl=animals</link><price>249.00</price><ean>5099902987613</ean><category_path>Musik &gt; Vinyl</category_path><in_stock>true</in_stock><images><image><location>https://img/1.jpg</location></image></images></product_info><update_info><status>active</status></update_info></product>
     <product><product_info><title><![CDATA[Alien (DVD)]]></title><link>https://lt45.net/c/?dl=alien</link><price>59</price><category_path>Film</category_path></product_info></product>
     <product><product_info><title>Genesis - Foxtrot</title><brand>Genesis</brand><link>https://lt45.net/c/?dl=foxtrot</link><price>199</price><category>Vinyl</category><in_stock>0</in_stock><delivery_description>Bestillingsvare</delivery_description></product_info><update_info><status>active</status></update_info></product>
    </products></program></programs></datafeed>
    """;

    static void IMusic() => Check.Section("iMusic", () =>
    {
        // Stregkoder
        Check.That(Barcode.Normalize("5 099902 987613") == "5099902987613", "EAN-13 med mellemrum → kun cifre");
        Check.That(Barcode.Normalize("0 77774 64612 5") == "0077774646125" && Barcode.Normalize("077774646125") == "0077774646125",
                   "UPC-A (12 cifre) → EAN-13 med foranstillet 0");
        Check.That(Barcode.Normalize("00077774646125") == "0077774646125", "GTIN-14 med foranstillet 0 → EAN-13");
        Check.That(Barcode.Normalize("1234-5678") == "12345678", "EAN-8");
        Check.That(Barcode.Normalize("SHVL 804") == null && Barcode.Normalize("") == null && Barcode.Normalize("12345") == null,
                   "katalognumre og korte tal er ikke stregkoder");

        // Priser og lager
        Check.That(IMusicFields.ParsePrice("249.00") == 249 && IMusicFields.ParsePrice("99,95") == 99.95
                   && IMusicFields.ParsePrice("1.249,95") == 1249.95 && IMusicFields.ParsePrice("DKK 1,249.50") == 1249.5
                   && IMusicFields.ParsePrice("gratis") == null && IMusicFields.ParsePrice("0") == null, "priser i begge talformater");
        Check.That(IMusicFields.ParseStock("true") == true && IMusicFields.ParseStock("0") == false && IMusicFields.ParseStock("3") == true
                   && IMusicFields.ParseStock("Out of stock") == false && IMusicFields.ParseStock("måske") == null, "lagerstatus");

        // JSON (læst i bidder på 7 byte)
        var fromJson = IMusicFeedParser.Parse(B(FxIMusicJson));
        Check.That(fromJson.Select(p => p.Title).SequenceEqual(new[] { "Animals (LP)", "Pink Floyd - Animals", "Værsgo \"Remastered\" {LP}" }),
                   $"JSON: kun aktive musikvarer (ikke film, ikke slettede): {string.Join(" | ", fromJson.Select(p => p.Title))}");
        var animalsLp = fromJson.FirstOrDefault();
        Check.That(animalsLp?.Artist == "Pink Floyd" && animalsLp.Ean == "5099902987613" && animalsLp.Price == 249
                   && animalsLp.Currency == "DKK" && animalsLp.InStock == true && animalsLp.IsVinyl
                   && animalsLp.Link.AbsoluteUri == "https://lt45.net/c/?si=19392&li=1&wi=1&ws=&dl=animals",
                   "JSON: kunstner fra titlen, EAN, pris, lager og affiliate-link");
        var animalsCd = fromJson.Skip(1).FirstOrDefault();
        Check.That(animalsCd?.Artist == "Pink Floyd" && animalsCd.Ean == "0077774646125" && animalsCd.Price == 99.95
                   && animalsCd.InStock == false && animalsCd.AvailabilityText == "bestillingsvare" && !animalsCd.IsVinyl,
                   "JSON: brand som kunstner, UPC → EAN, bestillingsvare");
        Check.That(fromJson.LastOrDefault()?.Price == 1249.95 && fromJson.Last().InStock == true, "JSON: anførselstegn og tuborgklammer i tekst, lager som antal");
        Check.That(animalsLp?.AvailabilityText == "på lager", "på lager-tekst");
        Check.That(new IMusicProduct("T", "A", null, "", null, "DKK", null, " Leveres om 1-2 hverdage ", new Uri("https://x.dk")).AvailabilityText
                   == "leveres om 1-2 hverdage", "leveringstekst, når lager er ukendt");

        // XML (streamet)
        var fromXml = IMusicFeedParser.Parse(B(FxIMusicXml));
        Check.That(fromXml.Select(p => p.Title).SequenceEqual(new[] { "Animals (LP)", "Genesis - Foxtrot" }),
                   $"XML: kun musikvarer: {string.Join(" | ", fromXml.Select(p => p.Title))}");
        Check.That(fromXml.FirstOrDefault()?.Link.AbsoluteUri == "https://lt45.net/c/?si=19392&dl=animals" && fromXml[0].Ean == "5099902987613",
                   "XML: &amp; i linket og EAN");
        Check.That(fromXml.LastOrDefault()?.Artist == "Genesis" && fromXml.Last().InStock == false && fromXml.Last().AvailabilityText == "bestillingsvare",
                   "XML: brand som kunstner og bestillingsvare");
        Check.That(IMusicFeedParser.DetectFormat(B("  \n{")) == IMusicFeedFormat.Json && IMusicFeedParser.DetectFormat(B("﻿<?xml")) == IMusicFeedFormat.Xml
                   && IMusicFeedParser.DetectFormat(B("title;link")) == null, "formatet genkendes (også med BOM)");
        try { IMusicFeedParser.Parse(B("title;link\nx;y")); Check.That(false, "CSV skal afvises"); }
        catch (IMusicFeedException e) { Check.That(e.Kind == IMusicFeedErrorKind.UnknownFormat && e.Message.StartsWith("iMusic-feedet er hverken JSON eller XML"), "ukendt format → dansk fejl"); }
        try { IMusicFeedParser.Parse(B("<datafeed><product>")); Check.That(false, "ødelagt XML uden varer skal fejle"); }
        catch (IMusicFeedException e) { Check.That(e.Message == "iMusic-feedet kunne ikke læses.", "ødelagt XML → dansk fejl"); }
        var cut = IMusicFeedParser.Parse(B(FxIMusicXml[..FxIMusicXml.IndexOf("<product><product_info><title><![CDATA", StringComparison.Ordinal)]));
        Check.That(cut.Count == 1, "afbrudt XML: de varer, der nåede at blive læst, beholdes");

        // Søge-URL (virker uden feed)
        Check.That(IMusicLink.SearchUrl("Pink Floyd", "Animals").AbsoluteUri == "https://imusic.dk/page/search?query=Pink%20Floyd%20Animals",
                   "søge-URL på imusic.dk");
        Check.That(IMusicLink.SearchUrl(" Kim Larsen ", "Værsgo", vinylOnly: true).AbsoluteUri == "https://imusic.dk/vinyl/search?query=Kim%20Larsen%20V%C3%A6rsgo",
                   "søge-URL kun i vinyl, med æøå");
        Check.That(IMusicLink.SearchUrl("AC/DC", "Back In Black & More").Query.Contains("%26"), "& kodes i søgningen");

        // Feed-URL'en
        Check.That(IMusicFeedUpdater.Validate(" https://daisycon.io/datafeed/?media_id=1&program_id[]=19392&type=JSON ") != null, "Daisycon-feed-URL godtages");
        Check.That(IMusicFeedUpdater.Validate("http://daisycon.io/datafeed/") == null && IMusicFeedUpdater.Validate("https://example.com/feed") == null
                   && IMusicFeedUpdater.Validate("hej") == null, "kun https hos Daisycon");

        // Cache: separat fil under Cache, aldrig vinyl.sqlite
        var defaultCache = IMusicCache.DefaultPath;
        Check.That(Path.GetFileName(defaultCache) == "imusic.sqlite" && defaultCache.Contains(Path.Combine("VinylShelfFinder", "Cache") + Path.DirectorySeparatorChar)
                   && defaultCache != ShelfStore.DefaultPath && Path.GetDirectoryName(defaultCache) != Path.GetDirectoryName(ShelfStore.DefaultPath),
                   "iMusic-cachen ligger i Cache, ikke ved vinyl.sqlite");
        var dir = Check.TempDir();
        try
        {
            var feedFile = Path.Combine(dir, "feed.json");
            File.WriteAllText(feedFile, FxIMusicJson);
            using (var cache = new IMusicCache(Path.Combine(dir, "imusic.sqlite")))
            {
                Check.That(IMusicCache.NeedsRefresh(null) && cache.LastFetched == null, "tom cache skal hentes");
                var day = DateTimeOffset.FromUnixTimeSeconds(1_790_000_000);
                var stored = cache.Replace(feedFile, day);
                Check.That(stored == 3 && cache.Count == 3, $"cachen får de 3 musikvarer fra feedet ({stored})");
                Check.That(cache.LastFetched == day && !IMusicCache.NeedsRefresh(day, day.AddHours(1))
                           && IMusicCache.NeedsRefresh(day, day.AddHours(25)) && IMusicCache.NeedsRefresh(day.AddHours(2), day),
                           "feedet hentes højst én gang i døgnet");
                var files = Directory.GetFiles(dir).Select(Path.GetFileName).ToHashSet();
                Check.That(!files.Contains("vinyl.sqlite") && files.IsSubsetOf(new[] { "feed.json", "imusic.sqlite", "imusic.sqlite-wal", "imusic.sqlite-shm" }),
                           $"cachen opretter ingen vinyl.sqlite: {string.Join(",", files.Order())}");
                var xmlFile = Path.Combine(dir, "feed.xml");
                File.WriteAllText(xmlFile, FxIMusicXml);
                var fromXmlFile = cache.Replace(xmlFile, day);
                Check.That(fromXmlFile == 2 && cache.Count == 2, "ny hentning erstatter hele cachen (XML)");
                var badFile = Path.Combine(dir, "feed.csv");
                File.WriteAllText(badFile, "title;link");
                try { cache.Replace(badFile, day); Check.That(false, "ukendt format skal fejle"); }
                catch (IMusicFeedException) { Check.That(cache.Count == 2, "fejl under hentning → den gamle cache beholdes"); }
                cache.Replace(feedFile, day);

                // Matching
                Check.That(cache.Match(new[] { "5 099902 987613" }, "", "")?.Price == 249, "match på stregkode");
                Check.That(cache.Match(new[] { "077774646125" }, "Noget", "Andet")?.Price == 99.95, "match på UPC mod EAN i feedet");
                Check.That(cache.Match(Array.Empty<string>(), "Pink Floyd", "Animals")?.IsVinyl == true, "kunstner + titel: vinyl foretrækkes");
                Check.That(cache.Match(Array.Empty<string>(), "Pink Floyd", "Animals", preferVinyl: false)?.IsVinyl == false,
                           "uden vinyl-ønske vinder den udgave, der passer bedst (her cd'en uden ekstra ord)");
                Check.That(cache.Match(Array.Empty<string>(), "Pink Floid", "Animals")?.Price == 249, "tåler en stavefejl i kunstnernavnet");
                Check.That(cache.Match(Array.Empty<string>(), "Kim Larsen", "Værsgo")?.Price == 1249.95, "æøå i titlen");
                Check.That(cache.Match(Array.Empty<string>(), "Pink Floyd", "The Wall") == null, "intet match, når et ord mangler");
                Check.That(cache.Match(new[] { "1234567890128" }, "", "") == null, "ukendt stregkode og ingen tekst → intet match");
                Check.That(IMusicMatcher.Score(new[] { "pink", "floyd", "animals" }, animalsCd!) == 30
                           && IMusicMatcher.Score(new[] { "pink", "floyd", "animals" }, animalsLp!) == 29, "score: præcise ord, ekstra ord trækker ned");

                // Hentning mod et falsk netværk (feedet hentes aldrig rigtigt i checks)
                var feedUrl = IMusicFeedUpdater.Validate("https://daisycon.io/datafeed/?media_id=1&type=XML")!;
                var feedNet = new FeedStub(200, FxIMusicXml, null);
                var n = Blocking(() => IMusicFeedUpdater.RefreshAsync(feedUrl, cache, new HttpClient(feedNet), day));
                Check.That(n.Value == 2 && cache.Count == 2 && feedNet.UserAgent == DiscogsClient.UserAgent, "RefreshAsync henter feedet og fylder cachen");
                Check.That(!Directory.GetFiles(Path.GetTempPath(), "vsf-imusic-*.feed").Any(), "den midlertidige feed-fil slettes");
                var notApproved = Blocking(() => IMusicFeedUpdater.RefreshAsync(feedUrl, cache, new HttpClient(new FeedStub(200, "[]", "0")), day));
                Check.That(ErrorText(notApproved.Error) == "Feedet er tomt. Er du godkendt til iMusic-kampagnen hos Daisycon endnu?" && cache.Count == 2,
                           "X-Total-Count: 0 → ikke godkendt endnu (cachen beholdes)");
                var http403 = Blocking(() => IMusicFeedUpdater.RefreshAsync(feedUrl, cache, new HttpClient(new FeedStub(403, "", null)), day));
                Check.That(ErrorText(http403.Error) == "Daisycon svarede med en fejl (kode 403). Tjek feed-URL'en i Indstillinger."
                           && !ErrorText(http403.Error)!.Contains("media_id"), "HTTP-fejl → dansk tekst uden feed-URL");
            }
        }
        finally
        {
            try { Directory.Delete(dir, true); } catch (IOException) { }
        }
    });

    /// Falsk Daisycon: ét fast svar.
    sealed class FeedStub : HttpMessageHandler
    {
        private readonly int _status;
        private readonly string _body;
        private readonly string? _totalCount;
        public string? UserAgent;
        public FeedStub(int status, string body, string? totalCount) { _status = status; _body = body; _totalCount = totalCount; }
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken ct)
        {
            UserAgent = request.Headers.TryGetValues("User-Agent", out var ua) ? string.Join(" ", ua) : null;
            var resp = new HttpResponseMessage((HttpStatusCode)_status) { Content = new StringContent(_body) };
            if (_totalCount != null) resp.Headers.TryAddWithoutValidation("X-Total-Count", _totalCount);
            return Task.FromResult(resp);
        }
    }
}
