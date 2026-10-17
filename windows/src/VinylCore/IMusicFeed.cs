using System.Globalization;
using System.Text;
using System.Text.Json;
using System.Xml;
using Microsoft.Data.Sqlite;

namespace VinylShelfFinder.Core;

// Port af Sources/VinylCore/IMusicFeed.swift.
// iMusic.dk som ekstra købssted.
// iMusic har ingen offentlig købs-API. Priser kommer fra brugerens eget produktfeed hos
// affiliate-netværket Daisycon (kampagnen "imusic dk"). Selve købet sker altid på imusic.dk.
// Feedet gemmes i en SEPARAT cache-database (imusic.sqlite under Cache), aldrig i vinyl.sqlite.

// MARK: Søgning på imusic.dk (virker uden feed)

public static class IMusicLink
{
    /// iMusics søgeside med kunstner og titel, fx https://imusic.dk/page/search?query=Pink%20Floyd%20Animals.
    /// vinylOnly søger kun i vinyl (https://imusic.dk/vinyl/search?query=…).
    /// Formatet er fundet i iMusic-adresser, som søgemaskiner har gemt (1. okt 2026). Siden selv
    /// kunne ikke åbnes fra udviklingsmiljøet, så det er ikke afprøvet i en browser.
    public static Uri SearchUrl(string artist, string title, bool vinylOnly = false)
    {
        var query = string.Join(" ", new[] { artist, title }.Select(s => s.Trim()).Where(s => s.Length > 0));
        var baseUrl = vinylOnly ? "https://imusic.dk/vinyl/search" : "https://imusic.dk/page/search";
        return new Uri($"{baseUrl}?query={Uri.EscapeDataString(query)}");
    }
}

// MARK: Produkt og stregkoder

/// Én vare fra iMusic-feedet (kun musik).
public sealed record IMusicProduct(
    string Title,
    string Artist,
    string? Ean,
    string Format,
    double? Price,
    string Currency,
    /// true/false hvis feedet siger det; null hvis det er ukendt.
    bool? InStock,
    /// Fx "Leveres om 1-2 hverdage" eller "Bestillingsvare".
    string? Delivery,
    /// Affiliate-linket fra feedet. Købet sker på imusic.dk.
    Uri Link)
{
    /// "på lager" / "bestillingsvare" / leveringstekst.
    public string? AvailabilityText
    {
        get
        {
            if (InStock == true) return "på lager";
            if (Delivery?.Trim() is { Length: > 0 } d) return d.ToLowerInvariant();
            if (InStock == false) return "bestillingsvare";
            return null;
        }
    }

    private static readonly HashSet<string> VinylWords = new() { "vinyl", "lp", "2lp", "3lp", "12", "7", "10" };

    /// Vinyl (LP, 12", 7") ud fra format/titel.
    public bool IsVinyl => SearchIndex.Words($"{Format} {Title}").Any(VinylWords.Contains);
}

public static class Barcode
{
    /// Kun cifre. UPC-A (12 cifre) gøres til EAN-13 med et foranstillet 0, og GTIN-14 med
    /// foranstillet 0 til EAN-13, så samme vare får samme nøgle. Andre længder end 8, 12, 13
    /// og 14 cifre er ikke stregkoder (fx katalognumre) og giver null.
    public static string? Normalize(string s)
    {
        var digits = new string(s.Where(c => c is >= '0' and <= '9').ToArray());
        return digits.Length switch
        {
            8 or 13 => digits,
            12 => "0" + digits,
            14 when digits.StartsWith('0') => digits[1..],
            _ => null,
        };
    }
}

// MARK: Tolerant oversættelse af feltnavne

