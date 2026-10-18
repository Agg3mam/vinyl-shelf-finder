using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using VinylShelfFinder.Core;
using VinylShelfFinder.UI;

namespace VinylShelfFinder.Views;

/// <summary>Indstillinger (SettingsView.swift): Discogs, Sortering, Reol, iMusic, Sikkerhedskopi og Opdatering.</summary>
public sealed class SettingsPane : IPane
{
    private readonly AppModel _model;
    private readonly Updater _updater;
    private readonly Grid _root = new();
    private readonly SelectorBar _tabs = new() { Margin = new Thickness(24, 12, 24, 0) };
    private readonly ScrollViewer _scroll = new() { HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled };
    private string _tab = "discogs";
    // Felterne har deres egen tekst, så et komma ikke forsvinder midt i skrivningen.
    private readonly TextBox _artistArticles = new() { Header = "Ignorerede artikler i kunstnernavne", PlaceholderText = "The, Die, Les" };
    private readonly TextBox _titleArticles = new() { Header = "Ignorerede artikler i titler", PlaceholderText = "(ingen)" };
    private readonly PasswordBox _token = new() { Header = "Nyt token", MaxWidth = 420, HorizontalAlignment = HorizontalAlignment.Left };
    private bool _building;

    /// <summary>Ekstra faner, som andre dele af appen lægger ind (fx iMusic).</summary>
    public static Func<AppModel, FrameworkElement>? IMusicTab { get; set; }

    public FrameworkElement View => _root;

    public SettingsPane(AppModel model, Updater updater)
    {
        _model = model;
        _updater = updater;
        _root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        _root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        foreach (var (tag, text) in new[] { ("discogs", "Discogs"), ("sort", "Sortering"), ("shelf", "Reol"), ("imusic", "iMusic"), ("backup", "Sikkerhedskopi og data"), ("update", "Opdatering") })
            _tabs.Items.Add(new SelectorBarItem { Text = text, Tag = tag });
        _tabs.SelectedItem = _tabs.Items[0];
        _tabs.SelectionChanged += (_, _) => { if (_tabs.SelectedItem?.Tag is string t) { _tab = t; Rebuild(); } };
        _root.Children.Add(_tabs);
        Grid.SetRow(_scroll, 1);
        _root.Children.Add(_scroll);

        _artistArticles.Text = string.Join(", ", model.Rules.ArtistArticles);
        _titleArticles.Text = string.Join(", ", model.Rules.TitleArticles);
        _artistArticles.TextChanged += (_, _) => UpdateRules(r => { var l = List(_artistArticles.Text); if (!l.SequenceEqual(r.ArtistArticles)) r.ArtistArticles = l; });
        _titleArticles.TextChanged += (_, _) => UpdateRules(r => { var l = List(_titleArticles.Text); if (!l.SequenceEqual(r.TitleArticles)) r.TitleArticles = l; });
        _updater.Changed += () => { if (_tab == "update") Rebuild(); };
        Rebuild();
    }

    public void OnModelChanged(string? property)
    {
        if (property is nameof(AppModel.HasToken) or nameof(AppModel.Username) or nameof(AppModel.Library) or nameof(AppModel.Medium)
            or nameof(AppModel.LastBackup) or nameof(AppModel.BackupError) or nameof(AppModel.SyncState))
            Rebuild();
        else if (property == nameof(AppModel.Rules) && _tab == "sort" && !_building)
            Rebuild();
    }

    private static List<string> List(string s) => s.Split(',').Select(x => x.Trim()).Where(x => x.Length > 0).ToList();

    private void UpdateRules(Action<SortRules> change)
    {
        if (_building) return;
        var r = _model.Rules.Clone();
        change(r);
        if (r.Equals(_model.Rules)) return;
        _building = true;
        _model.UpdateRules(r);
        _building = false;
    }

    private void Rebuild()
    {
        _building = true;
        var p = new StackPanel { Spacing = 16, Padding = new Thickness(24), MaxWidth = 760, HorizontalAlignment = HorizontalAlignment.Left };
        switch (_tab)
        {
            case "discogs": Account(p); break;
            case "sort": Sort(p); break;
            case "shelf": Shelf(p); break;
            case "imusic":
                if (IMusicTab is not null) p.Children.Add(IMusicTab(_model));
                else p.Children.Add(Ui.Text("iMusic kommer i en senere version.", color: Ui.Secondary));
                break;
            case "backup": Backup(p); break;
            default: Update(p); break;
        }
        _scroll.Content = p;
        _building = false;
    }

