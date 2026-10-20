using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Documents;
using VinylShelfFinder.Core;
using VinylShelfFinder.UI;

namespace VinylShelfFinder.Views;

/// <summary>Én række i søgning, indbakke og sektion (som RecordRow i ListViews.swift).</summary>
public static class RecordRow
{
    public static FrameworkElement Build(AppModel model, RecordItem item, bool showLocation = false, int? number = null,
                                         bool numberColumn = false, bool warning = false, bool dimAway = false)
    {
        bool dimmed = dimAway && item.Copy.Status != CopyStatus.Home;
        var grid = new Grid { ColumnSpacing = 12, Padding = new Thickness(0, 6, 0, 6) };
        int col = 0;

        void Add(FrameworkElement e, GridLength width)
        {
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = width });
            Grid.SetColumn(e, col++);
            e.VerticalAlignment = VerticalAlignment.Center;
            grid.Children.Add(e);
        }

        if (numberColumn || number is not null)
        {
            var n = Ui.Text(number?.ToString() ?? "", "CaptionTextBlockStyle", Ui.Secondary, wrap: false);
            n.TextAlignment = TextAlignment.Right;
            Add(n, new GridLength(28));
            Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(n, number is int k ? $"Nummer {k} i reolen" : "Står ikke i reolen");
        }

        var cover = Ui.Cover(item.Release, Ui.Style.BigCovers() ? 52 : 38);
        cover.Opacity = dimmed ? 0.45 : 1;
        Add(cover, GridLength.Auto);

        var text = new StackPanel { Spacing = 1 };
        var title = new TextBlock
        {
            Style = Ui.Res<Style>("BodyTextBlockStyle"),
            TextWrapping = TextWrapping.WrapWholeWords,
            TextTrimming = TextTrimming.CharacterEllipsis,
            MaxLines = 2,
            Opacity = dimmed ? 0.55 : 1,
        };
        title.Inlines.Add(new Run { Text = item.Artist, FontWeight = FontWeights.SemiBold });
        title.Inlines.Add(new Run { Text = " – ", Foreground = Ui.Secondary });
        title.Inlines.Add(new Run { Text = item.Title });
        text.Children.Add(title);
        if (item.Copy.Status != CopyStatus.Home)
        {
            var status = Ui.Label(item.Copy.Status.StatusGlyph(), item.Copy.Status.ListText(item.Copy.StatusNote),
                                  "CaptionTextBlockStyle", Ui.Secondary, 11);
            text.Children.Add(status);
        }
        var detail = Ui.Text(item.DetailLine, "CaptionTextBlockStyle", Ui.Secondary, wrap: false, maxLines: 1);
        detail.Opacity = dimmed ? 0.55 : 1;
        text.Children.Add(detail);
        Add(text, new GridLength(1, GridUnitType.Star));

        if (warning)
        {
            var w = Ui.Icon(Ui.Glyph.Swap, 14, Ui.Caution);
            ToolTipService.SetToolTip(w, "Står ikke i forventet sorteringsrækkefølge");
            Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(w, "Står ikke i forventet sorteringsrækkefølge");
            Add(w, GridLength.Auto);
        }
        if (!item.Copy.InDiscogs)
        {
            var w = Ui.Icon(Ui.Glyph.Warning, 14, Ui.Caution);
            ToolTipService.SetToolTip(w, "Ikke længere i din Discogs-samling");
            Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(w, "Ikke længere i din Discogs-samling");
            Add(w, GridLength.Auto);
        }
        if (showLocation)
        {
            var loc = model.Library.LocationOf(item.Id);
            var badge = loc is not null
                ? Ui.LocationBadge(loc.ShortName, tooltip: loc.Name)
                : Ui.LocationBadge("Ny", caution: true, tooltip: "Har endnu ingen plads i reolen");
            Add(badge, GridLength.Auto);
        }

        grid.ContextFlyout = ContextMenu(model, item.Id);
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(grid, item.FullName);
        return grid;
    }

    /// <summary>Højrekliksmenuen (som RecordContextMenu på Mac).</summary>
    public static MenuFlyout ContextMenu(AppModel model, long copyId)
    {
        var menu = new MenuFlyout();
        menu.Opening += (_, _) =>
        {
            menu.Items.Clear();
            var find = new MenuFlyoutItem { Text = "Find i reolen", Icon = new FontIcon { Glyph = Ui.Glyph.Pin } };
            find.Click += (_, _) => { model.Selection = copyId; model.FindModeCopy = copyId; };
            menu.Items.Add(find);
            if (model.IsAway(copyId))
            {
                var back = new MenuFlyoutItem { Text = "Sæt tilbage på plads…", Icon = new FontIcon { Glyph = Ui.Glyph.Undo } };
                back.Click += (_, _) => { model.Selection = copyId; model.StartReturn(copyId); };
                menu.Items.Add(back);
            }
            var move = new MenuFlyoutItem { Text = "Flyt…", Icon = new FontIcon { Glyph = Ui.Glyph.Swap } };
            move.Click += (_, _) => model.MoveCopy = copyId;
            menu.Items.Add(move);
            var status = new MenuFlyoutSubItem { Text = "Status" };
            foreach (var s in StatusChoices(model, copyId)) status.Items.Add(s);
            menu.Items.Add(status);
            foreach (var m in MediumChoices(model, copyId)) menu.Items.Add(m);
            if (model.Library.Item(copyId) is RecordItem it)
            {
                menu.Items.Add(new MenuFlyoutSeparator());
                var open = new MenuFlyoutItem { Text = "Åbn på Discogs" };
                open.Click += async (_, _) => await Windows.System.Launcher.LaunchUriAsync(it.Release.DiscogsUrl);
                menu.Items.Add(open);
            }
        };
        // En tom menu åbner ikke; Opening fylder den.
        menu.Items.Add(new MenuFlyoutItem { Text = "Find i reolen" });
        return menu;
    }

    /// <summary>"Flyt til cd-hylden" / "Flyt til pladehylden" og evt. "Følg Discogs' format" (MediumChoice på Mac).</summary>
    public static IEnumerable<MenuFlyoutItemBase> MediumChoices(AppModel model, long copyId)
    {
        if (model.Library.Item(copyId) is not RecordItem it) yield break;
        var other = it.Medium == Medium.Vinyl ? Medium.Cd : Medium.Vinyl;
        var move = new MenuFlyoutItem { Text = other == Medium.Cd ? "Flyt til cd-hylden" : "Flyt til pladehylden" };
        move.Click += (_, _) => model.SetMedium(copyId, other);
        yield return move;
        var discogs = MediumExtensions.Of(it.Release.Format);
        if (it.Copy.MediumOverride is not null && discogs != it.Medium)
        {
            var follow = new MenuFlyoutItem { Text = $"Følg Discogs' format ({discogs.Singular()})" };
            follow.Click += (_, _) => model.SetMedium(copyId, null);
            yield return follow;
        }
    }

    /// <summary>Statusvalgene. "Udlånt…" og "Opbevaret andet sted…" spørger efter navn/sted.</summary>
    public static IEnumerable<MenuFlyoutItemBase> StatusChoices(AppModel model, long copyId)
    {
        bool away = model.IsAway(copyId);
        foreach (var s in CopyStatusExtensions.All)
        {
            var label = s.WantsNote() || (s == CopyStatus.Home && away) ? $"{s.Label()}…" : s.Label();
            var item = new MenuFlyoutItem { Text = label, Icon = new FontIcon { Glyph = s.StatusGlyph() } };
            var status = s;
            item.Click += (_, _) => model.ChooseStatus(copyId, status);
            yield return item;
        }
    }
}
