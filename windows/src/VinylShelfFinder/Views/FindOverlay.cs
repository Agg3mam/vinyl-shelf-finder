using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Windows.System;
using VinylShelfFinder.Core;
using VinylShelfFinder.UI;

namespace VinylShelfFinder.Views;

/// <summary>
/// "Find i reolen" (FindModeView i Sheets.swift): gå hertil, find først X, derefter Y.
/// Samme flade er "Sæt tilbage"-guiden for en plade, der har været ude af reolen; først
/// "Sat på plads" registrerer den som hjemme. Vises som et lag over hele vinduet (ikke en
/// ContentDialog), så skærmbilledet i CI kan fange det.
/// </summary>
public sealed class FindOverlay
{
    private readonly AppModel _model;
    private readonly Grid _root = new() { Visibility = Visibility.Collapsed };
    private readonly Border _card;
    private readonly ScrollViewer _scroll = new() { HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled };
    private long? _copy;
    private bool _putBack;
    private bool _switchedToPutBack;

    public FrameworkElement View => _root;
    public bool IsOpen => _copy is not null;

    public FindOverlay(AppModel model)
    {
        _model = model;
        // Dæmpet baggrund; klik udenfor lukker (som et ark på Mac).
        var dim = new Grid { Background = new Microsoft.UI.Xaml.Media.SolidColorBrush(Windows.UI.Color.FromArgb(0x80, 0, 0, 0)) };
        dim.Tapped += (_, _) => Close();
        _root.Children.Add(dim);
        _card = new Border
        {
            MaxWidth = 640,
            MaxHeight = 900,
            Margin = new Thickness(24),
            CornerRadius = new CornerRadius(12),
            Background = Ui.ThemeBrush("SolidBackgroundFillColorBaseBrush"),
            BorderBrush = Ui.CardStroke,
            BorderThickness = new Thickness(1),
            HorizontalAlignment = HorizontalAlignment.Stretch,
            VerticalAlignment = VerticalAlignment.Center,
            Child = _scroll,
        };
        _root.Children.Add(_card);
        _root.KeyDown += OnKey;
    }

    public void OnModelChanged(string? property)
    {
        switch (property)
        {
            case nameof(AppModel.FindModeCopy):
                if (_model.FindModeCopy is long f) Open(f, putBack: false);
                else if (!_putBack) Hide();
                break;
            case nameof(AppModel.ReturnCopy):
                if (_model.ReturnCopy is long r) Open(r, putBack: true);
                else if (_putBack) Hide();
                break;
            case nameof(AppModel.Library):
                if (_copy is long c)
                {
                    if (_model.Library.Item(c) is null) Close();
                    else Rebuild();
                }
                break;
        }
    }

    private void Open(long copyId, bool putBack)
    {
        _copy = copyId;
        _putBack = putBack;
        _switchedToPutBack = false;
        Rebuild();
        _root.Visibility = Visibility.Visible;
        _scroll.ChangeView(null, 0, null, true);
        _root.DispatcherQueue.TryEnqueue(() => FocusDefault());
    }

    private void Hide()
    {
        _copy = null;
        _putBack = false;
        _switchedToPutBack = false;
        _root.Visibility = Visibility.Collapsed;
        _scroll.Content = null;
    }

    /// <summary>Luk uden at ændre noget (Esc, "Annullér", "OK", "Fundet").</summary>
    public void Close()
    {
        if (_model.FindModeCopy is not null) _model.FindModeCopy = null;
        if (_model.ReturnCopy is not null) _model.ReturnCopy = null;
        Hide();
    }

    private bool PuttingBack => _putBack || _switchedToPutBack;
    private Button? _default;

    private void FocusDefault() => _default?.Focus(FocusState.Programmatic);

    private void OnKey(object sender, KeyRoutedEventArgs e)
    {
        if (e.Key == VirtualKey.Escape) { Close(); e.Handled = true; }
    }

    private void Rebuild()
    {
        if (_copy is not long id || _model.Library.Item(id) is not RecordItem it) { _scroll.Content = null; return; }
        var p = new StackPanel { Spacing = 20, Padding = new Thickness(32) };
        if (!PuttingBack && it.AwayMessage() is string away)
            p.Children.Add(AwayBanner(away, it.Copy.Status.StatusGlyph()));
        p.Children.Add(Header(it, PuttingBack ? "Sæt tilbage" : "Find"));
        p.Children.Add(Placement(id, it));
        p.Children.Add(Actions(it));
        _scroll.Content = p;
    }

    private static FrameworkElement AwayBanner(string text, string glyph)
    {
        var l = Ui.Label(glyph, text, "SubtitleTextBlockStyle", iconSize: 18);
        return new Border
        {
            Child = l,
            Padding = new Thickness(16, 10, 16, 10),
            CornerRadius = new CornerRadius(10),
            Background = Ui.CautionBackground,
            BorderBrush = Ui.Caution,
            BorderThickness = new Thickness(1),
        };
    }

