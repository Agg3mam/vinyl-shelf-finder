using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using VinylShelfFinder.Core;

namespace VinylShelfFinder.UI;

/// <summary>
/// Små byggeklodser til skærmene, som bygges i C# (ikke XAML), så de er lette at holde ens:
/// tekststile, ikoner (Segoe Fluent Icons), covers, placeringsmærket "2A" og kort.
/// Farver og stile hentes fra WinUI's egne temaressourcer, så lys og mørk tilstand virker.
/// </summary>
public static class Ui
{
    // MARK: Glyffer (Segoe Fluent Icons / Segoe MDL2 Assets)

    public static class Glyph
    {
        public const string Music = "\uEC4F";
        public const string Search = "";
        public const string Value = "";
        public const string Bag = "";
        public const string Shuffle = "";
        public const string List = "";
        public const string New = "";
        public const string Warning = "";
        public const string Package = "";
        public const string Library = "";
        public const string History = "";
        public const string Disc = "";
        public const string Home = "";
        public const string Person = "";
        public const string Photo = "";
        public const string Help = "";
        public const string Swap = "";
        public const string Pin = "";
        public const string Check = "";
        public const string ChevronRight = "";
        public const string Play = "";
        public const string Undo = "";
        public const string Dashed = "";
        public const string Layers = "";
        public const string ToStart = "";
        public const string ToEnd = "";
        public const string Back = "";
        public const string Forward = "";
        public const string Checklist = "\uE9D5";
        public const string Refresh = "\uE72C";
        public const string Lock = "\uE72E";
        public const string Download = "\uE896";
        public const string Heart = "\uEB51";
        public const string Cancel = "\uE711";
        public const string Add = "\uE710";
        public const string QrCode = "\uED14";
        public const string ChevronDown = "\uE70D";
        public const string OpenInWindow = "\uE8A7";
        public const string Calendar = "\uE787";
        public const string Sync = "\uE895";
        public const string Tag = "\uE8EC";
        public const string Edit = "\uE70F";
        public const string Info = "\uE946";
    }

    public static string StatusGlyph(this CopyStatus s) => s switch
    {
        CopyStatus.Home => Glyph.Home,
        CopyStatus.Playing => Glyph.Music,
        CopyStatus.Wall => Glyph.Photo,
        CopyStatus.Stored => Glyph.Package,
        CopyStatus.Lent => Glyph.Person,
        _ => Glyph.Help,
    };

    /// <summary>Statusser, hvor appen spørger efter et navn eller et sted.</summary>
    public static bool WantsNote(this CopyStatus s) => s is CopyStatus.Lent or CopyStatus.Stored;

    /// <summary>Kort tekst til lister, fx "Udlånt til Jens" eller "Opbevaret: kælderen".</summary>
    public static string ListText(this CopyStatus s, string? note)
    {
        var n = note?.Trim() ?? "";
        if (n.Length == 0) return s.Label();
        return s switch
        {
            CopyStatus.Lent => $"Udlånt til {n}",
            CopyStatus.Stored => $"Opbevaret: {n}",
            _ => $"{s.Label()} – {n}",
        };
    }

    /// <summary>Én tydelig sætning, når pladen ikke står i reolen. null når den står på plads.</summary>
    public static string? AwayMessage(this RecordItem it)
    {
        var note = it.Copy.StatusNote?.Trim() ?? "";
        bool has = note.Length > 0;
        return it.Copy.Status switch
        {
            CopyStatus.Home => null,
            CopyStatus.Playing => "På pladespilleren – står ikke i reolen",
            CopyStatus.Wall => "Hænger på væggen – står ikke i reolen",
            CopyStatus.Lent => has ? $"Udlånt til {note} – står ikke i reolen" : "Udlånt – står ikke i reolen",
            CopyStatus.Stored => has ? $"Opbevaret andet sted ({note}) – står ikke i reolen" : "Opbevaret andet sted – står ikke i reolen",
            _ => "Mangler – står ikke i reolen",
        };
    }

    /// <summary>"1 plade" / "2 plader".</summary>
    public static string Plader(int n) => n == 1 ? "1 plade" : $"{n} plader";

    // MARK: Ressourcer

    public static T Res<T>(string key) where T : class =>
        Application.Current.Resources.TryGetValue(key, out var v) && v is T t ? t : throw new KeyNotFoundException(key);

    public static Brush ThemeBrush(string key) =>
        Application.Current.Resources.TryGetValue(key, out var v) && v is Brush b ? b : new SolidColorBrush(Microsoft.UI.Colors.Gray);

