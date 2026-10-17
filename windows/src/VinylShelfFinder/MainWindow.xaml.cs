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

    public MainWindow()
    {
        InitializeComponent();
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