/// Daisycons feltnavne varierer mellem standarder og formater. Hvert felt har en liste af
/// mulige navne (små bogstaver). Det første, der findes og ikke er tomt, bruges.
/// Daisycons egne navne (standarden "General", JSON og XML: datafeed › programs › products ›
/// product_info / update_info) står først: title, link, price, ean, brand, category, category_path,
/// keywords, in_stock, in_stock_amount, delivery_time, delivery_description og update_info.status.
/// Der er ikke noget kunstner-, format- eller valutafelt; kunstneren tages fra titlen eller brand,
/// formatet fra kategori/nøgleord/titel, og valutaen er kroner (iMusic.dk).
public static class IMusicFields
{
    internal static readonly string[] Title = { "title", "name", "product_title", "productname", "product_name" };
    internal static readonly string[] Link = { "link", "url", "deeplink", "deep_link", "product_url", "productlink", "product_link", "affiliate_link" };
    internal static readonly string[] Price = { "minimum_price", "price", "price_new", "sale_price", "selling_price", "price_incl_vat" };
    internal static readonly string[] Currency = { "currency", "currency_code", "price_currency" };
    internal static readonly string[] Ean = { "ean", "ean13", "gtin", "gtin13", "barcode", "upc", "ean_code" };
    internal static readonly string[] Artist = { "artist", "artists", "performer", "brand", "author", "manufacturer" };
    internal static readonly string[] Format = { "format", "media", "medium", "media_type", "product_type", "material", "binding" };
    internal static readonly string[] Category = { "category_path", "category", "sub_category", "sub_sub_category", "google_category", "categories" };
    internal static readonly string[] Keywords = { "keywords", "tags" };
    internal static readonly string[] Status = { "status" };
    internal static readonly string[] InStock = { "in_stock", "instock", "stock", "availability", "in_stock_amount", "stock_amount" };
    internal static readonly string[] Delivery = { "delivery_time", "delivery_description", "delivery", "shipping_time", "lead_time" };

    internal static string? First(string[] names, IReadOnlyDictionary<string, string> f)
    {
        foreach (var n in names)
            if (f.TryGetValue(n, out var v) && v.Trim() is { Length: > 0 } t) return t;
        return null;
    }

    /// Ord, der viser, at varen er musik. Alt andet (film, spil, bøger) springes over.
    internal static readonly HashSet<string> MusicWords = new()
    {
        "vinyl", "lp", "2lp", "3lp", "cd", "2cd", "kassette", "cassette", "musik", "music", "single", "maxi", "sacd", "boxset",
    };

    /// Laver én vare ud af et fladt felt-opslag (nøgler med små bogstaver), eller null hvis det
    /// ikke er en musikvare med titel og link.
    public static IMusicProduct? Product(IReadOnlyDictionary<string, string> f, string fallbackCurrency = "DKK")
    {
        if (First(Title, f) is not string rawTitle || First(Link, f) is not string linkText
            || !Uri.TryCreate(linkText, UriKind.Absolute, out var url) || !url.Scheme.StartsWith("http", StringComparison.Ordinal)) return null;
        // update_info.status: varer, der er udgået hos iMusic.
        if (First(Status, f)?.ToLowerInvariant() is "inactive" or "deleted") return null;
        var formatText = First(Format, f) ?? "";
        var categoryText = First(Category, f) ?? "";
        var keywordText = First(Keywords, f) ?? "";
        if (!SearchIndex.Words($"{formatText} {categoryText} {keywordText} {rawTitle}").Any(MusicWords.Contains)) return null;

        // "Pink Floyd - Animals (LP)": kunstner foran bindestregen, hvis feedet ikke har et kunstnerfelt.
        var artistText = First(Artist, f) ?? "";
        var titleText = rawTitle;
        if (artistText.Length == 0)
        {
            var i = rawTitle.IndexOf(" - ", StringComparison.Ordinal);
            if (i < 0) i = rawTitle.IndexOf(" – ", StringComparison.Ordinal);
            if (i >= 0)
            {
                artistText = rawTitle[..i].Trim();
                titleText = rawTitle[(i + 3)..].Trim();
            }
        }
        var eanText = First(Ean, f) is string e ? Barcode.Normalize(e) : null;
        var priceValue = First(Price, f) is string p ? ParsePrice(p) : null;
        var stockText = First(InStock, f);
        return new IMusicProduct(
            titleText, artistText, eanText,
            formatText.Length == 0 ? categoryText : formatText,
            priceValue, (First(Currency, f) ?? fallbackCurrency).ToUpperInvariant(),
            stockText == null ? null : ParseStock(stockText), First(Delivery, f), url);
    }

    /// "249", "249.00", "249,00", "1.249,95", "DKK 249" → tal.
    public static double? ParsePrice(string s)
    {
        var t = new string(s.Where(c => char.IsDigit(c) || c == ',' || c == '.').ToArray());
        if (t.Length == 0) return null;
        int comma = t.LastIndexOf(','), dot = t.LastIndexOf('.');
        if (comma >= 0 && dot >= 0)
        {
            // Den sidste af , og . er decimaltegnet; den anden er tusindtalsskilletegn.
            t = comma > dot ? t.Replace(".", "").Replace(",", ".") : t.Replace(",", "");
        }
        else if (comma >= 0)
        {
            t = t.Replace(",", ".");
        }
        if (!double.TryParse(t, NumberStyles.AllowDecimalPoint, CultureInfo.InvariantCulture, out var v) || !(v > 0)) return null;
        return v;
    }

