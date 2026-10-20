using System.Runtime.InteropServices.WindowsRuntime;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media.Imaging;
using QRCoder;
using VinylShelfFinder.Core;
using VinylShelfFinder.UI;

namespace VinylShelfFinder.Views;

/// <summary>
/// Totrinslogin (SecondFactorViews.swift på Mac): guiden med tre trin – hvad det er, tilføj Vinyl Shelf i kode-appen
/// (QR-kode eller koden skrevet af), og skriv koden. Vises én gang efter login og fra Indstillinger › Konto.
/// </summary>
public static class SecondFactorDialog
{
    public static async Task ShowAsync(AppModel model, XamlRoot root)
    {
        int step = 0;
        TotpEnrollment? enrollment = null;
        BitmapImage? qr = null;
        string? error = null;
        var code = new TextBox { PlaceholderText = "123 456", FontSize = 28, TextAlignment = TextAlignment.Center, InputScope = new Microsoft.UI.Xaml.Input.InputScope { Names = { new Microsoft.UI.Xaml.Input.InputScopeName(Microsoft.UI.Xaml.Input.InputScopeNameValue.Number) } } };
        var body = new StackPanel { Spacing = 12, Width = 420 };
        var dialog = new ContentDialog
        {
            XamlRoot = root,
            Title = "Totrinslogin",
            Content = body,
            DefaultButton = ContentDialogButton.Primary,
        };

        void Build()
        {
            body.Children.Clear();
            switch (step)
            {
                case 0:
                    body.Children.Add(Ui.Text("Slå totrinslogin til", "SubtitleTextBlockStyle"));
                    body.Children.Add(Ui.Text("Så kan ingen komme ind på din konto med kun din adgangskode eller din mail. Når du logger ind på en ny enhed, skal du også skrive en kode fra din telefon.", color: Ui.Secondary));
                    var steps = new[] { "Find en kode-app på telefonen", "Tilføj Vinyl Shelf i appen", "Skriv de 6 tal, appen viser" };
                    for (int i = 0; i < steps.Length; i++) body.Children.Add(Ui.Text($"{i + 1}.  {steps[i]}"));
                    body.Children.Add(Ui.Text("På iPhone kan du bruge appen Adgangskoder, som allerede er der. På Android kan du hente Google Authenticator gratis.", "CaptionTextBlockStyle", Ui.Secondary));
                    dialog.PrimaryButtonText = "Kom i gang";
                    dialog.CloseButtonText = "Ikke nu";
                    break;
                case 1:
                    body.Children.Add(Ui.Text("Tilføj Vinyl Shelf i kode-appen", "SubtitleTextBlockStyle"));
                    body.Children.Add(Ui.Text("Åbn kameraet eller kode-appen på telefonen, og scan koden. Vælg at tilføje den som en kode.", color: Ui.Secondary));
                    if (enrollment is TotpEnrollment e)
                    {
                        body.Children.Add(new Border
                        {
                            Background = new Microsoft.UI.Xaml.Media.SolidColorBrush(Microsoft.UI.Colors.White),
                            Padding = new Thickness(10), CornerRadius = new CornerRadius(12), HorizontalAlignment = HorizontalAlignment.Center,
                            Child = new Image { Source = qr, Width = 180, Height = 180 },
                        });
                        body.Children.Add(Ui.Text("Kan du ikke scanne? Skriv denne kode i kode-appen:", "CaptionTextBlockStyle", Ui.Secondary));
                        var secret = Ui.Text(e.GroupedSecret, size: 18);
                        secret.FontFamily = new Microsoft.UI.Xaml.Media.FontFamily("Consolas");
                        secret.IsTextSelectionEnabled = true;
                        body.Children.Add(secret);
                    }
                    else body.Children.Add(new ProgressRing { IsActive = true, HorizontalAlignment = HorizontalAlignment.Center });
                    dialog.PrimaryButtonText = "Næste";
                    dialog.IsPrimaryButtonEnabled = enrollment is not null;
                    dialog.CloseButtonText = "Annullér";
                    break;
                case 2:
                    body.Children.Add(Ui.Text("Skriv koden", "SubtitleTextBlockStyle"));
                    body.Children.Add(Ui.Text("Skriv de 6 tal, som kode-appen viser ud for Vinyl Shelf. Tallene skifter hvert 30. sekund – det er helt normalt.", color: Ui.Secondary));
                    body.Children.Add(code);
                    dialog.PrimaryButtonText = "Slå til";
                    dialog.IsPrimaryButtonEnabled = true;
                    dialog.CloseButtonText = "Annullér";
                    break;
                default:
                    body.Children.Add(Ui.Text("Totrinslogin er slået til", "SubtitleTextBlockStyle"));
                    body.Children.Add(Ui.Text("Næste gang du logger ind på en ny enhed, skal du også skrive en kode fra kode-appen. Dine enheder, der allerede er logget ind, beder om koden én gang.", color: Ui.Secondary));
                    body.Children.Add(Ui.Text("Mister du telefonen, kan du slå totrinslogin fra på en computer, hvor du stadig er logget ind (Indstillinger › Konto).", "CaptionTextBlockStyle", Ui.Secondary));
                    dialog.PrimaryButtonText = "Færdig";
                    dialog.CloseButtonText = "";
                    break;
            }
            if (error is string msg) body.Children.Add(Ui.Label(Ui.Glyph.Warning, msg, color: Ui.Secondary));
        }

        dialog.PrimaryButtonClick += async (_, args) =>
        {
            if (step == 3) return; // Færdig lukker dialogen
            args.Cancel = true;
            var deferral = args.GetDeferral();
            error = null;
            try
            {
                if (step == 0)
                {
                    step = 1;
                    Build();
                    try
                    {
                        var e = await model.BeginSecondFactorAsync();
                        qr = await QrAsync(e.Uri);
                        enrollment = e;
                    }
                    catch (CloudException ex) { error = ex.Message; }
                }
                else if (step == 1) step = 2;
                else if (step == 2 && enrollment is TotpEnrollment e)
                {
                    dialog.IsPrimaryButtonEnabled = false;
                    error = await model.ConfirmSecondFactorAsync(e, code.Text);
                    if (error is null) step = 3;
                }
            }
            finally
            {
                Build();
                deferral.Complete();
            }
        };
        Build();
        await dialog.ShowAsync();
    }

    /// <summary>QR-koden til kode-appen som billede (QRCoder, som reolskiltene). Kun i hukommelsen.</summary>
    private static async Task<BitmapImage> QrAsync(string text)
    {
        byte[] png;
        using (var gen = new QRCodeGenerator())
        using (var data = gen.CreateQrCode(text, QRCodeGenerator.ECCLevel.M))
            png = new PngByteQRCode(data).GetGraphic(8);
        var image = new BitmapImage();
        using var stream = new Windows.Storage.Streams.InMemoryRandomAccessStream();
        await stream.WriteAsync(png.AsBuffer());
        stream.Seek(0);
        await image.SetSourceAsync(stream);
        return image;
    }
}
