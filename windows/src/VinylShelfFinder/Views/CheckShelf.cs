using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Windows.System;
using VinylShelfFinder.Core;
using VinylShelfFinder.UI;

namespace VinylShelfFinder.Views;

/// <summary>
/// "Kontrollér sektion" (CheckShelfView i Sheets.swift): gå sektionen igennem plade for plade og svar
/// "Står rigtigt", "Står et andet sted", "Mangler" eller "Ved ikke". Til sidst kan manglende plader
/// markeres, og plader, der står et andet sted, kan flyttes.
/// </summary>
public sealed class CheckShelf
{
    private enum Verdict { Ok, Elsewhere, Missing, Unknown }

    private readonly AppModel _model;
    private readonly long _locationId;
    private readonly List<long> _ids;
    private readonly Dictionary<long, Verdict> _verdicts = new();
    private readonly HashSet<long> _moved = new();
    private int _index;
    private ContentDialog? _dialog;
    private long? _moveRequest;

    public CheckShelf(AppModel model, long locationId)
    {
        _model = model;
        _locationId = locationId;
        // Kun plader, der står i reolen.
        _ids = (model.Library.Sections.TryGetValue(locationId, out var ids) ? ids : Array.Empty<long>()).Where(i => !model.IsAway(i)).ToList();
    }

    /// <summary>Viser kontrollen. "Flyt…" lukker dialogen kortvarigt, viser Flyt og vender tilbage med svarene i behold.</summary>
    public async Task RunAsync(XamlRoot root)
    {
        while (true)
        {
            _moveRequest = null;
            _dialog = new ContentDialog
            {
                XamlRoot = root,
                Title = $"Kontrollér {_model.Library.LocationById(_locationId)?.Name ?? ""}",
                CloseButtonText = "Luk",
            };
            _dialog.Closing += OnClosing;
            Render();
            var result = await _dialog.ShowAsync();
            if (_moveRequest is long id)
            {
                var before = Place(id);
                await Dialogs.ShowMoveAsync(_model, id, root);
                if (!Place(id).SequenceEqual(before)) _moved.Add(id);
                continue;
            }
            if (result == ContentDialogResult.Primary)
                foreach (var m in _ids.Where(i => _verdicts.TryGetValue(i, out var v) && v == Verdict.Missing))
                    _model.SetStatus(m, CopyStatus.Missing);
            return;
        }
    }

    private int?[] Place(long id) =>
        new int?[] { _model.Library.LocationOfCopy.TryGetValue(id, out var l) ? (int)l : null, _model.Library.IndexInSection.TryGetValue(id, out var i) ? i : null };

    private bool _confirmed;

    private void OnClosing(ContentDialog sender, ContentDialogClosingEventArgs args)
    {
        if (_moveRequest is not null || args.Result == ContentDialogResult.Primary || _confirmed) return;
        bool unsaved = _verdicts.Values.Any(v => v is Verdict.Missing or Verdict.Elsewhere);
        if (!unsaved) return;
        // Luk uden at gemme? Svarene går tabt.
        args.Cancel = true;
        int missing = _verdicts.Values.Count(v => v == Verdict.Missing);
        var flyout = new Flyout();
        flyout.Content = Ui.VStack(10,
            Ui.Text("Luk uden at gemme?", "BodyStrongTextBlockStyle"),
            Ui.Text(missing == 0 ? "Dine svar fra kontrollen bliver ikke gemt."
                : $"{missing} {(missing == 1 ? "plade" : "plader")} bliver ikke markeret som “Mangler”, og dine svar bliver ikke gemt."),
            Ui.HStack(8,
                Ui.Btn("Luk og glem svarene", (_, _) => { flyout.Hide(); _confirmed = true; sender.Hide(); }),
                Ui.Btn("Bliv i kontrollen", (_, _) => flyout.Hide(), accent: true)));
        if (sender.Content is FrameworkElement anchor) flyout.ShowAt(anchor);
    }

    private void Answer(Verdict v)
    {
        if (_index < 0 || _index >= _ids.Count) return;
        _verdicts[_ids[_index]] = v;
        _index++;
        Render();
    }