    private static readonly HashSet<string> StockYes = new() { "true", "yes", "ja", "y", "in stock", "instock", "in_stock", "på lager", "available" };
    private static readonly HashSet<string> StockNo = new()
    {
        "false", "no", "nej", "n", "out of stock", "outofstock", "out_of_stock", "ikke på lager", "unavailable", "preorder", "backorder",
    };

    /// "true", "1", "yes", "in stock", "på lager", et antal &gt; 0 → true. "false", "0", "out of stock" → false.
    public static bool? ParseStock(string s)
    {
        var t = s.ToLowerInvariant().Trim();
        if (int.TryParse(t, NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture, out var n)) return n > 0;
        if (StockYes.Contains(t)) return true;
        if (StockNo.Contains(t)) return false;
        return null;
    }
}

// MARK: Streamet parsing (JSON og XML)

public enum IMusicFeedFormat { Json, Xml }

public static class IMusicFeedParser
{
    /// Gætter formatet ud fra første tegn, der ikke er mellemrum (eller BOM).
    public static IMusicFeedFormat? DetectFormat(ReadOnlySpan<byte> prefix)
    {
        foreach (var b in prefix)
        {
            if (b is 0x20 or 0x0A or 0x0D or 0x09 or 0xEF or 0xBB or 0xBF) continue;
            if (b == (byte)'<') return IMusicFeedFormat.Xml;
            if (b == (byte)'{' || b == (byte)'[') return IMusicFeedFormat.Json;
            return null;
        }
        return null;
    }

    /// Læser en feed-fil i bidder og kalder emit for hver musikvare. Filen læses aldrig hel ind i hukommelsen.
    /// Returnerer antal varer (musik), der blev fundet.
    public static int Parse(string filePath, Action<IMusicProduct> emit)
    {
        using var stream = new FileStream(filePath, FileMode.Open, FileAccess.Read, FileShare.Read, 1 << 16);
        var head = new byte[64];
        int got = 0, n;
        while (got < head.Length && (n = stream.Read(head, got, head.Length - got)) > 0) got += n;
        stream.Position = 0;
        switch (DetectFormat(head.AsSpan(0, got)))
        {
            case IMusicFeedFormat.Xml:
                return ParseXml(stream, emit);
            case IMusicFeedFormat.Json:
                var scanner = new JsonElementScanner();
                var count = 0;
                var chunk = new byte[1 << 20];
                while ((n = stream.Read(chunk, 0, chunk.Length)) > 0)
                {
                    scanner.Feed(chunk.AsSpan(0, n), obj =>
                    {
                        if (IMusicFields.Product(Flatten(obj)) is not { } p) return false;
                        emit(p); count++; return true;
                    });
                }
                return count;
            default:
                throw new IMusicFeedException(IMusicFeedErrorKind.UnknownFormat);
        }
    }

    /// Til checks og små feeds: parser data i hukommelsen.
    public static List<IMusicProduct> Parse(byte[] data)
    {
        var output = new List<IMusicProduct>();
        switch (DetectFormat(data.AsSpan(0, Math.Min(64, data.Length))))
        {
            case IMusicFeedFormat.Xml:
                ParseXml(new MemoryStream(data, writable: false), output.Add);
                break;
            case IMusicFeedFormat.Json:
                var scanner = new JsonElementScanner();
                // Bidder på 7 byte, så skillet mellem bidder også bliver afprøvet.
                for (int i = 0; i < data.Length; i += 7)
                {
                    scanner.Feed(data.AsSpan(i, Math.Min(7, data.Length - i)), obj =>
                    {
                        if (IMusicFields.Product(Flatten(obj)) is not { } p) return false;
                        output.Add(p); return true;
                    });
                }
                break;
            default:
                throw new IMusicFeedException(IMusicFeedErrorKind.UnknownFormat);
        }
        return output;
    }

