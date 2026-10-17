namespace VinylShelfFinder.Core;

// Port af modellerne i Sources/VinylCore/Market.swift. Selve hentningen og omregningen
// ligger i Market.cs; lagringen i ShelfStore (SaveMarket, LoadMarket …).

/// Markedsdata for én release fra Discogs. Bemærk: det er *aktuelle udbud* og
/// community-tal – Discogs' API udleverer ikke salgshistorik pr. release.
public sealed record MarketInfo(double? LowestPrice, string Currency, int? NumForSale, int? Have, int? Want, DateTimeOffset FetchedAt)
{
    public MarketInfo(double? lowestPrice, string currency, int? numForSale, int? have, int? want)
        : this(lowestPrice, currency, numForSale, have, want, DateTimeOffset.Now) { }

    /// Ønsker pr. ejer. Høj værdi = efterspurgt.
    public double? Demand => Have is int h && Want is int w && h > 0 ? (double)w / h : null;
}

/// Discogs' eget værdiestimat for hele samlingen (baseret på faktiske salg).
public sealed record CollectionValue(string Minimum, string Median, string Maximum, DateTimeOffset FetchedAt);
