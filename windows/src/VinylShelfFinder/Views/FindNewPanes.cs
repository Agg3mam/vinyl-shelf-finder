using System.ComponentModel;
using System.Globalization;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Windows.System;
using VinylShelfFinder.Core;
using VinylShelfFinder.UI;

namespace VinylShelfFinder.Views;

/// <summary>Fælles småting til "Find nye plader" (FindNewPrice på Mac).</summary>
public static class FindNewPanes
{
    private static readonly CultureInfo Da = CultureInfo.GetCultureInfo("da-DK");

    public static string Number(int n) => n.ToString("N0", Da);

    /// <summary>"189 kr." / "25,50 €"</summary>
    public static string PriceText(MarketInfo m)
    {
        if (m.LowestPrice is not double p) return "–";
        var digits = Math.Round(p) == p ? "N0" : "N2";
        return m.Currency switch
        {
            "DKK" => $"{p.ToString(digits, Da)} kr.",
            "EUR" => $"{p.ToString(digits, Da)} €",
            "USD" => $"${p.ToString(digits, Da)}",
            "GBP" => $"£{p.ToString(digits, Da)}",
            _ => $"{p.ToString(digits, Da)} {m.Currency}",
        };
    }

    public static string ForSale(int n) => $"{Number(n)} til salg";

    public static Border Badge(string text, string glyph) => new()
    {
        CornerRadius = new CornerRadius(10),
        Padding = new Thickness(7, 1, 7, 2),
        Background = Ui.AccentTint(0.15),
        Child = Ui.Label(glyph, text, "CaptionTextBlockStyle", Ui.Accent, 11),
    };
}

/// <summary>Midterkolonnen: søgning i hele Discogs' katalog (FindNewSearchView).</summary>
public sealed class FindNewSearchPane : IPane
{
    private readonly AppModel _model;
    private readonly FindNewModel _shop;
    private readonly Grid _root = new();
    private readonly TextBox _box = new() { PlaceholderText = "Kunstner eller album på Discogs …", FontSize = 16 };
    private readonly SelectorBar _format = new() { Margin = new Thickness(8, 0, 8, 4) };
    private readonly ListView _list = new() { SelectionMode = ListViewSelectionMode.Single };
    private readonly Grid _state = new();
    private bool _building;

    public FrameworkElement View => _root;