    private static Border Group(params UIElement[] children) => Ui.Card(Ui.VStack(12, children), 16);

    private static FrameworkElement Row(string label, string value)
    {
        var g = new Grid { ColumnSpacing = 12 };
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(220) });
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        g.Children.Add(Ui.Text(label));
        var v = Ui.Text(value, color: Ui.Secondary);
        Grid.SetColumn(v, 1);
        g.Children.Add(v);
        return g;
    }

    private static TextBlock Footer(string text) => Ui.Text(text, "CaptionTextBlockStyle", Ui.Secondary);

    private static void Detach(FrameworkElement e)
    {
        if (e.Parent is Panel panel) panel.Children.Remove(e);
    }

    // MARK: Discogs

    private void Account(StackPanel p)
    {
        var rows = new List<UIElement>
        {
            Row("Konto", _model.HasToken ? _model.Username ?? "Ikke forbundet" : "Ikke forbundet"),
            Row("Token", _model.HasToken ? "Gemt i Windows' Legitimationsadministrator" : "Mangler"),
        };
        if (_model.HasToken && _model.Username is not null && _model.LastSync is DateTimeOffset d)
            rows.Add(Row("Sidste synkronisering", DanishDate.DateTime(d)));
        Detach(_token);
        rows.Add(_token);
        var save = Ui.Btn("Gem nyt token", async (b, _) =>
        {
            ((Button)b).IsEnabled = false;
            if (await _model.ConnectAsync(_token.Password)) _token.Password = "";
            ((Button)b).IsEnabled = true;
        });
        var buttons = Ui.HStack(8, save);
        if (_model.HasToken) buttons.Children.Add(Ui.Btn("Fjern token", (_, _) => _model.Disconnect()));
        rows.Add(buttons);
        rows.Add(Footer("Tokenet vises aldrig, logges ikke og gemmes kun i Windows' Legitimationsadministrator."));
        if (_model.IsDemo) rows.Add(Footer("Demo-tilstanden forbinder ikke til Discogs."));
        p.Children.Add(Group(rows.ToArray()));
    }

    // MARK: Sortering

    private void Sort(StackPanel p)
    {
        var rules = _model.Rules;
        var discogs = new ToggleSwitch { Header = "Præcis samme rækkefølge som i Discogs-samlingen", IsOn = rules.UseDiscogsOrder };
        discogs.Toggled += (_, _) => UpdateRules(r => r.UseDiscogsOrder = discogs.IsOn);
        var numbers = new ToggleSwitch { Header = "Kunstnere, der starter med et tal, står sidst", IsOn = rules.NumbersLast };
        numbers.Toggled += (_, _) => UpdateRules(r => r.NumbersLast = numbers.IsOn);
        p.Children.Add(Group(discogs, Footer("Pladerne står i den rækkefølge, Discogs selv sorterer samlingen (kunstner A–Z). Reglerne herunder bruges kun, når dette er slået fra."),
            numbers, Footer("10cc, 2Pac og The 1975 står efter Z og Æ Ø Å. Gælder også med Discogs' rækkefølge, hvor tallene ellers står først.")));

        int fresh = SurnameDialog.NewCount(_model);
        var surname = Ui.Btn(fresh > 0 ? $"Vælg personer… ({fresh} nye forslag)" : "Vælg personer…",
            async (b, _) => await Safe(() => SurnameDialog.ShowAsync(_model, ((FrameworkElement)b).XamlRoot)));
        p.Children.Add(Group(Ui.Text("Efternavn først", "BodyStrongTextBlockStyle"), surname,
            Footer("Personer sorteres efter efternavn: Bob Dylan under D, Leonard Cohen under C. Appen foreslår, hvem der er personer, og du retter gættet. Bands som Pink Floyd røres ikke.")));

        Detach(_artistArticles);
        Detach(_titleArticles);
        var punct = new CheckBox { Content = "Ignorér tegnsætning (AC/DC = ACDC, A-ha = Aha)", IsChecked = rules.IgnorePunctuation };
        punct.Click += (_, _) => UpdateRules(r => r.IgnorePunctuation = punct.IsChecked == true);
        var danish = new CheckBox { Content = "Dansk alfabet (Æ, Ø, Å efter Z)", IsChecked = rules.DanishAlphabet };
        danish.Click += (_, _) => UpdateRules(r => r.DanishAlphabet = danish.IsChecked == true);
        var various = new ComboBox { Header = "Opsamlinger (Various)", ItemsSource = Enum.GetValues<VariousPlacement>().Select(v => v.Label()).ToList(), SelectedIndex = (int)rules.Various };
        various.SelectionChanged += (_, _) => UpdateRules(r => r.Various = (VariousPlacement)various.SelectedIndex);
        var within = new ComboBox { Header = "Flere plader af samme kunstner", ItemsSource = new[] { WithinArtist.Title.Label(), WithinArtist.Year.Label() }, SelectedIndex = rules.WithinArtist == WithinArtist.Title ? 0 : 1 };
        within.SelectionChanged += (_, _) => UpdateRules(r => r.WithinArtist = within.SelectedIndex == 1 ? WithinArtist.Year : WithinArtist.Title);
        var group = Group(_artistArticles, _titleArticles, punct, danish, various, within,
            Footer("Reglerne bruges til første opdeling og til at foreslå pladser til nye plader. De flytter aldrig plader, der allerede står i reolen."));
        group.Opacity = rules.UseDiscogsOrder ? 0.5 : 1;
        group.IsHitTestVisible = !rules.UseDiscogsOrder;
        p.Children.Add(group);

        // Sorteringsnavne for kunstnere.
        var names = new List<UIElement> { Ui.Text("Sorteringsnavne for kunstnere", "BodyStrongTextBlockStyle") };
        foreach (var artist in rules.ArtistOverrides.Keys.OrderBy(k => k, StringComparer.CurrentCulture))
        {
            var a = artist;
            var remove = new Button { Content = Ui.Icon("", 12), Background = null, BorderThickness = new Thickness(0) };
            ToolTipService.SetToolTip(remove, "Fjern");
            Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(remove, $"Fjern sorteringsnavn for {a}");
            remove.Click += (_, _) => UpdateRules(r => r.ArtistOverrides.Remove(a));
            names.Add(Ui.HStack(8, Ui.Text(a, wrap: false), Ui.Icon(Ui.Glyph.Forward, 12, Ui.Secondary), Ui.Text(rules.ArtistOverrides[a], "BodyStrongTextBlockStyle", wrap: false), remove));
        }
        var newArtist = new TextBox { PlaceholderText = "Kunstner, fx Bob Dylan", Width = 230 };
        var newSort = new TextBox { PlaceholderText = "Sorteres som, fx Dylan, Bob", Width = 230 };
        var add = Ui.Btn("Tilføj", (_, _) =>
        {
            var a = newArtist.Text.Trim();
            var v = newSort.Text.Trim();
            if (a.Length == 0 || v.Length == 0) return;
            UpdateRules(r => r.ArtistOverrides[a] = v);
            Rebuild();
        });
        names.Add(Ui.HStack(8, newArtist, Ui.Icon(Ui.Glyph.Forward, 12, Ui.Secondary), newSort, add));
        names.Add(Footer("Skriv kunstneren, som navnet står i Discogs, og det navn, pladen skal sorteres under."));
        p.Children.Add(Group(names.ToArray()));
    }

    // MARK: Reol

    private void Shelf(StackPanel p)
    {
        var lib = _model.Library;
        var word = _model.Medium.ShelfWord();
        if (_model.ShowsMediumPicker)
        {
            var bar = new SelectorBar();
            foreach (var m in new[] { Medium.Vinyl, Medium.Cd })
            {
                var item = new SelectorBarItem { Text = m.Title(), Tag = m };
                bar.Items.Add(item);
                if (m == _model.Medium) bar.SelectedItem = item;
            }
            bar.SelectionChanged += (_, _) => { if (!_building && bar.SelectedItem?.Tag is Medium m) _model.Medium = m; };
            p.Children.Add(Group(bar, Footer("Plader og cd'er har hver deres reoler. Ændringerne herunder gælder den valgte hylde.")));
        }
        var structure = new List<UIElement> { Ui.Text("Struktur", "BodyStrongTextBlockStyle") };
        var shelves = lib.Locations.Select(l => l.Shelf).Distinct().ToList();
        foreach (var shelf in shelves)
        {
            var secs = lib.Locations.Where(l => l.Shelf == shelf).ToList();
            var g = new Grid { ColumnSpacing = 12 };
            g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(120) });
            g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            g.Children.Add(Ui.Text($"{word} {shelf}"));
            var names = Ui.HStack(6);
            foreach (var loc in secs)
            {
                bool empty = !lib.Sections.TryGetValue(loc.Id, out var ids) || ids.Count == 0;
                var badge = Ui.LocationBadge(loc.Section, tooltip: empty ? "Tom sektion – højreklik for at slette" : loc.Name);
                if (empty)
                {
                    var menu = new MenuFlyout();
                    var del = new MenuFlyoutItem { Text = "Slet tom sektion" };
                    var id = loc.Id;
                    del.Click += (_, _) => _model.DeleteSection(id);
                    menu.Items.Add(del);
                    badge.ContextFlyout = menu;
                }
                names.Children.Add(badge);
            }
            Grid.SetColumn(names, 1);
            g.Children.Add(names);
            int s = shelf;
            var addSec = Ui.Btn("Sektion", (_, _) => _model.AddSection(s), "");
            Grid.SetColumn(addSec, 2);
            g.Children.Add(addSec);
            structure.Add(g);
        }
        structure.Add(Ui.Btn(_model.Medium == Medium.Vinyl ? "Ny reol" : "Ny cd-reol", (_, _) => _model.AddSection((shelves.Count == 0 ? 0 : shelves.Max()) + 1), ""));
        p.Children.Add(Group(structure.ToArray()));

        var labels = Ui.Btn("Udskriv reolskilte med QR-kode… (Ctrl+P)", async (_, _) => await Safe(() => LabelsPrint.ExportAsync(_model)), "");
        labels.IsEnabled = lib.Locations.Count > 0;
        p.Children.Add(Group(labels, Footer("Ét skilt pr. sektion med første og sidste kunstner. Skiltene åbnes i browseren, hvor de kan udskrives.")));

        var redo = Ui.Btn("Opdel samlingen forfra…", (_, _) => _model.ForceOnboarding = true);
        p.Children.Add(Group(redo, Footer("Åbner opdelingen igen. Intet ændres, før du bekræfter “Opret reol”.")));
    }

    // MARK: Sikkerhedskopi

    private void Backup(StackPanel p)
    {
        bool oneDrive = DatabaseBackup.IsInOneDrive(_model.BackupFolder);
        var rows = new List<UIElement>
        {
            Row("Seneste kopi", _model.LastBackup is DateTimeOffset d ? d.ToLocalTime().ToString("d. MMMM yyyy", System.Globalization.CultureInfo.GetCultureInfo("da-DK")) : "Ingen endnu"),
            Row("Gemmes i", oneDrive ? "OneDrive › Dokumenter › Vinyl Shelf Finder backup" : "Dokumenter › Vinyl Shelf Finder backup"),
        };
        if (_model.BackupError is string err) rows.Add(Ui.Label(Ui.Glyph.Warning, err, color: Ui.Secondary));
        var now = Ui.Btn("Tag en kopi nu", (_, _) => _model.BackupNow());
        now.IsEnabled = !_model.IsDemo;
        var show = Ui.Btn("Vis i Stifinder", async (_, _) =>
        {
            try
            {
                Directory.CreateDirectory(_model.BackupFolder);
                await Windows.System.Launcher.LaunchFolderPathAsync(_model.BackupFolder);
            }
            catch (Exception ex) { _model.ErrorMessage = ex.Message; }
        });
        rows.Add(Ui.HStack(8, now, show));
        rows.Add(Footer($"Appen gemmer selv en kopi af reolen, placeringer, historik og lyttelog én gang om dagen og beholder de seneste {DatabaseBackup.Keep}."));
        p.Children.Add(Group(rows.ToArray()));

        // Eksport: hele systemet i én fil, som kan importeres igen.
        var export = Ui.Btn("Eksportér…", async (b, _) => await Safe(() => ExportAsync((FrameworkElement)b)), "");
        p.Children.Add(Group(Ui.Text("Eksportér", "BodyStrongTextBlockStyle"), export,
            Footer("Gemmer hele dit system i én fil: plader og cd'er, reoler, sektioner, placeringer, flueben, historik, lyttelog og indstillinger. Discogs-tokenet kommer ikke med.")));

        // Import: tilbage til et gemt system.
        var import = Ui.Btn("Importér…", async (b, _) => await Safe(() => ImportAsync((FrameworkElement)b)), "");
        p.Children.Add(Group(Ui.Text("Importér", "BodyStrongTextBlockStyle"), import,
            Footer("Henter et system fra en eksport eller en af de daglige sikkerhedskopier. Det nuværende system gemmes først som en kopi, og appen åbner igen.")));

        // Nulstil: start helt forfra.
        var reset = Ui.Btn("Nulstil appen…", async (b, _) => await Safe(() => ResetAsync((FrameworkElement)b)), "");
        p.Children.Add(Group(Ui.Text("Start helt forfra", "BodyStrongTextBlockStyle"), reset,
            Footer("Sletter reoler, placeringer, historik og lyttelog, så appen starter forfra. Det nuværende system gemmes først som en kopi, som kan importeres igen.")));
    }

    /// <summary>
    /// En fejl i en async-knap (fx en fil-dialog, eller en anden dialog, der allerede er åben)
    /// må aldrig lukke appen: den vises i fejlbjælken i stedet.
    /// </summary>
    private async Task Safe(Func<Task> action)
    {
        try { await action(); }
        catch (Exception ex)
        {
            _model.CancelPendingChange();
            _model.ErrorMessage = ex is System.Runtime.InteropServices.COMException
                ? "Dialogen kunne ikke åbnes, fordi en anden dialog er åben. Prøv igen."
                : AppModel.Describe(ex);
        }
    }

    private static void InitPicker(object picker) => WinRT.Interop.InitializeWithWindow.Initialize(picker, MainWindow.Hwnd);

    private async Task ExportAsync(FrameworkElement anchor)
    {
        var picker = new Windows.Storage.Pickers.FileSavePicker
        {
            SuggestedStartLocation = Windows.Storage.Pickers.PickerLocationId.DocumentsLibrary,
            SuggestedFileName = Path.GetFileNameWithoutExtension(DataTransfer.ExportFileName(DateTimeOffset.Now)),
        };
        picker.FileTypeChoices.Add("Vinyl Shelf Finder-eksport", new List<string> { DataTransfer.Extension });
        InitPicker(picker);
        var file = await picker.PickSaveFileAsync();
        if (file is null) return;
        if (_model.ExportTo(file.Path))
            await Info(anchor, "Eksporteret", $"Dit system er gemt i:\n{file.Path}\n\nGem filen et sikkert sted. Den kan importeres igen under Indstillinger › Sikkerhedskopi og data.");
    }

    private async Task ImportAsync(FrameworkElement anchor)
    {
        var picker = new Windows.Storage.Pickers.FileOpenPicker { SuggestedStartLocation = Windows.Storage.Pickers.PickerLocationId.DocumentsLibrary };
        picker.FileTypeFilter.Add(DataTransfer.Extension);
        InitPicker(picker);
        var file = await picker.PickSingleFileAsync();
        if (file is null) return;
        if (_model.PrepareImport(file.Path) is not ImportSummary s) return;
        var d = new ContentDialog
        {
            XamlRoot = anchor.XamlRoot,
            Title = "Importér dette system?",
            Content = Ui.VStack(10,
                Ui.Text($"{file.Name} indeholder {Count(s.Vinyl, "plade", "plader")} og {Count(s.Cds, "cd", "cd'er")} fordelt på {Count(s.Sections, "sektion", "sektioner")}."),
                Ui.Text("Det nuværende system erstattes. Det gemmes først som en kopi i mappen med sikkerhedskopier, så du kan komme tilbage til det. Appen lukker og åbner igen.", color: Ui.Secondary)),
            PrimaryButtonText = "Importér og åbn igen",
            CloseButtonText = "Annullér",
            DefaultButton = ContentDialogButton.Close,
        };
        if (await d.ShowAsync() == ContentDialogResult.Primary) _model.ApplyAndRestart(reset: false, removeToken: false);
        else _model.CancelPendingChange();
    }

    private async Task ResetAsync(FrameworkElement anchor)
    {
        var token = new CheckBox { Content = "Fjern også forbindelsen til Discogs (tokenet)", IsChecked = false, IsEnabled = !_model.IsDemo && _model.HasToken };
        var d = new ContentDialog
        {
            XamlRoot = anchor.XamlRoot,
            Title = "Start helt forfra?",
            Content = Ui.VStack(12,
                Ui.Text("Alle reoler, sektioner, placeringer, flueben, historik og lyttelog slettes for både plader og cd'er. Bagefter henter appen samlingen fra Discogs igen, og du laver reolerne forfra."),
                Ui.Text("Det nuværende system gemmes først som en kopi i mappen med sikkerhedskopier, så du kan importere det igen. Appen lukker og åbner igen.", color: Ui.Secondary),
                token),
            PrimaryButtonText = "Nulstil og åbn igen",
            CloseButtonText = "Annullér",
            DefaultButton = ContentDialogButton.Close,
        };
        if (await d.ShowAsync() == ContentDialogResult.Primary) _model.ApplyAndRestart(reset: true, removeToken: token.IsChecked == true);
    }

    private static string Count(int n, string one, string many) => n == 1 ? $"1 {one}" : $"{n} {many}";

    private static async Task Info(FrameworkElement anchor, string title, string text)
    {
        var d = new ContentDialog { XamlRoot = anchor.XamlRoot, Title = title, Content = Ui.Text(text), CloseButtonText = "OK" };
        await d.ShowAsync();
    }

    // MARK: Opdatering

    private void Update(StackPanel p)
    {
        var rows = new List<UIElement> { Row("Denne version", _updater.CurrentVersion) };
        if (_updater.LastChecked is DateTimeOffset d) rows.Add(Row("Sidst tjekket", DanishDate.DateTime(d)));
        switch (_updater.State)
        {
            case Updater.Phase.Checking:
                rows.Add(Ui.Text("Tjekker GitHub …", color: Ui.Secondary));
                break;
            case Updater.Phase.UpToDate:
                rows.Add(Ui.Label(Ui.Glyph.Check, "Du har den nyeste version.", color: Ui.Secondary));
                break;
            case Updater.Phase.Available when _updater.Release is UpdateRelease r:
                rows.Add(Row("Ny version", r.Version.ToString()));
                if (r.Notes.Length > 0) rows.Add(Ui.Text(r.Notes.Length > 600 ? r.Notes[..600] : r.Notes, color: Ui.Secondary));
                rows.Add(Ui.Btn("Opdatér nu", (_, _) => _ = _updater.InstallAsync(r), accent: true));
                break;
            case Updater.Phase.Downloading:
                rows.Add(Ui.Text("Henter den nye version …", color: Ui.Secondary));
                break;
            case Updater.Phase.Installing:
                rows.Add(Ui.Text("Installerer og åbner igen …", color: Ui.Secondary));
                break;
            case Updater.Phase.Failed:
                rows.Add(Ui.Label(Ui.Glyph.Warning, _updater.Message ?? "", color: Ui.Secondary));
                break;
        }
        var check = Ui.Btn("Søg efter opdatering", (_, _) => _ = _updater.CheckAsync());
        check.IsEnabled = _updater.Enabled && _updater.State is not (Updater.Phase.Checking or Updater.Phase.Downloading or Updater.Phase.Installing);
        rows.Add(check);
        rows.Add(Footer(_updater.Enabled
            ? "Appen tjekker selv én gang om dagen og spørger, før den opdaterer. Nye versioner hentes fra projektets side på GitHub."
            : "Opdatering er slået fra i demo-tilstand."));
        p.Children.Add(Group(rows.ToArray()));
    }
}
