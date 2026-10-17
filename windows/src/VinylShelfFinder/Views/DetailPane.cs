using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using VinylShelfFinder.Core;
using VinylShelfFinder.UI;

namespace VinylShelfFinder.Views;

/// <summary>
/// Plade-detaljen i højre kolonne (RecordDetailView.swift): cover og titel, beskeder, placering,
/// naboer, knapperne "Rediger placering", "Spillet" og "Find i reolen", og sortering.
/// Bygges forfra, når valget eller data ændrer sig.
/// </summary>
public sealed class DetailPane
{
    private readonly AppModel _model;
    private readonly Grid _root = new();
    private readonly ScrollViewer _scroll = new() { HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled };
    private readonly InfoBar _toast = new()
    {
        IsClosable = false,
        Severity = InfoBarSeverity.Success,
        HorizontalAlignment = HorizontalAlignment.Center,
        VerticalAlignment = VerticalAlignment.Bottom,
        Margin = new Thickness(0, 0, 0, 16),
    };
    private long? _shownCopy;
    private bool _sortOpen;
    private int _toastToken;

    public FrameworkElement View => _root;

    public DetailPane(AppModel model)
    {
        _model = model;
        _root.Children.Add(_scroll);
        _root.Children.Add(_toast);
        Rebuild();
    }

    public void OnModelChanged(string? property)
    {
        switch (property)
        {
            case nameof(AppModel.Selection):
            case nameof(AppModel.Library):
            case nameof(AppModel.NeighborCount):
            case nameof(AppModel.Stats):
            case nameof(AppModel.Rules):
            case nameof(AppModel.Market):
                Rebuild();
                break;
        }
    }

    private void Rebuild()
    {
        var id = _model.Selection;
        if (id != _shownCopy)
        {
            _sortOpen = false;
            _toast.IsOpen = false;
            _scroll.ChangeView(null, 0, null, true);
        }
        _shownCopy = id;
        if (id is not long copyId || _model.Library.NeighborsOf(copyId, _model.NeighborCount) is not Neighbors n)
        {
            _scroll.Content = Ui.Empty(Ui.Glyph.Disc, "Ingen plade valgt", "Søg eller vælg en plade i listen.");
            return;
        }
        _scroll.Content = Page(n);
    }

    private FrameworkElement Page(Neighbors n)
    {
        var it = n.Target;
        var p = new StackPanel { Spacing = 20, Padding = new Thickness(24), MaxWidth = 640, HorizontalAlignment = HorizontalAlignment.Stretch };
        p.Children.Add(Header(it));
        foreach (var notice in Notices(it)) p.Children.Add(notice);
        if (n.Location is Location loc && n.Position is int pos)
        {
            bool away = !it.Copy.Status.IsOnShelf();
            p.Children.Add(RecordParts.LocationPanel(away ? "Plejer at stå i" : "Står i", loc, pos, n.SectionCount,
                $"{(away ? "Plads" : Cap(loc.Medium.Singular()))} {pos} af {n.SectionCount} fra venstre"));
            p.Children.Add(Neighbors(n));
            p.Children.Add(Actions(it));
        }
        else
        {
            p.Children.Add(UnplacedPanel(it));
        }
        p.Children.Add(SortEditor(it));

        var link = new HyperlinkButton
        {
            Content = Ui.Text($"Se pladen på Discogs (#{it.Release.Id})", "CaptionTextBlockStyle", Ui.Tertiary),
            NavigateUri = it.Release.DiscogsUrl,
            Padding = new Thickness(0),
        };
        p.Children.Add(link);
        return p;
    }

    private static string Cap(string s) => s.Length == 0 ? s : char.ToUpper(s[0]) + s[1..];

