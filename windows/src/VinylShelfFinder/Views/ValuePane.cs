using System.Globalization;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using VinylShelfFinder.Core;
using VinylShelfFinder.UI;

namespace VinylShelfFinder.Views;

/// <summary>Værdi (ValueView.swift): Discogs' estimat for samlingen og markedsdata pr. plade.</summary>
public sealed class ValuePane : IPane
{
    private enum SortMode { Price, Demand, Rare, Scarce }
    private static readonly string[] SortLabels = { "Højeste pris", "Mest efterspurgt", "Færrest ejere", "Færrest til salg" };

    private readonly AppModel _model;
    private readonly ListView _list = new() { SelectionMode = ListViewSelectionMode.Single, Padding = new Thickness(0, 0, 0, 12) };
    private readonly List<long?> _rowIds = new();
    private SortMode _sort = SortMode.Price;
    private bool _building;

    public FrameworkElement View => _list;

    public ValuePane(AppModel model)
    {
        _model = model;
        _list.SelectionChanged += (_, _) =>
        {
            if (_building) return;
            int i = _list.SelectedIndex;
            if (i >= 0 && i < _rowIds.Count && _rowIds[i] is long id) _model.Selection = id;
        };
        Rebuild();
    }

    public void OnModelChanged(string? property)
    {
        if (property is nameof(AppModel.Library) or nameof(AppModel.Market) or nameof(AppModel.ValueState)
            or nameof(AppModel.CollectionValue) or nameof(AppModel.Currency) or nameof(AppModel.HasToken))
            Rebuild();
    }

    public static string Money(double v, string currency)
    {
        var da = CultureInfo.GetCultureInfo("da-DK");
        return currency == "DKK" ? v.ToString("N2", da) + " kr." : $"{v.ToString("N2", da)} {currency}";
    }

    private List<(RecordItem Item, MarketInfo? Market)> Rows()
    {
        // Samme rækkefølge som i reolen ved lige værdier og for plader uden priser.
        var shelfOrder = _model.Rules.Sorted(_model.Library.AllItems.Where(i => i.Copy.InDiscogs)).ToList();
        var items = shelfOrder.Select(i => (Item: i, Market: _model.Market.TryGetValue(i.Release.Id, out var m) ? m : null)).ToList();
        double? Key(MarketInfo? m) => m is null ? null : _sort switch
        {
            SortMode.Price => m.LowestPrice,
            SortMode.Demand => m.Demand,
            SortMode.Rare => m.Have is int h ? -h : null,
            _ => m.NumForSale is int n ? -n : null,
        };
        // Stabil sortering på værdien; ved lige værdi bevares reolens rækkefølge.
        return items.Select((r, i) => (r, i, k: Key(r.Market)))
            .OrderBy(x => x.k is null ? 1 : 0).ThenByDescending(x => x.k ?? 0).ThenBy(x => x.i)
            .Select(x => x.r).ToList();
    }

    private void Add(UIElement row, long? id)
    {
        _list.Items.Add(row);
        _rowIds.Add(id);
    }

    private void Rebuild()
    {
        _building = true;
        _list.Items.Clear();
        _rowIds.Clear();
        var rows = Rows();
        // Kun priser i den valgte valuta må lægges sammen.
        var priced = rows.Select(r => r.Market).Where(m => m is not null && m.Currency == _model.Currency && m.LowestPrice is not null)
            .Select(m => m!.LowestPrice!.Value).ToList();
        Add(Header(priced.Count, rows.Count, priced.Sum()), null);

        var sort = new ComboBox { Header = "Sortér", ItemsSource = SortLabels, SelectedIndex = (int)_sort, Margin = new Thickness(4, 8, 4, 4) };
        sort.SelectionChanged += (_, _) => { if (!_building && sort.SelectedIndex >= 0) { _sort = (SortMode)sort.SelectedIndex; Rebuild(); } };
        Add(sort, null);

        if (rows.Count == 0) Add(Ui.Text("Ingen plader fra din Discogs-samling endnu.", color: Ui.Secondary), null);
        foreach (var (item, market) in rows) Add(Row(item, market), item.Id);
        if (_model.Selection is long s) { int i = _rowIds.IndexOf(s); if (i >= 0) _list.SelectedIndex = i; }
        _building = false;
    }