    public FindNewSearchPane(AppModel model, FindNewModel shop)
    {
        _model = model;
        _shop = shop;
        _root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        _root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        _root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });

        if (!shop.IsAvailable)
        {
            var p = Ui.VStack(12, Ui.Empty(Ui.Glyph.Bag, "Find nye plader", model.IsDemo
                ? "Her kan du søge i hele Discogs' katalog, se priser og købe plader. Demo-tilstanden har ingen forbindelse til Discogs, så funktionen er ikke med her."
                : "Her kan du søge i hele Discogs' katalog, se priser og købe plader. Det kræver, at appen er forbundet til Discogs."));
            p.VerticalAlignment = VerticalAlignment.Center;
            Grid.SetRowSpan(p, 3);
            _root.Children.Add(p);
            return;
        }

        _box.Text = shop.Query;
        _box.Margin = new Thickness(8, 12, 8, 8);
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(_box, "Søg i Discogs' katalog");
        _box.TextChanged += (_, _) => { if (_shop.Query != _box.Text) _shop.Query = _box.Text; };
        _box.PreviewKeyDown += OnKey;
        _root.Children.Add(_box);

        foreach (var f in FormatFilterExtensions.All)
        {
            var item = new SelectorBarItem { Text = f.Label(), Tag = f };
            _format.Items.Add(item);
            if (f == shop.Format) _format.SelectedItem = item;
        }
        ToolTipService.SetToolTip(_format, "Vis kun album og udgaver i dette format");
        _format.SelectionChanged += (_, _) => { if (_format.SelectedItem?.Tag is FormatFilter f) _shop.Format = f; };
        Grid.SetRow(_format, 1);
        _root.Children.Add(_format);

        _list.SelectionChanged += (_, _) =>
        {
            if (_building) return;
            if (_list.SelectedItem is FrameworkElement { Tag: DiscogsAlbum a }) _shop.SelectedKey = a.Key();
        };
        _list.KeyDown += (_, e) => { if (e.Key == VirtualKey.Enter) { _shop.ChooseHighlighted(); e.Handled = true; } };
        Grid.SetRow(_list, 2);
        _root.Children.Add(_list);
        Grid.SetRow(_state, 2);
        _root.Children.Add(_state);

        _shop.PropertyChanged += OnShopChanged;
        _root.Unloaded += (_, _) => _shop.PropertyChanged -= OnShopChanged;
        _root.Loaded += (_, _) => _box.Focus(FocusState.Programmatic);
        Rebuild();
    }

    private void OnShopChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName is nameof(FindNewModel.Albums) or nameof(FindNewModel.SearchPhase) or nameof(FindNewModel.LoadingMore))
            Rebuild();
        else if (e.PropertyName == nameof(FindNewModel.SelectedKey))
            SyncSelection();
    }

    public void OnModelChanged(string? property)
    {
        if (property == nameof(AppModel.Library)) Rebuild();
    }

    private void OnKey(object sender, KeyRoutedEventArgs e)
    {
        switch (e.Key)
        {
            case VirtualKey.Down: _shop.MoveSelection(1); e.Handled = true; break;
            case VirtualKey.Up: _shop.MoveSelection(-1); e.Handled = true; break;
            case VirtualKey.Enter: _shop.ChooseHighlighted(); e.Handled = true; break;
            case VirtualKey.Escape: if (_box.Text.Length > 0) { _box.Text = ""; e.Handled = true; } break;
        }
    }

    private void Rebuild()
    {
        _building = true;
        _state.Children.Clear();
        _list.Items.Clear();
        var q = _shop.Query.Trim();
        if (_shop.SearchPhase == LoadPhase.Failed)
            State(Ui.Empty("", "Discogs svarer ikke lige nu", _shop.SearchError ?? ""), Ui.Btn("Prøv igen", (_, _) => _shop.RetrySearch()));
        else if (q.Length < FindNewModel.MinimumQueryLength)
            State(Ui.Empty(Ui.Glyph.Bag, "Søg i hele Discogs", "Skriv kunstner eller album. Du ser album fra hele Discogs' katalog, også dem du ikke ejer. ↑↓ vælger et album."));
        else if (_shop.Albums.Count == 0 && _shop.SearchPhase == LoadPhase.Loaded)
            State(Ui.Empty(Ui.Glyph.Search, "Ingen album fundet", $"Discogs har ikke noget, der matcher “{_shop.ResultQuery}”. Prøv med færre ord eller en anden stavemåde."));
        else if (_shop.Albums.Count == 0)
            State(Ui.HStack(8, new ProgressRing { IsActive = true, Width = 20, Height = 20 }, Ui.Text("Søger på Discogs …", color: Ui.Secondary)));
        else
        {
            _list.Visibility = Visibility.Visible;
            foreach (var a in _shop.Albums) _list.Items.Add(Row(a));
            if (_shop.HasMore)
            {
                var more = Ui.Btn(_shop.LoadingMore ? "Henter flere …" : "Vis flere", (_, _) => _shop.LoadMore(), Ui.Glyph.ChevronDown);
                more.IsEnabled = !_shop.LoadingMore;
                more.HorizontalAlignment = HorizontalAlignment.Stretch;
                more.Margin = new Thickness(0, 4, 0, 8);
                _list.Items.Add(more);
            }
            SyncSelection();
        }
        _building = false;
    }

    private void State(FrameworkElement view, FrameworkElement? action = null)
    {
        _list.Visibility = Visibility.Collapsed;
        var p = Ui.VStack(12, view);
        if (action is not null) { action.HorizontalAlignment = HorizontalAlignment.Center; p.Children.Add(action); }
        p.HorizontalAlignment = HorizontalAlignment.Center;
        p.VerticalAlignment = VerticalAlignment.Center;
        _state.Children.Add(p);
    }

    private void SyncSelection()
    {
        bool was = _building;
        _building = true;
        var item = _list.Items.OfType<FrameworkElement>().FirstOrDefault(r => r.Tag is DiscogsAlbum a && a.Key() == _shop.SelectedKey);
        _list.SelectedItem = item;
        if (item is not null) _list.ScrollIntoView(item);
        _building = was;
    }

    private FrameworkElement Row(DiscogsAlbum a)
    {
        var g = new Grid { ColumnSpacing = 10, Padding = new Thickness(0, 4, 0, 4), Tag = a };
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        g.Children.Add(Ui.Cover(a.AsRelease(), 38));
        var t = new StackPanel { Spacing = 2 };
        var name = new TextBlock { TextWrapping = TextWrapping.WrapWholeWords, MaxLines = 2, TextTrimming = TextTrimming.CharacterEllipsis };
        name.Inlines.Add(new Microsoft.UI.Xaml.Documents.Run { Text = a.Artist, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold });
        name.Inlines.Add(new Microsoft.UI.Xaml.Documents.Run { Text = " – ", Foreground = Ui.Secondary });
        name.Inlines.Add(new Microsoft.UI.Xaml.Documents.Run { Text = a.Title });
        t.Children.Add(name);
        if (a.DetailLine().Length > 0) t.Children.Add(Ui.Text(a.DetailLine(), "CaptionTextBlockStyle", Ui.Secondary, wrap: false, maxLines: 1));
        bool owned = _shop.Owns(a);
        if (owned || a.InWantlist)
        {
            var badges = Ui.HStack(4);
            if (owned) badges.Children.Add(FindNewPanes.Badge("I din samling", Ui.Glyph.Check));
            if (a.InWantlist) badges.Children.Add(FindNewPanes.Badge("På ønskelisten", Ui.Glyph.Heart));
            t.Children.Add(badges);
        }
        Grid.SetColumn(t, 1);
        g.Children.Add(t);
        return g;
    }
}

