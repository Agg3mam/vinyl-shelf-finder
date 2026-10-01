import Foundation

/// Den mobilvenlige side, som Mac-appen serverer på det lokale netværk (fx iPhonens hotspot).
/// Kun HTML og routing – selve netværksdelen ligger i appen. Siden er læsbar; den eneste
/// ændring, man kan lave herfra, er at registrere en plade som spillet.
public enum MobileSite {
    public static let defaultPort: UInt16 = 8765

    // MARK: - HTTP

    public struct Request: Equatable {
        public let method: String
        public let path: String
        public let query: [String: String]

        public init(method: String, path: String, query: [String: String] = [:]) {
            self.method = method; self.path = path; self.query = query
        }

        /// Læser request-linjen ("GET /section/3?x=1 HTTP/1.1"). Headers og body ignoreres.
        public static func parse(_ data: Data) -> Request? {
            // Kun request-linjen afkodes. Ellers kan et UTF-8-tegn, der klippes over ved
            // 8192 bytes (eller ugyldige bytes i en header), få hele requesten afvist.
            let head = data.prefix(8192)
            let lineBytes = head.firstIndex(of: 0x0A).map { head[head.startIndex..<$0] } ?? head
            guard let text = String(data: lineBytes, encoding: .utf8) else { return nil }
            let line = text.hasSuffix("\r") ? String(text.dropLast()) : text
            let parts = line.split(separator: " ")
            guard parts.count >= 2, let comps = URLComponents(string: String(parts[1])) else { return nil }
            // Formularer koder mellemrum som "+" og et rigtigt plus som "%2B". "+" skal derfor
            // erstattes FØR procent-afkodningen, ellers bliver "AC%2BDC" til "AC DC".
            func decode(_ s: String) -> String {
                let spaced = s.replacingOccurrences(of: "+", with: " ")
                return spaced.removingPercentEncoding ?? spaced
            }
            var query: [String: String] = [:]
            for item in comps.percentEncodedQueryItems ?? [] {
                query[decode(item.name)] = decode(item.value ?? "")
            }
            return Request(method: String(parts[0]).uppercased(), path: comps.path.isEmpty ? "/" : comps.path, query: query)
        }
    }

    public enum Reply: Equatable {
        case html(String)
        case redirect(String)
        /// Registrér pladen som spillet, og send derefter browseren videre.
        case logPlay(copyID: Int64, then: String)
        /// Coverbillede for en release (stort eller lille).
        case cover(releaseID: Int, large: Bool)
        case notFound
    }

    public static func response(status: Int, contentType: String, body: Data, extraHeaders: [String: String] = [:]) -> Data {
        let reason = [200: "OK", 303: "See Other", 302: "Found", 404: "Not Found", 405: "Method Not Allowed"][status] ?? "OK"
        var head = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\nConnection: close\r\nCache-Control: no-store\r\n"
        for (k, v) in extraHeaders.sorted(by: { $0.key < $1.key }) { head += "\(k): \(v)\r\n" }
        return Data((head + "\r\n").utf8) + body
    }

    // MARK: - Routing

    public static func route(_ req: Request, library: Library, stats: ListeningStats, now: Date = Date()) -> Reply {
        let parts = req.path.split(separator: "/").map(String.init)
        switch (req.method, parts.count, parts.first) {
        case ("GET", 0, _):
            return .html(homePage(library: library, query: req.query["q"] ?? ""))
        case ("GET", 2, "section"):
            guard let id = Int64(parts[1]), let loc = library.location(id) else { return .notFound }
            return .html(sectionPage(library: library, location: loc, mark: req.query["mark"].flatMap(Int64.init)))
        case ("GET", 2, "record"):
            guard let id = Int64(parts[1]), library.item(id) != nil else { return .notFound }
            return .html(recordPage(library: library, copyID: id, stats: stats, justPlayed: req.query["played"] == "1", now: now))
        case ("POST", 3, "record") where parts[2] == "play":
            guard let id = Int64(parts[1]), library.item(id) != nil else { return .notFound }
            return .logPlay(copyID: id, then: "/record/\(id)?played=1")
        case ("GET", 2, "cover"):
            guard let id = Int(parts[1]), library.releases[id] != nil else { return .notFound }
            return .cover(releaseID: id, large: req.query["s"] == "l")
        default:
            return .notFound
        }
    }

    // MARK: - Sider