    public static Brush Primary => ThemeBrush("TextFillColorPrimaryBrush");
    public static Brush Secondary => ThemeBrush("TextFillColorSecondaryBrush");
    public static Brush Tertiary => ThemeBrush("TextFillColorTertiaryBrush");
    public static Brush Accent => ThemeBrush("AccentTextFillColorPrimaryBrush");
    public static Brush AccentFill => ThemeBrush("AccentFillColorDefaultBrush");
    public static Brush Caution => ThemeBrush("SystemFillColorCautionBrush");
    public static Brush CautionBackground => ThemeBrush("SystemFillColorCautionBackgroundBrush");
    public static Brush CardBackground => ThemeBrush("CardBackgroundFillColorDefaultBrush");
    public static Brush CardStroke => ThemeBrush("CardStrokeColorDefaultBrush");
    public static Brush Subtle => ThemeBrush("SubtleFillColorSecondaryBrush");
    public static Brush ControlFill => ThemeBrush("ControlFillColorSecondaryBrush");

    /// <summary>Appens accentfarve (blågrøn, se App.xaml) med en given gennemsigtighed.</summary>
    public static Brush AccentTint(double opacity)
    {
        var c = Application.Current.Resources.TryGetValue("SystemAccentColor", out var v) && v is Windows.UI.Color col
            ? col : Windows.UI.Color.FromArgb(255, 0x1C, 0x6E, 0x66);
        return new SolidColorBrush(c) { Opacity = opacity };
    }

    // MARK: Tekst

    /// <summary>Den valgte stil (Indstillinger › Udseende). Sættes af MainWindow.ApplyLook.</summary>
    public static LookStyle Style { get; set; } = LookStyle.Standard;

    public static TextBlock Text(string text, string style = "BodyTextBlockStyle", Brush? color = null, bool wrap = true,
                                 int maxLines = 0, Windows.UI.Text.FontWeight? weight = null, double? size = null)
    {
        var t = new TextBlock
        {
            Text = text,
            // En ukendt stil må aldrig få appen til at gå ned: brug brødtekst i stedet.
            Style = Application.Current.Resources.TryGetValue(style, out var st) && st is Style found ? found : Res<Style>("BodyTextBlockStyle"),
            TextWrapping = wrap ? TextWrapping.WrapWholeWords : TextWrapping.NoWrap,
            TextTrimming = TextTrimming.CharacterEllipsis,
            MaxLines = maxLines,
            IsTextSelectionEnabled = false,
        };
        // Smalle overskrifter som skillekortet i stilene (som Mac, telefonen og webappen).
        if (Style.CondensedTitles() && style is "TitleTextBlockStyle" or "TitleLargeTextBlockStyle" or "DisplayTextBlockStyle")
        {
            t.FontFamily = Condensed;
            t.FontStretch = Windows.UI.Text.FontStretch.Condensed;
        }
        if (color is not null) t.Foreground = color;
        if (weight is Windows.UI.Text.FontWeight w) t.FontWeight = w;
        if (size is double s) t.FontSize = s;
        return t;
    }

    /// <summary>Lille overskrift ("Gå til", "Start ved") i almindelige bogstaver (som på Mac).</summary>
    public static TextBlock Eyebrow(string text) => new()
    {
        Text = text,
        Style = Res<Style>("BodyStrongTextBlockStyle"),
        Foreground = Secondary,
    };

    /// <summary>Den smalle, kraftige skrift til skillekortet og tal (som den smalle systemskrift på Mac).</summary>
    public static readonly FontFamily Condensed = new("Bahnschrift");

    /// <summary>Tekst i den smalle skrift.</summary>
    public static TextBlock CondensedText(string text, double size, bool bold = true, Brush? color = null)
    {
        var t = new TextBlock { Text = text, FontFamily = Condensed, FontSize = size, FontStretch = Windows.UI.Text.FontStretch.Condensed,
            FontWeight = bold ? FontWeights.Bold : FontWeights.Medium };
        if (color is not null) t.Foreground = color;
        return t;
    }

    public static Windows.UI.Color Hex(uint rgb) => Windows.UI.Color.FromArgb(255, (byte)(rgb >> 16), (byte)(rgb >> 8), (byte)rgb);

    /// <summary>Kategoriens farve i det aktuelle tema (lys/mørk).</summary>
    public static SolidColorBrush CategoryBrush(Category c)
    {
        var (light, dark) = c.ColorHex();
        return new SolidColorBrush(Hex(IsDark ? dark : light));
    }

    /// <summary>Vinduet vises mørkt (sættes af hovedvinduet, når temaet skifter).</summary>
    public static bool IsDark { get; set; }

