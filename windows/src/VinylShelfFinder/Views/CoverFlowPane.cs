using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Windows.System;
using VinylShelfFinder.Core;
using VinylShelfFinder.UI;

namespace VinylShelfFinder.Views;

/// <summary>
/// Cover Flow (CoverFlowView.swift): sektionens plader i reolens rækkefølge, vist i højre kolonne.
/// Midterpladen er altid den valgte plade, så listen og Cover Flow følger hinanden. Styres med
/// ← →, musehjul/touchpad, klik på et sidecover og Enter eller klik på midten (Find i reolen).
/// </summary>
public sealed class CoverFlowPane
{
    private readonly AppModel _model;
    private readonly Grid _root = new() { Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent), IsTabStop = true };
    private readonly Canvas _strip = new();
    private readonly StackPanel _caption = new() { Spacing = 4, HorizontalAlignment = HorizontalAlignment.Center };
    private readonly ScrollStepper _stepper = new();
    private long _locationId;
    private List<RecordItem> _items = new();

    public FrameworkElement View => _root;

    public CoverFlowPane(AppModel model)
    {
        _model = model;
        _root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        _root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        _root.Padding = new Thickness(24);
        _root.Children.Add(_strip);
        Grid.SetRow(_caption, 1);
        _root.Children.Add(_caption);
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(_root, "Cover Flow");
        _strip.SizeChanged += (_, _) => Layout();
        _root.PointerWheelChanged += (_, e) =>
        {
            var pt = e.GetCurrentPoint(_root).Properties;
            // Vandret på touchpad (eller vandret hjul) og lodret hjul flytter begge en plade ad gangen.
            int delta = pt.IsHorizontalMouseWheel ? pt.MouseWheelDelta : -pt.MouseWheelDelta;
            bool precise = Math.Abs(pt.MouseWheelDelta) < 120;
            int steps = _stepper.Add(precise ? delta : delta / 120.0, precise);
            if (steps != 0) Step(steps);
            e.Handled = true;
        };
        _root.KeyDown += (_, e) =>
        {
            switch (e.Key)
            {
                case VirtualKey.Left: case VirtualKey.Up: Step(-1); e.Handled = true; break;
                case VirtualKey.Right: case VirtualKey.Down: Step(1); e.Handled = true; break;
                case VirtualKey.Enter:
                    if (Current is RecordItem c) _model.FindModeCopy = c.Id;
                    e.Handled = true;
                    break;
            }
        };
        _root.PointerPressed += (_, _) => _root.Focus(FocusState.Pointer);
    }

    public void Show(long locationId)
    {
        _locationId = locationId;
        _stepper.Reset();
        Reload();
        // Står den valgte plade ikke i sektionen, vælges den første (som i listen).
        if (Current is null || _model.Selection != Current.Id) _model.Selection = _items.FirstOrDefault()?.Id;
        Layout();
    }

    public void OnModelChanged(string? property)
    {
        if (property is nameof(AppModel.Library)) { Reload(); Layout(); }
        else if (property is nameof(AppModel.Selection)) Layout();
    }

    private void Reload() => _items = _model.Library.ItemsIn(_locationId);

    private int CenterIndex => Math.Max(0, _items.FindIndex(i => i.Id == _model.Selection));
    private RecordItem? Current => _items.Count == 0 ? null : _items[Math.Min(CenterIndex, _items.Count - 1)];

    private void Step(int delta)
    {
        if (_items.Count == 0) return;
        int target = Math.Clamp(CenterIndex + delta, 0, _items.Count - 1);
        if (target != CenterIndex) _model.Selection = _items[target].Id;
    }

    private void Layout()
    {
        _strip.Children.Clear();
        double w = _strip.ActualWidth, h = _strip.ActualHeight;
        int center = CenterIndex;
        if (w > 0 && h > 0 && _items.Count > 0)
        {
            double side = CoverFlowGeometry.Side(w, Math.Min(h, 460));
            var (start, end) = CoverFlowGeometry.VisibleRange(center, _items.Count);
            // Fjerneste først, så de nærmeste ligger øverst.
            foreach (int i in Enumerable.Range(start, end - start).OrderBy(i => -Math.Abs(i - center)))
            {
                var item = _items[i];
                double o = i - center;
                var cover = Ui.Cover(item.Release, side);
                cover.Opacity = _model.IsAway(item.Id) ? 0.45 : 1;
                double scale = CoverFlowGeometry.Scale(o);
                var b = new Button
                {
                    Content = cover,
                    Padding = new Thickness(0),
                    Background = null,
                    BorderThickness = new Thickness(0),
                    // WinUI's PlaneProjection drejer modsat vej af SwiftUI.
                    Projection = new PlaneProjection { RotationY = -CoverFlowGeometry.Angle(o) },
                    RenderTransform = new ScaleTransform { ScaleX = scale, ScaleY = scale, CenterX = side / 2, CenterY = side / 2 },
                };
                Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(b, item.FullName);
                int idx = i;
                b.Click += (_, _) =>
                {
                    if (idx == CenterIndex) _model.FindModeCopy = item.Id;
                    else _model.Selection = item.Id;
                };
                Canvas.SetLeft(b, w / 2 - side / 2 + CoverFlowGeometry.X(o, side));
                Canvas.SetTop(b, Math.Max(0, (h - side) / 2 - side * CoverFlowGeometry.ReflectionHeight / 2));
                Canvas.SetZIndex(b, (int)(1000 + CoverFlowGeometry.ZIndex(o) * 10));
                _strip.Children.Add(b);
            }
        }
        Caption();
    }

    private void Caption()
    {
        _caption.Children.Clear();
        if (Current is not RecordItem it)
        {
            _caption.Children.Add(Ui.Text("Sektionen er tom.", color: Ui.Secondary));
            return;
        }
        var numbers = _model.Library.ShelfNumbers(_locationId);
        int onShelf = _model.Library.OnShelfCount(_locationId);
        TextBlock Center(TextBlock t) { t.HorizontalAlignment = HorizontalAlignment.Center; t.TextAlignment = TextAlignment.Center; return t; }
        _caption.Children.Add(Center(Ui.Text(it.Title, "SubtitleTextBlockStyle", wrap: false)));
        _caption.Children.Add(Center(Ui.Text(it.Artist, "BodyLargeTextBlockStyle", Ui.Secondary, wrap: false)));
        _caption.Children.Add(Center(Ui.Text(numbers.TryGetValue(it.Id, out var n) ? $"Nr. {n} af {onShelf}" : it.AwayMessage() ?? "Ude af reolen",
            "BodyTextBlockStyle", Ui.Tertiary, wrap: false)));
        var find = Ui.Btn("Find i reolen", (_, _) => _model.FindModeCopy = it.Id, Ui.Glyph.Pin, accent: true, tooltip: "Find i reolen (Enter)");
        find.HorizontalAlignment = HorizontalAlignment.Center;
        find.Margin = new Thickness(0, 8, 0, 0);
        _caption.Children.Add(find);
    }
}