    static func homePage(library: Library, query: String) -> String {
        let q = query.trimmingCharacters(in: .whitespaces)
        var body = searchForm(q, autofocus: q.isEmpty)
        if q.isEmpty {
            // Samme tal og kunstnere som på reolskiltene: kun plader, der står i reolen.
            let labels = ShelfLabel.labels(for: library)
            for shelf in library.shelves {
                body += "<h2 class=\"kicker\">Reol \(shelf)</h2><ul class=\"list\">"
                for label in labels where label.location.shelf == shelf {
                    let loc = label.location
                    let range: String
                    if let first = label.firstArtist, let last = label.lastArtist {
                        range = "\(esc(first)) → \(esc(last))"
                    } else {
                        range = (library.sections[loc.id] ?? []).isEmpty ? "(tom sektion)" : "(alle plader er ude)"
                    }
                    body += """
                    <li><a class="row" href="/section/\(loc.id)"><span class="badge">\(esc(loc.section))</span>\
                    <span class="grow"><span class="t">\(range)</span><span class="sub">\(plural(label.count, "plade", "plader"))</span></span>\
                    <span class="chev">›</span></a></li>
                    """
                }
                body += "</ul>"
            }
            if library.locations.isEmpty { body += "<p class=\"muted\">Der er endnu ingen reoler. Opret dem i appen på Mac'en.</p>" }
        } else {
            let hits = SearchIndex(library: library).search(q, limit: 40).compactMap(library.item)
            if hits.isEmpty {
                body += "<p class=\"muted\">Ingen plader matcher “\(esc(q))”.</p>"
            } else {
                body += "<ul class=\"list\">"
                for it in hits { body += recordRow(it, library: library) }
                body += "</ul>"
            }
        }
        return page(title: "Vinyl Shelf Finder", body: body, home: true)
    }

    static func recordPage(library: Library, copyID: Int64, stats: ListeningStats, justPlayed: Bool, now: Date) -> String {
        let it = library.item(copyID)!
        var body = """
        <div class="hero"><img class="cover big" src="/cover/\(it.release.id)?s=l" alt=""></div>
        <p class="artist">\(esc(it.artist))</p>
        <h1 class="title">\(esc(it.title))</h1>
        <p class="sub">\(esc(it.detailLine))</p>
        """
        // Er pladen ude af reolen (fx på væggen), viser siden, hvor den skal sættes tilbage.
        let away = !it.copy.status.isOnShelf
        if away {
            body += "<p class=\"warn\">Pladen er markeret som “\(esc(it.copy.status.label))”\(it.copy.statusNote.map { " (\(esc($0)))" } ?? "") og står ikke i reolen.</p>"
        }
        if let loc = library.location(of: copyID), let n = library.neighbors(of: copyID),
           let adv = away ? library.returnAdvice(for: copyID) : library.referenceAdvice(for: copyID),
           let pos = n.position {
            // Fysiske tal: kun plader i reolen (plus denne) tælles med.
            let pct = n.sectionCount > 1 ? Double(pos - 1) / Double(n.sectionCount - 1) * 100 : 0
            body += """
            <a class="place" href="/section/\(loc.id)?mark=\(copyID)#c\(copyID)">
            <span class="kicker">\(away ? "Hører til" : "Gå til")</span>
            <span class="where">Reol \(loc.shelf) <span class="sep">▸</span> Sektion \(esc(loc.section))</span>
            <span class="bar"><span class="dot" style="left:\(String(format: "%.1f", pct))%"></span></span>
            <span class="sub">\(esc(adv.placementHint))</span>
            </a>
            """
            body += referenceBlock(away ? "Sæt tilbage" : "Find først", adv.primary)
            if let s = adv.secondary { body += referenceBlock(away ? "Tjek også" : "Dernæst", s) }
            for note in [adv.artistBlockHint, adv.sectionEdgeHint].compactMap({ $0 }) {
                body += "<p class=\"note\">\(esc(note))</p>"
            }
        } else {
            body += "<p class=\"note\">Pladen har endnu ingen fysisk placering.</p>"
        }

        let count = stats.count[copyID] ?? 0
        let playedLine = count == 0 ? "Aldrig spillet"
            : "Spillet \(plural(count, "gang", "gange")) · senest \(relative(stats.lastPlayed[copyID]!, now: now))"
        if justPlayed {
            body += "<p class=\"done\">✓ Registreret som spillet</p>"
        } else {
            body += "<form method=\"post\" action=\"/record/\(copyID)/play\"><button class=\"play\">Spillet</button></form>"
        }
        body += "<p class=\"sub center\">\(playedLine)</p>"
        return page(title: it.fullName, body: body)
    }