    private static FrameworkElement Header(RecordItem it, string eyebrow)
    {
        var grid = new Grid { ColumnSpacing = 16 };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        var cover = Ui.Cover(it.Release, 88);
        cover.VerticalAlignment = VerticalAlignment.Center;
        grid.Children.Add(cover);
        var text = new StackPanel { Spacing = 2, VerticalAlignment = VerticalAlignment.Center };
        text.Children.Add(Ui.Eyebrow(eyebrow));
        text.Children.Add(Ui.Text(it.Artist, "SubtitleTextBlockStyle", Ui.Secondary, maxLines: 2));
        text.Children.Add(Ui.Text(it.Title, "TitleTextBlockStyle", maxLines: 2));
        text.Children.Add(RecordParts.PressingLines(it));
        Grid.SetColumn(text, 1);
        grid.Children.Add(text);
        return grid;
    }

    private FrameworkElement Placement(long id, RecordItem it)
    {
        var lib = _model.Library;
        bool putBack = PuttingBack;
        if (lib.LocationOf(id) is not Location loc
            || (putBack ? lib.ReturnAdviceFor(id) : lib.ReferenceAdviceFor(id)) is not ReferenceAdvice adv
            || lib.NeighborsOf(id) is not Neighbors n)
        {
            return Ui.Card(Ui.Label(Ui.Glyph.Help, "Pladen har endnu ingen fysisk placering.", "SubtitleTextBlockStyle"), 20);
        }
        // Står pladen ikke i reolen, er navigationen kun til orientering: nedtonet. I guiden er den hovedsagen.
        bool away = !it.Copy.Status.IsOnShelf();
        int position = n.Position ?? 1;
        var p = new StackPanel { Spacing = 20, Opacity = away && !putBack ? 0.55 : 1 };
        p.Children.Add(RecordParts.LocationPanel(
            putBack ? "Sæt den her" : away ? "Her plejer den at stå" : "Gå til", loc, position, n.SectionCount,
            putBack ? adv.PlacementHint : $"{(away ? "Plads" : "Nr.")} {position} af {n.SectionCount} fra venstre",
            lineSize: 26));
        var refs = new Grid { ColumnSpacing = 20 };
        refs.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        refs.Children.Add(ReferenceBlock("Start ved", adv.Primary));
        if (adv.Secondary is Reference s)
        {
            refs.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            var b = ReferenceBlock("Så", s);
            Grid.SetColumn(b, 1);
            refs.Children.Add(b);
        }
        p.Children.Add(refs);
        var hints = new StackPanel { Spacing = 6 };
        if (adv.ArtistBlockHint is string hint) hints.Children.Add(Ui.Label(Ui.Glyph.Layers, hint, color: Ui.Secondary));
        if (adv.SectionEdgeHint is string edge)
            hints.Children.Add(Ui.Label(n.ReachedSectionEnd ? Ui.Glyph.ToEnd : Ui.Glyph.ToStart, edge, color: Ui.Secondary));
        if (hints.Children.Count > 0) p.Children.Add(hints);
        return p;
    }

    private static FrameworkElement ReferenceBlock(string title, Reference r)
    {
        var p = new StackPanel { Spacing = 8 };
        p.Children.Add(Ui.Eyebrow(title));
        if (r.Item is RecordItem it)
        {
            var row = new Grid { ColumnSpacing = 10 };
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            var cover = Ui.Cover(it.Release, 48);
            cover.VerticalAlignment = VerticalAlignment.Top;
            row.Children.Add(cover);
            var t = new StackPanel { Spacing = 2 };
            t.Children.Add(Ui.Text(it.Artist, "BodyTextBlockStyle", Ui.Secondary, maxLines: 2));
            t.Children.Add(Ui.Text(it.Title, "SubtitleTextBlockStyle", maxLines: 3));
            Grid.SetColumn(t, 1);
            row.Children.Add(t);
            p.Children.Add(row);
        }
        else
        {
            p.Children.Add(Ui.Text(r.Side == ReferenceSide.SectionStart ? "Sektionens venstre kant" : "Sektionens højre kant", "SubtitleTextBlockStyle"));
        }
        // Ingen pil: retningen står entydigt i teksten, set fra målpladen.
        p.Children.Add(Ui.Text(r.Reason, "BodyTextBlockStyle", Ui.Secondary));
        return p;
    }

    private FrameworkElement Actions(RecordItem it)
    {
        var p = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 12, 0, 0) };
        Button primary;
        if (PuttingBack)
        {
            p.Children.Add(Ui.Btn("Annullér", (_, _) => Close(), tooltip: "Luk uden at ændre noget (Esc)"));
            primary = Ui.Btn("Sat på plads", (_, _) =>
            {
                var id = it.Id;
                Close();
                _model.FinishReturn(id);
            }, Ui.Glyph.Check, accent: true, tooltip: "Registrér pladen som på plads i reolen (Enter)");
        }
        else if (it.AwayMessage() is not null)
        {
            if (_model.Library.LocationOfCopy.ContainsKey(it.Id))
                p.Children.Add(Ui.Btn("Sæt den tilbage nu", (_, _) => { _switchedToPutBack = true; Rebuild(); FocusDefault(); },
                    Ui.Glyph.Undo, tooltip: "Vis præcis, hvor pladen skal stå, når du sætter den tilbage"));
            primary = Ui.Btn("OK", (_, _) => Close(), accent: true);
        }
        else
        {
            primary = Ui.Btn("Fundet", (_, _) => Close(), Ui.Glyph.Check, accent: true);
        }
        primary.KeyboardAccelerators.Add(new KeyboardAccelerator { Key = VirtualKey.Enter });
        p.Children.Add(primary);
        _default = primary;
        return p;
    }
}