    private FrameworkElement Header(RecordItem it)
    {
        var grid = new Grid { ColumnSpacing = 20 };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        var cover = Ui.Cover(it.Release, 132);
        cover.VerticalAlignment = VerticalAlignment.Top;
        grid.Children.Add(cover);
        var text = new StackPanel { Spacing = 2 };
        text.Children.Add(Ui.Text(it.Artist, "SubtitleTextBlockStyle", Ui.Secondary));
        text.Children.Add(Ui.Text(it.Title, "TitleTextBlockStyle"));
        text.Children.Add(Ui.Text(it.DetailLine, "BodyTextBlockStyle", Ui.Tertiary, maxLines: 2));
        if (_model.Market.TryGetValue(it.Release.Id, out var m)) text.Children.Add(MarketLine(m));
        text.Children.Add(Ui.Text(RecordParts.PlayCountText(_model, it.Id), "CaptionTextBlockStyle", Ui.Secondary));
        var status = StatusButton(it);
        status.Margin = new Thickness(-8, 4, 0, 0);
        text.Children.Add(status);
        Grid.SetColumn(text, 1);
        grid.Children.Add(text);
        return grid;
    }

    /// <summary>"Fra 120,00 kr. · 4 til salg · 300 har / 80 ønsker" (MarketLine på Mac).</summary>
    private static FrameworkElement MarketLine(MarketInfo m)
    {
        var parts = new List<string> { m.LowestPrice is double p ? $"Fra {ValuePane.Money(p, m.Currency)}" : "Ikke til salg lige nu" };
        if (m.NumForSale is int n) parts.Add($"{n} til salg");
        if (m.Have is int h && m.Want is int w) parts.Add($"{h} har / {w} ønsker");
        var l = Ui.Label("", string.Join(" · ", parts), "CaptionTextBlockStyle", Ui.Secondary, 12);
        ToolTipService.SetToolTip(l, $"Discogs-markedsdata hentet {DanishDate.DateTime(m.FetchedAt)}");
        return l;
    }

    /// <summary>Statusmenuen under titlen (StatusMenu på Mac), med valget af hylde (plader/cd'er).</summary>
    private DropDownButton StatusButton(RecordItem it)
    {
        bool unplaced = it.Copy.Status == CopyStatus.Home && !_model.Library.LocationOfCopy.ContainsKey(it.Id);
        var label = unplaced
            ? Ui.Label(Ui.Glyph.Dashed, "Ikke placeret", "CaptionTextBlockStyle")
            : Ui.Label(it.Copy.Status.StatusGlyph(), it.Copy.Status.Label(), "CaptionTextBlockStyle");
        var menu = new MenuFlyout();
        foreach (var s in RecordRow.StatusChoices(_model, it.Id)) menu.Items.Add(s);
        menu.Items.Add(new MenuFlyoutSeparator());
        foreach (var m in RecordRow.MediumChoices(_model, it.Id)) menu.Items.Add(m);
        return new DropDownButton { Content = label, Flyout = menu, Background = null, BorderThickness = new Thickness(0) };
    }

    private IEnumerable<UIElement> Notices(RecordItem it)
    {
        if (!it.Copy.InDiscogs)
        {
            var actions = new List<UIElement>();
            if (it.Copy.RemovedFromDiscogsAt is not null)
                actions.Add(Ui.Btn("Behold i reolen", (_, _) => _model.KeepLocalOnly(it.Id)));
            actions.Add(Ui.Btn("Slet lokalt…", async (s, _) =>
            {
                var d = new ContentDialog
                {
                    XamlRoot = ((FrameworkElement)s).XamlRoot,
                    Title = $"Slet {it.FullName} fra den lokale samling?",
                    Content = "Pladens fysiske placering fjernes. Naboerne rykker automatisk sammen.",
                    PrimaryButtonText = "Slet plade og placering",
                    CloseButtonText = "Annullér",
                    DefaultButton = ContentDialogButton.Close,
                };
                if (await d.ShowAsync() == ContentDialogResult.Primary) _model.DeleteCopy(it.Id);
            }));
            yield return RecordParts.Notice(Ui.Glyph.Warning,
                "Denne plade er ikke længere i din Discogs Collection. Den fysiske placering er bevaret.", actions.ToArray());
        }
        if (it.AwayMessage() is string away)
        {
            bool placed = _model.Library.LocationOfCopy.ContainsKey(it.Id);
            var back = Ui.Btn("Sæt tilbage på plads…", (_, _) => _model.StartReturn(it.Id),
                tooltip: placed ? "Vis præcis, hvor pladen skal stå" : "Find en plads til pladen i reolen");
            yield return RecordParts.Notice(it.Copy.Status.StatusGlyph(),
                placed ? $"{away}. Appen husker dens plads, så du kan sætte den tilbage samme sted." : $"{away}.", back);
        }
    }

