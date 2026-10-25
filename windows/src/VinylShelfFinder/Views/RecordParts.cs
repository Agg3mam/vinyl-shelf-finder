using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;
using VinylShelfFinder.Core;
using VinylShelfFinder.UI;

namespace VinylShelfFinder.Views;

/// <summary>Dele, som plade-detaljen og "Find i reolen" har til fælles (som på Mac).</summary>
public static class RecordParts
{
    /// <summary>Skillekortets farve: kategoriens farve med hvid tekst, ellers accentfarven (som DividerColors på Mac).</summary>
    public static (Brush Fill, Brush Ink) DividerColors(Location loc) =>
        loc.Category is Category c ? (Ui.CategoryBrush(c), new SolidColorBrush(Microsoft.UI.Colors.White))
                                   : (Ui.AccentFill, Ui.ThemeBrush("TextOnAccentFillColorPrimaryBrush"));

    /// <summary>Skillekortet: sektionsbogstavet på en fane og "Reol 1 / Sektion A" ved siden af (som på Mac).
    /// <paramref name="size"/> er reolnavnets størrelse; fanen er knap dobbelt så høj.</summary>
    public static FrameworkElement PlacementLine(Location loc, double size = 28)
    {
        var (fill, ink) = DividerColors(loc);
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 12 };
        var letter = Ui.CondensedText(loc.Section, Math.Round(size * 1.65), color: ink);
        letter.HorizontalAlignment = HorizontalAlignment.Center;
        row.Children.Add(new Border
        {
            Child = letter,
            Background = fill,
            CornerRadius = new CornerRadius(8, 8, 0, 0),
            Padding = new Thickness(14, 2, 14, 0),
            MinWidth = Math.Round(size * 1.9),
            VerticalAlignment = VerticalAlignment.Bottom,
        });
        var names = new StackPanel { VerticalAlignment = VerticalAlignment.Bottom, Margin = new Thickness(0, 0, 0, 4) };
        names.Children.Add(Ui.CondensedText($"{loc.Kind.ShelfWord} {loc.Shelf}", size, bold: true));
        names.Children.Add(Ui.Text($"Sektion {loc.Section}", "BodyTextBlockStyle", Ui.Secondary, wrap: false));
        row.Children.Add(names);
        var card = new StackPanel { HorizontalAlignment = HorizontalAlignment.Left };
        card.Children.Add(row);
        // Kortets overkant: fanen sidder på en streg i samme farve.
        card.Children.Add(new Rectangle { Height = 3, Fill = fill, HorizontalAlignment = HorizontalAlignment.Stretch });
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(card, $"{loc.Kind.ShelfWord} {loc.Shelf}, sektion {loc.Section}");
        return card;
    }

    /// <summary>Sektionen tegnet som pladerygge set forfra: rygge i forskellig tykkelse, målet fremhævet (som på Mac).</summary>
    public static FrameworkElement ShelfSpines(int position, int count, Brush? accent = null)
    {
        const double height = 30;
        accent ??= Ui.AccentFill;
        var canvas = new Canvas { Height = height, HorizontalAlignment = HorizontalAlignment.Stretch };
        ToolTipService.SetToolTip(canvas, "Pladens plads i sektionen, set fra venstre");
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(canvas, $"Plade {position} af {count} i sektionen");
        var faint = Ui.ThemeBrush("ControlStrongFillColorDisabledBrush");
        void Draw(double width)
        {
            canvas.Children.Clear();
            if (width <= 0) return;
            int n = Math.Max(count, 1);
            int idx = Math.Min(Math.Max(position - 1, 0), n - 1);
            double slot = width / n;
            if (slot >= 3)
            {
                // Fast mønster ud fra pladsen, så samme sektion altid ser ens ud (samme formel som på Mac).
                double maxW = Math.Min(Math.Max(slot * 0.8, 2), 14);
                for (int i = 0; i < n; i++)
                {
                    double r = (double)((long)i * 2654435761L % 1000) / 1000;
                    bool target = i == idx;
                    double w = target ? maxW : maxW * (0.45 + 0.55 * r);
                    double h = target ? height : height * (0.72 + 0.16 * (1 - r));
                    var rect = new Rectangle { Width = w, Height = h, RadiusX = 1, RadiusY = 1, Fill = target ? accent : faint };
                    Canvas.SetLeft(rect, slot * (i + 0.5) - w / 2);
                    Canvas.SetTop(rect, height - h);
                    canvas.Children.Add(rect);
                }
            }
            else
            {
                var track = new Rectangle { Width = width, Height = 6, RadiusX = 3, RadiusY = 3, Fill = faint };
                Canvas.SetTop(track, height - 6);
                canvas.Children.Add(track);
                double x = n > 1 ? (double)idx / (n - 1) * (width - 6) : 0;
                var mark = new Rectangle { Width = 6, Height = height, RadiusX = 2, RadiusY = 2, Fill = accent };
                Canvas.SetLeft(mark, x);
                canvas.Children.Add(mark);
            }
        }
        canvas.SizeChanged += (_, e) => Draw(e.NewSize.Width);
        return canvas;
    }

    /// <summary>Den fremhævede blok: skillekortet, ryggene og pladsen i sektionen.</summary>
    public static Border LocationPanel(string eyebrow, Location loc, int position, int count, string hint, double lineSize = 28)
    {
        var p = new StackPanel { Spacing = 10 };
        p.Children.Add(Ui.Eyebrow(eyebrow));
        p.Children.Add(PlacementLine(loc, lineSize));
        p.Children.Add(ShelfSpines(position, count, DividerColors(loc).Fill));
        p.Children.Add(Ui.CondensedText(hint, 20, bold: false, color: Ui.Secondary));
        var card = Ui.Card(p, 20);
        card.BorderBrush = Ui.AccentTint(0.55);
        card.Background = Ui.AccentTint(0.07);
        return card;
    }

    /// <summary>Selskab, katalognr. og år på én linje og formatet på den næste (som PressingLines på Mac).</summary>
    public static FrameworkElement PressingLines(RecordItem it)
    {
        var p = new StackPanel();
        if (it.PressingLine.Length > 0) p.Children.Add(Ui.Text(it.PressingLine, "BodyTextBlockStyle", Ui.Secondary, wrap: false, maxLines: 1));
        if (!string.IsNullOrEmpty(it.Release.Format)) p.Children.Add(Ui.Text(it.Release.Format!, "BodyTextBlockStyle", Ui.Tertiary, wrap: false, maxLines: 1));
        return p;
    }

    /// <summary>Besked med ikon og knapper (fx "Denne plade er ikke længere i din Discogs Collection.").</summary>
    public static Border Notice(string glyph, string text, params UIElement[] actions)
    {
        var grid = new Grid { ColumnSpacing = 12 };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        var icon = Ui.Icon(glyph, 16, Ui.Caution);
        icon.VerticalAlignment = VerticalAlignment.Top;
        icon.Margin = new Thickness(0, 2, 0, 0);
        grid.Children.Add(icon);
        var body = new StackPanel { Spacing = 8 };
        body.Children.Add(Ui.Text(text));
        if (actions.Length > 0) body.Children.Add(Ui.HStack(8, actions));
        Grid.SetColumn(body, 1);
        grid.Children.Add(body);
        return new Border
        {
            Child = grid,
            Padding = new Thickness(12),
            CornerRadius = new CornerRadius(8),
            Background = Ui.CautionBackground,
        };
    }

    /// <summary>En nabo: cover, kunstner og titel. Klik viser pladen.</summary>
    public static FrameworkElement NeighborRow(AppModel model, RecordItem item)
    {
        var grid = new Grid { ColumnSpacing = 12 };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.Children.Add(Ui.Cover(item.Release, 44));
        var text = new StackPanel { Spacing = 0, VerticalAlignment = VerticalAlignment.Center };
        text.Children.Add(Ui.Text(item.Artist, "BodyTextBlockStyle", Ui.Secondary, maxLines: 2));
        text.Children.Add(Ui.Text(item.Title, "BodyStrongTextBlockStyle", maxLines: 2));
        Grid.SetColumn(text, 1);
        grid.Children.Add(text);
        // Detaljelinjen kun når der er plads: kunstner og titel har forrang.
        var detail = Ui.Text(item.DetailLine, "CaptionTextBlockStyle", Ui.Tertiary, wrap: false, maxLines: 1);
        detail.MaxWidth = 180;
        detail.VerticalAlignment = VerticalAlignment.Center;
        detail.TextAlignment = TextAlignment.Right;
        Grid.SetColumn(detail, 2);
        grid.Children.Add(detail);
        grid.SizeChanged += (_, e) => detail.Visibility = e.NewSize.Width < 460 ? Visibility.Collapsed : Visibility.Visible;
        var b = new Button
        {
            Content = grid,
            HorizontalAlignment = HorizontalAlignment.Stretch,
            HorizontalContentAlignment = HorizontalAlignment.Stretch,
            Padding = new Thickness(8),
            Background = Ui.ThemeBrush("SubtleFillColorSecondaryBrush"),
            BorderThickness = new Thickness(0),
        };
        b.Click += (_, _) => model.Reveal(item.Id);
        ToolTipService.SetToolTip(b, $"Vis {item.FullName}");
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(b, $"Vis {item.FullName}");
        return b;
    }

    /// <summary>En plade, der normalt står her, men er ude af reolen.</summary>
    public static FrameworkElement AbsentRow(RecordItem item)
    {
        var l = Ui.Label(item.Copy.Status.StatusGlyph(),
            $"{item.FullName} · {item.Copy.Status.ListText(item.Copy.StatusNote)} – står ikke i reolen",
            "CaptionTextBlockStyle", Ui.Secondary, 12);
        l.Margin = new Thickness(8, 0, 0, 0);
        return l;
    }

    /// <summary>Målpladen i rækken: accentkant og en svag accentflade.</summary>
    public static FrameworkElement TargetCard(RecordItem item)
    {
        var grid = new Grid { ColumnSpacing = 12 };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        var arrow = Ui.Icon("", 14, Ui.Accent);
        arrow.VerticalAlignment = VerticalAlignment.Center;
        Ui.AutomationHidden(arrow);
        grid.Children.Add(arrow);
        var text = new StackPanel();
        text.Children.Add(Ui.Text(item.Artist, "BodyStrongTextBlockStyle", Ui.Secondary));
        text.Children.Add(Ui.Text(item.Title, "SubtitleTextBlockStyle", weight: FontWeights.Bold));
        Grid.SetColumn(text, 1);
        grid.Children.Add(text);
        return new Border
        {
            Child = grid,
            Padding = new Thickness(16),
            CornerRadius = new CornerRadius(8),
            Background = Ui.AccentTint(0.12),
            BorderBrush = Ui.AccentFill,
            BorderThickness = new Thickness(2),
        };
    }

    /// <summary>"Starten af sektion A" med streg på hver side og en forklaring under.</summary>
    public static FrameworkElement SectionEdgeNote(string text, string? detail)
    {
        var p = new StackPanel { Spacing = 2, Padding = new Thickness(0, 2, 0, 2) };
        var row = new Grid { ColumnSpacing = 8 };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        Rectangle Line() => new() { Height = 1, Fill = Ui.Tertiary, VerticalAlignment = VerticalAlignment.Center, Opacity = 0.6 };
        var l1 = Line(); row.Children.Add(l1);
        var t = Ui.Text(text, "CaptionTextBlockStyle", Ui.Secondary, wrap: false, weight: FontWeights.SemiBold);
        Grid.SetColumn(t, 1); row.Children.Add(t);
        var l2 = Line(); Grid.SetColumn(l2, 2); row.Children.Add(l2);
        p.Children.Add(row);
        if (detail is not null)
        {
            var d = Ui.Text(detail, "CaptionTextBlockStyle", Ui.Secondary);
            d.TextAlignment = TextAlignment.Center;
            d.HorizontalAlignment = HorizontalAlignment.Center;
            p.Children.Add(d);
        }
        return p;
    }

    /// <summary>"Hørt 3 gange · sidst for 2 dage siden" / "Aldrig registreret som spillet".</summary>
    public static string PlayCountText(AppModel model, long copyId)
    {
        if (!model.Stats.LastPlayed.TryGetValue(copyId, out var last)) return "Aldrig registreret som spillet";
        int n = model.Stats.Count.TryGetValue(copyId, out var c) ? c : 0;
        return $"Hørt {n} {(n == 1 ? "gang" : "gange")} · sidst {DanishDate.Relative(last)}";
    }
}

