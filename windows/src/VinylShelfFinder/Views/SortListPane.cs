using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using VinylShelfFinder.Core;
using VinylShelfFinder.UI;

namespace VinylShelfFinder.Views;

/// <summary>
/// Sorteringslisten: hele rækkefølgen for den valgte hylde (plader eller cd'er), sektion for sektion,
/// med flueben, så man kan stille reolen op i flere omgange. Discogs blander formaterne; her gør vi ikke.
/// </summary>
public sealed class SortListPane : IPane
{
    private readonly AppModel _model;
    private readonly Grid _root = new();
    private readonly StackPanel _header = new() { Spacing = 10, Margin = new Thickness(24, 16, 24, 8) };
    private readonly ListView _list = new() { SelectionMode = ListViewSelectionMode.None, Padding = new Thickness(12, 0, 12, 24) };
    private ProgressBar _progress = new();
    private TextBlock _progressText = new();
    private readonly Dictionary<long, (CheckBox Box, ListViewItem Row)> _rows = new();
    private List<SortListEntry> _entries = new();
    private bool _updating;

    public FrameworkElement View => _root;

    public SortListPane(AppModel model)
    {
        _model = model;
        _root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        _root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        _root.Children.Add(_header);
        Grid.SetRow(_list, 1);
        _root.Children.Add(_list);
        Rebuild();
    }

    public void OnModelChanged(string? property)
    {
        if (property is nameof(AppModel.Library) or nameof(AppModel.Rules) or nameof(AppModel.Medium)) Rebuild();
        else if (property == nameof(AppModel.SortChecked)) UpdateChecks();
    }

    private void Rebuild()
    {
        var lib = _model.Library;
        var m = _model.Medium;
        _entries = SortList.Build(lib, _model.Rules);
        _rows.Clear();
        _list.Items.Clear();
        _header.Children.Clear();

        var title = new StackPanel { Spacing = 2 };
        title.Children.Add(Ui.Text($"Sorteringsliste · {_model.Kind.Title}", "SubtitleTextBlockStyle", wrap: false));
        title.Children.Add(Ui.Text(_model.Kind.Category is not null
            ? $"Rækkefølgen for {_model.Kind.Title.ToLowerInvariant()}, fra første til sidste {m.Singular()}. De andre hylder har deres egne lister."
            : m == Medium.Vinyl
            ? "Rækkefølgen for pladehylden, fra første til sidste plade. Cd'erne har deres egen liste."
            : "Rækkefølgen for cd-hylden, fra første til sidste cd. Pladerne har deres egen liste.",
            "CaptionTextBlockStyle", Ui.Secondary));
        _header.Children.Add(title);

        if (_entries.Count == 0)
        {
            _list.Visibility = Visibility.Collapsed;
            _header.Children.Add(Ui.Empty(Ui.Glyph.Library, $"Ingen {m.Plural()}", $"Der er ingen {m.Plural()} i samlingen endnu."));
            return;
        }
        _list.Visibility = Visibility.Visible;

        if (lib.Locations.Count == 0)
        {
            var make = Ui.Btn($"Lav {_model.Kind.ShelfWord.ToLowerInvariant()}er", (_, _) => _model.Sidebar = SidebarItem.Search);
            _header.Children.Add(Ui.Card(Ui.VStack(8,
                Ui.Text($"Der er ingen {_model.Kind.ShelfWord.ToLowerInvariant()}er endnu, så listen viser bare hele rækkefølgen. Når reolerne er lavet, deles listen op i sektioner.", color: Ui.Secondary),
                make), 12));
        }

        var next = Ui.Btn("Næste", (_, _) => ScrollToNext(), Ui.Glyph.ChevronRight, accent: true, tooltip: $"Hop til den første {m.Singular()} uden flueben");
        var restart = Ui.Btn("Start forfra", (_, _) => { }, Ui.Glyph.Undo, tooltip: "Fjern alle flueben");
        var confirm = new Flyout();
        var yes = Ui.Btn("Fjern alle flueben", (_, _) => { confirm.Hide(); _model.ClearSortChecked(); });
        confirm.Content = Ui.VStack(10, Ui.Text($"Fjern fluebenene ved alle {m.Plural()} på denne hylde?"), yes);
        restart.Flyout = confirm;
        // Nye elementer ved hver Rebuild(): WinUI tillader kun én forælder pr. element.
        _progress = new ProgressBar { Width = 260, VerticalAlignment = VerticalAlignment.Center };
        _progressText = Ui.Text("", "BodyTextBlockStyle", Ui.Secondary, wrap: false);
        _progressText.VerticalAlignment = VerticalAlignment.Center;
        var bar = Ui.HStack(12, _progress, _progressText, next, restart);
        _header.Children.Add(bar);

        long? lastLoc = -1;
        foreach (var e in _entries)
        {
            long? loc = e.Location?.Id;
            if (loc != lastLoc)
            {
                lastLoc = loc;
                if (e.Location is Location l) AddHeading(l.Name, lib.Sections.TryGetValue(l.Id, out var ids) ? ids.Count : 0, first: _list.Items.Count == 0);
                else if (lib.Locations.Count > 0) AddHeading("Uden plads endnu", _entries.Count(x => x.Location is null), first: false, note: $"Nye {m.Plural()}, der ikke har fået en plads. Rækkefølgen viser, hvor de hører til.");
            }
            AddEntry(e);
        }
        UpdateChecks();
    }

