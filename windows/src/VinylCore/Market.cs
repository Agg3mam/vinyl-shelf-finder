using System.Text.Json;

namespace VinylShelfFinder.Core;

// Port af Sources/VinylCore/Market.swift (uden lagringen, som ligger i ShelfStore) og MasterOffer
// fra DiscogsCatalog.swift. Modellerne MarketInfo og CollectionValue ligger i MarketModels.cs.

/// Valutaer i appens valutavalg og omregning mellem euro og kroner.
public static class MarketCurrency
{
    /// Valutavalget; DKK står først.
    public static readonly IReadOnlyList<string> AllCases = new[] { "DKK", "EUR", "USD", "GBP", "SEK", "CHF" };

    /// Kronen er fast bundet til euroen (centralkurs 7,46038), så de to kan regnes præcist om.
    /// Discogs giver selv priser i kroner; omregningen bruges kun, hvis et svar kommer i den anden.
    public const double DkkPerEur = 7.46038;

    /// Omregner mellem euro og kroner. Andre valutaer røres ikke – der gættes aldrig en kurs.
    public static MarketInfo Converted(MarketInfo m, string code)
    {
        double rate;
        if (m.Currency == "EUR" && code == "DKK") rate = DkkPerEur;
        else if (m.Currency == "DKK" && code == "EUR") rate = 1 / DkkPerEur;
        else return m;
        return m with
        {
            LowestPrice = m.LowestPrice is double p ? Math.Round(p * rate * 100, MidpointRounding.AwayFromZero) / 100 : null,
            Currency = code,
        };
    }
}

/// Markedstal for et helt album (master) fra GET /masters/{id}: gælder alle formater samlet.
public sealed record MasterOffer(
    double? LowestPrice,
    /// Valutaen, hvis svaret selv oplyser den. Ellers er prisen i brugerens Discogs-valuta.
    string? Currency,
    int? NumForSale,
    /// Discogs' hovedudgave af albummet (release-id).
    int? MainRelease)
{
    /// Til visning i appens valuta. Prisen er i svarets valuta eller i userCurrency (brugerens
    /// Discogs-valuta). Euro regnes om til kroner; alle andre valutaer vises, som Discogs giver dem
    /// (ingen opfundne vekselkurser). Kendes valutaen ikke, vises ingen pris, kun antal til salg.
    public MarketInfo Market(string? userCurrency, string appCurrency)
    {
        var cur = Currency ?? userCurrency;
        var info = new MarketInfo(cur == null ? null : LowestPrice, cur ?? appCurrency, NumForSale, null, null, DateTimeOffset.Now);
        return MarketCurrency.Converted(info, appCurrency);
    }
}

public sealed partial class DiscogsClient
{
    public async Task<CollectionValue> CollectionValueAsync(string username, CancellationToken ct = default)
    {
        var data = await GetAsync($"/users/{EscapePath(username)}/collection/value", ct: ct).ConfigureAwait(false);
        return ParseCollectionValue(data);
    }

    /// Laveste pris for én udgave via /marketplace/stats, hvor valutaen står i svaret.
    /// (/releases/{id} ignorerer curr_abbr og giver altid brugerens Discogs-valuta – målt 1. okt 2026.)
    public async Task<MarketInfo> MarketInfoAsync(int releaseId, string currency, CancellationToken ct = default)
    {
        var data = await GetAsync($"/marketplace/stats/{releaseId}", new[] { ("curr_abbr", currency) }, ct: ct).ConfigureAwait(false);
        return MarketCurrency.Converted(ParseMarketStats(data, currency), currency);
    }

    /// Markedsdata til Værdi-skærmen: pris og har/ønsker fra /releases/{id}. Prisen dér er i
    /// brugerens Discogs-valuta (discogsCurrency). Kan den ikke regnes om til appCurrency,
    /// hentes prisen i stedet fra /marketplace/stats; er valutaen ukendt, gemmes ingen pris.
    public async Task<MarketInfo> ReleaseMarketInfoAsync(int releaseId, string? discogsCurrency, string appCurrency, CancellationToken ct = default)
    {
        var data = await GetAsync($"/releases/{releaseId}", ct: ct).ConfigureAwait(false);
        var m = ParseMarketInfo(data, discogsCurrency ?? appCurrency);
        if (discogsCurrency == null) m = m with { LowestPrice = null };
        m = MarketCurrency.Converted(m, appCurrency);
        if (discogsCurrency == null || m.Currency != appCurrency)
        {
            var stats = await MarketInfoAsync(releaseId, appCurrency, ct).ConfigureAwait(false);
            m = m with { LowestPrice = stats.LowestPrice, Currency = stats.Currency, NumForSale = stats.NumForSale };
        }
        return m;
    }

    /// Svar fra /marketplace/stats/{id}: lowest_price er {"value": …, "currency": "DKK"} eller null.
    /// Mangler valutaen i et ellers gyldigt prisfelt, vises ingen pris (aldrig en gættet valuta).
    public static MarketInfo ParseMarketStats(byte[] data, string fallbackCurrency)
    {
        try
        {
            using var doc = JsonDocument.Parse(data);
            var s = doc.RootElement;
            if (s.ValueKind != JsonValueKind.Object) throw new FormatException();
            var p = Json.Prop(s, "lowest_price");
            double? value = null;
            string? cur = null;
            if (p is { ValueKind: JsonValueKind.Object } price)
            {
                value = Json.FlexDouble(Json.Prop(price, "value"));
                cur = Json.Str(Json.Prop(price, "currency")) is { Length: > 0 } c ? c.ToUpperInvariant() : null;
            }
            return new MarketInfo(cur == null ? null : value, cur ?? fallbackCurrency, Json.FlexInt(Json.Prop(s, "num_for_sale")), null, null, DateTimeOffset.Now);
        }
        catch (Exception e) when (e is JsonException or FormatException)
        {
            throw DiscogsException.Decoding("markedspriser");
        }
    }

    public static CollectionValue ParseCollectionValue(byte[] data)
    {
        try
        {
            using var doc = JsonDocument.Parse(data);
            var v = doc.RootElement;
            if (Json.Str(Json.Prop(v, "minimum")) is string min && Json.Str(Json.Prop(v, "median")) is string med
                && Json.Str(Json.Prop(v, "maximum")) is string max)
                return new CollectionValue(min, med, max, DateTimeOffset.Now);
        }
        catch (JsonException) { }
        throw DiscogsException.Decoding("samlingens værdi");
    }

    public static MarketInfo ParseMarketInfo(byte[] data, string currency)
    {
        try
        {
            using var doc = JsonDocument.Parse(data);
            var r = doc.RootElement;
            if (r.ValueKind != JsonValueKind.Object) throw new FormatException();
            var community = Json.Prop(r, "community");
            int? Community(string n) => community is { ValueKind: JsonValueKind.Object } c ? Json.Int(Json.Prop(c, n)) : null;
            return new MarketInfo(Json.Double(Json.Prop(r, "lowest_price")), currency, Json.Int(Json.Prop(r, "num_for_sale")),
                                  Community("have"), Community("want"), DateTimeOffset.Now);
        }
        catch (Exception e) when (e is JsonException or FormatException)
        {
            throw DiscogsException.Decoding("markedspriser");
        }
    }
}
