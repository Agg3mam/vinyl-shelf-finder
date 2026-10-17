using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Navigation;

namespace VinylShelfFinder.Pages;

/// <summary>Midlertidig side til skærme, der ikke er lavet endnu. Titlen kommer som navigationsparameter.</summary>
public sealed partial class PlaceholderPage : Page
{
    public PlaceholderPage() => InitializeComponent();

    protected override void OnNavigatedTo(NavigationEventArgs e)
    {
        base.OnNavigatedTo(e);
        if (e.Parameter is string title && title.Length > 0) TitleText.Text = title;
    }
}
