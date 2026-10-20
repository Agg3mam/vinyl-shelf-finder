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
    private static readonly FontFamily SerifFont = new("Georgia");

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
        // Overskrifter med fødder i de varme stile (som Mac, telefonen og webappen).
        if (Style.SerifTitles() && style is "TitleTextBlockStyle" or "TitleLargeTextBlockStyle" or "DisplayTextBlockStyle") t.FontFamily = SerifFont;
        if (color is not null) t.Foreground = color;
        if (weight is Windows.UI.Text.FontWeight w) t.FontWeight = w;
        if (size is double s) t.FontSize = s;
        return t;
    }

    /// <summary>Lille versal-overskrift ("GÅ TIL", "FIND FØRST").</summary>
    public static TextBlock Eyebrow(string text) => new()
    {
        Text = text.ToUpper(System.Globalization.CultureInfo.GetCultureInfo("da-DK")),
        Style = Res<Style>("CaptionTextBlockStyle"),
        FontWeight = FontWeights.SemiBold,
        CharacterSpacing = 60,
        Foreground = Tertiary,
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

    /// <summary>Cover i fast størrelse. Uden billede (eller uden net): en neutral flade med et pladesymbol.</summary>
    public static FrameworkElement Cover(Release release, double size)
    {
        bool large = size > 80;
        var grid = new Grid
        {
            Width = size,
            Height = size,
            CornerRadius = new CornerRadius(large ? 8 : 4),
            Background = ControlFill,
        };
        grid.Children.Add(new FontIcon
        {
            Glyph = Glyph.Disc,
            FontSize = Math.Round(size * 0.42),
            Foreground = Tertiary,
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center,
        });
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
