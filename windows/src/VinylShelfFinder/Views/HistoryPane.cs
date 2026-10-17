using System.Globalization;
using System.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using VinylShelfFinder.Core;
using VinylShelfFinder.UI;

namespace VinylShelfFinder.Views;

/// <summary>Historik (HistoryView i Sheets.swift): alle ændringer, nyeste først, med "Fortryd" på flytninger.</summary>
public sealed class HistoryPane : IPane
{
    private readonly AppModel _model;
    private readonly Grid _root = new();
    private readonly ListView _list = new() { SelectionMode = ListViewSelectionMode.None, Padding = new Thickness(0, 0, 0, 12) };

    public FrameworkElement View => _root;

    public HistoryPane(AppModel model)
    {
        _model = model;
        _root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        _root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        var title = Ui.Text("Historik", "TitleTextBlockStyle");
        title.Margin = new Thickness(24, 16, 24, 8);
        _root.Children.Add(title);
        Grid.SetRow(_list, 1);
        _root.Children.Add(_list);
        Load();
    }

    public void OnModelChanged(string? property)
    {
        if (property is nameof(AppModel.Library)) Load();
    }

    private void Load()
    {
        List<HistoryEntry> entries;
        try { entries = _model.Store.History(); }
        catch (Exception ex) { _model.ErrorMessage = AppModel.Describe(ex); entries = new(); }
        var undo = new HistoryUndo(entries);
        _list.Items.Clear();
        if (entries.Count == 0)
        {
            _list.Items.Add(Ui.Empty(Ui.Glyph.History, "Ingen historik endnu", "Flytninger, nye plader og ændringer i status vises her."));
            return;
        }
        foreach (var e in entries)
            _list.Items.Add(Row(e, undo.Undoable.Contains(e.Id), undo.Undone.Contains(e.Id)));
    }

    private FrameworkElement Row(HistoryEntry e, bool canUndo, bool wasUndone)
    {
        var text = new HistoryText(e, _model.Library);
        var grid = new Grid { ColumnSpacing = 12, Padding = new Thickness(12, 8, 12, 8) };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(20) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var icon = Ui.Icon(text.Glyph, 14, Ui.Secondary);
        icon.VerticalAlignment = VerticalAlignment.Top;
        icon.Margin = new Thickness(0, 3, 0, 0);
        grid.Children.Add(icon);
        var body = new StackPanel { Spacing = 2 };
        body.Children.Add(Ui.Text(text.Title, "BodyStrongTextBlockStyle", maxLines: 2));
        if (text.Detail is string d) body.Children.Add(Ui.Text(d, "BodyTextBlockStyle", Ui.Secondary));
        body.Children.Add(Ui.Text(DanishDate.DateTime(e.At), "CaptionTextBlockStyle", Ui.Secondary));
        Grid.SetColumn(body, 1);
        grid.Children.Add(body);
        if (canUndo)
        {
            var b = Ui.Btn("Fortryd", (_, _) => _model.Undo(e), tooltip: "Sæt pladen tilbage, hvor den stod før");
            b.VerticalAlignment = VerticalAlignment.Top;
            Grid.SetColumn(b, 2);
            grid.Children.Add(b);
        }
        else if (wasUndone)
        {
            var t = Ui.Text("Fortrudt", "CaptionTextBlockStyle", Ui.Secondary, wrap: false);
            Grid.SetColumn(t, 2);
            grid.Children.Add(t);
        }
        return grid;
    }
}

/// <summary>
/// Hvilke poster kan fortrydes? Kun den seneste flytning af hver plade – og kun hvis ingen senere
/// flytning (eller en ny opdeling af reolen) har overhalet den. En flytning, der selv er en
/// fortrydelse af den forrige, kan ikke fortrydes igen.
/// </summary>
public sealed class HistoryUndo
{
    public HashSet<long> Undoable { get; } = new();
    public HashSet<long> Undone { get; } = new();

    private static readonly HashSet<HistoryKind> PlacementKinds = new() { HistoryKind.Moved, HistoryKind.Placed, HistoryKind.Unplaced, HistoryKind.Deleted };

