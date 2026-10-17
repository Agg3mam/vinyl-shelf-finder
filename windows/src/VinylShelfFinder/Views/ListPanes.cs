using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Windows.System;
using VinylShelfFinder.Core;
using VinylShelfFinder.UI;

namespace VinylShelfFinder.Views;

/// <summary>Fælles for lister med valg: overskrift, ListView og synkronisering af valget med modellen.</summary>
public abstract class SelectableListPane : IPane
{
    protected readonly AppModel Model;
    protected readonly Grid Root = new();
    protected readonly ListView List = new() { SelectionMode = ListViewSelectionMode.Single, Padding = new Thickness(0, 0, 0, 12) };
    protected readonly StackPanel Header = new() { Spacing = 2, Margin = new Thickness(16, 14, 16, 8) };
    protected readonly Grid EmptyHost = new();
    /// <summary>Copy-id for hver række i listen (null for rækker, der ikke kan vælges).</summary>
    protected readonly List<long?> RowIds = new();
    private bool _syncing;

    public FrameworkElement View => Root;

    protected SelectableListPane(AppModel model)
    {
        Model = model;
        Root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        Root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        Root.Children.Add(Header);
        Grid.SetRow(List, 1);
        Root.Children.Add(List);
        Grid.SetRow(EmptyHost, 1);
        Root.Children.Add(EmptyHost);
        List.SelectionChanged += (_, _) =>
        {
            if (_syncing) return;
            int i = List.SelectedIndex;
            if (i >= 0 && i < RowIds.Count && RowIds[i] is long id && Model.Selection != id) Model.Selection = id;
            else if (i >= 0 && i < RowIds.Count && RowIds[i] is null) SyncSelection();
        };
        List.KeyDown += (_, e) =>
        {
            if (e.Key == VirtualKey.Enter && Model.Selection is long s) { Model.FindModeCopy = s; e.Handled = true; }
        };
    }

    protected void AddRow(FrameworkElement row, long? id)
    {
        if (id is null)
        {
            var item = new ListViewItem { Content = row, IsHitTestVisible = true, IsTabStop = false };
            List.Items.Add(item);
        }
        else
        {
            List.Items.Add(row);
        }
        RowIds.Add(id);
    }

    protected void ClearRows()
    {
        _syncing = true;
        List.Items.Clear();
        RowIds.Clear();
        _syncing = false;
    }

    protected void SyncSelection()
    {
        int i = Model.Selection is long s ? RowIds.IndexOf(s) : -1;
        if (List.SelectedIndex == i) return;
        _syncing = true;
        List.SelectedIndex = i;
        _syncing = false;
        if (i >= 0) List.ScrollIntoView(List.Items[i]);
    }

    /// <summary>Som de andre lister: står den valgte plade ikke her, vælges den første.</summary>
    protected void SelectFirstIfNeeded()
    {
        if (Model.Selection is long s && RowIds.Contains(s)) return;
        Model.Selection = RowIds.FirstOrDefault(id => id is not null);
    }

    protected void SetHeader(string title, string? subtitle = null)
    {
        Header.Children.Clear();
        Header.Children.Add(Ui.Text(title, "SubtitleTextBlockStyle", wrap: false));
        if (!string.IsNullOrEmpty(subtitle)) Header.Children.Add(Ui.Text(subtitle!, "CaptionTextBlockStyle", Ui.Secondary));
    }

    public virtual void OnModelChanged(string? property)
    {
        if (property == nameof(AppModel.Library) || property == nameof(AppModel.Rules)) Rebuild();
        else if (property == nameof(AppModel.Selection)) SyncSelection();
    }

    public abstract void Rebuild();
}

/// <summary>Nye plader / Fjernet fra Discogs / Ude af reolen (RecordListView på Mac).</summary>
public sealed class RecordListPane : SelectableListPane
{
    private readonly SidebarKind _kind;

    public RecordListPane(AppModel model, SidebarKind kind) : base(model)
    {
        _kind = kind;
        Rebuild();
        SelectFirstIfNeeded();
    }

    public override void Rebuild()
    {
        var (title, items, empty, glyph) = _kind switch
        {
            SidebarKind.NewRecords => ($"Nye {Model.Medium.Plural()}", Model.UnplacedItems, $"Ingen nye {Model.Medium.Plural()} venter på en plads.", Ui.Glyph.New),
            SidebarKind.Removed => ("Fjernet fra Discogs", Model.RemovedItems, $"Alle {Model.Medium.Plural()} findes stadig i din Discogs-samling.", Ui.Glyph.Check),
            _ => ("Ude af reolen", Model.AwayItems, $"Alle {Model.Medium.Plural()} står på plads.", Ui.Glyph.Home),
        };
        SetHeader(title);
        ClearRows();
        EmptyHost.Children.Clear();
        if (items.Count == 0)
        {
            List.Visibility = Visibility.Collapsed;
            EmptyHost.Children.Add(Ui.Empty(glyph, title, empty));
            return;
        }
        List.Visibility = Visibility.Visible;
        if (_kind == SidebarKind.NewRecords)
        {
            var place = Ui.Btn("Placér alle som foreslået", (_, _) => Model.PlaceAllAsSuggested(), accent: true);
            place.Margin = new Thickness(0, 0, 0, 4);
            Header.Children.Add(place);
        }
        foreach (var it in items) AddRow(RecordRow.Build(Model, it, showLocation: true), it.Id);
        SyncSelection();
    }
}

