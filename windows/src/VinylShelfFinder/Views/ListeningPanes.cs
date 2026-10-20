using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using VinylShelfFinder.Core;
using VinylShelfFinder.UI;

namespace VinylShelfFinder.Views;

/// <summary>
/// "Hvad skal jeg høre?" (ListenView i ListeningViews.swift): filtre, "Giv mig en plade" og én
/// kompakt linje med forslaget. Selve pladen vises i højre kolonne, fordi forslaget også vælges.
/// </summary>
public sealed class ListenPane : IPane
{
    private readonly AppModel _model;
    private readonly ScrollViewer _scroll = new() { HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled };
    private bool _building;

    public FrameworkElement View => _scroll;

    public ListenPane(AppModel model)
    {
        _model = model;
        // Højre kolonne skal vise det samme forslag som midterkolonnen.
        if (model.CurrentPick is long p && model.Library.Item(p) is not null && model.ListenCandidates.Count > 0) model.Selection = p;
        Rebuild();
    }

    public void OnModelChanged(string? property)
    {
        if (property is nameof(AppModel.Library) or nameof(AppModel.Stats) or nameof(AppModel.CurrentPick) or nameof(AppModel.ListenFilter)
            or nameof(AppModel.WheelSpinning))
            Rebuild();
    }

    private void Rebuild()
    {
        _building = true;
        var items = _model.Library.AllItems.ToList();
        var f = _model.ListenFilter;
        var candidates = _model.ListenCandidates;
        var p = new StackPanel { Spacing = 14, Padding = new Thickness(20) };
        p.Children.Add(Ui.Text("Hvad skal jeg høre?", "TitleTextBlockStyle"));

        var fresh = new ComboBox { Header = "Hvilke", HorizontalAlignment = HorizontalAlignment.Stretch };
        foreach (var fr in Enum.GetValues<Freshness>()) fresh.Items.Add(fr.Label());
        fresh.SelectedIndex = (int)f.Freshness;
        fresh.SelectionChanged += (_, _) => { if (!_building && fresh.SelectedIndex >= 0) _model.ListenFilter = _model.ListenFilter with { Freshness = (Freshness)fresh.SelectedIndex }; };
        p.Children.Add(fresh);

        var genres = ListenPicker.Genres(items);
        if (genres.Count > 0)
        {
            var genre = new ComboBox { Header = "Genre", HorizontalAlignment = HorizontalAlignment.Stretch };
            genre.Items.Add("Alle genrer");
            foreach (var g in genres) genre.Items.Add(g);
            genre.SelectedIndex = f.Genre is string sg ? genres.IndexOf(sg) + 1 : 0;
            genre.SelectionChanged += (_, _) =>
            {
                if (_building || genre.SelectedIndex < 0) return;
                _model.ListenFilter = _model.ListenFilter with { Genre = genre.SelectedIndex == 0 ? null : genres[genre.SelectedIndex - 1] };
            };
            p.Children.Add(genre);
        }

        var decades = ListenPicker.Decades(items);
        var decade = new ComboBox { Header = "Årti", HorizontalAlignment = HorizontalAlignment.Stretch };
        decade.Items.Add("Alle årtier");
        foreach (var d in decades) decade.Items.Add($"{d}'erne");
        decade.SelectedIndex = f.Decade is int sd ? decades.IndexOf(sd) + 1 : 0;
        decade.SelectionChanged += (_, _) =>
        {
            if (_building || decade.SelectedIndex < 0) return;
            _model.ListenFilter = _model.ListenFilter with { Decade = decade.SelectedIndex == 0 ? null : decades[decade.SelectedIndex - 1] };
        };
        p.Children.Add(decade);

        var pick = Ui.Btn("Giv mig en plade", (_, _) => _model.PickRecord(), Ui.Glyph.Shuffle, accent: true, tooltip: "Giv mig en plade (mellemrum)");
        pick.HorizontalAlignment = HorizontalAlignment.Stretch;
        pick.IsEnabled = candidates.Count > 0;
        p.Children.Add(pick);

        if (candidates.Count == 0)
            p.Children.Add(Ui.Label(Ui.Glyph.Info, NoMatchMessage(items), color: Ui.Secondary));
        else
            p.Children.Add(Ui.Text($"{_model.Medium.Count(candidates.Count)} matcher · {_model.Medium.Plural()} du ikke har hørt længe foreslås oftere · mellemrum = nyt forslag",
                "CaptionTextBlockStyle", Ui.Secondary));

        // Forslaget afsløres først, når lykkehjulet er landet.
        if (candidates.Count > 0 && _model.CurrentPick is long pid && _model.Library.Item(pid) is RecordItem it)
        {
            if (!_model.WheelSpinning) p.Children.Add(PickLine(it));
        }
        else if (candidates.Count > 0)
            p.Children.Add(Ui.Label(Ui.Glyph.Shuffle, "Tryk “Giv mig en plade” (eller mellemrum), så foreslår appen en plade.", color: Ui.Secondary));
        _scroll.Content = p;
        _building = false;
    }

