using System.ComponentModel;
using System.Runtime.InteropServices.WindowsRuntime;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media.Imaging;
using Windows.Graphics.Imaging;
using Windows.Storage.Streams;
using Windows.System;
using VinylShelfFinder.Core;
using VinylShelfFinder.UI;
using VinylShelfFinder.Views;

namespace VinylShelfFinder;

/// <summary>
/// Hovedvinduet (ContentView.swift): sidepanel, liste i midten, pladen til højre og "Find i reolen"
/// som et lag over det hele. Sidepanelet bygges i kode ud fra modellen (sektionerne pr. reol).
/// </summary>
public sealed partial class MainWindow : Window
{
    private readonly Updater _updater;
    internal AppModel Model { get; }
    internal SearchPane Search { get; }
    internal DetailPane Detail { get; }
    internal FindOverlay Find { get; }
    private IPane? _listPane;
    private FrameworkElement? _fullPane;
    private readonly InfoBar _errorBar = new() { Severity = InfoBarSeverity.Error, IsClosable = true, Margin = new Thickness(12, 8, 12, 0) };
    private readonly NavigationViewItem _updateItem = new() { Content = "Opdatering", Tag = "update", SelectsOnInvoked = false, Icon = new FontIcon { Glyph = "" } };
    private bool _buildingSidebar;
    private bool _dialogOpen;

    public MainWindow(Updater updater, AppModel model)
    {
        _updater = updater;
        Model = model;
        InitializeComponent();
        Title = "Vinyl Shelf Finder";
        AppWindow.Resize(new Windows.Graphics.SizeInt32(1280, 820));

        Search = new SearchPane(model);
        Detail = new DetailPane(model);
        Find = new FindOverlay(model);
        OverlayHost.Child = Find.View;
        DetailHost.Child = Detail.View;
        TopBar.Children.Add(_errorBar);
        _errorBar.Closed += (_, _) => Model.ErrorMessage = null;
        Nav.FooterMenuItems.Add(_updateItem);

        _updater.Changed += ShowUpdateState;
        Model.PropertyChanged += OnModelChanged;
        AddShortcuts();
        BuildSidebar();
        ShowContent();
    }

    // MARK: Modellen

    private void OnModelChanged(object? sender, PropertyChangedEventArgs e)
    {
        var p = e.PropertyName;
        switch (p)
        {
            case nameof(AppModel.Library):
            case nameof(AppModel.Stats):
                BuildSidebar();
                break;
            case nameof(AppModel.Sidebar):
                SelectSidebar();
                ShowContent();
                break;
            case nameof(AppModel.NeedsOnboarding):
                ShowContent();
                break;
            case nameof(AppModel.ErrorMessage):
                _errorBar.Title = "Noget gik galt";
                _errorBar.Message = Model.ErrorMessage ?? "";
                _errorBar.IsOpen = Model.ErrorMessage is not null;
                break;
            case nameof(AppModel.MoveCopy):
                if (Model.MoveCopy is long m) _ = ShowDialog(() => Dialogs.ShowMoveAsync(Model, m, Root.XamlRoot), () => Model.MoveCopy = null);
                break;
            case nameof(AppModel.StatusNoteRequest):
                if (Model.StatusNoteRequest is StatusNoteRequest r) _ = ShowDialog(() => Dialogs.ShowStatusNoteAsync(Model, r, Root.XamlRoot), () => Model.StatusNoteRequest = null);
                break;
        }
        Search.OnModelChanged(p);
        if (_listPane is not null && _listPane != Search) _listPane.OnModelChanged(p);
        Detail.OnModelChanged(p);
        Find.OnModelChanged(p);
    }

    /// <summary>Kun én ContentDialog ad gangen i WinUI.</summary>
    private async Task ShowDialog(Func<Task> show, Action done)
    {
        if (_dialogOpen) { done(); return; }
        _dialogOpen = true;
        try { await show(); }
        catch (Exception ex) { Model.ErrorMessage = ex.Message; }
        finally { _dialogOpen = false; done(); }
    }

    // MARK: Sidepanelet

    private static NavigationViewItem Item(string text, string glyph, object tag, int? badge = null)
    {
        var item = new NavigationViewItem { Content = text, Tag = tag, Icon = new FontIcon { Glyph = glyph } };
        if (badge is int b && b > 0) item.InfoBadge = new InfoBadge { Value = b };
        return item;
    }

