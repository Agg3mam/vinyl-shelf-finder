using System.Diagnostics;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Windows.System;
using VinylShelfFinder.Core;
using VinylShelfFinder.UI;

namespace VinylShelfFinder.Views;

/// <summary>
/// Cover Flow (CoverFlowView.swift), vist i højre kolonne. To slags:
/// en sektion (<see cref="Show"/>): sektionens plader i reolens rækkefølge, og midterpladen er altid den valgte plade,
/// så listen og Cover Flow følger hinanden; og "Hvad skal jeg høre?" (<see cref="ShowListen"/>): hele reolen, som snurrer
/// hen til forslaget som et lykkehjul. Styres med ← →, musehjul/touchpad, træk med musen eller fingeren (et kraftigt
/// stryg fortsætter med farten og bremser op), klik på et sidecover og Enter eller klik på midten (Find i reolen).
/// Hvid baggrund i lys tilstand og sort i mørk – som på Mac og telefonen.
/// </summary>
public sealed class CoverFlowPane
{
    private readonly AppModel _model;
    private readonly Grid _root = new() { IsTabStop = true };
    private readonly Canvas _strip = new() { Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent) };
    private readonly StackPanel _caption = new() { Spacing = 4, HorizontalAlignment = HorizontalAlignment.Center };
    private readonly ScrollStepper _stepper = new();
    private readonly Dictionary<long, Button> _nodes = new();
    private double _nodeSide;
    private long _locationId;
    private bool _listen;
    private List<RecordItem> _items = new();
    private int _center;
    /// <summary>Hvor langt rækken er skubbet under et træk eller glid (i plader, positiv = mod næste plade).</summary>
    private double _shift;
    private long? _captionId;

    // Træk med musen eller fingeren.
    private uint? _pointer;
    private double _startX, _lastX;
    private bool _dragging, _justDragged;
    private readonly List<(double T, double X)> _samples = new();

    // Glid (efter et stryg, et trin eller lykkehjulet).
    private readonly Stopwatch _clock = Stopwatch.StartNew();
    private bool _gliding, _spinning;
    private double _glideFrom, _glideTotal, _glideBegin, _glideDuration;
    private int _glideTarget;
    private double _popUntil;

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
        ApplyTheme();
        _root.ActualThemeChanged += (_, _) => ApplyTheme();
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
                    StopGlide();
                    if (Current is RecordItem c) _model.FindModeCopy = c.Id;
                    e.Handled = true;
                    break;
            }
        };
        // Også når et cover (en knap) tager imod trykket, så man kan trække fra et cover.
        _strip.AddHandler(UIElement.PointerPressedEvent, new PointerEventHandler(OnPressed), true);
        _strip.AddHandler(UIElement.PointerMovedEvent, new PointerEventHandler(OnMoved), true);
        _strip.AddHandler(UIElement.PointerReleasedEvent, new PointerEventHandler(OnReleased), true);
        _strip.AddHandler(UIElement.PointerCanceledEvent, new PointerEventHandler((_, _) => EndDrag(0)), true);
        _strip.AddHandler(UIElement.PointerCaptureLostEvent, new PointerEventHandler((_, _) => EndDrag(0)), true);
        _root.PointerPressed += (_, _) => _root.Focus(FocusState.Pointer);
        _root.Unloaded += (_, _) => { if (_gliding) StopGlide(); };
    }

    /// <summary>Hvid baggrund i lys tilstand og sort i mørk (ikke tonet efter coveret).</summary>
    private void ApplyTheme() =>
        _root.Background = new SolidColorBrush(_root.ActualTheme == ElementTheme.Dark ? Microsoft.UI.Colors.Black : Microsoft.UI.Colors.White);

    /// <summary>En sektion: midten følger den valgte plade.</summary>
    public void Show(long locationId)
    {
        if (_gliding) StopGlide();
        _listen = false;
        _locationId = locationId;
        _stepper.Reset();
        Reload();
        // Står den valgte plade ikke i sektionen, vælges den første (som i listen).
        int i = _items.FindIndex(it => it.Id == _model.Selection);
        if (i < 0) { i = 0; _model.Selection = _items.FirstOrDefault()?.Id; }
        _center = i;
        _shift = 0;
        Layout();
    }

    /// <summary>"Hvad skal jeg høre?": hele reolen. Står der et forslag, står det i midten.</summary>
    public void ShowListen()
    {
        if (_gliding) StopGlide();
        _listen = true;
        _stepper.Reset();
        Reload();
        long? p = _model.CurrentPick ?? _model.Selection;
        int i = _items.FindIndex(it => it.Id == p);
        if (i >= 0 || _center >= _items.Count) _center = Math.Max(0, i);
        _shift = 0;
        Layout();
    }

    public void OnModelChanged(string? property)
    {
        if (property is nameof(AppModel.Library))
        {
            long? id = Current?.Id;
            Reload();
            int i = _items.FindIndex(it => it.Id == id);
            _center = Math.Clamp(i < 0 ? _center : i, 0, Math.Max(0, _items.Count - 1));
            Layout();
        }
        else if (property is nameof(AppModel.Selection) && !_listen && !_gliding && !_dragging)
        {
            int i = _items.FindIndex(it => it.Id == _model.Selection);
            if (i >= 0 && i != _center) Glide(i, 0.3, spin: false);
        }
        else if (property is nameof(AppModel.CurrentPick) && _listen && _model.CurrentPick is long pick)
        {
            int i = _items.FindIndex(it => it.Id == pick);
            if (i >= 0) Spin(i);
        }
    }

    private void Reload() => _items = _listen
        ? _model.Library.Locations.SelectMany(l => _model.Library.ItemsIn(l.Id)).ToList()
        : _model.Library.ItemsIn(_locationId);

    private RecordItem? Current => _items.Count == 0 ? null : _items[Math.Clamp(_center, 0, _items.Count - 1)];

    /// <summary>Midten skifter. I en sektion følger valget med (så listen til venstre følger med).</summary>
    private void SetCenter(int i)
    {
        _center = i;
        if (!_listen && _items.Count > 0 && _model.Selection != _items[i].Id) _model.Selection = _items[i].Id;
    }

    private void Step(int delta)
    {
        if (_items.Count == 0) return;
        double from = _gliding && !_spinning ? _glideTarget : _center;
        if (_spinning) StopGlide();
        int target = Math.Clamp((int)from + delta, 0, _items.Count - 1);
        if (target != _center || _shift != 0) Glide(target, 0.3, spin: false);
    }

    // MARK: Træk og stryg

    private double PerCover => Math.Max(24, CoverFlowGeometry.Side(_strip.ActualWidth, Math.Min(_strip.ActualHeight, 460)) * 0.25);
    private double Now => _clock.Elapsed.TotalSeconds;

    private void OnPressed(object sender, PointerRoutedEventArgs e)
    {
        var pt = e.GetCurrentPoint(_strip);
        if (pt.PointerDeviceType == Microsoft.UI.Input.PointerDeviceType.Mouse && !pt.Properties.IsLeftButtonPressed) return;
        // En finger på rækken stopper et glid, der er i gang (og er så ikke et klik på et cover).
        if (_gliding) { StopGlide(); _justDragged = true; }
        _pointer = e.Pointer.PointerId;
        _dragging = false;
        _startX = _lastX = pt.Position.X;
        _samples.Clear();
        _samples.Add((Now, _lastX));
    }

    private void OnMoved(object sender, PointerRoutedEventArgs e)
    {
        if (_pointer != e.Pointer.PointerId || _items.Count == 0) return;
        double x = e.GetCurrentPoint(_strip).Position.X;
        if (!_dragging && Math.Abs(x - _startX) < 6) return;
        if (!_dragging) { _dragging = true; _strip.CapturePointer(e.Pointer); }
        double d = x - _lastX;
        _lastX = x;
        _samples.Add((Now, x));
        while (_samples.Count > 2 && Now - _samples[0].T > 0.1) _samples.RemoveAt(0);
        var g = CoverFlowGeometry.Glide(_center, _shift - d / PerCover, _items.Count);
        _shift = g.Shift;
        if (g.Center != _center) SetCenter(g.Center);
        Layout();
        e.Handled = true;
    }

    private void OnReleased(object sender, PointerRoutedEventArgs e)
    {
        if (_pointer != e.Pointer.PointerId) return;
        double v = 0;
        if (_dragging && _samples.Count >= 2)
        {
            var (t0, x0) = _samples[0];
            var (t1, x1) = _samples[^1];
            // Fingerens fart de sidste 100 ms (plader pr. sekund; mod venstre = næste plade).
            if (t1 - t0 > 0.01 && Now - t1 < 0.1) v = -(x1 - x0) / (t1 - t0) / PerCover;
        }
        if (_dragging) e.Handled = true;
        EndDrag(v);
    }

    private void EndDrag(double velocity)
    {
        if (_pointer is null) return;
        bool dragged = _dragging;
        _pointer = null;
        _dragging = false;
        _strip.ReleasePointerCaptures();
        // Et klik lige efter et træk (eller efter at have stoppet et glid) skal ikke åbne pladen.
        if (dragged) _justDragged = true;
        if (_justDragged) _root.DispatcherQueue.TryEnqueue(Microsoft.UI.Dispatching.DispatcherQueuePriority.Low, () => _justDragged = false);
        if (!dragged) return;
        if (CoverFlowGeometry.Fling(_center + _shift, velocity, _items.Count) is { } f)
            Glide(f.Target, f.Duration, spin: false);
        else if (_shift != 0)
            Glide(_center, 0.25, spin: false);
    }

    // MARK: Glid og lykkehjul

    /// <summary>Lykkehjulet: snurrer hen til pladen <paramref name="target"/>, og coveret popper, når det lander.</summary>
    private void Spin(int target)
    {
        double total = target - (_center + _shift);
        if (Math.Abs(total) < 0.5) { StopGlide(); _shift = 0; SetCenter(target); Landed(); return; }
        Glide(target, CoverFlowGeometry.SpinDuration(total), spin: true);
    }

    /// <summary>Rækken glider hen til <paramref name="target"/>: hurtigt først, bremser jævnt op.</summary>
    private void Glide(int target, double duration, bool spin)
    {
        if (_items.Count == 0) return;
        _glideFrom = _center + _shift;
        _glideTarget = Math.Clamp(target, 0, _items.Count - 1);
        _glideTotal = _glideTarget - _glideFrom;
        _glideBegin = Now;
        _glideDuration = Math.Max(0.01, duration);
        if (spin != _spinning) { _spinning = spin; _model.WheelSpinning = spin; }
        if (!_gliding) { _gliding = true; CompositionTarget.Rendering += OnFrame; }
    }

    private void OnFrame(object? sender, object e)
    {
        double t = Math.Min(1, (Now - _glideBegin) / _glideDuration);
        double pos = _glideFrom + _glideTotal * CoverFlowGeometry.EaseOut(t);
        int c = Math.Clamp((int)Math.Round(pos, MidpointRounding.AwayFromZero), 0, _items.Count - 1);
        _shift = pos - c;
        if (c != _center) SetCenter(c);
        if (t >= 1)
        {
            bool landed = _spinning;
            FinishGlide();
            _shift = 0;
            SetCenter(_glideTarget);
            if (landed) Landed();
        }
        Layout();
    }

    private void FinishGlide()
    {
        if (_gliding) CompositionTarget.Rendering -= OnFrame;
        _gliding = false;
        if (_spinning) { _spinning = false; _model.WheelSpinning = false; }
    }

    /// <summary>Et klik, en tast eller en finger stopper et glid (lykkehjulet lander straks på forslaget).</summary>
    private void StopGlide()
    {
        if (!_gliding) return;
        bool spin = _spinning;
        int target = _glideTarget;
        FinishGlide();
        if (spin) { _shift = 0; SetCenter(target); }
        else if (_shift != 0) Glide(_center, 0.25, spin: false);
        Layout();
    }

    /// <summary>Forslaget er fundet: midtercoveret popper kort (som på Mac og telefonen).</summary>
    private void Landed()
    {
        _popUntil = Now + 0.45;
        if (!_gliding) { _gliding = true; _glideFrom = _center; _glideTarget = _center; _glideTotal = 0; _glideBegin = Now; _glideDuration = 0.45; CompositionTarget.Rendering += OnFrame; }
    }

    // MARK: Tegning

    private void Layout()
    {
        double w = _strip.ActualWidth, h = _strip.ActualHeight;
        if (w <= 0 || h <= 0 || _items.Count == 0)
        {
            _strip.Children.Clear();
            _nodes.Clear();
            Caption();
            return;
        }
        double side = CoverFlowGeometry.Side(w, Math.Min(h, 460));
        if (Math.Abs(side - _nodeSide) > 0.5) { _strip.Children.Clear(); _nodes.Clear(); _nodeSide = side; }
        int center = Math.Clamp(_center, 0, _items.Count - 1);
        var (start, end) = CoverFlowGeometry.VisibleRange(center, _items.Count);
        var visible = new HashSet<long>();
        // Popper (0 → 1 → 0) over 0,45 s, når lykkehjulet lander.
        double popLeft = _popUntil - Now;
        double pop = popLeft > 0 ? Math.Sin(Math.PI * (1 - popLeft / 0.45)) * 0.07 : 0;
        for (int i = start; i < end; i++)
        {
            var item = _items[i];
            visible.Add(item.Id);
            double o = i - center - _shift;
            if (!_nodes.TryGetValue(item.Id, out var b))
            {
                b = MakeNode(item, side);
                _nodes[item.Id] = b;
                _strip.Children.Add(b);
            }
            b.Opacity = _model.IsAway(item.Id) ? 0.45 : 1;
            double scale = CoverFlowGeometry.Scale(o) * (i == center ? 1 + pop : 1);
            // WinUI's PlaneProjection drejer modsat vej af SwiftUI.
            ((PlaneProjection)b.Projection).RotationY = -CoverFlowGeometry.Angle(o);
            var st = (ScaleTransform)b.RenderTransform;
            st.ScaleX = st.ScaleY = scale;
            Canvas.SetLeft(b, w / 2 - side / 2 + CoverFlowGeometry.X(o, side));
            Canvas.SetTop(b, Math.Max(0, (h - side) / 2 - side * CoverFlowGeometry.ReflectionHeight / 2));
            // Nærmest midten øverst.
            Canvas.SetZIndex(b, (int)(1000 + CoverFlowGeometry.ZIndex(o) * 10));
        }
        foreach (var id in _nodes.Keys.Where(id => !visible.Contains(id)).ToList())
        {
            _strip.Children.Remove(_nodes[id]);
            _nodes.Remove(id);
        }
        if (Current?.Id != _captionId) Caption();
    }

    private Button MakeNode(RecordItem item, double side)
    {
        var b = new Button
        {
            Content = Ui.Cover(item.Release, side),
            Padding = new Thickness(0),
            Background = null,
            BorderThickness = new Thickness(0),
            Projection = new PlaneProjection(),
            RenderTransform = new ScaleTransform { CenterX = side / 2, CenterY = side / 2 },
        };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(b, item.FullName);
        b.Click += (_, _) =>
        {
            if (_justDragged) return;
            StopGlide();
            int idx = _items.FindIndex(it => it.Id == item.Id);
            if (idx < 0) return;
            if (idx == _center) _model.FindModeCopy = item.Id;
            else Glide(idx, 0.3, spin: false);
        };
        return b;
    }

    private void Caption()
    {
        _caption.Children.Clear();
        _captionId = Current?.Id;
        if (Current is not RecordItem it)
        {
            _caption.Children.Add(Ui.Text("Sektionen er tom.", color: Ui.Secondary));
            return;
        }
        TextBlock Center(TextBlock t) { t.HorizontalAlignment = HorizontalAlignment.Center; t.TextAlignment = TextAlignment.Center; return t; }
        _caption.Children.Add(Center(Ui.Text(it.Title, "SubtitleTextBlockStyle", Ui.Primary, wrap: false)));
        _caption.Children.Add(Center(Ui.Text(it.Artist, "BodyTextBlockStyle", Ui.Secondary, wrap: false, size: 18)));
        _caption.Children.Add(Center(Ui.Text(Line(it), "BodyTextBlockStyle", Ui.Tertiary, wrap: false)));
        var find = Ui.Btn("Find i reolen", (_, _) => _model.FindModeCopy = it.Id, Ui.Glyph.Pin, accent: true, tooltip: "Find i reolen (Enter)");
        find.HorizontalAlignment = HorizontalAlignment.Center;
        find.Margin = new Thickness(0, 8, 0, 0);
        _caption.Children.Add(find);
    }

    /// <summary>Nummeret i sektionen – i "Hvad skal jeg høre?" også reol og sektion.</summary>
    private string Line(RecordItem it)
    {
        var loc = _listen ? _model.Library.LocationOf(it.Id) : _model.Library.LocationById(_locationId);
        if (loc is null || !_model.Library.ShelfNumbers(loc.Id).TryGetValue(it.Id, out var n))
            return it.AwayMessage() ?? "Ude af reolen";
        string nr = $"Nr. {n} af {_model.Library.OnShelfCount(loc.Id)}";
        return _listen ? $"{loc.Name} · {nr}" : nr;
    }
}