    private FrameworkElement Neighbors(Neighbors n)
    {
        var p = new StackPanel { Spacing = 6 };
        var section = n.Location?.Section ?? "";
        if (n.Before.Count > 0)
            p.Children.Add(Ui.Eyebrow($"← {(n.Before.Count > 1 ? $"{n.Before.Count} før" : "Lige før")}"));
        if (n.ReachedSectionStart)
            p.Children.Add(RecordParts.SectionEdgeNote($"Starten af sektion {section}",
                n.PreviousSection is var (pl, last)
                    ? last is RecordItem l ? $"Forrige sektion ({pl.Name}) slutter med {l.FullName}" : $"Forrige sektion ({pl.Name}) er tom"
                    : null));
        // Fjerneste først, så listen læses i fysisk rækkefølge (venstre → højre).
        foreach (var it in n.Before.Reverse()) p.Children.Add(RecordParts.NeighborRow(_model, it));
        foreach (var it in n.AbsentBetweenBefore.Reverse()) p.Children.Add(RecordParts.AbsentRow(it));
        var target = RecordParts.TargetCard(n.Target);
        target.Margin = new Thickness(0, 2, 0, 2);
        p.Children.Add(target);
        foreach (var it in n.AbsentBetweenAfter) p.Children.Add(RecordParts.AbsentRow(it));
        foreach (var it in n.After) p.Children.Add(RecordParts.NeighborRow(_model, it));
        if (n.ReachedSectionEnd)
            p.Children.Add(RecordParts.SectionEdgeNote($"Slutningen af sektion {section}",
                n.NextSection is var (nl, first)
                    ? first is RecordItem f ? $"Næste sektion ({nl.Name}) starter med {f.FullName}" : $"Næste sektion ({nl.Name}) er tom"
                    : null));
        if (n.After.Count > 0)
            p.Children.Add(Ui.Eyebrow($"{(n.After.Count > 1 ? $"{n.After.Count} efter" : "Lige efter")} →"));
        return p;
    }

    private FrameworkElement Actions(RecordItem it)
    {
        var buttons = Ui.HStack(8,
            Ui.Btn("Rediger placering", (_, _) => _model.MoveCopy = it.Id, Ui.Glyph.Swap, tooltip: "Flyt pladen (Ctrl+Skift+M)"),
            Ui.Btn("Spillet", (_, _) => LogPlay(it.Id), Ui.Glyph.Play, tooltip: "Registrér i lyttelog (Ctrl+L)"),
            Ui.Btn("Find i reolen", (_, _) => _model.FindModeCopy = it.Id, Ui.Glyph.Pin, accent: true, tooltip: "Find i reolen (Enter)"));

        var picker = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        picker.Children.Add(new TextBlock { Text = "Naboer", VerticalAlignment = VerticalAlignment.Center, Foreground = Ui.Secondary });
        var seg = new ComboBox { ItemsSource = new[] { 1, 3, 5 }, SelectedItem = _model.NeighborCount is 1 or 3 or 5 ? _model.NeighborCount : 1 };
        ToolTipService.SetToolTip(seg, "Antal plader før/efter");
        seg.SelectionChanged += (_, _) => { if (seg.SelectedItem is int v) _model.NeighborCount = v; };
        picker.Children.Add(seg);

        var wrap = new Grid { ColumnSpacing = 8, RowSpacing = 8 };
        wrap.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        wrap.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        wrap.Children.Add(buttons);
        Grid.SetColumn(picker, 1);
        wrap.Children.Add(picker);
        return wrap;
    }

    /// <summary>"Spillet": registrér og vis en kort bekræftelse nederst (PlayedToast på Mac).</summary>
    public void LogPlay(long copyId)
    {
        bool logged = _model.LogPlay(copyId);
        _toast.Title = logged ? "Registreret som spillet" : "Allerede registreret for lidt siden";
        _toast.Severity = logged ? InfoBarSeverity.Success : InfoBarSeverity.Informational;
        _toast.IsOpen = true;
        int token = ++_toastToken;
        var timer = _root.DispatcherQueue.CreateTimer();
        timer.Interval = TimeSpan.FromSeconds(2.2);
        timer.IsRepeating = false;
        timer.Tick += (_, _) => { if (token == _toastToken) _toast.IsOpen = false; };
        timer.Start();
    }