    private void BuildSidebar()
    {
        _buildingSidebar = true;
        var lib = Model.Library;
        var items = Nav.MenuItems;
        items.Clear();
        items.Add(Item("Søg", Ui.Glyph.Search, SidebarItem.Search));
        items.Add(Item("Værdi", Ui.Glyph.Value, new SidebarItem(SidebarKind.Value)));
        items.Add(new NavigationViewItemHeader { Content = "Discogs" });
        items.Add(Item("Find nye plader", Ui.Glyph.Bag, new SidebarItem(SidebarKind.FindNew)));
        items.Add(new NavigationViewItemHeader { Content = "Lytning" });
        items.Add(Item("Hvad skal jeg høre?", Ui.Glyph.Shuffle, new SidebarItem(SidebarKind.Listen)));
        items.Add(Item("Lyttelog", Ui.Glyph.List, new SidebarItem(SidebarKind.Plays), Model.Stats.Plays.Count));
        items.Add(new NavigationViewItemHeader { Content = "Indbakke" });
        items.Add(Item("Nye plader", Ui.Glyph.New, new SidebarItem(SidebarKind.NewRecords), lib.Unplaced.Count));
        items.Add(Item("Fjernet fra Discogs", Ui.Glyph.Warning, new SidebarItem(SidebarKind.Removed), Model.RemovedItems.Count));
        items.Add(Item("Ude af reolen", Ui.Glyph.Package, new SidebarItem(SidebarKind.Away), Model.AwayItems.Count));
        foreach (var shelf in lib.Locations.Select(l => l.Shelf).Distinct())
        {
            var first = lib.Locations.First(l => l.Shelf == shelf);
            items.Add(new NavigationViewItemHeader { Content = $"{first.Medium.ShelfWord()} {shelf}" });
            foreach (var loc in lib.Locations.Where(l => l.Shelf == shelf))
            {
                int onShelf = lib.Sections.TryGetValue(loc.Id, out var ids)
                    ? ids.Count(id => lib.Copies.TryGetValue(id, out var c) && c.Status.IsOnShelf()) : 0;
                items.Add(Item($"Sektion {loc.Section}", Ui.Glyph.Library, SidebarItem.ForSection(loc.Id), onShelf));
            }
        }
        items.Add(new NavigationViewItemSeparator());
        items.Add(Item("Historik", Ui.Glyph.History, new SidebarItem(SidebarKind.History)));
        _buildingSidebar = false;
        SelectSidebar();
        // En sektion, der ikke findes mere: tilbage til søgning.
        if (Model.Sidebar.Kind == SidebarKind.Section && lib.LocationById(Model.Sidebar.SectionId) is null)
            Model.Sidebar = SidebarItem.Search;
    }

    private void SelectSidebar()
    {
        var want = Nav.MenuItems.OfType<NavigationViewItem>().FirstOrDefault(i => i.Tag is SidebarItem s && s == Model.Sidebar);
        if (want is null || Nav.SelectedItem == want) return;
        _buildingSidebar = true;
        Nav.SelectedItem = want;
        _buildingSidebar = false;
    }

    private void Nav_SelectionChanged(NavigationView sender, NavigationViewSelectionChangedEventArgs args)
    {
        if (_buildingSidebar) return;
        if (args.IsSettingsSelected) { ShowSettings(); return; }
        if (args.SelectedItem is NavigationViewItem { Tag: SidebarItem s })
        {
            _settingsShown = false;
            if (Model.Sidebar == s) ShowContent();
            else Model.Sidebar = s;
        }
    }

    private void Nav_ItemInvoked(NavigationView sender, NavigationViewItemInvokedEventArgs args)
    {
        if (args.InvokedItemContainer?.Tag as string != "update") return;
        _askedOnLaunch = false;
        if (_updater.State is Updater.Phase.Idle or Updater.Phase.UpToDate or Updater.Phase.Failed && _updater.Enabled)
            _ = _updater.CheckAsync();
        else ShowUpdateState();
    }

    // MARK: Indholdet

    private bool _settingsShown;

    private void ShowSettings()
    {
        _settingsShown = true;
        ShowFull(Ui.Empty(Ui.Glyph.Library, "Indstillinger", "Indstillingerne kommer i en senere version."));
    }

