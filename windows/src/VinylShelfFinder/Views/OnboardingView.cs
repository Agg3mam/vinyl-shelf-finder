using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using VinylShelfFinder.Core;
using VinylShelfFinder.UI;

namespace VinylShelfFinder.Views;

/// <summary>
/// "Kom i gang" (OnboardingView.swift): 1) forbind til Discogs, 2) hent samlingen,
/// 3) fortæl hvor reoler og sektioner starter og slutter. Bruges også, når reolen skal laves om.
/// </summary>
public sealed class OnboardingView : IPane
{
    private readonly AppModel _model;
    private readonly ScrollViewer _scroll = new() { HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled };
    private readonly PasswordBox _token = new() { PlaceholderText = "Indsæt dit Discogs-token", MinWidth = 360 };
    private bool _busy;

    // Trin 3: antal sektioner pr. reol og planen (antal plader pr. sektion).
    private List<int> _sectionsPerShelf = new() { 2, 2, 2 };
    private List<LayoutPlanner.SectionPlan> _plan = new();
    private int _lastCount = -1;

    public FrameworkElement View => _scroll;

    public OnboardingView(AppModel model)
    {
        _model = model;
        // Start med den nuværende opdeling, hvis der er en.
        var current = model.Library.Locations.GroupBy(l => l.Shelf).Select(g => g.Count()).Where(c => c > 0).ToList();
        if (current.Count > 0) _sectionsPerShelf = current;
        Redistribute();
        Rebuild();
    }

    public void OnModelChanged(string? property)
    {
        switch (property)
        {
            case nameof(AppModel.Library):
            case nameof(AppModel.HasToken):
            case nameof(AppModel.SyncState):
            case nameof(AppModel.Rules):
            case nameof(AppModel.Medium):
                Rebuild();
                break;
        }
    }

    private List<RecordItem> SortedItems => _model.Rules.Sorted(_model.Library.AllItems.Where(i => i.Copy.InDiscogs)).ToList();

    private void Redistribute()
    {
        _plan = LayoutPlanner.EvenPlan(SortedItems.Count, _sectionsPerShelf);
        _lastCount = SortedItems.Count;
    }

    private void Rebuild()
    {
        if (SortedItems.Count != _lastCount) Redistribute();
        var m = _model.Medium;
        bool step1Done = _model.HasToken || _model.IsDemo;
        bool hasCopies = _model.Library.Copies.Count > 0;

        var p = new StackPanel { Spacing = 20, Padding = new Thickness(32), MaxWidth = 820, HorizontalAlignment = HorizontalAlignment.Stretch };
        var title = new StackPanel { Spacing = 6 };
        title.Children.Add(Ui.Text(m == Medium.Cd ? "Dine cd'er" : "Vinyl Shelf Finder", "TitleLargeTextBlockStyle"));
        title.Children.Add(Ui.Text(m == Medium.Cd
            ? "Cd'erne får deres egne reoler og sektioner. Dine plader og deres placeringer røres ikke."
            : "Find dine plader i reolen. Tre trin, så er du i gang.", "SubtitleTextBlockStyle", Ui.Secondary));
        p.Children.Add(title);

        p.Children.Add(Step(1, "Forbind til Discogs", step1Done, ConnectStep(), enabled: true));
        // Trinnene bliver færdige i rækkefølge: trin 2 krydses aldrig af før trin 1.
        p.Children.Add(Step(2, "Hent din samling fra Discogs", step1Done && hasCopies, ImportStep(), enabled: _model.HasToken || (_model.IsDemo && hasCopies)));
        p.Children.Add(Step(3, "Fortæl hvor reoler og sektioner starter og slutter", false, LayoutStep(), enabled: hasCopies));
        _scroll.Content = p;
    }

    private static FrameworkElement Step(int number, string title, bool done, FrameworkElement content, bool enabled)
    {
        var badge = new Border
        {
            Width = 28,
            Height = 28,
            CornerRadius = new CornerRadius(14),
            Background = done ? new SolidColorBrush(Windows.UI.Color.FromArgb(255, 0x10, 0x7C, 0x10)) : Ui.AccentFill,
            Child = done
                ? Ui.Icon(Ui.Glyph.Check, 14, new SolidColorBrush(Microsoft.UI.Colors.White))
                : new TextBlock { Text = number.ToString(), FontWeight = FontWeights.SemiBold, Foreground = new SolidColorBrush(Microsoft.UI.Colors.White), HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center },
        };
        if (badge.Child is FrameworkElement c) { c.HorizontalAlignment = HorizontalAlignment.Center; c.VerticalAlignment = VerticalAlignment.Center; }
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(badge, done ? $"Trin {number}, færdigt" : $"Trin {number}");
        var head = Ui.HStack(12, badge, Ui.Text(title, "SubtitleTextBlockStyle"));
        var body = Ui.VStack(12, head, content);
        var card = Ui.Card(body, 20);
        card.Opacity = enabled ? 1 : 0.5;
        card.IsHitTestVisible = enabled;
        return card;
    }

