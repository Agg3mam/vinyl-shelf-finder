using System.ComponentModel;
using System.Runtime.CompilerServices;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using VinylShelfFinder.Core;
using VinylShelfFinder.UI;

namespace VinylShelfFinder;

/// <summary>
/// iMusic.dk som ekstra købssted (IMusicViews.swift). Uden feed: knappen "Søg på iMusic". Med
/// brugerens Daisycon-feed: pris og lager fra feedet og "Køb på iMusic" (affiliate-linket). Købet sker
/// altid på imusic.dk i standardbrowseren, aldrig i Discogs-vinduet. Feed-URL'en ligger kun i Windows'
/// Legitimationsadministrator og vises eller logges aldrig.
/// </summary>
public sealed class IMusicModel : INotifyPropertyChanged
{
    public event PropertyChangedEventHandler? PropertyChanged;
    private readonly bool _enabled;
    private readonly ISecretStore _secret;
    private IMusicCache? _cache;
    private readonly SemaphoreSlim _lock = new(1, 1);

    public bool HasFeed { get; private set; }
    public bool Updating { get; private set; }
    public string? Error { get; private set; }
    public int ProductCount { get; private set; }
    public DateTimeOffset? LastFetched { get; private set; }
    /// <summary>Stiger, når cachen er opdateret, så åbne skærme slår prisen op igen.</summary>
    public int Revision { get; private set; }

    /// <summary>Slået fra i demo- og smoke-tilstand: hverken adgangskodelager eller net.</summary>
    public IMusicModel(bool enabled)
    {
        _enabled = enabled;
        _secret = enabled ? WindowsCredentialStore.IMusicFeed : new InMemorySecretStore();
        try { HasFeed = enabled && _secret.Exists; } catch { HasFeed = false; }
    }

    private IMusicCache Open() => _cache ??= new IMusicCache();

    /// <summary>Ved start: hent feedet, hvis det er over et døgn gammelt.</summary>
    public async void Start()
    {
        if (!_enabled) return;
        await Task.Run(() =>
        {
            try { var c = Open(); ProductCount = c.Count; LastFetched = c.LastFetched; } catch { }
        });
        OnChanged(nameof(ProductCount));
        if (HasFeed && IMusicCache.NeedsRefresh(LastFetched)) Refresh();
    }

    /// <summary>Gemmer feed-URL'en. Returnerer en fejltekst, hvis den ikke kan bruges.</summary>
    public string? SaveFeed(string text)
    {
        if (!_enabled) return "iMusic-feedet er slået fra i demo-tilstand.";
        if (IMusicFeedUpdater.Validate(text) is not Uri url) return IMusicFeedException.Describe(IMusicFeedErrorKind.BadUrl);
        try { _secret.Save(url.ToString()); }
        catch (Exception ex) { return ex.Message; }
        HasFeed = true;
        OnChanged(nameof(HasFeed));
        Refresh();
        return null;
    }

    public void RemoveFeed()
    {
        if (!_enabled) return;
        try { _secret.Delete(); } catch { }
        HasFeed = false;
        Error = null;
        OnChanged(nameof(HasFeed));
    }

    /// <summary>Henter feedet nu ("Opdatér nu").</summary>
    public async void Refresh()
    {
        if (!_enabled || !HasFeed || Updating) return;
        // URL'en læses først her og gives kun til hentningen.
        string? text = null;
        try { text = _secret.Load(); } catch { }
        if (text is null || IMusicFeedUpdater.Validate(text) is not Uri url)
        {
            Error = IMusicFeedException.Describe(IMusicFeedErrorKind.BadUrl);
            OnChanged(nameof(Error));
            return;
        }
        Updating = true;
        Error = null;
        OnChanged(nameof(Updating));
        await _lock.WaitAsync();
        try
        {
            var cache = Open();
            await IMusicFeedUpdater.RefreshAsync(url, cache);
            ProductCount = cache.Count;
            LastFetched = cache.LastFetched;
            Revision++;
        }
        catch (IMusicFeedException e) { Error = e.Message; }
        catch (HttpRequestException) { Error = "Kunne ikke hente iMusic-feedet. Tjek internetforbindelsen, og prøv igen."; }
        catch (Exception) { Error = "iMusic-feedet kunne ikke opdateres."; }
        finally { _lock.Release(); }
        Updating = false;
        OnChanged(nameof(Updating));
    }

    public async Task<IMusicProduct?> OfferAsync(IReadOnlyList<string> barcodes, string artist, string title, bool preferVinyl)
    {
        if (!_enabled || ProductCount == 0) return null;
        await _lock.WaitAsync();
        try { return await Task.Run(() => Open().Match(barcodes, artist, title, preferVinyl)); }
        catch { return null; }
        finally { _lock.Release(); }
    }

    /// <summary>"iMusic: 249 kr. · på lager"</summary>
    public static string Summary(IMusicProduct p)
    {
        var first = "iMusic";
        if (p.Price is double price) first += ": " + Views.FindNewPanes.PriceText(new MarketInfo(price, p.Currency, null, null, null));
        var parts = new List<string> { first };
        if (p.AvailabilityText is string a) parts.Add(a);
        return string.Join(" · ", parts);
    }