/// <summary>
/// En sektion ("Jeg står her"): pladerne i fysisk rækkefølge med numre. Plader, der er ude,
/// står nedtonet på deres plads uden nummer. ⇄ markerer plader uden for sorteringen.
/// </summary>
public sealed class SectionPane : SelectableListPane
{
    public long LocationId { get; }

    public SectionPane(AppModel model, long locationId) : base(model)
    {
        LocationId = locationId;
        Rebuild();
        SelectFirstIfNeeded();
    }

    public override void Rebuild()
    {
        var lib = Model.Library;
        ClearRows();
        EmptyHost.Children.Clear();
        var loc = lib.LocationById(LocationId);
        if (loc is null)
        {
            Header.Children.Clear();
            List.Visibility = Visibility.Collapsed;
            EmptyHost.Children.Add(Ui.Empty(Ui.Glyph.Library, "Sektionen findes ikke længere", "Vælg en anden sektion i sidepanelet."));
            return;
        }
        List.Visibility = Visibility.Visible;
        var items = lib.ItemsIn(LocationId);
        var outOfOrder = lib.OutOfOrder(LocationId, Model.Rules);
        var numbers = lib.ShelfNumbers(LocationId);
        int locIndex = lib.Locations.ToList().FindIndex(l => l.Id == LocationId);
        var prev = locIndex > 0 ? lib.Locations[locIndex - 1] : null;
        var next = locIndex + 1 < lib.Locations.Count ? lib.Locations[locIndex + 1] : null;

        SetHeader(loc.Name, Subtitle(items.Count, outOfOrder.Count));
        var flow = new ToggleButton { IsChecked = Model.ShowCoverFlow, Content = Ui.Label(Ui.Glyph.Layers, "Cover Flow", "CaptionTextBlockStyle") };
        ToolTipService.SetToolTip(flow, Model.ShowCoverFlow ? "Vis plade-detaljen igen" : "Bladr i sektionen med Cover Flow (← →)");
        flow.Click += (_, _) => Model.ShowCoverFlow = flow.IsChecked == true;
        var check = Ui.Btn("Kontrollér…", (_, _) => Model.CheckSection = LocationId, tooltip: "Gå sektionen igennem plade for plade");
        var tools = Ui.HStack(8, flow, check);
        tools.Margin = new Thickness(0, 6, 0, 0);
        Header.Children.Add(tools);

        if (prev is not null && EdgeItem(prev, last: true) is RecordItem last)
            AddRow(Boundary($"Forrige sektion ({prev.Name}) slutter med", last), null);
        if (items.Count == 0)
            AddRow(Ui.Text("Sektionen er tom.", "BodyTextBlockStyle", Ui.Secondary), null);
        foreach (var it in items)
        {
            var row = RecordRow.Build(Model, it, number: numbers.TryGetValue(it.Id, out var n) ? n : null,
                                      numberColumn: true, warning: outOfOrder.Contains(it.Id), dimAway: true);
            AddRow(row, it.Id);
        }
        if (next is not null && EdgeItem(next, last: false) is RecordItem first)
            AddRow(Boundary($"Næste sektion ({next.Name}) starter med", first), null);
        SyncSelection();
    }

    /// <summary>"15 plader · 1 ude · 2 uden for sortering". Antallet er pladerne, der står i reolen.</summary>
    private string Subtitle(int total, int outOfOrder)
    {
        int onShelf = Model.Library.OnShelfCount(LocationId);
        var parts = new List<string> { Ui.Plader(onShelf) };
        if (total > onShelf) parts.Add($"{total - onShelf} ude");
        if (outOfOrder > 0) parts.Add($"{outOfOrder} uden for sortering");
        return string.Join(" · ", parts);
    }

    /// <summary>Første/sidste plade, der faktisk står i en nabosektion.</summary>
    private RecordItem? EdgeItem(Location loc, bool last)
    {
        var ids = Model.Library.Sections.TryGetValue(loc.Id, out var l) ? l : Array.Empty<long>();
        var onShelf = ids.Where(id => !Model.IsAway(id)).ToList();
        if (onShelf.Count == 0) return null;
        return Model.Library.Item(last ? onShelf[^1] : onShelf[0]);
    }

    private FrameworkElement Boundary(string text, RecordItem item)
    {
        var p = new StackPanel { Spacing = 1, Padding = new Thickness(0, 6, 0, 6) };
        p.Children.Add(Ui.Text(text, "CaptionTextBlockStyle", Ui.Secondary));
        p.Children.Add(Ui.Text(item.FullName, "BodyTextBlockStyle", Ui.Secondary, maxLines: 2));
        var b = new Button
        {
            Content = p,
            Background = null,
            BorderThickness = new Thickness(0),
            Padding = new Thickness(0),
            HorizontalAlignment = HorizontalAlignment.Stretch,
            HorizontalContentAlignment = HorizontalAlignment.Left,
        };
        b.Click += (_, _) => Model.Reveal(item.Id);
        ToolTipService.SetToolTip(b, $"Vis {item.FullName}");
        return b;
    }
}