    private FrameworkElement ConnectStep()
    {
        if (_model.HasToken)
            return Ui.Text($"Forbundet som {_model.Username ?? "?"}. Tokenet ligger i Windows' Legitimationsadministrator.");
        if (_model.IsDemo)
            return Ui.Text("Demo: appen bruger eksempelplader og forbinder ikke til Discogs.", color: Ui.Secondary);

        var p = new StackPanel { Spacing = 10 };
        var intro = new TextBlock { TextWrapping = TextWrapping.WrapWholeWords };
        intro.Inlines.Add(new Microsoft.UI.Xaml.Documents.Run { Text = "Gå til " });
        var link = new Microsoft.UI.Xaml.Documents.Hyperlink { NavigateUri = new Uri("https://www.discogs.com/settings/developers") };
        link.Inlines.Add(new Microsoft.UI.Xaml.Documents.Run { Text = "discogs.com/settings/developers" });
        intro.Inlines.Add(link);
        intro.Inlines.Add(new Microsoft.UI.Xaml.Documents.Run { Text = ", klik på “Generate new token”, og indsæt koden her. Den gemmes i Windows' Legitimationsadministrator – aldrig i filer eller logs." });
        p.Children.Add(intro);
        var connect = Ui.Btn(_busy ? "Forbinder …" : "Forbind", async (_, _) => await Connect(), accent: true);
        connect.IsEnabled = !_busy;
        _token.KeyDown -= OnTokenKey;
        _token.KeyDown += OnTokenKey;
        p.Children.Add(Ui.HStack(8, _token, connect));
        return p;
    }

    private async void OnTokenKey(object sender, Microsoft.UI.Xaml.Input.KeyRoutedEventArgs e)
    {
        if (e.Key != Windows.System.VirtualKey.Enter) return;
        e.Handled = true;
        await Connect();
    }

    private async Task Connect()
    {
        // Undgå dobbelt forbind/sync.
        if (_busy || _token.Password.Trim().Length == 0) return;
        _busy = true;
        Rebuild();
        if (await _model.ConnectAsync(_token.Password))
        {
            _token.Password = "";
            await _model.SyncAsync(showReport: false);
        }
        _busy = false;
        Rebuild();
    }