    private FrameworkElement PickLine(RecordItem it)
    {
        var grid = new Grid { ColumnSpacing = 10 };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.Children.Add(Ui.Cover(it.Release, 44));
        var t = new StackPanel { Spacing = 1 };
        t.Children.Add(Ui.Text("Forslag", "CaptionTextBlockStyle", Ui.Secondary));
        t.Children.Add(Ui.Text(it.Title, "BodyStrongTextBlockStyle", maxLines: 2));
        t.Children.Add(Ui.Text(it.Artist, "BodyTextBlockStyle", Ui.Secondary, maxLines: 2));
        Grid.SetColumn(t, 1);
        grid.Children.Add(t);
        if (_model.Library.LocationOf(it.Id) is Location loc)
        {
            var badge = Ui.LocationBadge(loc.ShortName, tooltip: loc.Name);
            Grid.SetColumn(badge, 2);
            grid.Children.Add(badge);
        }
        var b = new Button
        {
            Content = grid,
            HorizontalAlignment = HorizontalAlignment.Stretch,
            HorizontalContentAlignment = HorizontalAlignment.Stretch,
            Padding = new Thickness(8),
            Background = Ui.Subtle,
            BorderThickness = new Thickness(0),
        };
        ToolTipService.SetToolTip(b, "Vis forslaget");
        b.Click += (_, _) => _model.Selection = it.Id;
        return b;
    }

    /// <summary>Ingen plader matcher: sig venligt, hvilket filter man kan løsne.</summary>
    private string NoMatchMessage(List<RecordItem> items)
    {
        var f = _model.ListenFilter;
        bool Matches(ListenFilter g) => ListenPicker.Candidates(items, _model.Library, g, _model.Stats).Count > 0;
        var tips = new List<string>();
        if (f.Genre is not null && Matches(f with { Genre = null })) tips.Add("“Alle genrer”");
        if (f.Decade is not null && Matches(f with { Decade = null })) tips.Add("“Alle årtier”");
        if (f.Freshness != Freshness.Any && Matches(f with { Freshness = Freshness.Any })) tips.Add("“Alle plader”");
        if (tips.Count == 0)
            return Matches(new ListenFilter())
                ? "Ingen plader passer til den kombination. Nulstil et par af filtrene, så kommer der forslag igen."
                : "Der står ingen plader i reolen endnu, som kan foreslås.";
        var list = tips.Count == 1 ? tips[0] : string.Join(", ", tips.Take(tips.Count - 1)) + " eller " + tips[^1];
        return $"Ingen plader passer til filtrene lige nu. Prøv {list} – så er der plader at vælge imellem.";
    }
}

/// <summary>Lyttelog (PlaysView): tal øverst, mest spillet og seneste afspilninger med "Fortryd".</summary>
public sealed class PlaysPane : IPane
{
    private readonly AppModel _model;
    private readonly ListView _list = new() { SelectionMode = ListViewSelectionMode.Single, Padding = new Thickness(0, 0, 0, 12) };
    private readonly List<long?> _rowIds = new();
    private bool _building;

