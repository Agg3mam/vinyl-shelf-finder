using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.Web.WebView2.Core;
using VinylShelfFinder.UI;

namespace VinylShelfFinder;

/// <summary>
/// Det indbyggede Discogs-vindue (DiscogsBrowser.swift). Discogs' API kan ikke købe, så købet sker
/// på Discogs' egen side her.
/// SIKKERHED: Appen viser bare siden. Den injicerer ingen scripts, har ingen beskedkanaler til siden,
/// læser ingen cookies eller formularfelter og gemmer intet om login eller betaling. Login huskes af
/// WebView2's eget, vedvarende datalager i %LOCALAPPDATA%\VinylShelfFinder\WebView2 (som i Edge).
/// </summary>
public sealed class DiscogsBrowserWindow : Window
{
    private const string HintSeenKey = "discogs_browser_hint_seen";
    private static DiscogsBrowserWindow? _current;

    private readonly AppModel _model;
    private readonly WebView2 _web = new();
    private readonly Button _back = new() { Content = Ui.Icon(Ui.Glyph.Back, 14) };
    private readonly Button _forward = new() { Content = Ui.Icon(Ui.Glyph.Forward, 14) };
    private readonly Button _reload = new() { Content = Ui.Icon(Ui.Glyph.Refresh, 14) };
    private readonly TextBlock _host = new() { VerticalAlignment = VerticalAlignment.Center, TextTrimming = TextTrimming.CharacterEllipsis };
    private readonly FontIcon _lock = new() { Glyph = Ui.Glyph.Lock, FontSize = 12 };
    private readonly ProgressRing _loading = new() { Width = 16, Height = 16, IsActive = false };
    private readonly Grid _failure = new() { Visibility = Visibility.Collapsed };
    private Uri? _pending;
    private bool _ready;

    /// <summary>Åbner siden i Discogs-vinduet (ét vindue; det kommer frem, hvis det allerede er åbent).</summary>
    public static void Open(AppModel model, Uri url)
    {
        if (url.Scheme is not ("https" or "http")) return;
        if (_current is null)
        {
            _current = new DiscogsBrowserWindow(model);
            _current.Closed += (_, _) => _current = null;
        }
        _current.Navigate(url);
        _current.Activate();
    }

    private DiscogsBrowserWindow(AppModel model)
    {
        _model = model;
        Title = "Discogs";
        AppWindow.SetIcon(System.IO.Path.Combine(AppContext.BaseDirectory, "Assets", "AppIcon.ico"));
        AppWindow.Resize(new Windows.Graphics.SizeInt32(1100, 820));

        var root = new Grid();
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        root.Background = Ui.ThemeBrush("SolidBackgroundFillColorBaseBrush");

        // Værktøjslinje: tilbage, frem, genindlæs, adresse (værtsnavnet står tydeligt) og "Åbn i browser".
        var bar = new Grid { Padding = new Thickness(8), ColumnSpacing = 6 };
        for (int i = 0; i < 4; i++) bar.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        bar.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        bar.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        ToolTipService.SetToolTip(_back, "Tilbage");
        ToolTipService.SetToolTip(_forward, "Frem");
        ToolTipService.SetToolTip(_reload, "Indlæs igen");
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(_back, "Tilbage");
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(_forward, "Frem");
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(_reload, "Indlæs igen");
        _back.Click += (_, _) => { if (_web.CanGoBack) _web.GoBack(); };
        _forward.Click += (_, _) => { if (_web.CanGoForward) _web.GoForward(); };
        _reload.Click += (_, _) => _web.Reload();
        bar.Children.Add(_back);
        Grid.SetColumn(_forward, 1); bar.Children.Add(_forward);
        Grid.SetColumn(_reload, 2); bar.Children.Add(_reload);
        Grid.SetColumn(_loading, 3); bar.Children.Add(_loading);
        var address = new Border
        {
            CornerRadius = new CornerRadius(14),
            Padding = new Thickness(12, 4, 12, 4),
            Background = Ui.ThemeBrush("ControlFillColorSecondaryBrush"),
            MaxWidth = 560,
            HorizontalAlignment = HorizontalAlignment.Center,
            Child = Ui.HStack(6, _lock, _host),
        };
        Grid.SetColumn(address, 4); bar.Children.Add(address);
        var external = Ui.Btn("Åbn i browser", async (_, _) =>
        {
            if (_web.Source is Uri u) await Windows.System.Launcher.LaunchUriAsync(u);
        }, "", tooltip: "Åbn siden i din almindelige browser");
        Grid.SetColumn(external, 5); bar.Children.Add(external);
        root.Children.Add(bar);

        // Første gang: en kort, venlig forklaring.
        if (model.Store.Setting(HintSeenKey) != "1")
        {
            var hint = new InfoBar
            {
                IsOpen = true,
                Severity = InfoBarSeverity.Informational,
                Message = "Du køber direkte hos Discogs. Log ind på Discogs her første gang.",
                IsClosable = true,
            };
            hint.Closed += (_, _) => model.Store.SetSetting(HintSeenKey, "1");
            Grid.SetRow(hint, 1);
            root.Children.Add(hint);
        }

        Grid.SetRow(_web, 2);
        root.Children.Add(_web);
        _failure.Background = Ui.ThemeBrush("SolidBackgroundFillColorBaseBrush");
        Grid.SetRow(_failure, 2);
        root.Children.Add(_failure);
        Content = root;
        _ = InitAsync();
    }