    private FrameworkElement ImportStep()
    {
        var s = _model.SyncState;
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 12 };
        switch (s.Phase)
        {
            case SyncPhase.Running:
                row.Children.Add(new ProgressBar { Width = 260, Maximum = Math.Max(s.Total, 1), Value = s.Done, IsIndeterminate = s.Total == 0, VerticalAlignment = VerticalAlignment.Center });
                row.Children.Add(Ui.Text(s.Total > 0 ? $"{s.Done} af {s.Total}" : "Henter…", wrap: false));
                break;
            case SyncPhase.Failed:
                row.Children.Add(Ui.Text(s.Message ?? "", color: Ui.ThemeBrush("SystemFillColorCriticalBrush")));
                row.Children.Add(Ui.Btn("Prøv igen", async (_, _) => await _model.SyncAsync(showReport: false)));
                break;
            default:
                if (_model.Library.Copies.Count == 0)
                    row.Children.Add(Ui.Btn("Hent samlingen", async (_, _) => await _model.SyncAsync(showReport: false), accent: true));
                else
                {
                    row.Children.Add(Ui.Text($"Din samling indeholder {_model.Library.Copies.Count} {_model.Medium.Plural()}.", wrap: false));
                    if (!_model.IsDemo) row.Children.Add(Ui.Btn("Hent igen", async (_, _) => await _model.SyncAsync(showReport: false)));
                }
                break;
        }
        return row;
    }

    private FrameworkElement LayoutStep()
    {
        var m = _model.Medium;
        var items = SortedItems;
        var p = new StackPanel { Spacing = 16 };
        p.Children.Add(Ui.Text($"Samlingen sorteres efter reglerne herunder – ligesom {(m == Medium.Vinyl ? "pladerne" : "cd'erne")} står i din reol. Angiv hvor mange reoler og sektioner du har; {m.Plural()} fordeles jævnt, og du justerer grænserne, så de passer med virkeligheden.",
            color: Ui.Secondary));
        p.Children.Add(QuickSortRules());

        var grid = new Grid { ColumnSpacing = 24 };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(260) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });

        // Venstre: antal reoler og sektioner pr. reol.
        var left = new StackPanel { Spacing = 8 };
        var shelves = new NumberBox { Header = "Reoler", Value = _sectionsPerShelf.Count, Minimum = 1, Maximum = 20, SpinButtonPlacementMode = NumberBoxSpinButtonPlacementMode.Inline };
        shelves.ValueChanged += (_, e) =>
        {
            if (double.IsNaN(e.NewValue)) return;
            int n = (int)e.NewValue;
            while (_sectionsPerShelf.Count < n) _sectionsPerShelf.Add(_sectionsPerShelf.LastOrDefault(2));
            while (_sectionsPerShelf.Count > n && _sectionsPerShelf.Count > 1) _sectionsPerShelf.RemoveAt(_sectionsPerShelf.Count - 1);
            Redistribute();
            Rebuild();
        };
        left.Children.Add(shelves);
        for (int i = 0; i < _sectionsPerShelf.Count; i++)
        {
            int idx = i;
            var box = new NumberBox { Header = $"{m.ShelfWord()} {i + 1}: sektioner", Value = _sectionsPerShelf[i], Minimum = 1, Maximum = 26, SpinButtonPlacementMode = NumberBoxSpinButtonPlacementMode.Inline, Margin = new Thickness(12, 0, 0, 0) };
            box.ValueChanged += (_, e) =>
            {
                if (double.IsNaN(e.NewValue) || idx >= _sectionsPerShelf.Count) return;
                _sectionsPerShelf[idx] = (int)e.NewValue;
                Redistribute();
                Rebuild();
            };
            left.Children.Add(box);
        }
        left.Children.Add(Ui.Btn("Fordel jævnt", (_, _) => { Redistribute(); Rebuild(); }));
        grid.Children.Add(left);

        // Højre: hver sektion med antal og første/sidste plade.
        var right = new StackPanel { Spacing = 6 };
        int start = 0;
        for (int i = 0; i < _plan.Count; i++)
        {
            var plan = _plan[i];
            int idx = i, s0 = start, end = start + plan.Count;
            var row = new Grid { ColumnSpacing = 10 };
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(80) });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(120) });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            var name = Ui.Text($"{(m == Medium.Vinyl ? "Reol" : "Cd")} {plan.Shelf} · {plan.Section}", "BodyStrongTextBlockStyle", wrap: false);
            name.VerticalAlignment = VerticalAlignment.Center;
            row.Children.Add(name);
            var count = new NumberBox { Value = plan.Count, Minimum = 0, Maximum = items.Count, SpinButtonPlacementMode = NumberBoxSpinButtonPlacementMode.Inline };
            Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(count, $"Antal i {plan.Shelf}{plan.Section}");
            count.ValueChanged += (_, e) =>
            {
                if (double.IsNaN(e.NewValue) || idx >= _plan.Count) return;
                LayoutPlanner.Adjust(_plan, idx, (int)e.NewValue);
                Rebuild();
            };
            Grid.SetColumn(count, 1);
            row.Children.Add(count);
            var range = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
            if (plan.Count > 0 && s0 < items.Count)
            {
                range.Children.Add(Ui.Text($"fra {items[s0].FullName}", "CaptionTextBlockStyle", Ui.Secondary, wrap: false));
                range.Children.Add(Ui.Text($"til {items[Math.Min(end, items.Count) - 1].FullName}", "CaptionTextBlockStyle", Ui.Secondary, wrap: false));
            }
            else range.Children.Add(Ui.Text("(tom)", "CaptionTextBlockStyle", Ui.Secondary));
            Grid.SetColumn(range, 2);
            row.Children.Add(range);
            right.Children.Add(row);
            start = end;
        }
        Grid.SetColumn(right, 1);
        grid.Children.Add(right);
        p.Children.Add(grid);

        var bottom = new Grid { ColumnSpacing = 8 };
        bottom.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        bottom.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var summary = Ui.Text($"{(m == Medium.Vinyl ? "Plader " : "")}{RangeText()} – i alt {items.Count}.", "CaptionTextBlockStyle", Ui.Secondary);
        summary.VerticalAlignment = VerticalAlignment.Center;
        bottom.Children.Add(summary);
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        if (_model.ForceOnboarding) buttons.Children.Add(Ui.Btn("Annullér", (_, _) => _model.ForceOnboarding = false));
        var create = Ui.Btn(m == Medium.Vinyl ? "Opret reol" : "Opret cd-reol", async (s, _) =>
        {
            if (_model.Library.Locations.Count == 0) { _model.CreateLayout(_plan); return; }
            var d = new ContentDialog
            {
                XamlRoot = ((FrameworkElement)s).XamlRoot,
                Title = "Erstat den nuværende reolstruktur?",
                Content = m == Medium.Vinyl
                    ? "Alle nuværende fysiske placeringer erstattes med den sorterede rækkefølge. Historikken bevares."
                    : "Cd'ernes nuværende placeringer erstattes med den sorterede rækkefølge. Pladerne røres ikke. Historikken bevares.",
                PrimaryButtonText = "Erstat alle placeringer",
                CloseButtonText = "Annullér",
                DefaultButton = ContentDialogButton.Close,
            };
            if (await d.ShowAsync() == ContentDialogResult.Primary) _model.CreateLayout(_plan);
        }, accent: true);
        create.IsEnabled = _plan.Count > 0 && items.Count > 0;
        buttons.Children.Add(create);
        Grid.SetColumn(buttons, 1);
        bottom.Children.Add(buttons);
        p.Children.Add(bottom);
        return p;
    }

    private string RangeText()
    {
        int acc = 0;
        var ranges = new SortedDictionary<int, (int Start, int End)>();
        foreach (var p in _plan)
        {
            int s = acc + 1, e = acc + p.Count;
            acc = e;
            ranges[p.Shelf] = ranges.TryGetValue(p.Shelf, out var cur) ? (cur.Start, e) : (s, e);
        }
        return string.Join(" · ", ranges.Select(kv => $"{_model.Medium.ShelfWord()} {kv.Key}: {kv.Value.Start}–{kv.Value.End}"));
    }

    /// <summary>De vigtigste sorteringsregler direkte i opsætningen.</summary>
    private FrameworkElement QuickSortRules()
    {
        var rules = _model.Rules;
        var p = new StackPanel { Spacing = 6 };
        var discogs = new CheckBox { Content = "Præcis samme rækkefølge som i min Discogs-samling (kunstner A–Z)", IsChecked = rules.UseDiscogsOrder, FontWeight = FontWeights.SemiBold };
        discogs.Click += (_, _) => Update(r => r.UseDiscogsOrder = discogs.IsChecked == true);
        p.Children.Add(discogs);
        var the = new CheckBox { Content = "Ignorér “The”", IsChecked = rules.ArtistArticles.Any(a => a.Equals("the", StringComparison.OrdinalIgnoreCase)) };
        the.Click += (_, _) => Update(r =>
        {
            r.ArtistArticles.RemoveAll(a => a.Equals("the", StringComparison.OrdinalIgnoreCase));
            if (the.IsChecked == true) r.ArtistArticles.Insert(0, "The");
        });
        var danish = new CheckBox { Content = "Æ Ø Å efter Z", IsChecked = rules.DanishAlphabet };
        danish.Click += (_, _) => Update(r => r.DanishAlphabet = danish.IsChecked == true);
        var within = new ComboBox { Header = null, ItemsSource = new[] { WithinArtist.Title.Label(), WithinArtist.Year.Label() }, SelectedIndex = rules.WithinArtist == WithinArtist.Title ? 0 : 1 };
        within.SelectionChanged += (_, _) => Update(r => r.WithinArtist = within.SelectedIndex == 1 ? WithinArtist.Year : WithinArtist.Title);
        var label = Ui.Text("Samme kunstner:", wrap: false);
        label.VerticalAlignment = VerticalAlignment.Center;
        var row = Ui.HStack(16, the, danish, Ui.HStack(8, label, within));
        row.Opacity = rules.UseDiscogsOrder ? 0.5 : 1;
        row.IsHitTestVisible = !rules.UseDiscogsOrder;
        p.Children.Add(row);
        return p;
    }

    private void Update(Action<SortRules> change)
    {
        var r = _model.Rules.Clone();
        change(r);
        _model.UpdateRules(r);
    }
}
