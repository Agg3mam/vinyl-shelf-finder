using System.Globalization;
using System.Text;

namespace VinylShelfFinder.Core;

// Port af Sources/VinylCore/MobileSite.swift.

/// Den mobilvenlige side, som appen kan servere på det lokale netværk (fx telefonens hotspot).
/// Kun HTML og routing – selve netværksdelen ligger i appen. Siden er læsbar; den eneste
/// ændring, man kan lave herfra, er at registrere en plade som spillet.
public static class MobileSite
{
    public const ushort DefaultPort = 8765;

    // MARK: HTTP

    public sealed record Request(string Method, string Path, IReadOnlyDictionary<string, string> Query)
    {
        public Request(string method, string path) : this(method, path, new Dictionary<string, string>()) { }

        public bool Equals(Request? o) => o is not null && Method == o.Method && Path == o.Path
            && Query.Count == o.Query.Count && Query.All(kv => o.Query.TryGetValue(kv.Key, out var v) && v == kv.Value);
        public override int GetHashCode() => HashCode.Combine(Method, Path, Query.Count);

        private static readonly UTF8Encoding StrictUtf8 = new(false, true);

        /// Læser request-linjen ("GET /section/3?x=1 HTTP/1.1"). Headers og body ignoreres.
        public static Request? Parse(byte[] data)
        {
            // Kun request-linjen afkodes. Ellers kan et UTF-8-tegn, der klippes over ved
            // 8192 bytes (eller ugyldige bytes i en header), få hele requesten afvist.
            int headLen = Math.Min(data.Length, 8192);
            int nl = Array.IndexOf(data, (byte)0x0A, 0, headLen);
            int lineLen = nl >= 0 ? nl : headLen;
            string text;
            try { text = StrictUtf8.GetString(data, 0, lineLen); }
            catch (ArgumentException) { return null; }
            var line = text.EndsWith('\r') ? text[..^1] : text;
            var parts = line.Split(' ', StringSplitOptions.RemoveEmptyEntries);
            if (parts.Length < 2) return null;
            var target = parts[1];
            if (target.Any(c => c <= ' ' || c == '"' || c == '<' || c == '>' || c == '\\' || c == '^' || c == '`' || c == '{' || c == '|' || c == '}')) return null;
            int hash = target.IndexOf('#');
            if (hash >= 0) target = target[..hash];
            int q = target.IndexOf('?');
            var rawPath = q >= 0 ? target[..q] : target;
            var rawQuery = q >= 0 ? target[(q + 1)..] : null;
            // Formularer koder mellemrum som "+" og et rigtigt plus som "%2B". "+" skal derfor
            // erstattes FØR procent-afkodningen, ellers bliver "AC%2BDC" til "AC DC".
            static string Decode(string s) => Uri.UnescapeDataString(s.Replace('+', ' '));
            var query = new Dictionary<string, string>();
            if (!string.IsNullOrEmpty(rawQuery))
            {
                foreach (var item in rawQuery.Split('&'))
                {
                    int eq = item.IndexOf('=');
                    var name = eq >= 0 ? item[..eq] : item;
                    var value = eq >= 0 ? item[(eq + 1)..] : "";
                    query[Decode(name)] = Decode(value);
                }
            }
            var path = Uri.UnescapeDataString(rawPath);
            return new Request(parts[0].ToUpperInvariant(), path.Length == 0 ? "/" : path, query);
        }
    }

    public abstract record Reply
    {
        public sealed record Html(string Content) : Reply;
        public sealed record Redirect(string Location) : Reply;
        /// Registrér pladen som spillet, og send derefter browseren videre.
        public sealed record LogPlay(long CopyId, string Then) : Reply;
        /// Coverbillede for en release (stort eller lille).
        public sealed record Cover(int ReleaseId, bool Large) : Reply;
        public sealed record NotFound : Reply;
    }

