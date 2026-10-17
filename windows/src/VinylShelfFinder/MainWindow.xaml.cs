using System.Runtime.InteropServices.WindowsRuntime;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media.Imaging;
using Windows.Graphics.Imaging;
using Windows.Storage.Streams;
using VinylShelfFinder.Pages;

namespace VinylShelfFinder;

public sealed partial class MainWindow : Window
{
    /// <summary>
    /// Sidebjælkens punkter: Tag i MainWindow.xaml -> side, der vises i Frame'en.
    /// Ny skærm: lav en Page i Pages/ og ret typen her (PlaceholderPage får titlen som parameter).
    /// </summary>
    private static readonly Dictionary<string, Type> PageTypes = new()
    {
        ["search"] = typeof(PlaceholderPage),
        ["new"] = typeof(PlaceholderPage),
        ["removed"] = typeof(PlaceholderPage),
        ["out"] = typeof(PlaceholderPage),
        ["history"] = typeof(PlaceholderPage),
        ["value"] = typeof(PlaceholderPage),
        ["suggest"] = typeof(PlaceholderPage),
        ["listenlog"] = typeof(PlaceholderPage),
        ["discover"] = typeof(PlaceholderPage),
    };

    private readonly Updater _updater;

    public MainWindow(Updater updater)
    {
        _updater = updater;
        InitializeComponent();
        _updater.Changed += ShowUpdateState;
        Title = "Vinyl Shelf Finder";
        AppWindow.Resize(new Windows.Graphics.SizeInt32(1200, 800));
        Nav.SelectedItem = Nav.MenuItems.OfType<NavigationViewItem>().First();
    }

    private void Nav_SelectionChanged(NavigationView sender, NavigationViewSelectionChangedEventArgs args)
    {
        if (args.SelectedItem is not NavigationViewItem item || item.Tag is not string tag) return;
        if (!PageTypes.TryGetValue(tag, out var pageType)) return;
        ContentFrame.Navigate(pageType, item.Content?.ToString());
    }

    /// <summary>Tjekker GitHub ved start (højst én gang om dagen) og spørger, hvis der er en ny version.</summary>
    internal async Task CheckForUpdateOnLaunchAsync()
    {
        _silent = true;
        try { _askedOnLaunch = await _updater.CheckOnLaunchAsync(); }
        finally { _silent = false; }
        if (_askedOnLaunch) ShowUpdateState();
    }

    private bool _askedOnLaunch, _silent;

    private void Nav_ItemInvoked(NavigationView sender, NavigationViewItemInvokedEventArgs args)
    {
        if (args.InvokedItemContainer?.Tag as string != "update") return;
        _askedOnLaunch = false;
        if (_updater.State is Updater.Phase.Idle or Updater.Phase.UpToDate or Updater.Phase.Failed && _updater.Enabled)
            _ = _updater.CheckAsync();
        else ShowUpdateState();
    }

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