    /// Gør et JSON-objekt fladt: indlejrede objekter (fx product_info, update_info) lægges op på
    /// samme niveau. Nøgler gøres små; det første felt med et navn vinder.
    internal static Dictionary<string, string> Flatten(JsonElement obj)
    {
        var output = new Dictionary<string, string>();
        void Walk(JsonElement o)
        {
            foreach (var p in o.EnumerateObject().OrderBy(p => p.Name, StringComparer.Ordinal))
            {
                var key = p.Name.ToLowerInvariant();
                var v = p.Value;
                switch (v.ValueKind)
                {
                    case JsonValueKind.String: output.TryAdd(key, v.GetString()!); break;
                    case JsonValueKind.True: output.TryAdd(key, "true"); break;
                    case JsonValueKind.False: output.TryAdd(key, "false"); break;
                    case JsonValueKind.Number:
                        output.TryAdd(key, v.TryGetInt64(out var i) ? i.ToString(CultureInfo.InvariantCulture)
                                                                     : v.GetDouble().ToString("R", CultureInfo.InvariantCulture));
                        break;
                    case JsonValueKind.Object: Walk(v); break;
                    case JsonValueKind.Array:
                        // Fx "ean": ["5099..."] eller kategorier som liste.
                        // Lister af objekter (fx images) springes over.
                        var strings = v.EnumerateArray().Where(x => x.ValueKind == JsonValueKind.String).Select(x => x.GetString()!).ToList();
                        if (strings.Count > 0) output.TryAdd(key, string.Join(" ", strings));
                        break;
                }
            }
        }
        Walk(obj);
        return output;
    }

    // XML: hvert element med et af disse navne er én vare; alle blade under det samles fladt.
    internal static readonly HashSet<string> XmlProductElements = new() { "product", "item", "record", "offer", "entry" };

    /// Streamet XML: hver vare gives videre, så snart dens slut-tag er læst; intet samles op i hukommelsen.
    internal static int ParseXml(Stream stream, Action<IMusicProduct> emit)
    {
        var settings = new XmlReaderSettings
        {
            DtdProcessing = DtdProcessing.Ignore,   // ingen eksterne entiteter
            XmlResolver = null,
            IgnoreComments = true,
            IgnoreProcessingInstructions = true,
            CloseInput = false,
        };
        int count = 0, depthInProduct = 0;
        bool sawRecord = false;
        var current = new Dictionary<string, string>();
        var text = new StringBuilder();

        void Start(string name)
        {
            if (depthInProduct == 0)
            {
                if (XmlProductElements.Contains(name)) { depthInProduct = 1; current = new(); }
            }
            else depthInProduct++;
            text.Clear();
        }

        void End(string name)
        {
            if (depthInProduct == 0) return;
            depthInProduct--;
            if (depthInProduct == 0)
            {
                sawRecord = true;
                if (IMusicFields.Product(current) is { } p) { emit(p); count++; }
                current = new();
            }
            else
            {
                var t = text.ToString().Trim();
                if (t.Length > 0) current.TryAdd(name, t);
            }
            text.Clear();
        }

        try
        {
            using var reader = XmlReader.Create(stream, settings);
            while (reader.Read())
            {
                switch (reader.NodeType)
                {
                    case XmlNodeType.Element:
                        var name = reader.Name.ToLowerInvariant();
                        var empty = reader.IsEmptyElement;
                        Start(name);
                        if (empty) End(name);
                        break;
                    case XmlNodeType.EndElement:
                        End(reader.Name.ToLowerInvariant());
                        break;
                    case XmlNodeType.Text:
                    case XmlNodeType.CDATA:
                    case XmlNodeType.Whitespace:
                    case XmlNodeType.SignificantWhitespace:
                        if (depthInProduct > 0) text.Append(reader.Value);
                        break;
                }
            }
        }
        catch (XmlException)
        {
            // Ødelagt slutning: de varer, der allerede er læst, beholdes.
            if (!sawRecord) throw new IMusicFeedException(IMusicFeedErrorKind.Unreadable);
        }
        return count;
    }
}

public enum IMusicFeedErrorKind { UnknownFormat, Unreadable, BadUrl, Http, NotApproved }

/// Fejl ved hentning eller læsning af iMusic-feedet, med dansk tekst. Feed-URL'en står aldrig i teksten.
public sealed class IMusicFeedException : Exception
{
    public IMusicFeedErrorKind Kind { get; }
    public int StatusCode { get; }

    public IMusicFeedException(IMusicFeedErrorKind kind, int statusCode = 0) : base(Describe(kind, statusCode))
    {
        Kind = kind; StatusCode = statusCode;
    }