    /// <summary>Kunstnerens faste farve til blanke omslag (samme mønster som CoverTone.fallback på Mac).</summary>
    public static SolidColorBrush SleeveBrush(string artist)
    {
        ulong h = 0xcbf29ce484222325;
        foreach (var b in System.Text.Encoding.UTF8.GetBytes(artist.ToLowerInvariant())) h = (h ^ b) * 0x100000001b3;
        double hue = (h % 24) / 24.0;
        double sat = new[] { 0.30, 0.42 }[(int)((h / 24) % 2)];
        sat = Math.Min(Math.Max(sat, 0.5), 0.75);
        return new SolidColorBrush(FromHsb(hue, sat, 0.34));
    }

    private static Windows.UI.Color FromHsb(double h, double s, double v)
    {
        double i = Math.Floor(h * 6), f = h * 6 - i, p = v * (1 - s), q = v * (1 - f * s), t = v * (1 - (1 - f) * s);
        var (r, g, b) = ((int)i % 6) switch { 0 => (v, t, p), 1 => (q, v, p), 2 => (p, v, t), 3 => (p, q, v), 4 => (t, p, v), _ => (v, p, q) };
        return Windows.UI.Color.FromArgb(255, (byte)Math.Round(r * 255), (byte)Math.Round(g * 255), (byte)Math.Round(b * 255));
    }

    /// <summary>"Pink Floyd" → "PF", "Madonna" → "MA", "The Beatles" → "B" (som på Mac).</summary>
    public static string Initials(string artist)
    {
        var words = artist.Split(' ', StringSplitOptions.RemoveEmptyEntries).Where(w => !w.Equals("the", StringComparison.OrdinalIgnoreCase)).ToList();
        if (words.Count >= 2) return (words[0][..1] + words[1][..1]).ToUpperInvariant();
        return (words.FirstOrDefault() is string w ? w[..Math.Min(2, w.Length)] : "").ToUpperInvariant();
    }

    /// <summary>Lille fane med et bogstav til lister og sidepanelet (sektioner og kategorier).</summary>
    public static Border SectionTab(string letter, Brush fill) => new()
    {
        Width = 16, Height = 15,
        CornerRadius = new CornerRadius(4, 4, 0, 0),
        Background = fill,
        Child = new TextBlock { Text = letter, FontFamily = Condensed, FontStretch = Windows.UI.Text.FontStretch.Condensed, FontWeight = FontWeights.Bold,
            FontSize = 11, Foreground = new SolidColorBrush(Microsoft.UI.Colors.White), HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center },
    };

    public static FontIcon Icon(string glyph, double size = 16, Brush? color = null)
    {
        var i = new FontIcon { Glyph = glyph, FontSize = size };
        if (color is not null) i.Foreground = color;
        return i;
    }

    /// <summary>Ikon og tekst på én linje (som SwiftUI's Label).</summary>
    public static StackPanel Label(string glyph, string text, string style = "BodyTextBlockStyle", Brush? color = null, double iconSize = 14)
    {
        var p = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        var icon = Icon(glyph, iconSize, color);
        icon.VerticalAlignment = VerticalAlignment.Center;
        p.Children.Add(icon);
        var t = Text(text, style, color);
        t.VerticalAlignment = VerticalAlignment.Center;
        p.Children.Add(t);
        return p;
    }

    public static StackPanel VStack(double spacing, params UIElement[] children)
    {
        var p = new StackPanel { Spacing = spacing };
        foreach (var c in children) p.Children.Add(c);
        return p;
    }

    public static StackPanel HStack(double spacing, params UIElement[] children)
    {
        var p = new StackPanel { Orientation = Orientation.Horizontal, Spacing = spacing };
        foreach (var c in children) p.Children.Add(c);
        return p;
    }

    /// <summary>Kort med WinUI's kortbaggrund og -kant (som Indstillinger i Windows 11).</summary>
    public static Border Card(UIElement child, double padding = 16) => new()
    {
        Child = child,
        Padding = new Thickness(padding),
        CornerRadius = new CornerRadius(8),
        Background = CardBackground,
        BorderBrush = CardStroke,
        BorderThickness = new Thickness(1),
    };

    /// <summary>Det lille placeringsmærke ("2A"/"Ny"). Ét udseende overalt.</summary>
    public static Border LocationBadge(string text, bool caution = false, string? tooltip = null)
    {
        var b = new Border
        {
            CornerRadius = new CornerRadius(10),
            Padding = new Thickness(7, 1, 7, 2),
            Background = caution ? CautionBackground : AccentTint(0.15),
            VerticalAlignment = VerticalAlignment.Center,
            Child = new TextBlock
            {
                Text = text,
                Style = Res<Style>("CaptionTextBlockStyle"),
                FontWeight = FontWeights.SemiBold,
                FontFamily = new FontFamily("Cascadia Mono, Consolas"),
                Foreground = caution ? Primary : Accent,
            },
        };
        if (tooltip is not null) ToolTipService.SetToolTip(b, tooltip);
        return b;
    }