    private void Render()
    {
        if (_dialog is null) return;
        var p = new StackPanel { Spacing = 14, Width = 560 };
        var head = new Grid();
        head.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        head.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var count = Ui.Text($"{Math.Min(_index + 1, _ids.Count)} / {_ids.Count}", color: Ui.Secondary, wrap: false);
        Grid.SetColumn(count, 1);
        head.Children.Add(count);
        p.Children.Add(head);
        p.Children.Add(new ProgressBar { Maximum = Math.Max(_ids.Count, 1), Value = _index });

        if (_index < _ids.Count && _model.Library.Item(_ids[_index]) is RecordItem it)
        {
            Step(p, it);
            _dialog.PrimaryButtonText = "";
        }
        else
        {
            Summary(p);
            int missing = _ids.Count(i => _verdicts.TryGetValue(i, out var v) && v == Verdict.Missing);
            _dialog.PrimaryButtonText = missing == 0 ? "Færdig" : "Markér manglende og luk";
            _dialog.DefaultButton = ContentDialogButton.Primary;
        }
        _dialog.Content = new ScrollViewer { Content = p, MaxHeight = 560 };
    }

    private static TextBlock Hint(string label, RecordItem item)
    {
        var t = new TextBlock { TextTrimming = TextTrimming.CharacterEllipsis };
        t.Inlines.Add(new Microsoft.UI.Xaml.Documents.Run { Text = $"{label}: ", Foreground = Ui.Secondary });
        t.Inlines.Add(new Microsoft.UI.Xaml.Documents.Run { Text = item.FullName });
        return t;
    }

    private void Step(StackPanel p, RecordItem it)
    {
        p.Children.Add(Ui.Text("Forventet næste plade i reolen:", color: Ui.Secondary));
        if (_index > 0 && _model.Library.Item(_ids[_index - 1]) is RecordItem prev) p.Children.Add(Hint("Efter", prev));
        var row = new Grid { ColumnSpacing = 16 };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        row.Children.Add(Ui.Cover(it.Release, 96));
        var t = Ui.VStack(2, Ui.Text(it.Artist, "SubtitleTextBlockStyle", maxLines: 2), Ui.Text(it.Title, "TitleTextBlockStyle", maxLines: 2),
            Ui.Text(it.DetailLine, "CaptionTextBlockStyle", Ui.Secondary, wrap: false, maxLines: 1));
        t.VerticalAlignment = VerticalAlignment.Center;
        Grid.SetColumn(t, 1);
        row.Children.Add(t);
        p.Children.Add(row);
        if (_index + 1 < _ids.Count && _model.Library.Item(_ids[_index + 1]) is RecordItem nx) p.Children.Add(Hint("Derefter", nx));

        Button B(string text, string glyph, Verdict v, VirtualKey key, bool accent = false)
        {
            var b = Ui.Btn(text, (_, _) => Answer(v), glyph, accent);
            b.KeyboardAccelerators.Add(new KeyboardAccelerator { Key = key });
            return b;
        }
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        buttons.Children.Add(B("Står rigtigt", Ui.Glyph.Check, Verdict.Ok, VirtualKey.Enter, accent: true));
        buttons.Children.Add(B("Står et andet sted", Ui.Glyph.Warning, Verdict.Elsewhere, VirtualKey.S));
        buttons.Children.Add(B("Mangler", CopyStatus.Missing.StatusGlyph(), Verdict.Missing, VirtualKey.M));
        buttons.Children.Add(B("Ved ikke", Ui.Glyph.Help, Verdict.Unknown, VirtualKey.Space));
        var back = Ui.Btn("Tilbage", (_, _) => { if (_index > 0) { _index--; Render(); } });
        back.IsEnabled = _index > 0;
        back.KeyboardAccelerators.Add(new KeyboardAccelerator { Key = VirtualKey.Left });
        buttons.Children.Add(back);
        p.Children.Add(buttons);
        p.Children.Add(Ui.Text("Genveje: Enter rigtigt · S andet sted · M mangler · mellemrum ved ikke · ← tilbage", "CaptionTextBlockStyle", Ui.Secondary));
    }