    public HistoryUndo(IReadOnlyList<HistoryEntry> entries) // nyeste først
    {
        var seen = new HashSet<long>();
        for (int i = 0; i < entries.Count; i++)
        {
            var e = entries[i];
            if (e.Kind == HistoryKind.LayoutCreated) break; // alt før en ny opdeling er overhalet
            if (!PlacementKinds.Contains(e.Kind) || e.CopyId is not long copy || seen.Contains(copy)) continue;
            seen.Add(copy);
            if (e.Kind != HistoryKind.Moved || e.FromLocationId is null) continue;
            var older = entries.Skip(i + 1).TakeWhile(o => o.Kind != HistoryKind.LayoutCreated)
                .FirstOrDefault(o => o.CopyId == copy && PlacementKinds.Contains(o.Kind));
            if (older is not null && (older.Kind is HistoryKind.Moved or HistoryKind.Placed)
                && e.ToLocationId == older.FromLocationId && e.ToPosition == older.FromPosition && e.FromLocationId == older.ToLocationId)
                Undone.Add(older.Id); // e er en fortrydelse af older
            else
                Undoable.Add(e.Id);
        }
    }
}

/// <summary>Historikpostens tekst i appens almindelige format ("Reol 1 · Sektion A, plade 3"), uden emoji.</summary>
public sealed class HistoryText
{
    public string Title { get; }
    public string? Detail { get; }
    public string Glyph { get; }

    private const string Swap = "", In = "", Out = "", Trash = "", Sparkle = "", Sync = "", Tag = "";

    public HistoryText(HistoryEntry e, Library library)
    {
        var summary = Clean(e.Summary);
        var name = (e.CopyId is long c ? library.Item(c)?.FullName : null) ?? RecordName(summary);

        string? Place(long? loc, int? pos)
        {
            if (library.LocationById(loc) is not Location l) return null;
            return pos is int p ? $"{l.Name}, {l.Medium.Singular()} {p}" : l.Name;
        }
        var from = Place(e.FromLocationId, e.FromPosition);
        var to = Place(e.ToLocationId, e.ToPosition);

        switch (e.Kind)
        {
            case HistoryKind.Moved when from is not null && to is not null:
                (Title, Detail, Glyph) = (name ?? summary, $"Flyttet fra {from} til {to}", Swap);
                break;
            case HistoryKind.Placed when to is not null:
                (Title, Detail, Glyph) = (name ?? summary, $"Placeret i {to}", In);
                break;
            case HistoryKind.Unplaced when from is not null:
                (Title, Detail, Glyph) = (name ?? summary, $"Fjernet fra {from}", Out);
                break;
            case HistoryKind.StatusChanged:
                var status = CopyStatusExtensions.All.Cast<CopyStatus?>().FirstOrDefault(s => summary.Contains($": {s!.Value.Label()}") || summary.Contains($"“{s!.Value.Label()}”"));
                (Title, Detail, Glyph) = Split(summary, name, status?.StatusGlyph() ?? Tag);
                break;
            default:
                var g = e.Kind switch
                {
                    HistoryKind.Moved => Swap,
                    HistoryKind.Placed => In,
                    HistoryKind.Unplaced => Out,
                    HistoryKind.Deleted => Trash,
                    HistoryKind.AddedFromDiscogs => Sparkle,
                    HistoryKind.RemovedFromDiscogs => Ui.Glyph.Warning,
                    HistoryKind.MetadataUpdated => Sync,
                    HistoryKind.LayoutCreated => Ui.Glyph.Library,
                    _ => Tag,
                };
                (Title, Detail, Glyph) = Split(summary, name, g);
                break;
        }
    }

    /// "Ny i Discogs: A – T" → titel "A – T", detalje "Ny i Discogs".
    private static (string, string?, string) Split(string summary, string? name, string glyph)
    {
        int i = name is null ? -1 : summary.IndexOf(name, StringComparison.Ordinal);
        if (i < 0) return (summary, null, glyph);
        var rest = summary.Remove(i, name!.Length).Trim(':', '–', ' ');
        if (rest.Length == 0) return (name, null, glyph);
        return (name, char.ToUpper(rest[0], CultureInfo.GetCultureInfo("da-DK")) + rest[1..], glyph);
    }

    /// "Kunstner – Titel" i starten af en ældre tekst.
    private static string? RecordName(string summary)
    {
        foreach (var marker in new[] { ":", " flyttet", " placeret", " fjernet", " slettet", " er ikke længere" })
        {
            int r = summary.IndexOf(marker, StringComparison.Ordinal);
            if (r > 0 && summary[..r].Contains(" – ")) return summary[..r];
        }
        return null;
    }

    /// Fjerner emoji (ældre poster kan indeholde 🏠📦👤❓) og dobbelte mellemrum.
    public static string Clean(string s)
    {
        var sb = new StringBuilder();
        foreach (var rune in s.EnumerateRunes())
        {
            bool emoji = rune.Value >= 0x1F000 || (rune.Value >= 0x2600 && rune.Value <= 0x27BF) || rune.Value == 0xFE0F;
            if (!emoji) sb.Append(rune.ToString());
        }
        return sb.ToString().Replace("  ", " ").Trim();
    }
}