    private void AddHeading(string name, int count, bool first, string? note = null)
    {
        var p = new StackPanel { Spacing = 1, Margin = new Thickness(0, first ? 4 : 18, 0, 4) };
        p.Children.Add(Ui.Text(name, "BodyStrongTextBlockStyle", wrap: false));
        p.Children.Add(Ui.Text(note ?? (count == 1 ? $"1 {_model.Medium.Singular()}" : $"{count} {_model.Medium.Plural()}"), "CaptionTextBlockStyle", Ui.Secondary));
        _list.Items.Add(new ListViewItem { Content = p, IsHitTestVisible = false, IsTabStop = false });
    }

    private void AddEntry(SortListEntry e)
    {
        var it = e.Item;
        var grid = new Grid { ColumnSpacing = 12 };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(44) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var number = Ui.Text(e.Number?.ToString() ?? "–", "BodyTextBlockStyle", Ui.Secondary, wrap: false);
        number.HorizontalAlignment = HorizontalAlignment.Right;
        number.VerticalAlignment = VerticalAlignment.Center;
        grid.Children.Add(number);
        var name = Ui.Text(it.FullName, "BodyTextBlockStyle", wrap: false);
        name.VerticalAlignment = VerticalAlignment.Center;
        Grid.SetColumn(name, 1);
        grid.Children.Add(name);
        var meta = new List<string>();
        if (it.Copy.Status != CopyStatus.Home) meta.Add(it.Copy.Status.Label());
        if (it.Release.Year is int y) meta.Add(y.ToString());
        if (it.Release.Format is string f && f.Length > 0) meta.Add(f.Split(',')[0].Trim());
        var info = Ui.Text(string.Join(" · ", meta), "CaptionTextBlockStyle", Ui.Secondary, wrap: false);
        info.VerticalAlignment = VerticalAlignment.Center;
        Grid.SetColumn(info, 2);
        grid.Children.Add(info);

        var row = new ListViewItem { HorizontalContentAlignment = HorizontalAlignment.Stretch, Padding = new Thickness(8, 0, 12, 0), MinHeight = 36 };
        if (e.Number is null)
        {
            // Ude af reolen: står på sin plads i listen, men skal ikke stilles op nu.
            grid.Margin = new Thickness(32, 0, 0, 0);
            row.Content = grid;
            row.Opacity = 0.5;
            row.IsHitTestVisible = false;
            _list.Items.Add(row);
            return;
        }
        var box = new CheckBox { Content = grid, HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Stretch, MinWidth = 0 };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(box, $"{e.Number}. {it.FullName}");
        long id = it.Id;
        box.Click += (_, _) => { if (!_updating) _model.SetSortChecked(id, box.IsChecked == true); };
        row.Content = box;
        _rows[id] = (box, row);
        _list.Items.Add(row);
    }

    private void UpdateChecks()
    {
        var done = _model.SortChecked;
        _updating = true;
        foreach (var (id, (box, row)) in _rows)
        {
            bool on = done.Contains(id);
            if (box.IsChecked != on) box.IsChecked = on;
            row.Opacity = on ? 0.55 : 1;
        }
        _updating = false;
        int total = _rows.Count, count = _rows.Keys.Count(done.Contains);
        _progress.Maximum = Math.Max(total, 1);
        _progress.Value = count;
        _progressText.Text = count == total && total > 0
            ? $"Alle {total} {_model.Medium.Plural()} står på plads"
            : $"{count} af {total} sat på plads";
    }

    private void ScrollToNext()
    {
        if (SortList.NextUnchecked(_entries, _model.SortChecked) is not SortListEntry e || !_rows.TryGetValue(e.Item.Id, out var r)) return;
        _list.ScrollIntoView(r.Row, ScrollIntoViewAlignment.Leading);
        r.Box.Focus(FocusState.Programmatic);
    }
}