    private void ShowFull(FrameworkElement view)
    {
        _listPane = null;
        _fullPane = view;
        ListHost.Child = null;
        FullHost.Child = view;
        FullHost.Visibility = Visibility.Visible;
        ListHost.Visibility = Visibility.Collapsed;
        DetailHost.Visibility = Visibility.Collapsed;
    }

    private void ShowList(IPane pane)
    {
        _listPane = pane;
        _fullPane = null;
        FullHost.Child = null;
        FullHost.Visibility = Visibility.Collapsed;
        ListHost.Child = pane.View;
        ListHost.Visibility = Visibility.Visible;
        DetailHost.Visibility = Visibility.Visible;
    }

    private void ShowContent()
    {
        if (_settingsShown) return;
        if (Model.NeedsOnboarding)
        {
            ShowFull(Ui.Empty(Ui.Glyph.Disc, "Kom i gang", "Forbind til Discogs og opret dine reoler. (Opsætningen kommer i næste version.)"));
            return;
        }
        var s = Model.Sidebar;
        switch (s.Kind)
        {
            case SidebarKind.Search:
                ShowList(Search);
                break;
            case SidebarKind.NewRecords:
            case SidebarKind.Removed:
            case SidebarKind.Away:
                ShowList(new RecordListPane(Model, s.Kind));
                break;
            case SidebarKind.Section:
                ShowList(new SectionPane(Model, s.SectionId));
                break;
            default:
                var title = s.Kind switch
                {
                    SidebarKind.Value => "Værdi",
                    SidebarKind.FindNew => "Find nye plader",
                    SidebarKind.Listen => "Hvad skal jeg høre?",
                    SidebarKind.Plays => "Lyttelog",
                    _ => "Historik",
                };
                ShowFull(Ui.Empty(Ui.Glyph.Disc, title, "Denne skærm kommer i en senere version."));
                break;
        }
    }

    // MARK: Genveje

    private void AddShortcuts()
    {
        void Add(VirtualKey key, VirtualKeyModifiers mods, Action action)
        {
            var a = new KeyboardAccelerator { Key = key, Modifiers = mods };
            a.Invoked += (_, e) => { action(); e.Handled = true; };
            Root.KeyboardAccelerators.Add(a);
        }
        Add(VirtualKey.F, VirtualKeyModifiers.Control, () =>
        {
            Model.Sidebar = SidebarItem.Search;
            Model.RequestSearchFocus();
        });
        Add(VirtualKey.K, VirtualKeyModifiers.Control, () =>
        {
            Model.Sidebar = SidebarItem.Search;
            Model.RequestSearchFocus();
        });
        Add(VirtualKey.L, VirtualKeyModifiers.Control, () => { if (Model.Selection is long s) Detail.LogPlay(s); });
        Add(VirtualKey.M, VirtualKeyModifiers.Control | VirtualKeyModifiers.Shift, () => { if (Model.Selection is long s) Model.MoveCopy = s; });
    }

    // MARK: Opdatering

    /// <summary>Tjekker GitHub ved start (højst én gang om dagen) og spørger, hvis der er en ny version.</summary>
    internal async Task CheckForUpdateOnLaunchAsync()
    {
        _silent = true;
        try { _askedOnLaunch = await _updater.CheckOnLaunchAsync(); }
        finally { _silent = false; }
        if (_askedOnLaunch) ShowUpdateState();
    }

    private bool _askedOnLaunch, _silent;

