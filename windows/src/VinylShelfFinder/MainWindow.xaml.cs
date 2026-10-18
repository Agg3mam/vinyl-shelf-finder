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
    private CoverFlowPane? _coverFlow;
    internal FindNewModel FindNew { get; }
    internal IMusicModel IMusic { get; }
    private FindNewDetailPane? _findNewDetail;
    private IPane? _listPane;
    private IPane? _fullPane;
    private readonly InfoBar _errorBar = new() { Severity = InfoBarSeverity.Error, IsClosable = true, Margin = new Thickness(12, 8, 12, 0) };
    private readonly NavigationViewItem _updateItem = new() { Content = "Opdatering", Tag = "update", SelectsOnInvoked = false, Icon = new FontIcon { Glyph = Ui.Glyph.Download } };
    private bool _buildingSidebar;
    private readonly SelectorBar _mediumBar = new();
    private readonly Button _syncButton = new();
    private OnboardingView? _onboarding;
    private bool _dialogOpen;

    /// <summary>Hovedvinduets handle (fil-dialoger i en app uden MSIX-pakke skal kende vinduet).</summary>
    internal static IntPtr Hwnd { get; private set; }

    public MainWindow(Updater updater, AppModel model, IMusicModel imusic)
    {
        _updater = updater;
        Model = model;
        IMusic = imusic;
        FindNew = new FindNewModel(model);
        FindNew.OpenBrowserRequested += url => DiscogsBrowserWindow.Open(Model, url);
        SettingsPane.IMusicTab = m => IMusic.SettingsTab(m);
        DetailPane.IMusic = imusic;
        InitializeComponent();
        Title = "Vinyl Shelf Finder";
        AppWindow.SetIcon(System.IO.Path.Combine(AppContext.BaseDirectory, "Assets", "AppIcon.ico"));
        Hwnd = WinRT.Interop.WindowNative.GetWindowHandle(this);
        FitToScreen();

        Search = new SearchPane(model);
        Detail = new DetailPane(model);
        Find = new FindOverlay(model);
        OverlayHost.Child = Find.View;
        DetailHost.Child = Detail.View;
        Body.SizeChanged += (_, e) => ListColumn.Width = new GridLength(Math.Clamp(e.NewSize.Width * 0.4, 260, 360));
        // Under 1100 px vises sidepanelet kun med ikoner (NavigationView's Auto folder sig ikke ud igen).
        Nav.SizeChanged += (_, e) => FitPane(e.NewSize.Width);
        TopBar.Children.Add(BuildToolbar());
        TopBar.Children.Add(_errorBar);
        _errorBar.Closed += (_, _) => Model.ErrorMessage = null;
        if (Model.JustApplied != DataTransfer.Applied.None)
        {
            var reset = Model.JustApplied == DataTransfer.Applied.Reset;
            TopBar.Children.Add(new InfoBar
            {
                Severity = InfoBarSeverity.Success,
                IsOpen = true,
                Margin = new Thickness(12, 8, 12, 0),
                Title = reset ? "Appen er nulstillet" : "Systemet er importeret",
                Message = reset
                    ? "Du starter helt forfra. Det gamle system ligger som en kopi i mappen med sikkerhedskopier og kan importeres igen."
                    : "Reoler, placeringer og historik er hentet fra filen. Det tidligere system ligger som en kopi i mappen med sikkerhedskopier.",
            });
        }
        if (Model.ErrorMessage is string startError)
        {
            _errorBar.Title = "Noget gik galt";
            _errorBar.Message = startError;
            _errorBar.IsOpen = true;
        }
        Nav.FooterMenuItems.Add(_updateItem);
        Nav.Loaded += (_, _) => { if (Nav.SettingsItem is NavigationViewItem si) si.Content = "Indstillinger"; };

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
                // "Opdel samlingen forfra…" i Indstillinger: forlad Indstillinger, så opdelingen kan ses.
                if (Model.ForceOnboarding && _settingsShown)
                {
                    _settingsShown = false;
                    var item = Nav.MenuItems.OfType<NavigationViewItem>().FirstOrDefault(i => i.Tag is SidebarItem s && s == Model.Sidebar);
                    if (item is not null) Nav.SelectedItem = item;
                }
                ShowContent();
                break;
            case nameof(AppModel.SyncState):
                UpdateToolbar();
                break;
            case nameof(AppModel.CloudChoice):
                if (Model.CloudChoice is NeedsChoiceException choice) _ = AskCloudChoiceAsync(choice);
                break;
            case nameof(AppModel.HasToken):
                FindNew.ResetClient();
                UpdateToolbar();
                if (Model.Sidebar.Kind == SidebarKind.FindNew) ShowContent();
                break;
            case nameof(AppModel.Medium):
                UpdateToolbar();
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
            case nameof(AppModel.CheckSection):
                if (Model.CheckSection is long cs) _ = ShowDialog(() => new CheckShelf(Model, cs).RunAsync(Root.XamlRoot), () => Model.CheckSection = null);
                break;
            case nameof(AppModel.SyncReportToShow):
                if (Model.SyncReportToShow is SyncReport rep) _ = ShowDialog(() => CheckShelf.ShowSyncReportAsync(Model, rep, Root.XamlRoot), () => Model.SyncReportToShow = null);
                break;
            case nameof(AppModel.StatusNoteRequest):
                if (Model.StatusNoteRequest is StatusNoteRequest r) _ = ShowDialog(() => Dialogs.ShowStatusNoteAsync(Model, r, Root.XamlRoot), () => Model.StatusNoteRequest = null);
                break;
        }
        Search.OnModelChanged(p);
        if (_listPane is not null && _listPane != Search) _listPane.OnModelChanged(p);
        _fullPane?.OnModelChanged(p);
        Detail.OnModelChanged(p);
        Find.OnModelChanged(p);
        if (DetailHost.Child == _coverFlow?.View) _coverFlow?.OnModelChanged(p);
        if (DetailHost.Child == _findNewDetail?.View) _findNewDetail?.OnModelChanged(p);
        if (p == nameof(AppModel.ShowCoverFlow)) UpdateDetail();
        if (p == nameof(AppModel.Library)) UpdateToolbar();
    }

    // MARK: Værktøjslinjen

    private FrameworkElement BuildToolbar()
    {
        var bar = new Grid { Padding = new Thickness(12, 6, 12, 6), ColumnSpacing = 8 };
        bar.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        bar.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        foreach (var m in new[] { Medium.Vinyl, Medium.Cd })
            _mediumBar.Items.Add(new SelectorBarItem { Text = m.Title(), Tag = m });
        ToolTipService.SetToolTip(_mediumBar, "Skift mellem pladereolerne og cd-reolerne");
        _mediumBar.SelectionChanged += (_, _) =>
        {
            if (_mediumBar.SelectedItem?.Tag is Medium m && Model.Medium != m) Model.Medium = m;
        };
        bar.Children.Add(_mediumBar);
        _syncButton.Click += async (_, _) => await Model.SyncAsync();
        Grid.SetColumn(_syncButton, 1);
        bar.Children.Add(_syncButton);
        UpdateToolbar();
        return bar;
    }

    private void UpdateToolbar()
    {
        _mediumBar.Visibility = Model.ShowsMediumPicker ? Visibility.Visible : Visibility.Collapsed;
        var want = _mediumBar.Items.FirstOrDefault(i => i.Tag is Medium m && m == Model.Medium);
        if (want is not null && _mediumBar.SelectedItem != want) _mediumBar.SelectedItem = want;

        var s = Model.SyncState;
        _syncButton.Visibility = Model.IsDemo ? Visibility.Collapsed : Visibility.Visible;
        _syncButton.IsEnabled = Model.HasToken && s.Phase != SyncPhase.Running;
        _syncButton.Content = s.Phase switch
        {
            SyncPhase.Running => Ui.Label(Ui.Glyph.Sync, s.Total > 0 ? $"{s.Done}/{s.Total}" : "Henter…"),
            SyncPhase.Failed => Ui.Label(Ui.Glyph.Warning, "Synkronisering fejlede"),
            _ => Ui.Label(Ui.Glyph.Sync, "Synkronisér"),
        };
        ToolTipService.SetToolTip(_syncButton, s.Phase == SyncPhase.Failed ? s.Message
            : Model.HasToken ? "Synkronisér med Discogs (Ctrl+R)" : "Forbind til Discogs for at synkronisere");
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
        items.Add(Item("Sorteringsliste", Ui.Glyph.Checklist, new SidebarItem(SidebarKind.SortList)));
        items.Add(Item("Værdi", Ui.Glyph.Value, new SidebarItem(SidebarKind.Value)));
        items.Add(new NavigationViewItemHeader { Content = "Discogs" });
        items.Add(Item("Find nye plader", Ui.Glyph.Bag, new SidebarItem(SidebarKind.FindNew)));
        items.Add(new NavigationViewItemHeader { Content = "Lytning" });
        items.Add(Item("Hvad skal jeg høre?", Ui.Glyph.Shuffle, new SidebarItem(SidebarKind.Listen)));
        items.Add(Item("Lyttelog", Ui.Glyph.List, new SidebarItem(SidebarKind.Plays), Model.Stats.Plays.Count));
        items.Add(new NavigationViewItemHeader { Content = "Indbakke" });
        items.Add(Item($"Nye {Model.Medium.Plural()}", Ui.Glyph.New, new SidebarItem(SidebarKind.NewRecords), lib.Unplaced.Count));
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
                var secItem = Item($"Sektion {loc.Section}", Ui.Glyph.Library, SidebarItem.ForSection(loc.Id), onShelf);
                secItem.ContextFlyout = SectionMenu(loc, shelf, onShelf == 0 && (!lib.Sections.TryGetValue(loc.Id, out var all) || all.Count == 0));
                items.Add(secItem);
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

    /// <summary>Højreklik på en sektion: Kontrollér, tilføj sektion, slet tom sektion.</summary>
    private MenuFlyout SectionMenu(Location loc, int shelf, bool empty)
    {
        var menu = new MenuFlyout();
        var check = new MenuFlyoutItem { Text = "Kontrollér sektion…" };
        check.Click += (_, _) => Model.CheckSection = loc.Id;
        menu.Items.Add(check);
        var add = new MenuFlyoutItem { Text = $"Tilføj sektion i {loc.Medium.ShelfWord()} {shelf}" };
        add.Click += (_, _) => Model.AddSection(shelf);
        menu.Items.Add(add);
        if (empty)
        {
            var del = new MenuFlyoutItem { Text = "Slet tom sektion" };
            del.Click += (_, _) => Model.DeleteSection(loc.Id);
            menu.Items.Add(del);
        }
        return menu;
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

    private SettingsPane? _settings;

    private void ShowSettings()
    {
        _settingsShown = true;
        _settings ??= new SettingsPane(Model, _updater);
        ShowFull(_settings);
    }

    /// <summary>
    /// vinylshelf://section/&lt;id&gt; (QR-koden på et reolskilt): viser sektionen med første plade valgt
    /// og lægger vinduet forrest. Ukendte adresser ignoreres (som på Mac).
    /// </summary>
    internal void OpenScanCode(string? code)
    {
        // Linket i login-mailen (vinylshelf://auth#…) logger ind på kontoen.
        if (code is not null && Model.CompleteCloudLink(code)) { Activate(); return; }
        if (code is null || Model.Library.LocationForScanCode(code)?.Id is not long id) return;
        Model.Sidebar = SidebarItem.ForSection(id);
        Model.Selection = Model.Library.Sections.TryGetValue(id, out var ids) && ids.Count > 0 ? ids[0] : null;
        Activate();
    }

    /// <summary>Første gang: kontoen og denne pc har hver deres reoler. Hvilke skal bruges?</summary>
    private async Task AskCloudChoiceAsync(NeedsChoiceException c)
    {
        var d = new ContentDialog
        {
            XamlRoot = Root.XamlRoot,
            Title = "Hvilke reoler skal bruges?",
            Content = Ui.Text($"Kontoen har {c.CloudSections} sektioner, og denne pc har {c.LocalSections} andre. Pladerne, lyttelog og flueben flettes, men reolerne skal komme ét sted fra. Vælger du denne pc's reoler, forsvinder kontoens reoler også på dine andre enheder. Før reoler slettes, gemmes en sikkerhedskopi i mappen med sikkerhedskopier."),
            PrimaryButtonText = "Brug kontoens reoler",
            SecondaryButtonText = "Brug denne pc's reoler",
            CloseButtonText = "Senere",
            DefaultButton = ContentDialogButton.Close,
        };
        try
        {
            var r = await d.ShowAsync();
            if (r == ContentDialogResult.Primary) Model.ResolveCloudChoice(FirstSync.UseCloud);
            else if (r == ContentDialogResult.Secondary) Model.ResolveCloudChoice(FirstSync.UseThisDevice);
            else Model.PostponeCloudChoice();
        }
        catch (System.Runtime.InteropServices.COMException) { Model.CloudChoice = null; } // en anden dialog er åben
    }

    /// <summary>Åbner Indstillinger (fx fra "Opdatering" i sidepanelet).</summary>
    internal void OpenSettings() => Nav.SelectedItem = Nav.SettingsItem;

    private sealed class StaticPane(FrameworkElement view) : IPane
    {
        public FrameworkElement View => view;
        public void OnModelChanged(string? property) { }
    }

    private void ShowFull(FrameworkElement view) => ShowFull(new StaticPane(view));

    private void ShowFull(IPane pane)
    {
        _listPane = null;
        _fullPane = pane;
        ListHost.Child = null;
        FullHost.Child = pane.View;
        FullHost.Visibility = Visibility.Visible;
        ListHost.Visibility = Visibility.Collapsed;
        DetailHost.Visibility = Visibility.Collapsed;
    }

    /// <summary>Højre kolonne: Cover Flow i en sektion (når det er slået til), ellers plade-detaljen.</summary>
    private void UpdateDetail()
    {
        if (Model.Sidebar.Kind == SidebarKind.FindNew)
        {
            _findNewDetail ??= new FindNewDetailPane(Model, FindNew, IMusic);
            DetailHost.Child = _findNewDetail.View;
            return;
        }
        if (Model.Sidebar.Kind == SidebarKind.Section && Model.ShowCoverFlow && Model.Library.LocationById(Model.Sidebar.SectionId) is not null)
        {
            _coverFlow ??= new CoverFlowPane(Model);
            DetailHost.Child = _coverFlow.View;
            _coverFlow.Show(Model.Sidebar.SectionId);
        }
        else DetailHost.Child = Detail.View;
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
        UpdateDetail();
    }

    private void ShowContent()
    {
        if (_settingsShown) return;
        // Sorteringslisten kan ses, før reolerne er lavet (så man kan se rækkefølgen først).
        bool sortListWithoutShelves = Model.Sidebar.Kind == SidebarKind.SortList && !Model.ForceOnboarding
                                      && Model.Library.Copies.Count > 0 && (Model.HasToken || Model.IsDemo);
        if (Model.NeedsOnboarding && !sortListWithoutShelves)
        {
            _onboarding ??= new OnboardingView(Model);
            ShowFull(_onboarding);
            return;
        }
        _onboarding = null;
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
            case SidebarKind.Listen:
                ShowList(new ListenPane(Model));
                break;
            case SidebarKind.Plays:
                ShowList(new PlaysPane(Model));
                break;
            case SidebarKind.FindNew:
                ShowList(new FindNewSearchPane(Model, FindNew));
                break;
            case SidebarKind.Value:
                ShowList(new ValuePane(Model));
                break;
            case SidebarKind.History:
                ShowFull(new HistoryPane(Model));
                break;
            case SidebarKind.SortList:
                ShowFull(new SortListPane(Model));
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
        // Mellemrum = ny plade i "Hvad skal jeg høre?" (men ikke, når man skriver i et tekstfelt).
        Root.KeyDown += (_, e) =>
        {
            if (e.Key != VirtualKey.Space || Model.Sidebar.Kind != SidebarKind.Listen) return;
            if (Microsoft.UI.Xaml.Input.FocusManager.GetFocusedElement(Root.XamlRoot) is TextBox or PasswordBox or AutoSuggestBox) return;
            Model.PickRecord();
            e.Handled = true;
        };
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
        Add(VirtualKey.P, VirtualKeyModifiers.Control, () => { if (Model.Library.Locations.Count > 0) _ = LabelsPrint.ExportAsync(Model); });
        Add(VirtualKey.R, VirtualKeyModifiers.Control, () => _ = Model.SyncAsync());
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
    [System.Runtime.InteropServices.DllImport("user32.dll")]
    private static extern uint GetDpiForWindow(IntPtr hwnd);

    /// <summary>
    /// Startstørrelse: så stor, at plade-detaljen kan ses uden at rulle (op til 1440×1000 ved 100 %,
    /// tilsvarende større ved skalering), men aldrig større end skærmen. Vinduet lægges midt på skærmen.
    /// </summary>
    private void FitToScreen()
    {
        var area = Microsoft.UI.Windowing.DisplayArea.GetFromWindowId(AppWindow.Id, Microsoft.UI.Windowing.DisplayAreaFallback.Primary).WorkArea;
        uint dpi = GetDpiForWindow(Hwnd);
        double scale = dpi == 0 ? 1 : dpi / 96.0;
        int w = Math.Min((int)(1440 * scale), area.Width * 9 / 10), h = Math.Min((int)(1000 * scale), area.Height * 9 / 10);
        AppWindow.MoveAndResize(new Windows.Graphics.RectInt32(area.X + (area.Width - w) / 2, area.Y + (area.Height - h) / 2, w, h));
    }

    /// <summary>
    /// Fuldt sidepanel fra 1100 px, ellers kun ikoner. NavigationView lukker selv panelet under
    /// skiftet, så det åbnes først bagefter.
    /// </summary>
    private void FitPane(double width)
    {
        bool wide = width >= 1100;
        var mode = wide ? NavigationViewPaneDisplayMode.Left : NavigationViewPaneDisplayMode.LeftCompact;
        if (Nav.PaneDisplayMode != mode) Nav.PaneDisplayMode = mode;
        if (wide && !Nav.IsPaneOpen) DispatcherQueue.TryEnqueue(() => { if (Nav.PaneDisplayMode == NavigationViewPaneDisplayMode.Left) Nav.IsPaneOpen = true; });
    }

    /// <summary>Fast vinduesstørrelse til smoke-testens billeder.</summary>
    internal void ResizeForSmoke(int width, int height) => AppWindow.Resize(new Windows.Graphics.SizeInt32(width, height));

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