    public static string Describe(IMusicFeedErrorKind kind, int statusCode = 0) => kind switch
    {
        IMusicFeedErrorKind.UnknownFormat => "iMusic-feedet er hverken JSON eller XML. Vælg JSON eller XML, når du laver feed-URL'en hos Daisycon.",
        IMusicFeedErrorKind.Unreadable => "iMusic-feedet kunne ikke læses.",
        IMusicFeedErrorKind.BadUrl => "Feed-URL'en ser ikke rigtig ud. Den skal starte med https://.",
        IMusicFeedErrorKind.Http => $"Daisycon svarede med en fejl (kode {statusCode}). Tjek feed-URL'en i Indstillinger.",
        _ => "Feedet er tomt. Er du godkendt til iMusic-kampagnen hos Daisycon endnu?",
    };
}

/// Finder JSON-objekter, der er elementer i en liste (fx varerne i "products": [...]), i en
/// strøm af bidder, uden at læse hele feedet ind. Objekter over MaxObjectBytes (fx et
/// helt "program" med alle varerne) gives ikke videre; deres indhold bliver fundet i stedet.
internal sealed class JsonElementScanner
{
    public const int MaxObjectBytes = 1 << 20;

    private byte[] _buffer = new byte[1 << 16];
    private int _length;
    /// Absolut position for _buffer[0].
    private long _bufferStart;
    private long _position;
    private bool _inString;
    private bool _escaped;
    /// Containere fra yderst til inderst: true = liste, false = objekt.
    private readonly List<bool> _stack = new();
    /// Åbne objekter, der er elementer i en liste: (dybde, startposition). Fjernes, hvis de bliver for store.
    private readonly List<(int Depth, long Start)> _candidates = new();
    /// Start på den seneste vare, der blev givet videre.
    private long? _lastProductStart;

    /// handle returnerer true, hvis objektet var en vare (så dets indre ikke undersøges igen).
    public void Feed(ReadOnlySpan<byte> chunk, Func<JsonElement, bool> handle)
    {
        if (_length + chunk.Length > _buffer.Length)
            Array.Resize(ref _buffer, Math.Max(_buffer.Length * 2, _length + chunk.Length));
        chunk.CopyTo(_buffer.AsSpan(_length));
        _length += chunk.Length;

        while (_position - _bufferStart < _length)
        {
            var b = _buffer[_position - _bufferStart];
            if (_inString)
            {
                if (_escaped) _escaped = false;
                else if (b == 0x5C) _escaped = true;          // \
                else if (b == 0x22) _inString = false;        // "
            }
            else
            {
                switch (b)
                {
                    case 0x22: _inString = true; break;
                    case 0x7B:                                // {
                        if (_stack.Count > 0 && _stack[^1]) _candidates.Add((_stack.Count, _position));
                        _stack.Add(false);
                        break;
                    case 0x5B: _stack.Add(true); break;       // [
                    case 0x7D:                                // }
                    case 0x5D:                                // ]
                        var depth = _stack.Count;
                        if (_stack.Count > 0) _stack.RemoveAt(_stack.Count - 1);
                        // Et objekt, der var element i en liste, er slut.
                        if (b == 0x7D && _candidates.Count > 0 && _candidates[^1].Depth == depth - 1)
                        {
                            var last = _candidates[^1];
                            _candidates.RemoveAt(_candidates.Count - 1);
                            long from = last.Start - _bufferStart, to = _position - _bufferStart;
                            // Et objekt, der indeholder varer, vi allerede har givet videre (fx et lille
                            // "program"), undersøges ikke igen.
                            var containsProduct = _lastProductStart is long lp && lp > last.Start;
                            if (from >= 0 && to - from + 1 <= MaxObjectBytes && !containsProduct)
                            {
                                JsonDocument? doc = null;
                                try { doc = JsonDocument.Parse(_buffer.AsMemory((int)from, (int)(to - from + 1))); }
                                catch (JsonException) { }
                                if (doc != null)
                                {
                                    using (doc)
                                        if (doc.RootElement.ValueKind == JsonValueKind.Object && handle(doc.RootElement))
                                            _lastProductStart = last.Start;
                                }
                            }
                        }
                        break;
                }
            }
            _position++;
            // Kandidater, der er blevet for store, opgives (deres indre elementer findes for sig).
            while (_candidates.Count > 0 && _position - _candidates[0].Start > MaxObjectBytes) _candidates.RemoveAt(0);
        }
        // Behold kun bytes fra den ældste åbne kandidat (eller intet).
        var keepFrom = _candidates.Count > 0 ? _candidates[0].Start : _position;
        var drop = keepFrom - _bufferStart;
        if (drop > 0)
        {
            var d = (int)Math.Min(drop, _length);
            Buffer.BlockCopy(_buffer, d, _buffer, 0, _length - d);
            _length -= d;
            _bufferStart += drop;
        }
    }
}

