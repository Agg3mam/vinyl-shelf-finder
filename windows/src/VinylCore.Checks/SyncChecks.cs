using System.Net;
using System.Text;
using System.Text.Json.Nodes;
using VinylShelfFinder.Core;

namespace VinylShelfFinder.Checks;

/// Svarer som Supabase: login med koden 123456, og en tabel med poster, hvor serveren sætter updated_at.
sealed class StubCloud : HttpMessageHandler
{
    public readonly Dictionary<string, JsonObject> Rows = new();
    private int _tick;
    private readonly object _lock = new();

    protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken ct)
    {
        var url = request.RequestUri!;
        var q = NetChecks.QueryItems(url).GroupBy(x => x.Name).ToDictionary(g => g.Key, g => g.First().Value);
        var body = request.Content is null ? null : JsonNode.Parse(await request.Content.ReadAsStringAsync(ct));
        int status = 200;
        JsonNode? output = new JsonObject();
        var session = new JsonObject
        {
            ["access_token"] = "adgang", ["refresh_token"] = "forny", ["expires_in"] = 3600,
            ["user"] = new JsonObject { ["id"] = "00000000-0000-0000-0000-000000000001", ["email"] = "test@example.com" },
        };
        lock (_lock)
        {
            switch (request.Method.Method, url.AbsolutePath)
            {
                case ("POST", "/auth/v1/otp"): break;
                case ("POST", "/auth/v1/verify"):
                    if (body?["token"]?.GetValue<string>() == "123456" || body?["token_hash"]?.GetValue<string>() == "pkce_hash1") output = session;
                    else { status = 403; output = new JsonObject { ["code"] = 403, ["error_code"] = "otp_expired" }; }
                    break;
                case ("POST", "/auth/v1/token") when q.GetValueOrDefault("grant_type") == "password":
                    if (body?["email"]?.GetValue<string>() == "test@example.com" && body?["password"]?.GetValue<string>() == "hemmelig-kode") output = session;
                    else { status = 400; output = new JsonObject { ["code"] = 400, ["error_code"] = "invalid_credentials" }; }
                    break;
                case ("POST", "/auth/v1/token"): output = session; break;
                case ("PUT", "/auth/v1/user"):
                    if (!request.Headers.TryGetValues("Authorization", out var a) || a.First() != "Bearer adgang") { status = 401; break; }
                    output = new JsonObject { ["id"] = "00000000-0000-0000-0000-000000000001", ["email"] = "test@example.com" };
                    break;
                case ("GET", "/rest/v1/sync_records"):
                {
                    if (!request.Headers.TryGetValues("Authorization", out var auth) || auth.First() != "Bearer adgang")
                    { status = 401; output = new JsonObject { ["code"] = "PGRST301" }; break; }
                    var from = (q.GetValueOrDefault("updated_at") ?? "").Replace("gte.", "");
                    var list = Rows.Values.Where(r => from.Length == 0 || string.CompareOrdinal(r["updated_at"]!.GetValue<string>(), from) >= 0)
                                   .OrderBy(r => r["updated_at"]!.GetValue<string>(), StringComparer.Ordinal).ToList();
                    int offset = int.Parse(q.GetValueOrDefault("offset") ?? "0"), limit = int.Parse(q.GetValueOrDefault("limit") ?? "1000");
                    output = new JsonArray(list.Skip(offset).Take(limit).Select(r => JsonNode.Parse(r.ToJsonString())).ToArray());
                    break;
                }
                case ("POST", "/rest/v1/sync_records"):
                    foreach (var r in body!.AsArray().OfType<JsonObject>())
                    {
                        _tick++;
                        var row = (JsonObject)JsonNode.Parse(r.ToJsonString())!;
                        row["updated_at"] = $"2026-10-18T12:{_tick / 60:00}:{_tick % 60:00}.123456+00:00";
                        Rows[$"{row["kind"]}|{row["key"]}"] = row;
                    }
                    status = 201;
                    break;
                default: status = 404; break;
            }
        }
        return new HttpResponseMessage((HttpStatusCode)status)
        {
            Content = new ByteArrayContent(Encoding.UTF8.GetBytes(output?.ToJsonString() ?? "{}")),
            RequestMessage = request,
        };
    }
}