    private FrameworkElement UnplacedPanel(RecordItem it)
    {
        var p = new StackPanel { Spacing = 10 };
        p.Children.Add(Ui.Label(Ui.Glyph.Dashed, "Ikke placeret i reolen endnu", "BodyStrongTextBlockStyle", Ui.Caution));
        var lib = _model.Library;
        if (lib.SuggestPlacement(it.Id, _model.Rules) is PlacementSuggestion s && lib.LocationById(s.LocationId) is Location loc)
        {
            p.Children.Add(Ui.Text($"Foreslået plads: {loc.Name}, mellem"));
            p.Children.Add(s.Before is long b && lib.Item(b) is RecordItem bi
                ? RecordParts.NeighborRow(_model, bi) : RecordParts.SectionEdgeNote("Starten af sektionen", null));
            p.Children.Add(RecordParts.TargetCard(it));
            p.Children.Add(s.After is long a && lib.Item(a) is RecordItem ai
                ? RecordParts.NeighborRow(_model, ai) : RecordParts.SectionEdgeNote("Slutningen af sektionen", null));
            p.Children.Add(Ui.HStack(8,
                Ui.Btn("Placér her", (_, _) => _model.Move(it.Id, s.LocationId, s.Index), accent: true),
                Ui.Btn("Vælg anden placering…", (_, _) => _model.MoveCopy = it.Id)));
        }
        else
        {
            p.Children.Add(Ui.Text("Opret først reoler og sektioner."));
        }
        return p;
    }

    /// <summary>"Sortering": hvordan pladen sorteres, og regler for kunstner og denne plade.</summary>
    private FrameworkElement SortEditor(RecordItem it)
    {
        var rules = _model.Rules;
        var p = new StackPanel { Spacing = 10 };
        p.Children.Add(Ui.Text($"Sorteres som: {rules.SortArtist(it.Artist, it.Copy.SortArtistOverride)} / {rules.SortTitle(it.Title, it.Copy.SortTitleOverride)}"));
        var artistRule = new TextBox
        {
            Header = $"Kunstnerregel for alle “{it.Artist}”",
            PlaceholderText = "fx Dylan, Bob",
            Text = rules.ArtistOverrides.TryGetValue(it.Artist, out var ar) ? ar : "",
        };
        var artist = new TextBox { Header = "Kun denne plade – kunstner", PlaceholderText = "(standard)", Text = it.Copy.SortArtistOverride ?? "" };
        var title = new TextBox { Header = "Kun denne plade – titel", PlaceholderText = "(standard)", Text = it.Copy.SortTitleOverride ?? "" };
        p.Children.Add(artistRule);
        p.Children.Add(artist);
        p.Children.Add(title);
        var save = Ui.Btn("Gem sortering", (_, _) =>
        {
            var r = _model.Rules.Clone();
            if (artistRule.Text.Trim().Length == 0) r.ArtistOverrides.Remove(it.Artist);
            else r.ArtistOverrides[it.Artist] = artistRule.Text.Trim();
            _model.UpdateRules(r);
            _model.SetSortOverrides(it.Id, artist.Text, title.Text);
        });
        save.HorizontalAlignment = HorizontalAlignment.Right;
        p.Children.Add(save);
        p.Children.Add(Ui.Text("Påvirker kun forslag til nye plader. Den fysiske rækkefølge ændres ikke – flyt selv pladen, hvis den skal stå et andet sted.",
            "CaptionTextBlockStyle", Ui.Secondary));
        var expander = new Expander
        {
            Header = "Sortering",
            Content = p,
            IsExpanded = _sortOpen,
            HorizontalAlignment = HorizontalAlignment.Stretch,
            HorizontalContentAlignment = HorizontalAlignment.Stretch,
        };
        expander.Expanding += (_, _) => _sortOpen = true;
        expander.Collapsed += (_, _) => _sortOpen = false;
        return expander;
    }
}