// MARK: Cache-database (imusic.sqlite)

/// iMusic-varerne fra feedet. Ligger i %LOCALAPPDATA%\VinylShelfFinder\Cache\imusic.sqlite, adskilt fra
/// brugerens rigtige database (vinyl.sqlite), og kan altid slettes og hentes igen.
public sealed class IMusicCache : IDisposable
{
    public string FilePath { get; }
    private readonly SqliteConnection _db;
    private readonly object _lock = new();

    public static string DefaultPath =>
        System.IO.Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "VinylShelfFinder", "Cache", "imusic.sqlite");

    /// Feedet hentes højst én gang i døgnet.
    public static readonly TimeSpan RefreshInterval = TimeSpan.FromHours(24);

    public IMusicCache(string? path = null)
    {
        FilePath = path ?? DefaultPath;
        var dir = System.IO.Path.GetDirectoryName(System.IO.Path.GetFullPath(FilePath));
        if (!string.IsNullOrEmpty(dir)) Directory.CreateDirectory(dir);
        // Uden pulje, så filen lukkes helt ved Dispose (og kan slettes).
        _db = new SqliteConnection(new SqliteConnectionStringBuilder { DataSource = FilePath, Pooling = false }.ToString());
        _db.Open();
        Execute("PRAGMA journal_mode=WAL;");
        Execute("""
            CREATE TABLE IF NOT EXISTS products (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                ean TEXT,
                artist TEXT NOT NULL,
                title TEXT NOT NULL,
                search TEXT NOT NULL,
                format TEXT NOT NULL,
                price REAL,
                currency TEXT NOT NULL,
                in_stock INTEGER,
                delivery TEXT,
                link TEXT NOT NULL
            );
            CREATE INDEX IF NOT EXISTS products_ean ON products(ean);
            CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT);
            """);
    }

    public void Dispose()
    {
        lock (_lock) _db.Dispose();
    }

    private void Execute(string sql, SqliteTransaction? tx = null)
    {
        using var cmd = _db.CreateCommand();
        cmd.CommandText = sql;
        cmd.Transaction = tx;
        cmd.ExecuteNonQuery();
    }

    public DateTimeOffset? LastFetched
    {
        get
        {
            lock (_lock)
            {
                using var cmd = _db.CreateCommand();
                cmd.CommandText = "SELECT value FROM meta WHERE key = 'fetched_at'";
                var v = cmd.ExecuteScalar();
                var text = Convert.ToString(v, CultureInfo.InvariantCulture);
                if (v == null || v is DBNull || !double.TryParse(text, NumberStyles.Float, CultureInfo.InvariantCulture, out var secs)) return null;
                return DateTimeOffset.FromUnixTimeMilliseconds((long)Math.Round(secs * 1000));
            }
        }
    }

    public int Count
    {
        get
        {
            lock (_lock)
            {
                using var cmd = _db.CreateCommand();
                cmd.CommandText = "SELECT COUNT(*) FROM products";
                return Convert.ToInt32(cmd.ExecuteScalar(), CultureInfo.InvariantCulture);
            }
        }
    }

    public static bool NeedsRefresh(DateTimeOffset? lastFetched, DateTimeOffset? now = null)
    {
        if (lastFetched is not DateTimeOffset last) return true;
        var n = now ?? DateTimeOffset.Now;
        return n - last >= RefreshInterval || last > n;
    }

    /// Erstatter hele indholdet med varerne fra en feed-fil (i én transaktion; fejler noget,
    /// beholdes den gamle cache).
    public int Replace(string feedPath, DateTimeOffset? now = null)
    {
        var at = now ?? DateTimeOffset.Now;
        lock (_lock)
        {
            using var tx = _db.BeginTransaction();
            Execute("DELETE FROM products", tx);
            using var insert = InsertCommand(tx);
            var n = IMusicFeedParser.Parse(feedPath, p => RunInsert(insert, p));
            using (var meta = _db.CreateCommand())
            {
                meta.Transaction = tx;
                meta.CommandText = "INSERT INTO meta(key, value) VALUES('fetched_at', $v) ON CONFLICT(key) DO UPDATE SET value = excluded.value";
                meta.Parameters.AddWithValue("$v", (at.ToUnixTimeMilliseconds() / 1000.0).ToString("R", CultureInfo.InvariantCulture));
                meta.ExecuteNonQuery();
            }
            tx.Commit();
            return n;
        }
    }

    /// Til checks: læg varer direkte i cachen.
    public void Insert(IMusicProduct p)
    {
        lock (_lock)
        {
            using var cmd = InsertCommand(null);
            RunInsert(cmd, p);
        }
    }

    private SqliteCommand InsertCommand(SqliteTransaction? tx)
    {
        var cmd = _db.CreateCommand();
        cmd.Transaction = tx;
        cmd.CommandText = """
            INSERT INTO products(ean, artist, title, search, format, price, currency, in_stock, delivery, link)
            VALUES($ean, $artist, $title, $search, $format, $price, $currency, $in_stock, $delivery, $link)
            """;
        foreach (var name in new[] { "$ean", "$artist", "$title", "$search", "$format", "$price", "$currency", "$in_stock", "$delivery", "$link" })
            cmd.Parameters.Add(new SqliteParameter { ParameterName = name });
        return cmd;
    }

    private static void RunInsert(SqliteCommand cmd, IMusicProduct p)
    {
        cmd.Parameters["$ean"].Value = (object?)p.Ean ?? DBNull.Value;
        cmd.Parameters["$artist"].Value = p.Artist;
        cmd.Parameters["$title"].Value = p.Title;
        cmd.Parameters["$search"].Value = SearchIndex.Normalize($"{p.Artist} {p.Title}");
        cmd.Parameters["$format"].Value = p.Format;
        cmd.Parameters["$price"].Value = (object?)p.Price ?? DBNull.Value;
        cmd.Parameters["$currency"].Value = p.Currency;
        cmd.Parameters["$in_stock"].Value = p.InStock is bool b ? (b ? 1 : 0) : DBNull.Value;
        cmd.Parameters["$delivery"].Value = (object?)p.Delivery ?? DBNull.Value;
        cmd.Parameters["$link"].Value = p.Link.AbsoluteUri;
        cmd.ExecuteNonQuery();
    }

    private List<IMusicProduct> Query(string sql, string value)
    {
        lock (_lock)
        {
            using var cmd = _db.CreateCommand();
            cmd.CommandText = sql;
            cmd.Parameters.AddWithValue("$v", value);
            using var r = cmd.ExecuteReader();
            var output = new List<IMusicProduct>();
            while (r.Read())
            {
                string? Text(string c) => r.IsDBNull(r.GetOrdinal(c)) ? null : r.GetString(r.GetOrdinal(c));
                if (!Uri.TryCreate(Text("link"), UriKind.Absolute, out var link)) continue;
                var priceOrd = r.GetOrdinal("price");
                var stockOrd = r.GetOrdinal("in_stock");
                output.Add(new IMusicProduct(
                    Text("title") ?? "", Text("artist") ?? "", Text("ean"), Text("format") ?? "",
                    r.IsDBNull(priceOrd) ? null : r.GetDouble(priceOrd),
                    Text("currency") ?? "DKK",
                    r.IsDBNull(stockOrd) ? null : r.GetInt64(stockOrd) != 0,
                    Text("delivery"), link));
            }
            return output;
        }
    }

    /// Bedste vare for en plade: først på stregkode, ellers på kunstner + titel (tåler små stavefejl),
    /// med vinyl foran andre formater, når preferVinyl er sat.
    public IMusicProduct? Match(IEnumerable<string> barcodes, string artist, string title, bool preferVinyl = true)
    {
        var eans = barcodes.Select(Barcode.Normalize).OfType<string>().Distinct().OrderBy(e => e, StringComparer.Ordinal);
        foreach (var ean in eans)
        {
            if (Query("SELECT * FROM products WHERE ean = $v ORDER BY id", ean).FirstOrDefault() is { } hit) return hit;
        }
        var wanted = SearchIndex.Words($"{artist} {title}").Where(w => w.Length >= 2).ToList();
        if (wanted.Count == 0) return null;
        // Kandidater: varer, hvis tekst indeholder det længste ord (hurtigt via LIKE), derefter scoring.
        var anchor = wanted.MaxBy(w => w.Length)!;
        var rows = Query("SELECT * FROM products WHERE search LIKE $v ORDER BY id LIMIT 400", $"%{anchor}%");
        IMusicProduct? best = null;
        int bestScore = int.MinValue;
        foreach (var p in rows)
        {
            if (IMusicMatcher.Score(wanted, p) is not int s) continue;
            s += preferVinyl && p.IsVinyl ? 5 : 0;
            if (s > bestScore) { best = p; bestScore = s; }
        }
        return best;
    }
}