    public static byte[] Response(int status, string contentType, byte[] body, IReadOnlyDictionary<string, string>? extraHeaders = null)
    {
        var reason = status switch { 200 => "OK", 303 => "See Other", 302 => "Found", 404 => "Not Found", 405 => "Method Not Allowed", _ => "OK" };
        var head = new StringBuilder($"HTTP/1.1 {status} {reason}\r\nContent-Type: {contentType}\r\nContent-Length: {body.Length}\r\nConnection: close\r\nCache-Control: no-store\r\n");
        foreach (var (k, v) in (extraHeaders ?? new Dictionary<string, string>()).OrderBy(kv => kv.Key, StringComparer.Ordinal))
            head.Append($"{k}: {v}\r\n");
        head.Append("\r\n");
        return Encoding.UTF8.GetBytes(head.ToString()).Concat(body).ToArray();
    }

    // MARK: Routing

    public static Reply Route(Request req, Library library, ListeningStats stats, DateTimeOffset? now = null)
    {
        var parts = req.Path.Split('/', StringSplitOptions.RemoveEmptyEntries);
        var first = parts.FirstOrDefault();
        static long? ParseLong(string s) => long.TryParse(s, NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture, out var v) ? v : null;
        switch (req.Method, parts.Length, first)
        {
            case ("GET", 0, _):
                return new Reply.Html(HomePage(library, req.Query.GetValueOrDefault("q") ?? ""));
            case ("GET", 2, "section"):
            {
                if (ParseLong(parts[1]) is not long id || library.LocationById(id) is not Location loc) return new Reply.NotFound();
                return new Reply.Html(SectionPage(library, loc, req.Query.GetValueOrDefault("mark") is string m ? ParseLong(m) : null));
            }
            case ("GET", 2, "record"):
            {
                if (ParseLong(parts[1]) is not long id || library.Item(id) is null) return new Reply.NotFound();
                return new Reply.Html(RecordPage(library, id, stats, req.Query.GetValueOrDefault("played") == "1", now ?? DateTimeOffset.Now));
            }
            case ("POST", 3, "record") when parts[2] == "play":
            {
                if (ParseLong(parts[1]) is not long id || library.Item(id) is null) return new Reply.NotFound();
                return new Reply.LogPlay(id, $"/record/{id}?played=1");
            }
            case ("GET", 2, "cover"):
            {
                if (!int.TryParse(parts[1], NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture, out var id) || !library.Releases.ContainsKey(id))
                    return new Reply.NotFound();
                return new Reply.Cover(id, req.Query.GetValueOrDefault("s") == "l");
            }
            default:
                return new Reply.NotFound();
        }
    }

    // MARK: Sider

    internal static string HomePage(Library library, string query)
    {
        var q = TextFold.TrimSpaces(query);
        var body = new StringBuilder(SearchForm(q, autofocus: q.Length == 0));
        if (q.Length == 0)
        {
            // Samme tal og kunstnere som på reolskiltene: kun plader, der står i reolen.
            var labels = ShelfLabel.Labels(library);
            foreach (var shelf in library.Shelves)
            {
                body.Append($"<h2 class=\"kicker\">Reol {shelf}</h2><ul class=\"list\">");
                foreach (var label in labels.Where(l => l.Location.Shelf == shelf))
                {
                    var loc = label.Location;
                    string range;
                    if (label.FirstArtist is string f && label.LastArtist is string l)
                        range = $"{Esc(f)} → {Esc(l)}";
                    else
                        range = library.Sections.TryGetValue(loc.Id, out var ids) && ids.Count > 0 ? "(alle plader er ude)" : "(tom sektion)";
                    body.Append($"<li><a class=\"row\" href=\"/section/{loc.Id}\"><span class=\"badge\">{Esc(loc.Section)}</span>"
                              + $"<span class=\"grow\"><span class=\"t\">{range}</span><span class=\"sub\">{Plural(label.Count, "plade", "plader")}</span></span>"
                              + "<span class=\"chev\">›</span></a></li>");
                }
                body.Append("</ul>");
            }
            if (library.Locations.Count == 0) body.Append("<p class=\"muted\">Der er endnu ingen reoler. Opret dem i appen på pc'en.</p>");
        }
        else
        {
            var hits = new SearchIndex(library).Search(q, 40).Select(library.Item).OfType<RecordItem>().ToList();
            if (hits.Count == 0)
            {
                body.Append($"<p class=\"muted\">Ingen plader matcher “{Esc(q)}”.</p>");
            }
            else
            {
                body.Append("<ul class=\"list\">");
                foreach (var it in hits) body.Append(RecordRow(it, library));
                body.Append("</ul>");
            }
        }
        return Page("Vinyl Shelf Finder", body.ToString(), home: true);
    }