/// <summary>Højre kolonne: billigste køb øverst, andre udgaver med pris nedenunder (FindNewDetailColumn).</summary>
public sealed class FindNewDetailPane
{
    private readonly AppModel _model;
    private readonly FindNewModel _shop;
    private readonly IMusicModel _imusic;
    private readonly ScrollViewer _scroll = new() { HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled };
    private (int, bool)? _shownKey;
    private FrameworkElement? _imusicLine;
    private bool _pending;

    public FrameworkElement View => _scroll;

    public FindNewDetailPane(AppModel model, FindNewModel shop, IMusicModel imusic)
    {
        _model = model;
        _shop = shop;
        _imusic = imusic;
        _shop.PropertyChanged += (_, e) =>
        {
            if (e.PropertyName is nameof(FindNewModel.SelectedAlbum) or nameof(FindNewModel.Versions) or nameof(FindNewModel.Price)
                or nameof(FindNewModel.Want) or nameof(FindNewModel.ShowAllVersions) or nameof(FindNewModel.Format))
                Schedule();
        };
        Rebuild();
    }

    public void OnModelChanged(string? property)
    {
        // Valutaskift: hent priserne igen i den nye valuta.
        if (property == nameof(AppModel.Currency)) { _shop.LoadCandidatePrices(); Schedule(); }
        else if (property is nameof(AppModel.Library) or nameof(AppModel.HasToken)) Schedule();
    }

    /// <summary>Mange priser kommer næsten samtidig: byg kun én gang pr. omgang.</summary>
    private void Schedule()
    {
        if (_pending) return;
        _pending = true;
        _scroll.DispatcherQueue.TryEnqueue(() => { _pending = false; Rebuild(); });
    }

    private void Rebuild()
    {
        if (!_shop.IsAvailable)
        {
            _scroll.Content = Ui.Empty(Ui.Glyph.Bag, "Køb via Discogs", "Priser, udgaver og køb vises her, når appen er forbundet til Discogs.");
            return;
        }
        if (_shop.SelectedAlbum is not DiscogsAlbum album)
        {
            _scroll.Content = Ui.Empty(Ui.Glyph.Disc, "Vælg et album", "Vælg et album i listen for at se, hvad det koster.");
            return;
        }
        if (_shownKey != album.Key())
        {
            _shownKey = album.Key();
            _imusicLine = _imusic.OfferLine(album.Barcodes, album.Artist, album.Title, _shop.Format is FormatFilter.Vinyl or FormatFilter.All);
            _scroll.ChangeView(null, 0, null, true);
        }
        if (_imusicLine?.Parent is Panel old) old.Children.Remove(_imusicLine);

        var p = new StackPanel { Spacing = 20, Padding = new Thickness(24), MaxWidth = 640, HorizontalAlignment = HorizontalAlignment.Stretch };
        var card = new StackPanel { Spacing = 16 };
        card.Children.Add(Header(album));
        card.Children.Add(BestBuy(album));
        if (_imusicLine is not null) card.Children.Add(_imusicLine);
        var panel = Ui.Card(card, 20);
        panel.BorderBrush = Ui.AccentTint(0.55);
        panel.Background = Ui.AccentTint(0.07);
        p.Children.Add(panel);
        if (VersionList() is FrameworkElement list) p.Children.Add(list);

        var offers = Ui.Btn(album.IsMaster ? "Se alle tilbud på Discogs" : "Se tilbud på Discogs", (_, _) => _shop.OpenInBrowser(_shop.OffersUrl(album)), Ui.Glyph.OpenInWindow,
            tooltip: album.IsMaster && _shop.Format != FormatFilter.All
                ? $"Åbner Discogs' markedsplads med albummets {_shop.Format.Label()}-udgaver i et vindue her i appen"
                : "Åbner Discogs' markedsplads i et vindue her i appen");
        p.Children.Add(offers);
        p.Children.Add(Ui.Text($"Prisen er det billigste eksemplar til salg lige nu, uanset stand og uden fragt og moms, så Discogs' kurv viser et højere beløb. Billigste køb findes blandt de {FindNewModel.PricedCount} mest udbredte udgaver. Du køber direkte hos Discogs i et vindue her i appen.",
            "CaptionTextBlockStyle", Ui.Tertiary));
        _scroll.Content = p;
    }