/// Fuzzy-sammenligning af kunstner + titel. Bruger samme normalisering og stavefejl-afstand som
/// den lokale søgning (SearchIndex).
public static class IMusicMatcher
{
    /// null, hvis ikke alle ønskede ord findes i varen (tåler 1 stavefejl i ord på mindst 4 tegn).
    /// Ellers en score: flere præcise ord og færre ekstra ord er bedre.
    public static int? Score(IReadOnlyList<string> wanted, IMusicProduct p)
    {
        // Samme ord to gange (fx kunstneren både i brand og titel) tæller kun én gang.
        var have = SearchIndex.Words($"{p.Artist} {p.Title}").Distinct().ToList();
        var score = 0;
        foreach (var w in wanted)
        {
            if (have.Contains(w)) { score += 10; continue; }
            if (w.Length < 4 || !have.Any(h => Math.Abs(h.Length - w.Length) <= 1 && SearchIndex.EditDistance(w, h, 1) <= 1)) return null;
            score += 6;
        }
        // Ekstra ord (fx "Deluxe Edition") trækker lidt ned, så den rene udgave vinder.
        score -= Math.Max(0, have.Count - wanted.Count);
        return score;
    }
}

// MARK: Hentning af feedet

public static class IMusicFeedUpdater
{
    private static readonly HttpClient SharedHttp = new();