    internal static string RecordPage(Library library, long copyId, ListeningStats stats, bool justPlayed, DateTimeOffset now)
    {
        var it = library.Item(copyId)!;
        var body = new StringBuilder();
        body.Append($"<div class=\"hero\"><img class=\"cover big\" src=\"/cover/{it.Release.Id}?s=l\" alt=\"\"></div>\n"
                  + $"<p class=\"artist\">{Esc(it.Artist)}</p>\n"
                  + $"<h1 class=\"title\">{Esc(it.Title)}</h1>\n"
                  + $"<p class=\"sub\">{Esc(it.DetailLine)}</p>");
        // Er pladen ude af reolen (fx på væggen), viser siden, hvor den skal sættes tilbage.
        bool away = !it.Copy.Status.IsOnShelf();
        if (away)
        {
            var note = it.Copy.StatusNote is string n ? $" ({Esc(n)})" : "";
            body.Append($"<p class=\"warn\">Pladen er markeret som “{Esc(it.Copy.Status.Label())}”{note} og står ikke i reolen.</p>");
        }
        if (library.LocationOf(copyId) is Location loc && library.NeighborsOf(copyId) is Neighbors nb
            && (away ? library.ReturnAdviceFor(copyId) : library.ReferenceAdviceFor(copyId)) is ReferenceAdvice adv
            && nb.Position is int pos)
        {
            // Fysiske tal: kun plader i reolen (plus denne) tælles med.
            double pct = nb.SectionCount > 1 ? (double)(pos - 1) / (nb.SectionCount - 1) * 100 : 0;
            body.Append($"<a class=\"place\" href=\"/section/{loc.Id}?mark={copyId}#c{copyId}\">\n"
                      + $"<span class=\"kicker\">{(away ? "Hører til" : "Gå til")}</span>\n"
                      + $"<span class=\"where\">Reol {loc.Shelf} <span class=\"sep\">▸</span> Sektion {Esc(loc.Section)}</span>\n"
                      + $"<span class=\"bar\"><span class=\"dot\" style=\"left:{pct.ToString("F1", CultureInfo.InvariantCulture)}%\"></span></span>\n"
                      + $"<span class=\"sub\">{Esc(adv.PlacementHint)}</span>\n"
                      + "</a>");
            body.Append(ReferenceBlock(away ? "Sæt tilbage" : "Find først", adv.Primary));
            if (adv.Secondary is Reference s) body.Append(ReferenceBlock(away ? "Tjek også" : "Dernæst", s));
            foreach (var note in new[] { adv.ArtistBlockHint, adv.SectionEdgeHint }.OfType<string>())
                body.Append($"<p class=\"note\">{Esc(note)}</p>");
        }
        else
        {
            body.Append("<p class=\"note\">Pladen har endnu ingen fysisk placering.</p>");
        }

        int count = stats.Count.GetValueOrDefault(copyId);
        var playedLine = count == 0 ? "Aldrig spillet"
            : $"Spillet {Plural(count, "gang", "gange")} · senest {Relative(stats.LastPlayed[copyId], now)}";
        if (justPlayed)
            body.Append("<p class=\"done\">✓ Registreret som spillet</p>");
        else
            body.Append($"<form method=\"post\" action=\"/record/{copyId}/play\"><button class=\"play\">Spillet</button></form>");
        body.Append($"<p class=\"sub center\">{playedLine}</p>");
        return Page(it.FullName, body.ToString());
    }