    private string FormatText(DiscogsAlbum a)
    {
        if (a.IsMaster) return _shop.Format == FormatFilter.All ? "Alle formater" : _shop.Format.Label();
        var f = string.Join(", ", a.Formats.Take(3));
        return f.Length == 0 ? "Én udgave" : f;
    }

    private FrameworkElement Header(DiscogsAlbum a)
    {
        var g = new Grid { ColumnSpacing = 16 };
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        var cover = Ui.Cover(a.AsRelease(), 96);
        cover.VerticalAlignment = VerticalAlignment.Top;
        g.Children.Add(cover);
        var t = new StackPanel { Spacing = 2 };
        t.Children.Add(Ui.Text(a.Artist, "SubtitleTextBlockStyle", Ui.Secondary));
        t.Children.Add(Ui.Text(a.Title, "TitleTextBlockStyle"));
        t.Children.Add(Ui.Text(string.Join(" · ", new[] { a.Year?.ToString(), FormatText(a) }.OfType<string>()), "BodyTextBlockStyle", Ui.Tertiary, maxLines: 2));
        bool owned = _shop.Owns(a);
        if (owned || a.InWantlist)
        {
            var badges = Ui.HStack(4);
            if (owned) badges.Children.Add(FindNewPanes.Badge("I din samling", Ui.Glyph.Check));
            if (a.InWantlist) badges.Children.Add(FindNewPanes.Badge("På ønskelisten", Ui.Glyph.Heart));
            badges.Margin = new Thickness(0, 4, 0, 0);
            t.Children.Add(badges);
        }
        Grid.SetColumn(t, 1);
        g.Children.Add(t);
        return g;
    }

    private string What => _shop.Format switch
    {
        FormatFilter.Vinyl => "vinyl",
        FormatFilter.Cd => "cd",
        FormatFilter.Cassette => "kassette",
        _ => "udgave",
    };

    private FrameworkElement Loading(string text) =>
        Ui.HStack(8, new ProgressRing { IsActive = true, Width = 16, Height = 16 }, Ui.Text(text, color: Ui.Secondary));