    /// <summary>Linjen med pris og knap, eller "Søg på iMusic", når der ikke er et match.</summary>
    public FrameworkElement OfferLine(IReadOnlyList<string> barcodes, string artist, string title, bool preferVinyl, bool compact = false)
    {
        var host = new ContentControl { HorizontalContentAlignment = HorizontalAlignment.Left };
        Microsoft.UI.Xaml.Controls.Primitives.ButtonBase Link(string text, string glyph, Uri url, string tip)
        {
            Microsoft.UI.Xaml.Controls.Primitives.ButtonBase b = compact
                ? new HyperlinkButton { Content = Ui.Text(text, "CaptionTextBlockStyle", Ui.Tertiary), Padding = new Thickness(0) }
                : Ui.Btn(text, (_, _) => { }, glyph);
            b.Click += async (_, _) => await Windows.System.Launcher.LaunchUriAsync(url);
            ToolTipService.SetToolTip(b, tip);
            return b;
        }
        host.Content = Link("Søg på iMusic", Ui.Glyph.Search, IMusicLink.SearchUrl(artist, title, preferVinyl),
            $"Åbner iMusics søgning på {artist} – {title} i din browser");
        _ = Fill();
        async Task Fill()
        {
            if (await OfferAsync(barcodes, artist, title, preferVinyl) is not IMusicProduct p) return;
            var t = Ui.Text(Summary(p), compact ? "CaptionTextBlockStyle" : "BodyTextBlockStyle", compact ? Ui.Tertiary : Ui.Secondary, wrap: false);
            t.VerticalAlignment = VerticalAlignment.Center;
            host.Content = Ui.HStack(8, t, Link("Køb på iMusic", "", p.Link, $"Åbner varen hos iMusic i din browser: {p.Artist} – {p.Title} ({p.Format})"));
        }
        return host;
    }

    /// <summary>Fanen iMusic i Indstillinger.</summary>
    public FrameworkElement SettingsTab(AppModel model)
    {
        var p = new StackPanel { Spacing = 12 };
        void Build()
        {
            p.Children.Clear();
            p.Children.Add(Ui.Text("iMusic-feed (Daisycon)", "BodyStrongTextBlockStyle"));
            p.Children.Add(Ui.Text($"Feed: {(HasFeed ? "Gemt i Windows' Legitimationsadministrator" : "Ikke sat op")}"));
            if (ProductCount > 0) p.Children.Add(Ui.Text($"Varer: {ProductCount.ToString("N0", System.Globalization.CultureInfo.GetCultureInfo("da-DK"))} musikvarer"));
            if (LastFetched is DateTimeOffset d) p.Children.Add(Ui.Text($"Sidst hentet: {Views.DanishDate.DateTime(d)}"));
            if (Updating) p.Children.Add(Ui.HStack(8, new ProgressRing { IsActive = true, Width = 16, Height = 16 }, Ui.Text("Henter iMusic-feedet …", color: Ui.Secondary)));
            if (Error is string err) p.Children.Add(Ui.Label(Ui.Glyph.Warning, err, color: Ui.Secondary));
            var box = new PasswordBox { PlaceholderText = "https://daisycon.io/datafeed/?…", MinWidth = 360, MaxWidth = 480, HorizontalAlignment = HorizontalAlignment.Left };
            Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(box, "iMusic-feed (Daisycon)");
            p.Children.Add(box);
            var msg = Ui.Text("", "CaptionTextBlockStyle", Ui.Secondary);
            var save = Ui.Btn("Gem feed", (_, _) =>
            {
                var e = SaveFeed(box.Password);
                if (e is null) box.Password = ""; else msg.Text = e;
            });
            save.IsEnabled = !model.IsDemo;
            var row = Ui.HStack(8, save);
            if (HasFeed)
            {
                var now = Ui.Btn("Opdatér nu", (_, _) => Refresh());
                now.IsEnabled = !Updating;
                row.Children.Add(now);
                row.Children.Add(Ui.Btn("Fjern feed", (_, _) => RemoveFeed()));
            }
            p.Children.Add(row);
            p.Children.Add(msg);
            p.Children.Add(Ui.Text("Med dit eget produktfeed fra Daisycon viser appen iMusics pris og lagerstatus ved siden af Discogs. Feedet hentes højst én gang i døgnet og gemmes kun som cache på denne pc. URL'en indeholder dit Daisycon-id; den gemmes kun i Windows' Legitimationsadministrator og vises aldrig. Uden feed kan du stadig søge på iMusic.",
                "CaptionTextBlockStyle", Ui.Secondary));
        }
        Build();
        PropertyChangedEventHandler h = (_, _) => p.DispatcherQueue?.TryEnqueue(Build);
        PropertyChanged += h;
        p.Unloaded += (_, _) => PropertyChanged -= h;
        return Ui.Card(p, 16);
    }

    private void OnChanged([CallerMemberName] string? name = null) =>
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
}
