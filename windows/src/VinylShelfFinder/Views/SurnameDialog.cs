using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using VinylShelfFinder.Core;
using VinylShelfFinder.UI;

namespace VinylShelfFinder.Views;

/// <summary>
/// "Efternavn først": appen foreslår, hvilke kunstnere der er personer ("Bob Dylan" → "Dylan, Bob"),
/// og brugeren retter gættet. Valgene bliver almindelige sorteringsnavne (Indstillinger › Sortering).
/// </summary>
public static class SurnameDialog
{
    /// Antal nye forslag (kunstnere, der hverken er valgt eller fravalgt endnu) – til knappernes tekst.
    public static int NewCount(AppModel model)
    {
        var no = SafeNotPersons(model);
        return Candidates(model).Count(c => !SurnameSort.IsChosen(model.Rules, c) && !no.Contains(c.Artist));
    }

    private static List<SurnameCandidate> Candidates(AppModel model) =>
        SurnameSort.Candidates(model.Library.Releases.Values.Select(r => r.Artist));

    private static HashSet<string> SafeNotPersons(AppModel model)
    {
        try { return model.Store.SurnameNotPersons(); } catch { return new(StringComparer.Ordinal); }
    }

    public static async Task ShowAsync(AppModel model, XamlRoot root)
    {
        var rules = model.Rules;
        var candidates = Candidates(model);
        var notPersons = SafeNotPersons(model);
        if (candidates.Count == 0)
        {
            await new ContentDialog { XamlRoot = root, Title = "Efternavn først", Content = Ui.Text("Der er ingen kunstnere i samlingen, hvis navn kan vendes."), CloseButtonText = "OK" }.ShowAsync();
            return;
        }

        var boxes = new List<(SurnameCandidate C, CheckBox Box)>();
        var list = new StackPanel { Spacing = 0 };
        int fresh = 0;
        foreach (var c in candidates)
        {
            bool chosen = SurnameSort.IsChosen(rules, c);
            bool isNew = !chosen && !notPersons.Contains(c.Artist);
            if (isNew) fresh++;
            var row = new Grid { ColumnSpacing = 12 };
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            row.Children.Add(Ui.Text(c.Artist, wrap: false));
            var shown = chosen && rules.ArtistOverrides.TryGetValue(c.Artist, out var own) ? own : c.Surname;
            var right = Ui.Text(isNew ? $"→ {shown} · ny" : $"→ {shown}", "CaptionTextBlockStyle", Ui.Secondary, wrap: false);
            right.VerticalAlignment = VerticalAlignment.Center;
            Grid.SetColumn(right, 1);
            row.Children.Add(right);
            var box = new CheckBox
            {
                Content = row,
                IsChecked = chosen || (isNew && c.LikelyPerson),
                HorizontalAlignment = HorizontalAlignment.Stretch,
                HorizontalContentAlignment = HorizontalAlignment.Stretch,
                MinWidth = 0,
            };
            Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(box, $"{c.Artist} sorteres som {shown}");
            boxes.Add((c, box));
            list.Children.Add(box);
        }

        var count = Ui.Text("", "CaptionTextBlockStyle", Ui.Secondary);
        void UpdateCount() => count.Text = $"{boxes.Count(b => b.Box.IsChecked == true)} af {boxes.Count} sorteres efter efternavn"
                                          + (fresh > 0 ? $" · {fresh} nye forslag, hvor fluebenet er appens gæt" : "");
        foreach (var (_, box) in boxes) box.Click += (_, _) => UpdateCount();
        UpdateCount();

        var filter = new TextBox { PlaceholderText = "Find kunstner", MinWidth = 220 };
        filter.TextChanged += (_, _) =>
        {
            var q = filter.Text.Trim();
            foreach (var (c, box) in boxes)
                box.Visibility = q.Length == 0 || c.Artist.Contains(q, StringComparison.CurrentCultureIgnoreCase) ? Visibility.Visible : Visibility.Collapsed;
        };
        var none = Ui.Btn("Ingen", (_, _) => { foreach (var b in boxes) if (b.Box.Visibility == Visibility.Visible) b.Box.IsChecked = false; UpdateCount(); });
        var guess = Ui.Btn("Brug gættet", (_, _) => { foreach (var b in boxes) if (b.Box.Visibility == Visibility.Visible) b.Box.IsChecked = b.C.LikelyPerson; UpdateCount(); },
            tooltip: "Kryds af ud fra navnet: personer til, bands fra");

        var content = new StackPanel { Spacing = 10, Width = 500 };
        content.Children.Add(Ui.Text("Kryds af de kunstnere, der er personer. De sorteres efter efternavn: Bob Dylan står under D. Bands som Pink Floyd lader du være. Appen har gættet ud fra navnet – ret de forkerte.", color: Ui.Secondary));
        if (rules.UseDiscogsOrder)
            content.Children.Add(Ui.Label(Ui.Glyph.Warning, "Discogs sorterer efter fornavn, så appen bruger sine egne regler, når du gemmer (“The” ignoreres, tal sidst, Æ Ø Å efter Z).", "CaptionTextBlockStyle", Ui.Secondary));
        content.Children.Add(Ui.HStack(8, filter, guess, none));
        content.Children.Add(count);
        content.Children.Add(new ScrollViewer { Content = list, MaxHeight = 380, Padding = new Thickness(0, 0, 12, 0) });

        var dialog = new ContentDialog
        {
            XamlRoot = root,
            Title = "Efternavn først",
            Content = content,
            PrimaryButtonText = "Gem",
            CloseButtonText = "Annullér",
            DefaultButton = ContentDialogButton.Primary,
        };
        if (await dialog.ShowAsync() != ContentDialogResult.Primary) return;

        var persons = boxes.Where(b => b.Box.IsChecked == true).Select(b => b.C.Artist).ToHashSet(StringComparer.Ordinal);
        model.UpdateRules(SurnameSort.Apply(model.Rules, candidates, persons));
        try { model.Store.SaveSurnameNotPersons(boxes.Where(b => b.Box.IsChecked != true).Select(b => b.C.Artist)); }
        catch (Exception ex) { model.ErrorMessage = AppModel.Describe(ex); }
    }
}