    private FrameworkElement BestBuy(DiscogsAlbum album)
    {
        FrameworkElement content;
        if (_shop.BestBuy is var (version, m))
        {
            bool checking = !_shop.CandidatesPriced;
            var p = new StackPanel { Spacing = 6 };
            var head = Ui.HStack(8, Ui.Text(checking ? $"Billigste {What} indtil videre" : $"Billigste {What} lige nu", "BodyStrongTextBlockStyle", Ui.Secondary, wrap: false));
            if (checking) head.Children.Add(new ProgressRing { IsActive = true, Width = 12, Height = 12 });
            p.Children.Add(head);
            p.Children.Add(Ui.Text(FindNewPanes.PriceText(m), "TitleLargeTextBlockStyle", wrap: false));
            p.Children.Add(Ui.Text(version.Summary().Length == 0 ? "Ukendt udgave" : version.Summary(), color: Ui.Secondary));
            p.Children.Add(Ui.Text($"{FindNewPanes.ForSale(m.NumForSale ?? 0)} · + fragt", "CaptionTextBlockStyle", Ui.Tertiary));
            var buy = Ui.Btn("Køb på Discogs", (_, _) => _shop.OpenInBrowser(DiscogsClient.MarketplaceUrl(version.Id)), Ui.Glyph.Bag, accent: true,
                tooltip: "Åbner Discogs' sælgere af netop denne udgave i et vindue her i appen");
            Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(buy, $"Køb på Discogs: {version.Summary()}, {FindNewPanes.PriceText(m)}");
            p.Children.Add(Ui.HStack(8, buy, WantButton(version.Id, false, $"Lægger netop denne udgave på din ønskeliste på Discogs: {version.Summary()}")));
            if (_shop.Want(version.Id) is { Phase: LoadPhase.Failed, Error: string err })
                p.Children.Add(Ui.Label(Ui.Glyph.Warning, err, "CaptionTextBlockStyle", Ui.Caution));
            content = p;
        }
        else if (_shop.VersionsPhase == LoadPhase.Failed)
            content = RecordParts.Notice(Ui.Glyph.Warning, _shop.VersionsError ?? "", Ui.Btn("Prøv igen", (_, _) => _shop.RetryVersions()));
        else if (_shop.VersionsPhase == LoadPhase.Loaded && _shop.Versions.Count == 0)
            content = Ui.Text(_shop.Format == FormatFilter.All ? "Discogs har ingen udgaver af dette album." : $"Discogs har ingen {_shop.Format.Label()}-udgaver af dette album.", color: Ui.Secondary);
        else if (_shop.VersionsPhase == LoadPhase.Loaded && _shop.CandidatesPriced)
            content = Ui.VStack(6,
                Ui.Text("Ingen af de mest udbredte udgaver er til salg lige nu", "BodyStrongTextBlockStyle"),
                Ui.Text("Måske er der en sjældnere udgave til salg. Se alle tilbud hos Discogs, eller hent prisen på en bestemt udgave nedenfor.", color: Ui.Secondary),
                Ui.Btn("Se alle tilbud på Discogs", (_, _) => _shop.OpenInBrowser(_shop.OffersUrl(album)), Ui.Glyph.Bag, accent: true));
        else
            content = Loading($"Finder den billigste {What} …");
        return new Border { Child = content, Padding = new Thickness(12), CornerRadius = new CornerRadius(12), Background = Ui.ThemeBrush("LayerFillColorDefaultBrush") };
    }

    private Button WantButton(int releaseId, bool iconOnly, string help)
    {
        bool onList = _shop.IsOnWantlist(releaseId);
        bool adding = _shop.Want(releaseId) is { Phase: LoadPhase.Loading };
        var title = adding ? "Tilføjer …" : onList ? "På ønskelisten" : "Ønskeliste";
        var glyph = onList ? "" : "";
        var b = iconOnly ? new Button { Content = Ui.Icon(glyph, 14) } : Ui.Btn(title, (_, _) => { }, glyph);
        b.Click += (_, _) => _shop.AddToWantlist(releaseId);
        b.IsEnabled = !onList && !adding;
        ToolTipService.SetToolTip(b, help);
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(b, onList ? "På ønskelisten" : "Læg på ønskelisten");
        return b;
    }

    private FrameworkElement? VersionList()
    {
        var listed = _shop.ListedCandidates;
        if (_shop.VersionsPhase != LoadPhase.Loaded || (listed.Count == 0 && _shop.OtherVersions.Count == 0)) return null;
        var p = new StackPanel();
        if (listed.Count > 0)
        {
            var h = Ui.Text("Andre udgaver", "BodyStrongTextBlockStyle");
            h.Margin = new Thickness(12, 12, 12, 4);
            p.Children.Add(h);
            foreach (var v in listed) p.Children.Add(PricedRow(v, autoPriced: true));
        }
        if (_shop.OtherVersions.Count > 0 || _shop.VersionsHasMore)
        {
            int total = Math.Max(_shop.VersionsTotal, _shop.Versions.Count);
            var toggle = new Button
            {
                Content = Ui.Label(_shop.ShowAllVersions ? "" : "", _shop.ShowAllVersions ? "Skjul de andre udgaver" : $"Vis alle {FindNewPanes.Number(total)} udgaver", color: Ui.Secondary, iconSize: 10),
                Background = null,
                BorderThickness = new Thickness(0),
                Margin = new Thickness(4),
            };
            toggle.Click += (_, _) => _shop.ShowAllVersions = !_shop.ShowAllVersions;
            p.Children.Add(toggle);
            if (_shop.ShowAllVersions)
            {
                foreach (var v in _shop.OtherVersions) p.Children.Add(PricedRow(v, autoPriced: false));
                if (_shop.VersionsHasMore)
                {
                    var more = Ui.Btn(_shop.LoadingMoreVersions ? "Henter flere …" : "Vis flere udgaver", (_, _) => _shop.LoadMoreVersions(), Ui.Glyph.ChevronDown);
                    more.IsEnabled = !_shop.LoadingMoreVersions;
                    more.Margin = new Thickness(12);
                    p.Children.Add(more);
                }
            }
        }
        return new Border { Child = p, CornerRadius = new CornerRadius(10), Background = Ui.Subtle };
    }