    internal static string SectionPage(Library library, Location loc, long? mark)
    {
        var items = library.ItemsIn(loc.Id);
        // Kun plader, der står i reolen, får et nummer. Plader, der er ude, vises nedtonede
        // uden nummer og med deres status – så numrene passer med det, man ser i reolen.
        var numbers = library.ShelfNumbers(loc.Id);
        int awayCount = items.Count - numbers.Count;
        int idx = library.Locations.ToList().IndexOf(loc);
        var prev = idx > 0 ? library.Locations[idx - 1] : null;
        var next = idx + 1 < library.Locations.Count ? library.Locations[idx + 1] : null;
        static string Nav(Location? l, string label) => l is null
            ? $"<span class=\"navbtn off\">{label}</span>"
            : $"<a class=\"navbtn\" href=\"/section/{l.Id}\">{label.Replace("·", Esc(l.ShortName))}</a>";
        var body = new StringBuilder();
        body.Append("<p class=\"kicker\">Jeg står her</p>\n"
                  + $"<h1 class=\"title\">Reol {loc.Shelf} · Sektion {Esc(loc.Section)}</h1>\n"
                  + $"<div class=\"secnav\"><span class=\"sub\">{Plural(numbers.Count, "plade", "plader")}{(awayCount > 0 ? $" (+{awayCount} ude)" : "")} · venstre mod højre</span>"
                  + $"<span>{Nav(prev, "‹ ·")} {Nav(next, "· ›")}</span></div>\n"
                  + "<ol class=\"list\">");
        foreach (var it in items)
        {
            int? number = numbers.TryGetValue(it.Id, out var nr) ? nr : null;
            var cls = number is null ? "away" : "";
            if (it.Id == mark) cls += " mark";
            body.Append($"<li id=\"c{it.Id}\" class=\"{cls}\"><a class=\"row\" href=\"/record/{it.Id}\"><span class=\"num\">{number?.ToString(CultureInfo.InvariantCulture) ?? ""}</span>"
                      + $"<img class=\"cover\" loading=\"lazy\" src=\"/cover/{it.Release.Id}\" alt=\"\">"
                      + $"<span class=\"grow\"><span class=\"a\">{Esc(it.Artist)}</span><span class=\"t\">{Esc(it.Title)}</span>"
                      + $"{(number is null ? $"<span class=\"sub\">{Esc(it.Copy.Status.Label())}</span>" : "")}</span></a></li>");
        }
        body.Append("</ol>");
        if (items.Count == 0) body.Append("<p class=\"muted\">Sektionen er tom.</p>");
        return Page($"Sektion {loc.ShortName}", body.ToString());
    }

    // MARK: Byggeklodser

    internal static string RecordRow(RecordItem it, Library library)
    {
        // Fysisk nummer for plader i reolen; en plade, der er ude, har intet nummer lige nu.
        string place;
        if (library.LocationOf(it.Id) is not Location loc) place = "Ingen placering";
        else if (!library.ShelfNumbers(loc.Id).TryGetValue(it.Id, out var nr)) place = Esc(loc.ShortName);
        else place = $"{Esc(loc.ShortName)} · plads {nr}";
        var status = it.Copy.Status.IsOnShelf() ? "" : $" · {Esc(it.Copy.Status.Label().ToLowerInvariant())}";
        return $"<li><a class=\"row\" href=\"/record/{it.Id}\"><img class=\"cover\" loading=\"lazy\" src=\"/cover/{it.Release.Id}\" alt=\"\">"
             + $"<span class=\"grow\"><span class=\"a\">{Esc(it.Artist)}</span><span class=\"t\">{Esc(it.Title)}</span>"
             + $"<span class=\"loc\">{place}{status}</span></span><span class=\"chev\">›</span></a></li>";
    }

    internal static string ReferenceBlock(string heading, Reference r)
    {
        var arrow = r.Side is ReferenceSide.Before or ReferenceSide.SectionStart ? "←" : "→";
        string what;
        if (r.Item is RecordItem it)
        {
            what = $"<a class=\"row\" href=\"/record/{it.Id}\"><img class=\"cover\" src=\"/cover/{it.Release.Id}\" alt=\"\">"
                 + $"<span class=\"grow\"><span class=\"a\">{Esc(it.Artist)}</span><span class=\"t\">{Esc(it.Title)}</span></span></a>";
        }
        else
        {
            what = $"<div class=\"row\"><span class=\"t\">{(r.Side == ReferenceSide.SectionStart ? "Sektionens venstre kant" : "Sektionens højre kant")}</span></div>";
        }
        return $"<section class=\"ref\"><p class=\"kicker\"><span class=\"arrow\">{arrow}</span> {Esc(heading)}</p>{what}"
             + $"<p class=\"sub\">{Esc(r.Reason)}</p></section>";
    }

    internal static string SearchForm(string q, bool autofocus) =>
        $"<form class=\"search\" action=\"/\" method=\"get\"><input type=\"search\" name=\"q\" value=\"{Esc(q)}\" "
        + $"placeholder=\"Søg i reolen…\" autocomplete=\"off\" autocorrect=\"off\" autocapitalize=\"off\" enterkeyhint=\"search\"{(autofocus ? " autofocus" : "")}></form>";

    internal static string Page(string title, string body, bool home = false)
    {
        var header = home
            ? "<header><span class=\"brand\">Vinyl Shelf Finder</span></header>"
            : "<header><a class=\"back\" href=\"/\">‹ Søg</a><span class=\"brand\">Vinyl Shelf Finder</span></header>";
        return "<!doctype html><html lang=\"da\"><head><meta charset=\"utf-8\">\n"
             + "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1, viewport-fit=cover\">\n"
             + "<meta name=\"theme-color\" content=\"#f5eee1\" media=\"(prefers-color-scheme: light)\">\n"
             + "<meta name=\"theme-color\" content=\"#1c1712\" media=\"(prefers-color-scheme: dark)\">\n"
             + $"<title>{Esc(title)}</title><style>{Css}</style></head>\n"
             + $"<body>{header}<main>{body}</main></body></html>";
    }

    internal const string Css = """
    :root{--bg:#f5eee1;--card:#fbf7ef;--ink:#2a2118;--muted:#7a6a58;--line:#e3d7c3;--accent:#b8691b;--accent-ink:#fff;--mark:#f3dfbf;
    --serif:ui-serif,"New York",Georgia,serif;--sans:-apple-system,system-ui,sans-serif}
    @media (prefers-color-scheme:dark){:root{--bg:#1c1712;--card:#262019;--ink:#f1e7d8;--muted:#a8977f;--line:#3a3128;--accent:#e0923f;--accent-ink:#1c1712;--mark:#3d2e1d}}
    *{box-sizing:border-box}
    body{margin:0;background:var(--bg);color:var(--ink);font:17px/1.4 var(--sans);-webkit-text-size-adjust:100%}
    header{display:flex;align-items:center;gap:12px;padding:calc(env(safe-area-inset-top) + 12px) 16px 10px;border-bottom:1px solid var(--line)}
    .brand{font:600 12px var(--sans);letter-spacing:.14em;text-transform:uppercase;color:var(--muted);margin-left:auto}
    header .brand:first-child{margin:0 auto}
    .back{color:var(--accent);text-decoration:none;font-weight:600}
    main{max-width:560px;margin:0 auto;padding:16px 16px calc(env(safe-area-inset-bottom) + 32px)}
    a{color:inherit}
    .kicker{font:700 12px var(--sans);letter-spacing:.14em;text-transform:uppercase;color:var(--muted);margin:20px 0 6px}
    .title{font:700 28px/1.15 var(--serif);margin:2px 0 4px}
    .artist{font:20px var(--serif);margin:14px 0 0;color:var(--muted)}
    .sub{display:block;font-size:14px;color:var(--muted);margin:2px 0}
    .muted{color:var(--muted)} .center{text-align:center}
    .search input{width:100%;font:17px var(--sans);padding:12px 14px;border:1px solid var(--line);border-radius:12px;background:var(--card);color:var(--ink);-webkit-appearance:none}
    .search input:focus{outline:2px solid var(--accent);outline-offset:-1px}
    .list{list-style:none;margin:8px 0 0;padding:0}
    .list li{border-bottom:1px solid var(--line)}
    .row{display:flex;align-items:center;gap:12px;padding:10px 0;text-decoration:none;min-height:56px}
    .grow{flex:1;min-width:0}
    .a,.t{display:block;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
    .a{font-size:14px;color:var(--muted)} .t{font:600 17px var(--serif)}
    .loc{display:block;font-size:13px;color:var(--accent);font-weight:600;margin-top:2px}
    .chev{color:var(--muted);font-size:22px}
    .badge{display:inline-grid;place-items:center;width:36px;height:36px;border-radius:8px;background:var(--card);border:1px solid var(--line);font:700 17px var(--serif);color:var(--accent)}
    .cover{width:48px;height:48px;border-radius:4px;object-fit:cover;background:var(--line);flex:none}
    .cover.big{width:min(72vw,300px);height:min(72vw,300px);border-radius:6px;box-shadow:0 6px 20px rgba(60,40,20,.18)}
    .hero{text-align:center;margin-top:8px}
    .place{display:block;text-decoration:none;background:var(--card);border:1px solid var(--line);border-left:4px solid var(--accent);border-radius:10px;padding:12px 14px;margin:18px 0 6px}
    .place .kicker{margin:0 0 2px}
    .where{display:block;font:700 26px/1.2 var(--serif)}
    .sep{color:var(--accent)}
    .bar{display:block;position:relative;height:6px;border-radius:3px;background:var(--line);margin:12px 6px 8px}
    .dot{position:absolute;top:50%;width:14px;height:14px;margin:-7px 0 0 -7px;border-radius:50%;background:var(--accent)}
    .ref{margin-top:4px} .ref .row{padding:6px 0}
    .arrow{color:var(--accent);font-size:16px}
    .note{font-size:15px;color:var(--muted);border-top:1px solid var(--line);padding-top:10px}
    .warn{color:var(--accent);font-weight:600}
    .play{display:block;width:100%;margin:24px 0 6px;padding:15px;border:0;border-radius:12px;background:var(--accent);color:var(--accent-ink);font:600 18px var(--sans)}
    .play:active{opacity:.8}
    .done{text-align:center;font-weight:600;color:var(--accent);margin:24px 0 6px;padding:14px;border:1px solid var(--accent);border-radius:12px}
    .secnav{display:flex;justify-content:space-between;align-items:center;gap:8px}
    .navbtn{display:inline-block;padding:6px 10px;border:1px solid var(--line);border-radius:8px;text-decoration:none;font-weight:600;color:var(--accent);background:var(--card)}
    .navbtn.off{color:var(--line)}
    .num{width:26px;text-align:right;font:600 14px var(--sans);color:var(--muted);flex:none}
    li.away{opacity:.5} li.mark{background:var(--mark);border-radius:8px}
""";

    // MARK: Hjælpere

    internal static string Esc(string s)
    {
        var sb = new StringBuilder(s.Length);
        foreach (var c in s)
        {
            switch (c)
            {
                case '&': sb.Append("&amp;"); break;
                case '<': sb.Append("&lt;"); break;
                case '>': sb.Append("&gt;"); break;
                case '"': sb.Append("&quot;"); break;
                case '\'': sb.Append("&#39;"); break;
                default: sb.Append(c); break;
            }
        }
        return sb.ToString();
    }

    internal static string Plural(int n, string one, string many) => $"{n} {(n == 1 ? one : many)}";

    internal static string Relative(DateTimeOffset date, DateTimeOffset now)
    {
        int days = (int)((now - date).TotalSeconds / 86400);
        if (days < 1) return "i dag";
        if (days == 1) return "i går";
        if (days < 31) return $"for {days} dage siden";
        if (days < 365) return $"for {days / 30} md. siden";
        return $"for {Plural(days / 365, "år", "år")} siden";
    }
}