/// Port af afsnittene om synkronisering og kontoen i skyen i VinylCoreChecks/main.swift.
static class SyncChecks
{
    private static readonly List<string> Dirs = new();
    private static string TempDb(string tag)
    {
        var d = Check.TempDir();
        Dirs.Add(d);
        return Path.Combine(d, $"vsf-{tag}.sqlite");
    }

    static DiscogsCollectionItem It(long i, string artist, string title) =>
        new(2_400_000_000 + i, null, new Release((int)(950_000 + i), artist, title, Format: "Vinyl, LP"));

    static List<List<string>> Order(Library l) =>
        l.Locations.Select(loc => (l.Sections.TryGetValue(loc.Id, out var ids) ? ids : new List<long>())
            .Select(id => l.Item(id)?.Title).OfType<string>().ToList()).ToList();

    static bool Same(List<List<string>> a, List<List<string>> b) => a.Count == b.Count && a.Zip(b).All(p => p.First.SequenceEqual(p.Second));

    public static void Run()
    {
        Docs();
        Tracks();
        Cloud();
        foreach (var d in Dirs) { try { Directory.Delete(d, true); } catch { } }
    }

    private static void Tracks() => Check.Section("sanglister (søg på en sang)", () =>
    {
        var json = """{"id":1,"tracklist":[{"position":"","type_":"heading","title":"Side 1"},{"position":"A1","type_":"track","title":"Shine On You Crazy Diamond (Parts I-V)","duration":"13:30"},{"position":"A2","type_":"track","title":"Welcome To The Machine","duration":""},{"position":"","type_":"index","title":"Suite","sub_tracks":[{"position":"B1a","type_":"track","title":"Have A Cigar"},{"position":"B1b","type_":"track","title":"Wish You Were Here"}]}]}""";
        var tracks = DiscogsClient.ParseTracklist(System.Text.Encoding.UTF8.GetBytes(json));
        Check.That(tracks.Select(t => t.Position).SequenceEqual(new[] { "A1", "A2", "B1a", "B1b" }) && tracks[0].Duration == "13:30" && tracks[1].Duration is null,
                   "sanglisten læses: overskrifter springes over, delte numre giver delene");
        Check.That(DiscogsClient.ParseTracklist("{}"u8.ToArray()).Count == 0, "udgivelse uden sangliste giver en tom liste");

        using var s = new ShelfStore(TempDb("tracks"));
        s.ApplyCollection(new[]
        {
            new DiscogsCollectionItem(7_000_001, null, new Release(970_001, "Pink Floyd", "Wish You Were Here", Format: "Vinyl, LP")),
            new DiscogsCollectionItem(7_000_002, null, new Release(970_002, "Pink Floyd", "Animals", Format: "Vinyl, LP")),
            new DiscogsCollectionItem(7_000_003, null, new Release(970_003, "The Beatles", "Help!", Format: "Vinyl, LP")),
        });
        Check.That(s.Db.UserVersion >= 7 && s.TrackProgress() == (0, 3) && s.ReleasesWithoutTracks().SequenceEqual(new[] { 970_001, 970_002, 970_003 }),
                   "ny database har tabellen til sanglister, og intet er hentet endnu");
        s.SaveTracks(970_002, new[] { new Track("A1", "Pigs On The Wing (Part One)"), new Track("B1", "Dogs") });
        s.SaveTracks(970_003, new[] { new Track("A1", "Help!"), new Track("B7", "Yesterday") });
        s.SaveTracks(970_001, Array.Empty<Track>());
        Check.That(s.TrackProgress() == (3, 3) && s.ReleasesWithoutTracks().Count == 0, "hentede (også tomme) lister tælles som hentet");
        var lib = s.LoadLibrary();
        var index = new SearchIndex(lib);
        (string? Title, string? Track) First(string q) => index.Hits(q).FirstOrDefault() is { } h ? (lib.Item(h.Id)?.Title, h.Track?.Title) : (null, null);
        Check.That(First("dogs") == ("Animals", "Dogs"), $"en sang findes, og sangen vises: {First("dogs")}");
        Check.That(First("floyd dogs") == ("Animals", "Dogs"), $"kunstner + sang: {First("floyd dogs")}");
        Check.That(First("yesturday") == ("Help!", "Yesterday"), $"sang med stavefejl: {First("yesturday")}");
        Check.That(First("help") == ("Help!", null), $"pladens egen titel vinder over en sang med samme navn: {First("help")}");
        Check.That(First("wish you were here").Track is null, "pladen selv vises uden sang, når det er albummet");
        Check.That(index.Search("dogs").SequenceEqual(index.Hits("dogs").Select(h => h.Id)), "Search og Hits giver samme plader");

        // Albummer før sange: "blue" giver Joni Mitchell – Blue øverst, derefter Kind Of Blue, og først så sangene.
        using var bs = new ShelfStore(TempDb("tracks-blue"));
        DiscogsCollectionItem Rel(int i, string artist, string title) => new(7_100_000 + i, null, new Release(971_000 + i, artist, title, Format: "Vinyl, LP"));
        bs.ApplyCollection(new[] { Rel(1, "Abba", "Arrival"), Rel(2, "Miles Davis", "Kind Of Blue"), Rel(3, "Joni Mitchell", "Blue"),
                                   Rel(4, "Elvis Presley", "Elvis"), Rel(5, "Bill Evans", "Portrait In Jazz") });
        bs.SaveTracks(971_002, new[] { new Track("A1", "So What"), new Track("B1", "Blue In Green") });
        bs.SaveTracks(971_003, new[] { new Track("A1", "All I Want"), new Track("B1", "Blue") });
        bs.SaveTracks(971_004, new[] { new Track("A1", "Blue Suede Shoes"), new Track("B1", "Blue Moon") });
        bs.SaveTracks(971_005, new[] { new Track("A1", "Blue In Green") });
        var blib = bs.LoadLibrary();
        var blue = new SearchIndex(blib).Hits("blue").Select(h => (blib.Item(h.Id)!.Title, h.Track?.Title)).ToList();
        Check.That(blue.Count >= 4 && blue[0] == ("Blue", null) && blue[1] == ("Kind Of Blue", null) && blue.Skip(2).All(b => b.Item2 is not null),
                   $"albummer før sange, og et album med præcis den titel øverst: {string.Join("; ", blue)}");

        // Søgereglerne (samme checks på Mac): faste tilfælde fra testene af den nye søgning.
        using var rs = new ShelfStore(TempDb("search-rules"));
        DiscogsCollectionItem R2(int i, string artist, string title, string? cat = null, int? year = null) =>
            new(7_200_000 + i, null, new Release(972_000 + i, artist, title, year, CatalogNumber: cat, Format: "Vinyl, LP"));
        rs.ApplyCollection(new[] { R2(1, "The Beatles", "Please Please Me"), R2(2, "The Beatles", "Beatles For Sale"),
                                   R2(3, "Led Zeppelin", "Led Zeppelin II"), R2(4, "AC/DC", "Back In Black", cat: "K 50735"),
                                   R2(5, "Amy Winehouse", "Back To Black"), R2(6, "Prince", "1999", year: 1982),
                                   R2(7, "Bryan Adams", "Reckless", year: 1999), R2(8, "Elvis Costello", "This Year's Model", cat: "RAD 3"),
                                   R2(9, "Radiohead", "OK Computer") });
        rs.SaveTracks(972_007, new[] { new Track("A1", "Summer Of '69") });
        var rlib = rs.LoadLibrary(); var ridx = new SearchIndex(rlib);
        List<string> Top(string q) => ridx.Hits(q).Select(h => rlib.Item(h.Id)!.Title + (h.Track is { } t ? " ♪ " + t.Title : "")).ToList();
        var ruleCases = new (string Q, string[] Want)[]
        {
            ("rad", new[] { "OK Computer" }), ("1999", new[] { "1999" }), ("back i", new[] { "Back In Black" }), ("led zeppelin 2", new[] { "Led Zeppelin II" }),
            ("acdc", new[] { "Back In Black" }), ("okcomputer", new[] { "OK Computer" }), ("k50735", new[] { "Back In Black" }), ("summer of 69", new[] { "Reckless ♪ Summer Of '69" }),
            ("beatles", new[] { "Please Please Me", "Beatles For Sale" }), ("beetles", new[] { "Please Please Me", "Beatles For Sale" }), ("zepelin", new[] { "Led Zeppelin II" }),
        };
        foreach (var (q, want) in ruleCases)
            Check.That(Top(q).Take(want.Length).SequenceEqual(want), $"søgning \"{q}\" giver {string.Join(", ", want)}: {string.Join(", ", Top(q).Take(3))}");
        Check.That(Top("the zzzzzz").Count == 0 && Top("!!!").Count == 0, "en artikel alene (eller tegn) giver ingen resultater");

        // Sanglisten følger med til en anden enhed – og en enhed uden liste sletter den ikke.
        var docs = s.ExportSyncDocs();
        var animals = docs.First(d => d.Kind == SyncKind.Release && d.Key == "970002");
        Check.That((animals.Data?["tracks"] as JsonArray)?.Count == 2, "sanglisten er med i udgivelsens post");
        using var b = new ShelfStore(TempDb("tracks-b"));
        b.ApplySyncDocs(docs);
        Check.That(b.LoadLibrary().Releases[970_002].Tracks.Select(t => t.Title).SequenceEqual(new[] { "Pigs On The Wing (Part One)", "Dogs" }) && b.PendingSyncDocs().Count == 0,
                   "en anden enhed får sanglisten og sender intet tilbage");
        var noTracks = (JsonObject)JsonNode.Parse(animals.Data!.ToJsonString())!;
        noTracks.Remove("tracks"); noTracks["title"] = "Animals (2018 Remix)";
        b.ApplySyncDocs(new List<SyncDoc> { new(SyncKind.Release, "970002", noTracks) });
        var afterOld = b.LoadLibrary().Releases[970_002];
        Check.That(afterOld.Title == "Animals (2018 Remix)" && afterOld.Tracks.Count == 2, "en post uden sangliste (ældre app) sletter ikke listen");
    });

