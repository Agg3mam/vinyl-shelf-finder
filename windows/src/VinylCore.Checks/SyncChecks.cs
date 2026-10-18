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
                case ("POST", "/auth/v1/token"): output = session; break;
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
        Cloud();
        foreach (var d in Dirs) { try { Directory.Delete(d, true); } catch { } }
    }

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
        CloudSync.RunAsync(mac, cloud, session, "mac", FirstSync.UseCloud).GetAwaiter().GetResult();
        var ml = mac.LoadLibrary();
        Check.That(ml.Locations.Count == 1 && ml.Locations[0].Shelf == 1 && ml.Copies.Count == 2, "\"Brug kontoens reoler\" erstatter enhedens reoler, plader bevares");

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

        bool needsLogin = false;
        try { cloud.FetchAsync(null, session with { AccessToken = "forkert" }).GetAwaiter().GetResult(); }
        catch (CloudException e) { needsLogin = e.NeedsLogin; }
        Check.That(needsLogin, "afvist login: brugeren bedes logge ind igen");
    });
}
