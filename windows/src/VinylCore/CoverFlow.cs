namespace VinylShelfFinder.Core;

// Port af Sources/VinylCore/CoverFlow.swift.

/// Placering af covers i Cover Flow (som på en iPod classic). Ren matematik, så den kan tjekkes.
/// `o` er afstanden fra midten i antal plader: 0 = coveret i midten, -1 = lige til venstre osv.
/// `o` må gerne være et kommatal (under en trackpad-bevægelse glider coverne mellem pladserne).
public static class CoverFlowGeometry
{
    /// Så mange covers vises på hver side af midten.
    public const int Visible = 6;
    /// Hvor skråt sidecoverne står (grader om den lodrette akse).
    public const double Tilt = 65.0;
    /// Perspektiv til 3D-drejningen (svagt, så sidecoverne ikke forvrænges).
    public const double Perspective = 0.4;
    /// Sidecovers' størrelse i forhold til midtercoveret.
    public const double SideScale = 0.9;
    /// Spejlingen under coveret: højde (andel af coveret) og synlighed ved kanten.
    public const double ReflectionHeight = 0.28;
    public const double ReflectionOpacity = 0.25;
    /// Afstand fra midten til første sidecover og mellem de næste (i forhold til coverets side).
    internal const double FirstGap = 0.62;
    internal const double StackGap = 0.25;

    /// Coverets side ud fra den plads, der er. Der skal være plads til spejlingen under coveret,
    /// og det bliver aldrig over 360.
    public static double Side(double width, double height) => Math.Max(80, Math.Min(Math.Min(height * 0.62, width * 0.36), 360));

    private static double Clamped(double o) => Math.Min(Math.Max(o, -1), 1);

    /// Vandret forskydning fra midten.
    public static double X(double o, double side)
    {
        var c = Clamped(o);
        return side * (FirstGap * c + StackGap * (o - c));
    }

    /// Drejning: midten vender lige frem; siderne vender ind mod midten, så deres yderkant er
    /// nærmest (som væggene i en gang). Negativ vinkel til højre for midten (som på Mac).
    /// Bemærk: WinUI's PlaneProjection.RotationY drejer modsat vej af SwiftUI – vend fortegnet i UI'et om nødvendigt.
    public static double Angle(double o) => -Tilt * Clamped(o);

    public static double Scale(double o) => 1 - (1 - SideScale) * Math.Abs(Clamped(o));

    /// Covers tættest på midten ligger øverst.
    public static double ZIndex(double o) => -Math.Abs(o);

    /// De plader (indeks), der skal tegnes omkring `center`: [Start, End).
    public static (int Start, int End) VisibleRange(int center, int count)
    {
        if (count <= 0) return (0, 0);
        int c = Math.Min(Math.Max(center, 0), count - 1);
        return (Math.Max(0, c - Visible), Math.Min(count, c + Visible + 1));
    }

    /// Glid under en trackpad- eller musebevægelse. `shift` er, hvor langt rækken er skubbet
    /// (i plader, positiv = mod næste plade). Når den passerer en halv plade, skifter midten,
    /// og `shift` rykkes tilsvarende, så intet hopper. I enderne kan man kun skubbe lidt (gummibånd).
    public static (int Center, double Shift) Glide(int center, double shift, int count)
    {
        if (count <= 0) return (0, 0);
        int c = Math.Min(Math.Max(center, 0), count - 1);
        double s = shift;
        while (s > 0.5 && c < count - 1) { s -= 1; c += 1; }
        while (s < -0.5 && c > 0) { s += 1; c -= 1; }
        if (c == 0) s = Math.Max(s, -0.3);
        if (c == count - 1) s = Math.Min(s, 0.3);
        return (c, s);
    }
}

/// Lægger rullebevægelser sammen til hele trin (én plade pr. trin).
/// Præcisionstouchpad giver mange små, præcise bevægelser; et musehjul giver få, grove hak.
public sealed class ScrollStepper
{
    /// Punkter pr. plade på touchpad.
    public double PreciseStep { get; set; } = 28.0;
    /// Hak pr. plade på musehjul (på Windows er ét hak typisk delta 120: kald Add(delta / 120.0, false)).
    public double WheelStep { get; set; } = 1.0;
    private double _accumulated;

    /// Lægger `delta` til og returnerer antal hele trin (negativt = mod venstre).
    public int Add(double delta, bool precise)
    {
        var step = precise ? PreciseStep : WheelStep;
        _accumulated += delta;
        int steps = (int)(_accumulated / step);
        _accumulated -= steps * step;
        return steps;
    }

    public void Reset() => _accumulated = 0;
}