    public FrameworkElement View => _list;

    public PlaysPane(AppModel model)
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
        if (property is nameof(AppModel.Library) or nameof(AppModel.Stats)) Rebuild();
    }

    private void Add(UIElement row, long? id)
    {
        if (row is Control c && id is null) c.IsEnabled = true;
        _list.Items.Add(row);
        _rowIds.Add(id);
    }

    private void Rebuild()
    {
        _building = true;
        _list.Items.Clear();
        _rowIds.Clear();
        var stats = _model.Stats;
        var lib = _model.Library;

        var title = Ui.Text("Lyttelog", "TitleTextBlockStyle");
        title.Margin = new Thickness(4, 12, 4, 4);
        Add(title, null);

        int neverPlayed = lib.AllItems.Count(i => i.Copy.InDiscogs && !stats.Count.ContainsKey(i.Id));
        var grid = new Grid { ColumnSpacing = 16, RowSpacing = 10, Margin = new Thickness(4, 4, 4, 8) };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.RowDefinitions.Add(new RowDefinition());
        grid.RowDefinitions.Add(new RowDefinition());
        (string Label, string Value, string Glyph)[] cells =
        {
            ("Afspilninger", stats.Plays.Count.ToString(), Ui.Glyph.Play),
            ("Sidste 30 dage", stats.PlaysSince(DateTimeOffset.Now.AddDays(-30)).ToString(), Ui.Glyph.Calendar),
            ("Forskellige plader", stats.Count.Count.ToString(), Ui.Glyph.Disc),
            ("Aldrig spillet", neverPlayed.ToString(), Ui.Glyph.Dashed),
        };
        for (int i = 0; i < cells.Length; i++)
        {
            var c = Ui.VStack(2, Ui.Text(cells[i].Value, "SubtitleTextBlockStyle"), Ui.Label(cells[i].Glyph, cells[i].Label, "CaptionTextBlockStyle", Ui.Secondary, 12));
            Grid.SetColumn(c, i % 2);
            Grid.SetRow(c, i / 2);
            grid.Children.Add(c);
        }
        Add(grid, null);

        if (stats.Plays.Count == 0)
        {
            Add(Ui.Label(Ui.Glyph.Check, "Tryk “Spillet” på en plade, når du har hørt den – så bygges loggen op her.", color: Ui.Secondary), null);
            _building = false;
            return;
        }

        Add(Header("Mest spillet"), null);
        foreach (var (copyId, count) in stats.MostPlayed(10))
        {
            if (lib.Item(copyId) is not RecordItem it) continue;
            var row = new Grid { ColumnSpacing = 8 };
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            row.Children.Add(RecordRow.Build(_model, it));
            var n = Ui.Text($"{count}×", "BodyStrongTextBlockStyle", wrap: false);
            n.VerticalAlignment = VerticalAlignment.Center;
            Grid.SetColumn(n, 1);
            row.Children.Add(n);
            Add(row, it.Id);
        }

        Add(Header("Seneste"), null);
        foreach (var play in stats.Plays.Take(50))
        {
            if (lib.Item(play.CopyId) is not RecordItem it) continue;
            var row = new Grid { ColumnSpacing = 8, Padding = new Thickness(0, 4, 0, 4) };
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            row.Children.Add(Ui.VStack(1, Ui.Text(it.FullName, maxLines: 2), Ui.Text(DanishDate.DateTime(play.PlayedAt), "CaptionTextBlockStyle", Ui.Secondary)));
            var id = play.Id;
            var undo = Ui.Btn("Fortryd", (_, _) => _model.DeletePlay(id), Ui.Glyph.Undo);
            undo.VerticalAlignment = VerticalAlignment.Center;
            Grid.SetColumn(undo, 1);
            row.Children.Add(undo);
            Add(row, it.Id);
        }
        _building = false;
    }

    private static FrameworkElement Header(string text)
    {
        var t = Ui.Eyebrow(text);
        t.Margin = new Thickness(4, 12, 4, 2);
        return t;
    }
}