    private async Task InitAsync()
    {
        try
        {
            var folder = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "VinylShelfFinder", "WebView2");
            var env = await CoreWebView2Environment.CreateWithOptionsAsync(null, folder, new CoreWebView2EnvironmentOptions { Language = "da-DK" });
            await _web.EnsureCoreWebView2Async(env);
            var core = _web.CoreWebView2;
            // Bevidst ingen scripts, beskedkanaler eller adgang til sidens indhold.
            core.Settings.AreDevToolsEnabled = false;
            core.Settings.AreHostObjectsAllowed = false;
            core.Settings.IsWebMessageEnabled = false;
            core.Settings.IsStatusBarEnabled = true;
            core.NavigationStarting += (sender, e) =>
            {
                // Kun almindelige websider – aldrig lokale filer. Andre adresser (fx mailto:) gives til Windows.
                if (!Uri.TryCreate(e.Uri, UriKind.Absolute, out var u)) { e.Cancel = true; return; }
                if (u.Scheme is "https" or "http")
                {
                    _failure.Visibility = Visibility.Collapsed;
                    _loading.IsActive = true;
                    ShowAddress(u);
                    return;
                }
                e.Cancel = true;
                if (u.Scheme is "mailto" or "tel") _ = Windows.System.Launcher.LaunchUriAsync(u);
            };
            // Links med target=_blank og window.open indlæses i samme vindue.
            core.NewWindowRequested += (_, e) =>
            {
                e.Handled = true;
                if (Uri.TryCreate(e.Uri, UriKind.Absolute, out var u) && u.Scheme is "https" or "http") core.Navigate(u.ToString());
            };
            core.NavigationCompleted += (_, e) =>
            {
                _loading.IsActive = false;
                UpdateButtons();
                if (!e.IsSuccess && e.WebErrorStatus is not (CoreWebView2WebErrorStatus.OperationCanceled or CoreWebView2WebErrorStatus.Unknown))
                    ShowFailure(e.WebErrorStatus is CoreWebView2WebErrorStatus.Disconnected or CoreWebView2WebErrorStatus.CannotConnect
                        or CoreWebView2WebErrorStatus.HostNameNotResolved or CoreWebView2WebErrorStatus.ConnectionAborted
                        ? "Der er ingen forbindelse til internettet. Tjek forbindelsen, og prøv igen."
                        : "Discogs svarede ikke. Prøv igen om lidt.");
            };
            core.SourceChanged += (_, _) => { if (Uri.TryCreate(core.Source, UriKind.Absolute, out var u)) ShowAddress(u); UpdateButtons(); };
            core.HistoryChanged += (_, _) => UpdateButtons();
            core.DocumentTitleChanged += (_, _) => Title = string.IsNullOrWhiteSpace(core.DocumentTitle) ? "Discogs" : core.DocumentTitle;
            _ready = true;
            if (_pending is Uri p) core.Navigate(p.ToString());
            _pending = null;
        }
        catch (Exception)
        {
            ShowFailure("Discogs-vinduet kræver Microsoft Edge WebView2, som følger med Windows 11. Hent det hos Microsoft, eller brug “Åbn i browser”.");
        }
    }

    private void Navigate(Uri url)
    {
        if (_ready) _web.CoreWebView2.Navigate(url.ToString());
        else _pending = url;
        ShowAddress(url);
    }

    private void ShowAddress(Uri u)
    {
        _host.Text = u.Host;
        _lock.Glyph = u.Scheme == "https" ? "" : "";
        ToolTipService.SetToolTip(_host, u.ToString());
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(_host, u.Scheme == "https" ? $"Sikker forbindelse til {u.Host}" : $"Adresse: {u.Host}");
    }

    private void UpdateButtons()
    {
        _back.IsEnabled = _web.CanGoBack;
        _forward.IsEnabled = _web.CanGoForward;
    }

    private void ShowFailure(string message)
    {
        _failure.Children.Clear();
        var retry = Ui.Btn("Prøv igen", (_, _) => { _failure.Visibility = Visibility.Collapsed; if (_ready) _web.Reload(); });
        var p = Ui.VStack(12, Ui.Empty("", "Siden kunne ikke vises", message), retry);
        p.HorizontalAlignment = HorizontalAlignment.Center;
        p.VerticalAlignment = VerticalAlignment.Center;
        retry.HorizontalAlignment = HorizontalAlignment.Center;
        _failure.Children.Add(p);
        _failure.Visibility = Visibility.Visible;
    }
}
