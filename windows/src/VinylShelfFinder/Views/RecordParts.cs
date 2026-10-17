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
    /// <summary>"Reol 1 › Sektion A" – samme linje på pladeskærmene.</summary>
    public static FrameworkElement PlacementLine(Location loc, double size = 28)
    {
        var p = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10 };
        var icon = Ui.Icon(Ui.Glyph.Library, size * 0.8, Ui.Accent);
        icon.VerticalAlignment = VerticalAlignment.Center;
        p.Children.Add(icon);
        p.Children.Add(new TextBlock { Text = $"{loc.Medium.ShelfWord()} {loc.Shelf}", FontSize = size, FontWeight = FontWeights.SemiBold, VerticalAlignment = VerticalAlignment.Center });
        var chev = Ui.Icon(Ui.Glyph.ChevronRight, size * 0.45, Ui.Tertiary);
        chev.VerticalAlignment = VerticalAlignment.Center;
        p.Children.Add(chev);
        p.Children.Add(new TextBlock { Text = $"Sektion {loc.Section}", FontSize = size, FontWeight = FontWeights.SemiBold, VerticalAlignment = VerticalAlignment.Center });
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(p, loc.Name);
        return p;
    }

    /// <summary>Sektionen tegnet som pladerygge set forfra: én streg pr. plade, målet fremhævet.</summary>
    public static FrameworkElement ShelfSpines(int position, int count)
    {
        const double height = 22;
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
                double w = Math.Min(Math.Max(slot * 0.45, 2), 6);
                for (int i = 0; i < n; i++)
                {
                    bool target = i == idx;
                    double h = target ? height : height * 0.55;
                    var r = new Rectangle
                    {
                        Width = target ? w + 2 : w,
                        Height = h,
                        RadiusX = 1.5,
                        RadiusY = 1.5,
                        Fill = target ? Ui.AccentFill : faint,
                    };
                    Canvas.SetLeft(r, slot * (i + 0.5) - w / 2);
                    Canvas.SetTop(r, height - h);
                    canvas.Children.Add(r);
                }
            }
            else
            {
                var track = new Rectangle { Width = width, Height = 6, RadiusX = 3, RadiusY = 3, Fill = faint };
                Canvas.SetTop(track, height - 6);
                canvas.Children.Add(track);
                double x = n > 1 ? (double)idx / (n - 1) * (width - 6) : 0;
                var mark = new Rectangle { Width = 6, Height = height, RadiusX = 2, RadiusY = 2, Fill = Ui.AccentFill };
                Canvas.SetLeft(mark, x);
                canvas.Children.Add(mark);
            }
        }
        canvas.SizeChanged += (_, e) => Draw(e.NewSize.Width);
        return canvas;
    }

    /// <summary>Den fremhævede blok: reol, sektion og plads i sektionen.</summary>
    public static Border LocationPanel(string eyebrow, Location loc, int position, int count, string hint, double lineSize = 28)
    {
        var p = new StackPanel { Spacing = 10 };
        p.Children.Add(Ui.Eyebrow(eyebrow));
        p.Children.Add(PlacementLine(loc, lineSize));
        p.Children.Add(ShelfSpines(position, count));
        p.Children.Add(Ui.Text(hint, "BodyTextBlockStyle", Ui.Secondary));
        var card = Ui.Card(p, 20);
        card.BorderBrush = Ui.AccentTint(0.55);
        card.Background = Ui.AccentTint(0.07);
        return card;
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
        text.Children.Add(Ui.Text(item.Title.ToUpper(System.Globalization.CultureInfo.GetCultureInfo("da-DK")), "SubtitleTextBlockStyle", weight: FontWeights.Bold));
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

    /// <summary>"STARTEN AF SEKTION A" med streg på hver side og en forklaring under.</summary>
    public static FrameworkElement SectionEdgeNote(string text, string? detail)
    {
        var p = new StackPanel { Spacing = 2, Padding = new Thickness(0, 2, 0, 2) };
        var row = new Grid { ColumnSpacing = 8 };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        Rectangle Line() => new() { Height = 1, Fill = Ui.Tertiary, VerticalAlignment = VerticalAlignment.Center, Opacity = 0.6 };
        var l1 = Line(); row.Children.Add(l1);
        var t = Ui.Text(text.ToUpper(System.Globalization.CultureInfo.GetCultureInfo("da-DK")), "CaptionTextBlockStyle", Ui.Secondary, wrap: false, weight: FontWeights.Bold);
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