    private void Summary(StackPanel p)
    {
        List<long> With(Verdict v) => _ids.Where(i => _verdicts.TryGetValue(i, out var x) && x == v).ToList();
        var elsewhere = With(Verdict.Elsewhere);
        var missing = With(Verdict.Missing);
        var unknown = With(Verdict.Unknown);
        int ok = With(Verdict.Ok).Count;
        p.Children.Add(Ui.Text("Kontrol færdig", "SubtitleTextBlockStyle"));
        if (_ids.Count == 0) p.Children.Add(Ui.Text("Sektionen er tom – der er ingen plader at kontrollere.", color: Ui.Secondary));
        p.Children.Add(Ui.HStack(16,
            Ui.Label(Ui.Glyph.Check, $"{ok} står rigtigt"),
            Ui.Label(Ui.Glyph.Warning, $"{elsewhere.Count} står et andet sted"),
            Ui.Label(CopyStatus.Missing.StatusGlyph(), $"{missing.Count} mangler"),
            Ui.Label(Ui.Glyph.Help, $"{unknown.Count} ved ikke")));
        string Name(long id) => _model.Library.Item(id)?.FullName ?? "";
        if (elsewhere.Count > 0)
        {
            p.Children.Add(Ui.Eyebrow("Står et andet sted – flyt dem her, eller sæt dem på plads i reolen"));
            foreach (var id in elsewhere)
            {
                var g = new Grid();
                g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
                g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
                g.Children.Add(Ui.Text(Name(id), wrap: false));
                FrameworkElement right = _moved.Contains(id)
                    ? Ui.Label(Ui.Glyph.Check, "Flyttet", color: Ui.Secondary)
                    : Ui.Btn("Flyt…", (_, _) => { _moveRequest = id; _dialog?.Hide(); });
                Grid.SetColumn(right, 1);
                g.Children.Add(right);
                p.Children.Add(g);
            }
        }
        if (missing.Count > 0)
        {
            p.Children.Add(Ui.Eyebrow("Mangler – markeres som “Mangler” (appen husker pladens plads)"));
            foreach (var id in missing) p.Children.Add(Ui.Text(Name(id), wrap: false));
        }
        if (unknown.Count > 0)
        {
            p.Children.Add(Ui.Eyebrow("Ved ikke – ingen ændring"));
            foreach (var id in unknown) p.Children.Add(Ui.Text(Name(id), color: Ui.Secondary, wrap: false));
        }
        var back = Ui.Btn("Tilbage", (_, _) => { _index = Math.Max(_ids.Count - 1, 0); Render(); }, Ui.Glyph.Back);
        back.IsEnabled = _ids.Count > 0;
        p.Children.Add(back);
    }

    /// <summary>"Synkronisering færdig" (SyncReportView).</summary>
    public static async Task ShowSyncReportAsync(AppModel model, SyncReport r, XamlRoot root)
    {
        var lib = model.Library;
        var p = new StackPanel { Spacing = 10, Width = 480 };
        p.Children.Add(Ui.Text($"{r.Total} plader og cd'er i din Discogs Collection.", color: Ui.Secondary));
        if (r.NewCopies.Count == 0 && r.RemovedCopies.Count == 0 && r.UpdatedReleases == 0 && r.ReturnedCopies.Count == 0)
            p.Children.Add(Ui.Label(Ui.Glyph.Check, "Ingen ændringer."));
        if (r.NewCopies.Count > 0)
        {
            p.Children.Add(Ui.Label(Ui.Glyph.New, r.NewCopies.Count == 1 ? "1 ny plade venter på en plads" : $"{r.NewCopies.Count} nye plader venter på en plads", "BodyStrongTextBlockStyle"));
            foreach (var id in r.NewCopies.Take(6))
            {
                if (lib.SuggestPlacement(id, model.Rules) is not PlacementSuggestion s || lib.Item(id) is not RecordItem it) continue;
                string N(long? x) => x is long v && lib.Item(v) is RecordItem i ? i.FullName : "";
                p.Children.Add(Ui.VStack(1, Ui.Text(it.FullName, "BodyStrongTextBlockStyle"),
                    Ui.Text($"mellem {(s.Before is null ? "start" : N(s.Before))} og {(s.After is null ? "slut" : N(s.After))}", "CaptionTextBlockStyle", Ui.Secondary)));
            }
        }
        if (r.RemovedCopies.Count > 0)
            p.Children.Add(Ui.Label(Ui.Glyph.Warning, $"{Ui.Plader(r.RemovedCopies.Count)} er fjernet fra Discogs. {(r.RemovedCopies.Count == 1 ? "Dens" : "Deres")} fysiske placering er bevaret – se “Fjernet fra Discogs”."));
        if (r.ReturnedCopies.Count > 0)
            p.Children.Add(Ui.Label(Ui.Glyph.Undo, $"{Ui.Plader(r.ReturnedCopies.Count)} er tilbage i Discogs Collection."));
        if (r.UpdatedReleases > 0)
            p.Children.Add(Ui.Label(Ui.Glyph.Edit, $"Oplysninger fra Discogs er opdateret for {Ui.Plader(r.UpdatedReleases)}. Ingen plader er flyttet."));
        var d = new ContentDialog
        {
            XamlRoot = root,
            Title = "Synkronisering færdig",
            Content = new ScrollViewer { Content = p, MaxHeight = 520 },
            CloseButtonText = "OK",
            DefaultButton = ContentDialogButton.Close,
        };
        await d.ShowAsync();
    }
}