    /// Kun https-adresser hos Daisycon godtages (feedet ligger på daisycon.io).
    public static Uri? Validate(string text)
    {
        var t = text.Trim();
        if (!Uri.TryCreate(t, UriKind.Absolute, out var url) || url.Scheme != "https") return null;
        var host = url.Host.ToLowerInvariant();
        return host == "daisycon.io" || host.EndsWith(".daisycon.io", StringComparison.Ordinal) || host.EndsWith("daisycon.com", StringComparison.Ordinal)
            ? url : null;
    }

    /// Henter feedet til en midlertidig fil (aldrig hele feedet i hukommelsen) og lægger musikvarerne
    /// i cachen. Adressen indeholder brugerens media_id og logges aldrig.
    public static async Task<int> RefreshAsync(Uri feed, IMusicCache cache, HttpClient? http = null, DateTimeOffset? now = null,
                                               CancellationToken ct = default)
    {
        using var req = new HttpRequestMessage(HttpMethod.Get, feed);
        req.Headers.TryAddWithoutValidation("User-Agent", DiscogsClient.UserAgent);
        using var resp = await (http ?? SharedHttp).SendAsync(req, HttpCompletionOption.ResponseHeadersRead, ct).ConfigureAwait(false);
        var code = (int)resp.StatusCode;
        if (code < 200 || code >= 300) throw new IMusicFeedException(IMusicFeedErrorKind.Http, code);
        // Daisycon svarer med X-Total-Count: 0, før man er godkendt til kampagnen.
        if (resp.Headers.TryGetValues("X-Total-Count", out var total) && total.FirstOrDefault() == "0")
            throw new IMusicFeedException(IMusicFeedErrorKind.NotApproved);
        var file = System.IO.Path.Combine(System.IO.Path.GetTempPath(), $"vsf-imusic-{Guid.NewGuid():N}.feed");
        try
        {
            await using (var output = new FileStream(file, FileMode.CreateNew, FileAccess.Write, FileShare.None, 1 << 16, useAsync: true))
            await using (var body = await resp.Content.ReadAsStreamAsync(ct).ConfigureAwait(false))
                await body.CopyToAsync(output, ct).ConfigureAwait(false);
            return await Task.Run(() => cache.Replace(file, now), ct).ConfigureAwait(false);
        }
        finally
        {
            try { File.Delete(file); } catch (IOException) { } catch (UnauthorizedAccessException) { }
        }
    }
}