    /// Bjælken øverst viser, hvor opdateringen er (samme tekster som Indstillinger › Opdatering på Mac).
    private void ShowUpdateState()
    {
        if (_silent) return;
        string title, message = "";
        var severity = InfoBarSeverity.Informational;
        bool now = false, later = false, check = false, closable = true;
        var current = _updater.CurrentVersion;
        switch (_updater.State)
        {
            case Updater.Phase.Available when _updater.Release is { } r:
                title = $"Version {r.Version} er klar";
                message = $"Du har version {current}. Appen henter den nye version fra GitHub, lukker og åbner sig selv igen. Dine plader og placeringer røres ikke.";
                if (r.Notes.Length > 0) message += "\n\nNyt:\n" + (r.Notes.Length > 600 ? r.Notes[..600] : r.Notes);
                now = true; later = true;
                break;
            case Updater.Phase.Checking:
                title = "Tjekker GitHub …"; closable = false;
                break;
            case Updater.Phase.Downloading:
                title = "Henter den nye version …"; closable = false;
                break;
            case Updater.Phase.Installing:
                title = "Installerer og åbner igen …"; closable = false;
                break;
            case Updater.Phase.Failed:
                title = _updater.Message ?? "Opdateringen mislykkedes.";
                severity = InfoBarSeverity.Warning; check = true;
                break;
            default:
                if (!_updater.Enabled)
                {
                    title = $"Denne version: {current}";
                    message = "Opdatering er slået fra i demo-tilstand.";
                }
                else
                {
                    title = $"Du har den nyeste version ({current}).";
                    if (_updater.LastChecked is { } d) message = $"Sidst tjekket {d.LocalDateTime:d. MMMM yyyy 'kl.' HH:mm}. ";
                    message += "Appen tjekker selv én gang om dagen og spørger, før den opdaterer. Nye versioner hentes fra projektets side på GitHub.";
                    severity = InfoBarSeverity.Success; check = true;
                }
                break;
        }
        UpdateBar.Title = title;
        UpdateBar.Message = message;
        UpdateBar.Severity = severity;
        UpdateBar.IsClosable = closable;
        UpdateNowButton.Visibility = now ? Visibility.Visible : Visibility.Collapsed;
        UpdateLaterButton.Visibility = later ? Visibility.Visible : Visibility.Collapsed;
        UpdateCheckButton.Visibility = check ? Visibility.Visible : Visibility.Collapsed;
        UpdateButtons.Visibility = now || later || check ? Visibility.Visible : Visibility.Collapsed;
        UpdateBar.IsOpen = true;
    }

    private void UpdateNow_Click(object sender, RoutedEventArgs e)
    {
        if (_updater.Release is { } r) _ = _updater.InstallAsync(r);
    }

    private void UpdateLater_Click(object sender, RoutedEventArgs e)
    {
        if (_updater.Release is { } r) _updater.Postpone(r);
        UpdateBar.IsOpen = false;
    }

    private void UpdateBar_CloseButtonClick(InfoBar sender, object args)
    {
        // Lukkes spørgsmålet ved start med krydset, tæller det som "Senere".
        if (_askedOnLaunch && _updater.Release is { } r) _updater.Postpone(r);
        _askedOnLaunch = false;
    }

    private void UpdateCheck_Click(object sender, RoutedEventArgs e) => _ = _updater.CheckAsync();

    // MARK: Skærmbillede

    /// <summary>Gemmer et PNG-billede af vinduets indhold (bruges af --smoke i CI). Mica-baggrunden kommer ikke med.</summary>
    internal async Task SaveScreenshotAsync(string path)
    {
        var rtb = new RenderTargetBitmap();
        await rtb.RenderAsync(Root);
        var pixels = (await rtb.GetPixelsAsync()).ToArray();

        // Gennemsigtige områder (hvor Mica ville være) får en hvid/mørk baggrund, så billedet kan læses.
        bool dark = Root.ActualTheme == ElementTheme.Dark;
        byte bg = dark ? (byte)0x20 : (byte)0xF3;
        for (int i = 0; i < pixels.Length; i += 4)
        {
            int a = pixels[i + 3];
            if (a == 255) continue;
            int inv = 255 - a; // præmultipliceret alfa: farve + baggrund * (1 - alfa)
            pixels[i] = (byte)(pixels[i] + bg * inv / 255);
            pixels[i + 1] = (byte)(pixels[i + 1] + bg * inv / 255);
            pixels[i + 2] = (byte)(pixels[i + 2] + bg * inv / 255);
            pixels[i + 3] = 255;
        }

        using var stream = new InMemoryRandomAccessStream();
        var encoder = await BitmapEncoder.CreateAsync(BitmapEncoder.PngEncoderId, stream);
        encoder.SetPixelData(BitmapPixelFormat.Bgra8, BitmapAlphaMode.Premultiplied,
            (uint)rtb.PixelWidth, (uint)rtb.PixelHeight, 96, 96, pixels);
        await encoder.FlushAsync();

        stream.Seek(0);
        using var file = File.Create(path);
        await stream.AsStreamForRead().CopyToAsync(file);
    }
}