    private static void Docs() => Check.Section("synkronisering (poster)", () =>
    {
        var cloud = new Dictionary<string, SyncDoc>();
        int Push(ShelfStore s)
        {
            var p = s.PendingSyncDocs();
            foreach (var d in p) cloud[d.Id] = d;
            s.MarkSynced(p);
            return p.Count;
        }
        var items = new[] { It(1, "ABBA", "Arrival"), It(2, "Bowie", "Low"), It(3, "Cohen", "Songs") };

        using var a = new ShelfStore(TempDb("sync-a"));
        a.ApplyCollection(items);
        var aIds = new SortRules().Sorted(a.LoadLibrary().AllItems).Select(i => i.Id).ToList();
        a.CreateLayout(new List<(int, string, IReadOnlyList<long>)> { (1, "A", aIds.Take(2).ToList()), (1, "B", aIds.Skip(2).ToList()) });
        a.LogPlay(aIds[0]);
        a.SetSortChecked(Medium.Vinyl, aIds[1], true);
        var r = a.LoadSortRules(); r.ArtistOverrides["Cohen"] = "Cohen, Leonard"; a.SaveSortRules(r);
        int first = Push(a);
        Check.That(first > 0 && a.PendingSyncDocs().Count == 0, "første synkronisering sender alt, derefter intet");

        using var b = new ShelfStore(TempDb("sync-b"));
        b.ApplySyncDocs(cloud.Values.ToList());
        var la = a.LoadLibrary(); var lb = b.LoadLibrary();
        Check.That(Same(Order(lb), Order(la)) && lb.Copies.Count == 3, "ny enhed får samme reoler og rækkefølge");
        Check.That(b.LoadPlays().Count == 1 && b.SortChecked(Medium.Vinyl).Count == 1 && b.LoadSortRules().ArtistOverrides.GetValueOrDefault("Cohen") == "Cohen, Leonard",
                   "afspilning, flueben og sorteringsnavne følger med");
        Check.That(b.PendingSyncDocs().Count == 0, "det hentede sendes ikke tilbage igen");
        Check.That(b.ApplySyncDocs(cloud.Values.ToList()) == 0, "samme poster igen ændrer intet");

        var low = lb.AllItems.First(i => i.Title == "Low").Id;
        b.Move(low, lb.Locations[1].Id, 0);
        var moved = b.PendingSyncDocs();
        Check.That(moved.All(d => d.Kind == SyncKind.Section), "en flytning sendes som sektionernes rækkefølge");
        Push(b);
        a.ApplySyncDocs(cloud.Values.ToList());
        Check.That(Same(Order(a.LoadLibrary()), Order(b.LoadLibrary())), "flytningen er nået frem");

        // QR-koden fra et trykt skilt på A virker også på B, hvor sektionen har et andet nummer.
        var printed = a.LoadLibrary().Locations[1];
        a.SetScanCode(printed.Id, "vinylshelf://section/999");
        Push(a);
        b.ApplySyncDocs(cloud.Values.ToList());
        var lbq = b.LoadLibrary();
        var hit = lbq.LocationForScanCode("vinylshelf://section/999");
        Check.That(hit is not null && hit.Shelf == printed.Shelf && hit.Section == printed.Section
                   && ShelfLabel.Labels(lbq).First(l => l.Location.Id == hit.Id).ScanCode == "vinylshelf://section/999",
                   "QR-koden på et trykt skilt følger sektionen til en anden enhed");

        using var c = new ShelfStore(TempDb("sync-c"));
        c.ApplyCollection(items);
        c.ApplySyncDocs(cloud.Values.ToList());
        Check.That(c.LoadLibrary().Copies.Count == 3 && c.LoadLibrary().Locations.Count == 2, "samme Discogs-plader bliver ikke dobbelte");

        a.Db.Run("DELETE FROM plays");
        Push(a);
        b.ApplySyncDocs(cloud.Values.ToList());
        Check.That(b.LoadPlays().Count == 0, "sletning følger med");

        var local = a.Db.Run("INSERT INTO copies(release_id, status, in_discogs) VALUES(950001, 'home', 0)");
        a.Move(local, a.LoadLibrary().Locations[0].Id, 0);
        Push(a);
        b.ApplySyncDocs(cloud.Values.ToList());
        int bHas = b.LoadLibrary().Copies.Count;
        a.DeleteCopy(local);
        Push(a);
        b.ApplySyncDocs(cloud.Values.ToList());
        var lbAfter = b.LoadLibrary();
        Check.That(bHas == 4 && lbAfter.Copies.Count == 3 && Same(Order(lbAfter), Order(a.LoadLibrary())), "slettet plade forsvinder også på den anden enhed");

        // En afspilning af en plade, som enheden ikke kender, huskes ikke som synkroniseret, så den ikke slettes i skyen.
        b.ApplySyncDocs(new List<SyncDoc> { new(SyncKind.Play, "ukendt-afspilning", new JsonObject { ["copy"] = "findes-ikke", ["at"] = 1.0 }) });
        Check.That(!b.PendingSyncDocs().Any(x => x.Key == "ukendt-afspilning"), "en post, der ikke kunne lægges ind, slettes ikke i skyen");

        // Poster fra Mac (Swift) har samme felter: et eksempel læses korrekt.
        using var d = new ShelfStore(TempDb("sync-mac"));
        var macDocs = new List<SyncDoc>
        {
            new(SyncKind.Release, "777", (JsonObject)JsonNode.Parse("""{"artist":"Kim Larsen","title":"Værsgo","year":1973,"format":"Vinyl, LP","catalog":null,"cover":null,"genres":null,"label":null,"thumb":null}""")!),
            new(SyncKind.Copy, "i2400000777", (JsonObject)JsonNode.Parse("""{"instance":2400000777,"release":777,"status":"home","inDiscogs":true,"rank":3,"medium":null,"note":null,"removedAt":null,"sortArtist":null,"sortTitle":null,"dateAdded":null}""")!),
            new(SyncKind.Location, "loc-1", (JsonObject)JsonNode.Parse("""{"shelf":1,"section":"A","sortIndex":0,"medium":"vinyl"}""")!),
            new(SyncKind.Section, "loc-1", (JsonObject)JsonNode.Parse("""{"copies":["i2400000777"]}""")!),
            new(SyncKind.Play, "p-1", (JsonObject)JsonNode.Parse("""{"copy":"i2400000777","at":1760000000.5}""")!),
        };
        d.ApplySyncDocs(macDocs);
        var ld = d.LoadLibrary();
        Check.That(ld.Copies.Values.Single().InstanceId == 2_400_000_777L && ld.Sections.Values.Single().Count == 1 && d.LoadPlays().Count == 1,
                   "poster fra Mac-appen læses (store tal, reol, afspilning)");
    });