/// <summary>Datoer på dansk uanset systemets sprog.</summary>
public static class DanishDate
{
    private static readonly System.Globalization.CultureInfo Da = System.Globalization.CultureInfo.GetCultureInfo("da-DK");

    /// <summary>"1. okt. 2026 kl. 10.26"</summary>
    public static string DateTime(DateTimeOffset d) => d.ToLocalTime().ToString("d. MMM yyyy 'kl.' HH.mm", Da);

    /// <summary>"i dag", "i går", "for 3 dage siden" …</summary>
    public static string Relative(DateTimeOffset d)
    {
        var now = DateTimeOffset.Now;
        var span = now - d;
        if (span < TimeSpan.FromMinutes(1)) return "lige nu";
        if (span < TimeSpan.FromHours(1)) { int m = (int)span.TotalMinutes; return m == 1 ? "for 1 minut siden" : $"for {m} minutter siden"; }
        if (span < TimeSpan.FromDays(1) && d.LocalDateTime.Date == now.LocalDateTime.Date) { int h = (int)span.TotalHours; return h == 1 ? "for 1 time siden" : $"for {h} timer siden"; }
        int days = (now.LocalDateTime.Date - d.LocalDateTime.Date).Days;
        if (days == 1) return "i går";
        if (days < 7) return $"for {days} dage siden";
        if (days < 31) { int w = days / 7; return w == 1 ? "for 1 uge siden" : $"for {w} uger siden"; }
        if (days < 365) { int mo = days / 30; return mo <= 1 ? "for 1 måned siden" : $"for {mo} måneder siden"; }
        int y = days / 365;
        return y == 1 ? "for 1 år siden" : $"for {y} år siden";
    }
}