    static func sectionPage(library: Library, location loc: Location, mark: Int64?) -> String {
        let items = library.items(in: loc.id)
        // Kun plader, der står i reolen, får et nummer. Plader, der er ude, vises nedtonede
        // uden nummer og med deres status – så numrene passer med det, man ser i reolen.
        let numbers = library.shelfNumbers(in: loc.id)
        let awayCount = items.count - numbers.count
        let idx = library.locations.firstIndex(of: loc)!
        let prev = idx > 0 ? library.locations[idx - 1] : nil
        let next = idx + 1 < library.locations.count ? library.locations[idx + 1] : nil
        func nav(_ l: Location?, _ label: String) -> String {
            guard let l else { return "<span class=\"navbtn off\">\(label)</span>" }
            return "<a class=\"navbtn\" href=\"/section/\(l.id)\">\(label.replacingOccurrences(of: "·", with: esc(l.shortName)))</a>"
        }
        var body = """
        <p class="kicker">Jeg står her</p>
        <h1 class="title">Reol \(loc.shelf) · Sektion \(esc(loc.section))</h1>
        <div class="secnav"><span class="sub">\(plural(numbers.count, "plade", "plader"))\(awayCount > 0 ? " (+\(awayCount) ude)" : "") · venstre mod højre</span>\
        <span>\(nav(prev, "‹ ·")) \(nav(next, "· ›"))</span></div>
        <ol class="list">
        """
        for it in items {
            let number = numbers[it.id]
            var cls = number == nil ? "away" : ""
            if it.id == mark { cls += " mark" }
            body += """
            <li id="c\(it.id)" class="\(cls)"><a class="row" href="/record/\(it.id)"><span class="num">\(number.map(String.init) ?? "")</span>\
            <img class="cover" loading="lazy" src="/cover/\(it.release.id)" alt="">\
            <span class="grow"><span class="a">\(esc(it.artist))</span><span class="t">\(esc(it.title))</span>\
            \(number == nil ? "<span class=\"sub\">\(esc(it.copy.status.label))</span>" : "")</span></a></li>
            """
        }
        body += "</ol>"
        if items.isEmpty { body += "<p class=\"muted\">Sektionen er tom.</p>" }
        return page(title: "Sektion \(loc.shortName)", body: body)
    }

    // MARK: - Byggeklodser

    static func recordRow(_ it: RecordItem, library: Library) -> String {
        // Fysisk nummer for plader i reolen; en plade, der er ude, har intet nummer lige nu.
        let place: String = {
            guard let loc = library.location(of: it.id) else { return "Ingen placering" }
            guard let nr = library.shelfNumbers(in: loc.id)[it.id] else { return esc(loc.shortName) }
            return "\(esc(loc.shortName)) · plads \(nr)"
        }()
        let status = it.copy.status.isOnShelf ? "" : " · \(esc(it.copy.status.label.lowercased()))"
        return """
        <li><a class="row" href="/record/\(it.id)"><img class="cover" loading="lazy" src="/cover/\(it.release.id)" alt="">\
        <span class="grow"><span class="a">\(esc(it.artist))</span><span class="t">\(esc(it.title))</span>\
        <span class="loc">\(place)\(status)</span></span><span class="chev">›</span></a></li>
        """
    }

    static func referenceBlock(_ heading: String, _ ref: Library.Reference) -> String {
        let arrow = (ref.side == .before || ref.side == .sectionStart) ? "←" : "→"
        let what: String
        if let it = ref.item {
            what = """
            <a class="row" href="/record/\(it.id)"><img class="cover" src="/cover/\(it.release.id)" alt="">\
            <span class="grow"><span class="a">\(esc(it.artist))</span><span class="t">\(esc(it.title))</span></span></a>
            """
        } else {
            what = "<div class=\"row\"><span class=\"t\">\(ref.side == .sectionStart ? "Sektionens venstre kant" : "Sektionens højre kant")</span></div>"
        }
        return """
        <section class="ref"><p class="kicker"><span class="arrow">\(arrow)</span> \(esc(heading))</p>\(what)\
        <p class="sub">\(esc(ref.reason))</p></section>
        """
    }

    static func searchForm(_ q: String, autofocus: Bool) -> String {
        """
        <form class="search" action="/" method="get"><input type="search" name="q" value="\(esc(q))" \
        placeholder="Søg i reolen…" autocomplete="off" autocorrect="off" autocapitalize="off" enterkeyhint="search"\(autofocus ? " autofocus" : "")></form>
        """
    }

    static func page(title: String, body: String, home: Bool = false) -> String {
        let header = home
            ? "<header><span class=\"brand\">Vinyl Shelf Finder</span></header>"
            : "<header><a class=\"back\" href=\"/\">‹ Søg</a><span class=\"brand\">Vinyl Shelf Finder</span></header>"
        return """
        <!doctype html><html lang="da"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
        <meta name="theme-color" content="#f5eee1" media="(prefers-color-scheme: light)">
        <meta name="theme-color" content="#1c1712" media="(prefers-color-scheme: dark)">
        <title>\(esc(title))</title><style>\(css)</style></head>
        <body>\(header)<main>\(body)</main></body></html>
        """
    }

    static let css = """
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
    """

    // MARK: - Hjælpere

    static func esc(_ s: String) -> String {
        var out = ""
        for c in s {
            switch c {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&#39;"
            default: out.append(c)
            }
        }
        return out
    }

    static func plural(_ n: Int, _ one: String, _ many: String) -> String { "\(n) \(n == 1 ? one : many)" }

    static func relative(_ date: Date, now: Date) -> String {
        let days = Int(now.timeIntervalSince(date) / 86400)
        switch days {
        case ..<1: return "i dag"
        case 1: return "i går"
        case ..<31: return "for \(days) dage siden"
        case ..<365: return "for \(days / 30) md. siden"
        default: return "for \(plural(days / 365, "år", "år")) siden"
        }
    }
}