    private static void Cloud() => Check.Section("kontoen i skyen", () =>
    {
        var stub = new StubCloud();
        var cloud = new CloudClient(new Uri("https://stub.supabase.co/"), "sb_publishable_test", new HttpClient(stub));

        Check.That(CloudClient.ParseDate("2026-10-18T15:01:02.123456+00:00") is not null, "serverens tidsstempler læses");
        string? Err(Func<Task> f) { try { f().GetAwaiter().GetResult(); return null; } catch (Exception e) { return e.Message; } }
        Check.That(Err(() => cloud.RequestCodeAsync("test@example.com")) is null, "login-mail sendes");
        Check.That(Err(() => cloud.VerifyAsync("test@example.com", "000000")) == "Koden er forkert eller udløbet. Bed om en ny kode.", "forkert kode giver en dansk besked");
        var session = cloud.VerifyAsync("test@example.com", "123456").GetAwaiter().GetResult();
        Check.That(session.UserId.EndsWith('1') && session.AccessToken == "adgang" && !session.IsExpired, "rigtig kode giver et login");
        Check.That(CloudSession.FromJson(session.ToJson()) == session, "login gemmes og læses (samme JSON som på Mac)");

        DiscogsCollectionItem I(int i, string artist, string title) => new(960_000 + i, null, new Release(960_000 + i, artist, title, Format: "Vinyl, LP"));
        using var pc = new ShelfStore(TempDb("cloud-pc"));
        pc.ApplyCollection(new[] { I(1, "ABBA", "Arrival"), I(2, "Bowie", "Low") });
        pc.CreateLayout(new List<(int, string, IReadOnlyList<long>)> { (1, "A", new SortRules().Sorted(pc.LoadLibrary().AllItems).Select(i => i.Id).ToList()) });
        var up = CloudSync.RunAsync(pc, cloud, session, "windows").GetAwaiter().GetResult();
        Check.That(up.Sent > 0 && stub.Rows.Count > 0, "første synkronisering sender systemet op");
        var again = CloudSync.RunAsync(pc, cloud, session, "windows").GetAwaiter().GetResult();
        Check.That(again == new CloudSyncReport(0, 0), $"intet nyt: intet sendes eller hentes ({again})");

        using var phone = new ShelfStore(TempDb("cloud-phone"));
        var down = CloudSync.RunAsync(phone, cloud, session, "iphone").GetAwaiter().GetResult();
        var pl = phone.LoadLibrary();
        Check.That(down.Received > 0 && pl.Locations.Count == 1 && pl.Sections.Values.First().Count == 2, "en ny enhed henter reolen fra kontoen");

        using var mac = new ShelfStore(TempDb("cloud-mac"));
        mac.ApplyCollection(new[] { I(1, "ABBA", "Arrival"), I(2, "Bowie", "Low") });
        mac.CreateLayout(new List<(int, string, IReadOnlyList<long>)> { (9, "Z", mac.LoadLibrary().AllItems.Select(i => i.Id).ToList()) });
        bool asked = false;
        try { CloudSync.RunAsync(mac, cloud, session, "mac").GetAwaiter().GetResult(); }
        catch (NeedsChoiceException) { asked = true; }
        Check.That(asked, "konto og enhed har hver deres reoler: brugeren spørges");
        int safetyCopies = 0;
        CloudSync.RunAsync(mac, cloud, session, "mac", FirstSync.UseCloud, () => safetyCopies++).GetAwaiter().GetResult();
        var ml = mac.LoadLibrary();
        Check.That(ml.Locations.Count == 1 && ml.Locations[0].Shelf == 1 && ml.Copies.Count == 2, "\"Brug kontoens reoler\" erstatter enhedens reoler, plader bevares");
        Check.That(safetyCopies == 1, "der tages en sikkerhedskopi, før enhedens reoler erstattes");

        // En sektion slettet på pc'en: telefonen tager en sikkerhedskopi, før den slettes der.
        var extra = pc.Db.Run("INSERT INTO locations(shelf, section, sort_index, medium) VALUES(2, 'X', 5, 'vinyl')");
        CloudSync.RunAsync(pc, cloud, session, "windows").GetAwaiter().GetResult();
        CloudSync.RunAsync(phone, cloud, session, "iphone").GetAwaiter().GetResult();
        int phoneHad = phone.LoadLibrary().Locations.Count;
        pc.DeleteEmptySection(extra);
        CloudSync.RunAsync(pc, cloud, session, "windows").GetAwaiter().GetResult();
        int phoneCopies = 0;
        CloudSync.RunAsync(phone, cloud, session, "iphone", safetyCopy: () => phoneCopies++).GetAwaiter().GetResult();
        int phoneNow = phone.LoadLibrary().Locations.Count;
        Check.That(phoneHad == 2 && phoneNow == 1 && phoneCopies == 1, $"slettet sektion: sikkerhedskopi først, så slettes den ({phoneHad}, {phoneCopies})");
        bool failingCopy = false;
        CloudSync.RunAsync(phone, cloud, session, "iphone", safetyCopy: () => failingCopy = true).GetAwaiter().GetResult();
        Check.That(!failingCopy, "ingen sikkerhedskopi, når intet slettes");

        // Login fra linket i mailen og fra en indsat localhost-adresse.
        var claims = Convert.ToBase64String(Encoding.UTF8.GetBytes("""{"sub":"abc-123","email":"a@b.dk","exp":2000000000}"""))
                            .TrimEnd('=').Replace('+', '-').Replace('/', '_');
        var link = CloudClient.SessionFromLink($"vinylshelf://auth#access_token=x.{claims}.y&refresh_token=r1&expires_in=3600&expires_at=1999999999&type=magiclink");
        Check.That(link?.UserId == "abc-123" && link.Email == "a@b.dk" && link.RefreshToken == "r1" && link.ExpiresAt == 1999999999, "login fra linket i mailen");
        Check.That(CloudClient.SessionFromLink("vinylshelf://section/4") is null && CloudClient.SessionFromLink("https://example.com/side") is null,
                   "QR-adresser og almindelige webadresser er ikke et login");
        Check.That(CloudClient.SessionFromLink($"http://localhost:3000/#access_token=x.{claims}.y&refresh_token=r2&type=signup")?.RefreshToken == "r2",
                   "en indsat localhost-adresse fra browseren virker også");
        string? linkError = null;
        try { CloudClient.SessionFromLink("vinylshelf://auth#error=access_denied&error_code=otp_expired&error_description=Email+link+is+invalid+or+has+expired"); }
        catch (CloudException e) { linkError = e.Message; }
        Check.That(linkError == "Linket er brugt eller udløbet. Bed om en ny mail.", "udløbet link giver en dansk besked");

        // Linket fra mailen, kopieret og indsat i appen: appen bytter det selv for et login.
        var mailLink = "https://stub.supabase.co/auth/v1/verify?token=pkce_hash1&type=magiclink&redirect_to=vinylshelf://auth";
        Check.That(CloudClient.EmailLinkToken(mailLink) == ("pkce_hash1", "magiclink") && CloudClient.EmailLinkToken("https://example.com/") is null,
                   "linket fra mailen genkendes");
        Check.That(cloud.VerifyEmailLinkAsync(mailLink).GetAwaiter().GetResult()?.AccessToken == "adgang", "indsat link fra mailen giver et login");
        string usedError = "";
        try { cloud.VerifyEmailLinkAsync(mailLink.Replace("pkce_hash1", "brugt")).GetAwaiter().GetResult(); }
        catch (CloudException e) { usedError = e.Message; }
        Check.That(usedError == CloudClient.UsedLink, "brugt link fra mailen siger, at linket er brugt (ikke koden)");

        // Adgangskode: vælges, mens man er logget ind, og bruges til at logge ind på en ny enhed uden mail.
        Check.That(Err(() => cloud.SetPasswordAsync("hemmelig-kode", session)) is null, "adgangskode kan vælges");
        Check.That(Err(() => cloud.SetPasswordAsync("kort", session)) == CloudClient.ShortPassword, "for kort adgangskode afvises på dansk");
        var viaPassword = cloud.SignInAsync("test@example.com", "hemmelig-kode").GetAwaiter().GetResult();
        Check.That(viaPassword.AccessToken == "adgang" && viaPassword.Email == "test@example.com", "login med e-mail og adgangskode");
        Check.That(Err(() => cloud.SignInAsync("test@example.com", "forkert-kode")) == CloudClient.WrongPassword, "forkert adgangskode giver en dansk besked");

        bool needsLogin = false;
        try { cloud.FetchAsync(null, session with { AccessToken = "forkert" }).GetAwaiter().GetResult(); }
        catch (CloudException e) { needsLogin = e.NeedsLogin; }
        Check.That(needsLogin, "afvist login: brugeren bedes logge ind igen");
    });
}