    private FrameworkElement Header(int pricedCount, int total, double sum)
    {
        var p = new StackPanel { Spacing = 10, Padding = new Thickness(4, 12, 4, 8) };
        p.Children.Add(Ui.Text("Værdi", "TitleTextBlockStyle"));
        p.Children.Add(Ui.Eyebrow("Discogs' estimat for samlingen"));
        if (_model.CollectionValue is CollectionValue v)
        {
            var g = new Grid();
            for (int i = 0; i < 3; i++) g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            (string L, string V, bool Big)[] cells = { ("Min", v.Minimum, false), ("Median", v.Median, true), ("Max", v.Maximum, false) };
            for (int i = 0; i < 3; i++)
            {
                var c = Ui.VStack(2, Ui.Text(cells[i].L, "CaptionTextBlockStyle", Ui.Secondary), Ui.Text(cells[i].V, cells[i].Big ? "SubtitleTextBlockStyle" : "BodyStrongTextBlockStyle", wrap: false));
                Grid.SetColumn(c, i);
                g.Children.Add(c);
            }
            p.Children.Add(g);
            p.Children.Add(Ui.Text($"Baseret på faktiske salg på Discogs · opdateret {DanishDate.DateTime(v.FetchedAt)}", "CaptionTextBlockStyle", Ui.Secondary));
        }
        else p.Children.Add(Ui.Text("Ikke hentet endnu.", color: Ui.Secondary));
        p.Children.Add(Ui.Divider());

        if (pricedCount > 0)
        {
            p.Children.Add(Ui.Text($"Sum af laveste udbudspriser: {Money(sum, _model.Currency)}", "BodyStrongTextBlockStyle"));
            p.Children.Add(Ui.Text($"{pricedCount} af {total} plader er til salg på Discogs lige nu. Laveste pris er det billigste eksemplar i dag – uanset stand og pressing-kvalitet – ikke nødvendigvis hvad din plade er værd.",
                "CaptionTextBlockStyle", Ui.Secondary));
        }

        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10 };
        var st = _model.ValueState;
        switch (st.Phase)
        {
            case SyncPhase.Running:
                row.Children.Add(new ProgressBar { Width = 200, Maximum = Math.Max(st.Total, 1), Value = st.Done, VerticalAlignment = VerticalAlignment.Center });
                row.Children.Add(Ui.Text($"{st.Done}/{st.Total}", color: Ui.Secondary, wrap: false));
                break;
            case SyncPhase.Failed:
                row.Children.Add(Ui.Text(st.Message ?? "", "CaptionTextBlockStyle", Ui.ThemeBrush("SystemFillColorCriticalBrush")));
                row.Children.Add(Ui.Btn("Prøv igen", async (_, _) => await _model.RefreshValuesAsync()));
                break;
            default:
                var fetch = Ui.Btn(_model.Market.Count == 0 ? "Hent værdier" : "Opdater værdier", async (_, _) => await _model.RefreshValuesAsync(), "", accent: true);
                fetch.IsEnabled = _model.HasToken;
                row.Children.Add(fetch);
                var cur = new ComboBox { ItemsSource = MarketCurrency.AllCases, SelectedItem = _model.Currency };
                Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(cur, "Valuta");
                cur.SelectionChanged += (_, _) => { if (!_building && cur.SelectedItem is string c) _model.Currency = c; };
                row.Children.Add(cur);
                break;
        }
        p.Children.Add(row);
        if (!_model.HasToken)
            p.Children.Add(Ui.Text(_model.IsDemo ? "Demo-tilstanden henter ikke værdier fra Discogs." : "Forbind til Discogs i Indstillinger for at hente værdier.",
                "CaptionTextBlockStyle", Ui.Secondary));
        else if (st.Phase == SyncPhase.Idle && _model.Market.Count > 0)
            p.Children.Add(Ui.Text("Priser ældre end 7 dage hentes igen. Tager ca. 1 sekund pr. plade (Discogs' grænse).", "CaptionTextBlockStyle", Ui.Secondary));
        return p;
    }

    private FrameworkElement Row(RecordItem item, MarketInfo? m)
    {
        var g = new Grid { ColumnSpacing = 10, Padding = new Thickness(0, 4, 0, 4) };
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        g.Children.Add(Ui.Cover(item.Release, 38));
        var t = Ui.VStack(2, Ui.Text(item.FullName, maxLines: 2), Ui.Text(item.DetailLine, "CaptionTextBlockStyle", Ui.Secondary, wrap: false, maxLines: 1));
        Grid.SetColumn(t, 1);
        g.Children.Add(t);
        var right = new StackPanel { HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Center };
        if (m is not null)
        {
            var price = Ui.Text(m.LowestPrice is double p ? Money(p, m.Currency) : "–", _sort == SortMode.Price ? "BodyStrongTextBlockStyle" : "BodyTextBlockStyle", wrap: false);
            price.HorizontalAlignment = HorizontalAlignment.Right;
            right.Children.Add(price);
            var sec = _sort switch
            {
                SortMode.Demand => m.Demand is double d ? $"{d.ToString("N2", CultureInfo.GetCultureInfo("da-DK"))} ønsker pr. ejer" : "",
                SortMode.Rare => m.Have is int h ? $"{h} ejere" : "",
                _ => m.NumForSale is int n ? $"{n} til salg" : "",
            };
            var s2 = Ui.Text(sec, "CaptionTextBlockStyle", Ui.Secondary, wrap: false);
            s2.HorizontalAlignment = HorizontalAlignment.Right;
            right.Children.Add(s2);
        }
        else right.Children.Add(Ui.Text("ikke hentet", "CaptionTextBlockStyle", Ui.Secondary, wrap: false));
        Grid.SetColumn(right, 2);
        g.Children.Add(right);
        return g;
    }
}