    /// <summary>Én udgave: år · land, label og format til venstre; pris, "Køb" og ♡ til højre.</summary>
    private FrameworkElement PricedRow(DiscogsVersion v, bool autoPriced)
    {
        var g = new Grid { ColumnSpacing = 8, Padding = new Thickness(12, 6, 12, 6) };
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var left = new StackPanel { Spacing = 1 };
        var top = Ui.HStack(6, Ui.Text(v.YearCountry().Length == 0 ? "Ukendt år" : v.YearCountry(), "BodyStrongTextBlockStyle", wrap: false));
        if (_shop.Owns(v)) top.Children.Add(FindNewPanes.Badge("I samlingen", Ui.Glyph.Check));
        left.Children.Add(top);
        left.Children.Add(Ui.Text(v.DetailLine(), "CaptionTextBlockStyle", Ui.Secondary, wrap: false, maxLines: 1));
        ToolTipService.SetToolTip(left, v.Summary());
        g.Children.Add(left);

        FrameworkElement price;
        switch (_shop.Price(v.Id))
        {
            case { Phase: LoadPhase.Loaded, Market: MarketInfo m }:
                if (m.LowestPrice is not null && (m.NumForSale ?? 0) > 0)
                {
                    var pr = new StackPanel { HorizontalAlignment = HorizontalAlignment.Right };
                    var a = Ui.Text(FindNewPanes.PriceText(m), "BodyStrongTextBlockStyle", wrap: false);
                    a.HorizontalAlignment = HorizontalAlignment.Right;
                    var b = Ui.Text(FindNewPanes.ForSale(m.NumForSale ?? 0), "CaptionTextBlockStyle", Ui.Tertiary, wrap: false);
                    b.HorizontalAlignment = HorizontalAlignment.Right;
                    pr.Children.Add(a);
                    pr.Children.Add(b);
                    price = pr;
                }
                else price = Ui.Text("Ikke til salg", color: Ui.Tertiary, wrap: false);
                break;
            case { Phase: LoadPhase.Failed, Error: var err }:
                var retry = Ui.Btn("Prøv igen", (_, _) => _shop.LoadPrice(v.Id), tooltip: $"Prisen kunne ikke hentes: {err}");
                price = retry;
                break;
            case { Phase: LoadPhase.Loading }:
                price = new ProgressRing { IsActive = true, Width = 16, Height = 16 };
                break;
            default:
                price = autoPriced ? new ProgressRing { IsActive = true, Width = 16, Height = 16 } : Ui.Btn("Hent pris", (_, _) => _shop.LoadPrice(v.Id));
                break;
        }
        price.VerticalAlignment = VerticalAlignment.Center;
        Grid.SetColumn(price, 1);
        g.Children.Add(price);
        var buy = Ui.Btn("Køb", (_, _) => _shop.OpenInBrowser(DiscogsClient.MarketplaceUrl(v.Id)), tooltip: "Åbner Discogs' sælgere af netop denne udgave i et vindue her i appen");
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(buy, $"Køb {v.Summary()}");
        buy.VerticalAlignment = VerticalAlignment.Center;
        Grid.SetColumn(buy, 2);
        g.Children.Add(buy);
        var want = WantButton(v.Id, true, _shop.IsOnWantlist(v.Id) ? "På din ønskeliste på Discogs" : "Læg denne udgave på din ønskeliste på Discogs");
        want.VerticalAlignment = VerticalAlignment.Center;
        Grid.SetColumn(want, 3);
        g.Children.Add(want);
        return g;
    }
}
