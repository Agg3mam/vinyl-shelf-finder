using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Windows.System;
using VinylShelfFinder.Core;
using VinylShelfFinder.UI;

namespace VinylShelfFinder.Views;

/// <summary>En skærm i midterkolonnen. Hovedvinduet sender modellens ændringer videre.</summary>
public interface IPane
{
    FrameworkElement View { get; }
    void OnModelChanged(string? property);
}

/// <summary>Søg: søgefelt og resultatliste (SearchResultsView i ListViews.swift).</summary>
public sealed class SearchPane : IPane
{
    private readonly AppModel _model;
    private readonly Grid _root = new();
    public readonly TextBox Box;
    private readonly Button _clear;
    private readonly ListView _list;
    private readonly Grid _emptyHost = new();
    private bool _syncingSelection;
    private IReadOnlyList<long> _shown = Array.Empty<long>();

    public FrameworkElement View => _root;

    public SearchPane(AppModel model)
    {
        _model = model;
        _root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        _root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });

        // Søgefeltet
        Box = new TextBox
        {
            PlaceholderText = "Kunstner, titel, label, katalognr. …",
            Text = model.Query,
            FontSize = 16,
            BorderThickness = new Thickness(0),
            Background = null,
            VerticalAlignment = VerticalAlignment.Center,
            Padding = new Thickness(4, 6, 4, 6),
        };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(Box, "Søg");
        Box.Resources["TextControlBackgroundFocused"] = new Microsoft.UI.Xaml.Media.SolidColorBrush(Microsoft.UI.Colors.Transparent);
        Box.Resources["TextControlBackgroundPointerOver"] = new Microsoft.UI.Xaml.Media.SolidColorBrush(Microsoft.UI.Colors.Transparent);
        Box.Resources["TextControlBorderThemeThicknessFocused"] = new Thickness(0);
        Box.TextChanged += (_, _) => { if (_model.Query != Box.Text) _model.Query = Box.Text; };
        Box.PreviewKeyDown += OnSearchKey;

        _clear = new Button
        {
            Content = Ui.Icon("", 12),
            Background = null,
            BorderThickness = new Thickness(0),
            Padding = new Thickness(6),
            Visibility = Visibility.Collapsed,
            VerticalAlignment = VerticalAlignment.Center,
        };
        ToolTipService.SetToolTip(_clear, "Ryd søgning (Esc)");
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(_clear, "Ryd søgning");
        _clear.Click += (_, _) => { Box.Text = ""; Box.Focus(FocusState.Programmatic); };

        var hint = Ui.Text("Ctrl+F", "CaptionTextBlockStyle", Ui.Tertiary, wrap: false);
        hint.VerticalAlignment = VerticalAlignment.Center;
        Ui.AutomationHidden(hint);

        var bar = new Grid { ColumnSpacing = 6 };
        bar.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        bar.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        bar.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        bar.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var icon = Ui.Icon(Ui.Glyph.Search, 16, Ui.Secondary);
        icon.VerticalAlignment = VerticalAlignment.Center;
        bar.Children.Add(icon);
        Grid.SetColumn(Box, 1); bar.Children.Add(Box);
        Grid.SetColumn(_clear, 2); bar.Children.Add(_clear);
        Grid.SetColumn(hint, 3); bar.Children.Add(hint);
        var barBorder = new Border
        {
            Child = bar,
            Padding = new Thickness(12, 2, 12, 2),
            CornerRadius = new CornerRadius(8),
            Background = Ui.ThemeBrush("ControlFillColorDefaultBrush"),
            BorderBrush = Ui.ThemeBrush("ControlStrokeColorDefaultBrush"),
            BorderThickness = new Thickness(1),
            Margin = new Thickness(12, 12, 12, 8),
        };
        _root.Children.Add(barBorder);

        // Resultater
        _list = new ListView { SelectionMode = ListViewSelectionMode.Single, Padding = new Thickness(0, 0, 0, 12) };
        _list.SelectionChanged += (_, _) =>
        {
            if (_syncingSelection) return;
            if (_list.SelectedIndex >= 0 && _list.SelectedIndex < _shown.Count)
            {
                var id = _shown[_list.SelectedIndex];
                if (_model.Selection != id) _model.Selection = id;
            }
        };
        _list.KeyDown += (_, e) =>
        {
            if (e.Key == VirtualKey.Enter && _model.Selection is long s) { _model.FindModeCopy = s; e.Handled = true; }
        };
        Grid.SetRow(_list, 1);
        _root.Children.Add(_list);
        Grid.SetRow(_emptyHost, 1);
        _root.Children.Add(_emptyHost);

        RebuildList();
        _root.Loaded += (_, _) => Box.Focus(FocusState.Programmatic);
    }

    private void OnSearchKey(object sender, KeyRoutedEventArgs e)
    {
        switch (e.Key)
        {
            case VirtualKey.Down: _model.MoveSelection(1); e.Handled = true; break;
            case VirtualKey.Up: _model.MoveSelection(-1); e.Handled = true; break;
            case VirtualKey.Enter:
                if (_model.Selection is long s) _model.FindModeCopy = s;
                e.Handled = true;
                break;
            case VirtualKey.Escape:
                if (Box.Text.Length > 0) { Box.Text = ""; e.Handled = true; }
                break;
        }
    }

    public void OnModelChanged(string? property)
    {
        switch (property)
        {
            case nameof(AppModel.Results):
            case nameof(AppModel.Library):
                RebuildList();
                break;
            case nameof(AppModel.Selection):
                SyncSelection();
                break;
            case nameof(AppModel.Query):
                if (Box.Text != _model.Query) Box.Text = _model.Query;
                UpdateEmpty();
                break;
            case nameof(AppModel.FocusSearchRequest):
                Box.Focus(FocusState.Programmatic);
                Box.SelectAll();
                break;
        }
    }

    private void RebuildList()
    {
        _shown = _model.Results.ToList();
        _syncingSelection = true;
        _list.Items.Clear();
        foreach (var id in _shown)
        {
            if (_model.Library.Item(id) is RecordItem it)
            {
                var row = RecordRow.Build(_model, it, showLocation: true);
                if (_model.ResultTracks.TryGetValue(id, out var t))
                {
                    // "♪ Wish You Were Here · B1" under et resultat, der er fundet på en sang.
                    var song = Ui.Label(Ui.Glyph.Music, t.Position.Length == 0 ? t.Title : $"{t.Title} · {t.Position}", "CaptionTextBlockStyle", Ui.Secondary, 12);
                    song.Margin = new Thickness(4, -4, 0, 4);
                    Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(song, $"Sangen {t.Title}");
                    var stack = new StackPanel();
                    stack.Children.Add(row);
                    stack.Children.Add(song);
                    _list.Items.Add(stack);
                }
                else _list.Items.Add(row);
            }
            else
                _list.Items.Add(new Grid());
        }
        _syncingSelection = false;
        SyncSelection();
        UpdateEmpty();
    }

    private void SyncSelection()
    {
        int i = _model.Selection is long s ? _shown.ToList().IndexOf(s) : -1;
        if (_list.SelectedIndex == i) return;
        _syncingSelection = true;
        _list.SelectedIndex = i;
        _syncingSelection = false;
        if (i >= 0) _list.ScrollIntoView(_list.Items[i]);
    }

    private void UpdateEmpty()
    {
        // TextBox har selv et ryd-kryds; vores egen knap bruges ikke (to kryds så forkert ud).
        _clear.Visibility = Visibility.Collapsed;
        _emptyHost.Children.Clear();
        var q = _model.Query.Trim();
        if (_model.Query.Length == 0)
        {
            _list.Visibility = Visibility.Collapsed;
            _emptyHost.Children.Add(Ui.Empty(Ui.Glyph.Disc, _model.Medium.Count(_model.Library.Copies.Count),
                "Skriv for at søge. ↑↓ vælger, Enter åbner “Find i reolen”, Esc rydder."));
        }
        else if (_shown.Count == 0)
        {
            _list.Visibility = Visibility.Collapsed;
            _emptyHost.Children.Add(Ui.Empty(Ui.Glyph.Search, "Ingen resultater",
                $"Ingen {_model.Medium.Plural()} matcher “{q}”. Prøv med færre ord, eller søg på katalognummer."));
        }
        else
        {
            _list.Visibility = Visibility.Visible;
        }
    }
}