    public static Border Divider() => new()
    {
        Height = 1,
        Background = ThemeBrush("DividerStrokeColorDefaultBrush"),
        Margin = new Thickness(0, 4, 0, 4),
    };

    // MARK: Cover

    /// <summary>Henter covers fra nettet? Slået fra i demo- og smoke-tilstand (ingen net).</summary>
    public static bool AllowNetworkCovers { get; set; } = true;

    /// <summary>Cover i fast størrelse. Uden billede (eller uden net): et blankt omslag i kunstnerens farve med navnet
    /// trykt på (forbogstaverne i små størrelser), som på Mac.</summary>
    public static FrameworkElement Cover(Release release, double size)
    {
        bool large = size > 80;
        var grid = new Grid
        {
            Width = size,
            Height = size,
            CornerRadius = new CornerRadius(large ? 8 : 4),
            Background = SleeveBrush(release.Artist),
        };
        var white = new SolidColorBrush(Microsoft.UI.Colors.White);
        if (large)
        {
            var names = new StackPanel { Spacing = 2, VerticalAlignment = VerticalAlignment.Bottom, Margin = new Thickness(size * 0.08) };
            var a = CondensedText(release.Artist, Math.Round(size * 0.11), color: white); a.TextTrimming = TextTrimming.CharacterEllipsis; a.MaxLines = 2; a.TextWrapping = TextWrapping.Wrap;
            var t = CondensedText(release.Title, Math.Round(size * 0.08), bold: false, color: white); t.Opacity = 0.85; t.TextTrimming = TextTrimming.CharacterEllipsis; t.MaxLines = 2; t.TextWrapping = TextWrapping.Wrap;
            names.Children.Add(a); names.Children.Add(t);
            grid.Children.Add(names);
        }
        else
        {
            var i = CondensedText(Initials(release.Artist), Math.Round(size * 0.4), color: white);
            i.Opacity = 0.92; i.HorizontalAlignment = HorizontalAlignment.Center; i.VerticalAlignment = VerticalAlignment.Center;
            grid.Children.Add(i);
        }
        var url = large ? release.CoverUrl ?? release.ThumbUrl : release.ThumbUrl ?? release.CoverUrl;
        if (AllowNetworkCovers && !string.IsNullOrEmpty(url) && Uri.TryCreate(url, UriKind.Absolute, out var uri)
            && uri.Scheme == Uri.UriSchemeHttps)
        {
            var bmp = new BitmapImage { DecodePixelWidth = (int)Math.Ceiling(size * 2), UriSource = uri };
            grid.Children.Add(new Image { Source = bmp, Stretch = Stretch.UniformToFill });
        }
        AutomationHidden(grid);
        return grid;
    }

    public static void AutomationHidden(UIElement e) =>
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetAccessibilityView(e, Microsoft.UI.Xaml.Automation.Peers.AccessibilityView.Raw);

    /// <summary>"Tom tilstand" midt på en flade (som ContentUnavailableView på Mac).</summary>
    public static FrameworkElement Empty(string glyph, string title, string description)
    {
        var p = new StackPanel
        {
            Spacing = 8,
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center,
            MaxWidth = 360,
            Padding = new Thickness(24),
        };
        var icon = Icon(glyph, 40, Tertiary);
        icon.Margin = new Thickness(0, 0, 0, 8);
        p.Children.Add(icon);
        var t = Text(title, "SubtitleTextBlockStyle");
        t.HorizontalAlignment = HorizontalAlignment.Center;
        t.TextAlignment = TextAlignment.Center;
        p.Children.Add(t);
        var d = Text(description, "BodyTextBlockStyle", Secondary);
        d.HorizontalAlignment = HorizontalAlignment.Center;
        d.TextAlignment = TextAlignment.Center;
        p.Children.Add(d);
        return p;
    }

    public static Button Btn(string text, RoutedEventHandler click, string? glyph = null, bool accent = false, string? tooltip = null)
    {
        object content = glyph is null ? text : HStack(8, Icon(glyph, 14), new TextBlock { Text = text, VerticalAlignment = VerticalAlignment.Center });
        var b = new Button { Content = content };
        if (accent) b.Style = Res<Style>("AccentButtonStyle");
        b.Click += click;
        if (tooltip is not null) ToolTipService.SetToolTip(b, tooltip);
        return b;
    }
}
