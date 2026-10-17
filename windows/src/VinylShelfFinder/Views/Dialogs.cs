using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using VinylShelfFinder.Core;
using VinylShelfFinder.UI;

namespace VinylShelfFinder.Views;

/// <summary>Dialogerne fra hovedvinduet: "Flyt plade" (MoveSheet) og navn/sted for status (StatusNoteAlert).</summary>
public static class Dialogs
{
    private enum MoveMode { Suggested, Start, End, After }

    /// <summary>"Flyt plade": vælg sektion og plads, se hvor pladen kommer til at stå, eller fjern den fra reolen.</summary>
    public static async Task ShowMoveAsync(AppModel model, long copyId, XamlRoot root)
    {
        var lib = model.Library;
        if (lib.Item(copyId) is not RecordItem it) return;
        var word = it.Medium.Singular();

        var p = new StackPanel { Spacing = 12, MinWidth = 460 };
        p.Children.Add(Ui.Text(it.FullName, "BodyStrongTextBlockStyle"));
        if (lib.LocationOf(copyId) is Location from && lib.NeighborsOf(copyId)?.Position is int pos)
            p.Children.Add(Ui.Text(model.IsAway(copyId)
                ? $"Hører til: {from.Name}, plads {pos} fra venstre (står ikke i reolen nu)"
                : $"Står nu: {from.Name}, {from.Medium.Singular()} {pos} fra venstre", color: Ui.Secondary));
        else
            p.Children.Add(Ui.Text("Står nu: ikke placeret i reolen", color: Ui.Secondary));

        var section = new ComboBox { Header = "Til sektion", HorizontalAlignment = HorizontalAlignment.Stretch, DisplayMemberPath = "Name" };
        foreach (var l in lib.Locations) section.Items.Add(l);
        long start = lib.LocationOfCopy.TryGetValue(copyId, out var cur) ? cur
            : lib.SuggestPlacement(copyId, model.Rules)?.LocationId ?? lib.Locations.FirstOrDefault()?.Id ?? 0;
        section.SelectedItem = lib.Locations.FirstOrDefault(l => l.Id == start);
        p.Children.Add(section);

        var modes = new RadioButtons { Header = "Placering" };
        modes.Items.Add("Sorteret plads i sektionen (foreslået)");
        modes.Items.Add("Først i sektionen");
        modes.Items.Add("Sidst i sektionen");
        modes.Items.Add("Lige efter en bestemt plade…");
        modes.SelectedIndex = 0;
        p.Children.Add(modes);

        var after = new ComboBox { Header = "Efter", HorizontalAlignment = HorizontalAlignment.Stretch, Visibility = Visibility.Collapsed };
        p.Children.Add(after);

        var between = new StackPanel { Spacing = 4 };
        p.Children.Add(Ui.Card(Ui.VStack(6, Ui.Eyebrow("Pladen kommer til at stå mellem"), between), 12));

        long LocationId() => (section.SelectedItem as Location)?.Id ?? 0;
        List<long> SectionIds() => (lib.Sections.TryGetValue(LocationId(), out var ids) ? ids : Array.Empty<long>()).Where(i => i != copyId).ToList();
        MoveMode Mode() => (MoveMode)Math.Max(0, modes.SelectedIndex);
        int TargetIndex()
        {
            var ids = SectionIds();
            return Mode() switch
            {
                MoveMode.Suggested => lib.SuggestPlacement(copyId, model.Rules, LocationId())?.Index ?? ids.Count,
                MoveMode.Start => 0,
                MoveMode.End => ids.Count,
                _ => after.SelectedIndex >= 0 ? after.SelectedIndex + 1 : ids.Count,
            };
        }

        var dialog = new ContentDialog
        {
            XamlRoot = root,
            Title = $"Flyt {word}",
            Content = new ScrollViewer { Content = p },
            PrimaryButtonText = "Flyt",
            CloseButtonText = "Annullér",
            DefaultButton = ContentDialogButton.Primary,
        };
        if (lib.LocationOfCopy.ContainsKey(copyId))
        {
            dialog.SecondaryButtonText = "Fjern fra reolen";
            p.Children.Add(Ui.Text("“Fjern fra reolen” sletter kun pladens plads – naboerne rykker sammen. Pladen findes stadig i samlingen og kan placeres igen fra “Nye plader” i sidepanelet.",
                "CaptionTextBlockStyle", Ui.Secondary));
        }

        void Refresh()
        {
            var ids = SectionIds();
            after.Visibility = Mode() == MoveMode.After ? Visibility.Visible : Visibility.Collapsed;
            int i = TargetIndex();
            string Name(long? id) => id is long x && lib.Item(x) is RecordItem r ? r.FullName : "";
            between.Children.Clear();
            between.Children.Add(Ui.Text($"Til venstre: {(i > 0 ? Name(ids[i - 1]) : "sektionens venstre kant")}", wrap: false));
            between.Children.Add(Ui.Text($"Din plade: {it.Title}", "BodyStrongTextBlockStyle", wrap: false));
            between.Children.Add(Ui.Text($"Til højre: {(i < ids.Count ? Name(ids[i]) : "sektionens højre kant")}", wrap: false));
            dialog.IsPrimaryButtonEnabled = section.SelectedItem is Location && !(Mode() == MoveMode.After && after.SelectedIndex < 0);
        }
        void FillAfter()
        {
            after.Items.Clear();
            foreach (var id in SectionIds()) after.Items.Add(lib.Item(id)?.FullName ?? "?");
        }
        section.SelectionChanged += (_, _) => { FillAfter(); Refresh(); };
        modes.SelectionChanged += (_, _) => Refresh();
        after.SelectionChanged += (_, _) => Refresh();
        FillAfter();
        Refresh();

        switch (await dialog.ShowAsync())
        {
            case ContentDialogResult.Primary:
                model.Move(copyId, LocationId(), TargetIndex());
                break;
            case ContentDialogResult.Secondary:
                model.Unplace(copyId);
                break;
        }
    }

    /// <summary>Spørger efter navn (udlånt) eller sted (opbevaret andet sted), og sætter status.</summary>
    public static async Task ShowStatusNoteAsync(AppModel model, StatusNoteRequest req, XamlRoot root)
    {
        bool lent = req.Status == CopyStatus.Lent;
        var box = new TextBox
        {
            PlaceholderText = lent ? "Navn" : "Sted",
            Text = req.Note,
        };
        var dialog = new ContentDialog
        {
            XamlRoot = root,
            Title = lent ? "Hvem har lånt pladen?" : "Hvor er pladen?",
            Content = box,
            PrimaryButtonText = "Gem",
            CloseButtonText = "Annullér",
            DefaultButton = ContentDialogButton.Primary,
        };
        box.Loaded += (_, _) => { box.Focus(FocusState.Programmatic); box.SelectAll(); };
        if (await dialog.ShowAsync() == ContentDialogResult.Primary)
            model.SetStatus(req.CopyId, req.Status, box.Text.Trim().Length == 0 ? null : box.Text.Trim());
    }
}
