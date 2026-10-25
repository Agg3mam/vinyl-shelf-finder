using System.Net;
using System.Text;
using QRCoder;
using VinylShelfFinder.Core;

namespace VinylShelfFinder;

/// <summary>
/// Reolskilte (LabelsPDF.swift på Mac): ét skilt pr. sektion med QR-kode, første og sidste kunstner.
/// På Windows laves en HTML-side i A4 (8 skilte pr. side), som åbnes i browseren og udskrives derfra.
/// </summary>
public static class LabelsPrint
{
    public static string Html(IReadOnlyList<ShelfLabel> labels)
    {
        static string E(string s) => WebUtility.HtmlEncode(s);
        var sb = new StringBuilder();
        sb.Append("""
            <!doctype html><html lang="da"><head><meta charset="utf-8"><title>Reolskilte</title>
            <style>
            @page { size: A4; margin: 14mm; }
            body { font-family: "Segoe UI", system-ui, sans-serif; color: #000; margin: 0; }
            .hint { font-size: 13px; color: #555; margin: 0 0 12px; }
            @media print { .hint { display: none; } }
            .grid { display: grid; grid-template-columns: 89mm 89mm; gap: 5mm; }
            .label { box-sizing: border-box; width: 89mm; height: 60mm; padding: 5mm; border: 0.3mm solid #ccc; border-radius: 3mm;
                     display: flex; flex-direction: column; break-inside: avoid; }
            .top { display: flex; align-items: flex-end; gap: 3mm; border-bottom: 1mm solid var(--c); padding-bottom: 0; }
            .tab { background: var(--c); color: #fff; font-family: Bahnschrift, "Segoe UI", sans-serif; font-stretch: condensed;
                   font-weight: 700; font-size: 40px; line-height: 1; padding: 1mm 4mm 0; min-width: 9mm; text-align: center;
                   border-radius: 2mm 2mm 0 0; }
            .shelf { font-family: Bahnschrift, "Segoe UI", sans-serif; font-stretch: condensed; font-size: 17px; font-weight: 600; }
            .section { font-size: 11px; color: #777; margin-bottom: 1mm; }
            .qr { margin-left: auto; margin-bottom: 1mm; }
            .qr svg { width: 20mm; height: 20mm; display: block; }
            .names { margin-top: auto; font-size: 15px; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
            .first { font-weight: 600; }
            .count { font-size: 9px; color: #777; margin-top: 3px; }
            .empty { margin-top: auto; font-size: 15px; color: #777; }
            </style></head><body>
            <p class="hint">Udskriv med Ctrl+P. Vælg A4 og 100 % (ingen tilpasning).</p>
            <div class="grid">
            """);
        using var gen = new QRCodeGenerator();
        foreach (var l in labels)
        {
            using var data = gen.CreateQrCode(l.ScanCode, QRCodeGenerator.ECCLevel.M);
            var svg = new SvgQRCode(data).GetGraphic(4);
            // Skiltet er et skillekort (som på Mac): bogstavet på en fane i kategoriens farve, sort for de almindelige reoler.
            var color = l.Location.Category is Category c ? $"#{c.ColorHex().Light:X6}" : "#000000";
            sb.Append($"<div class=\"label\" style=\"--c:{color}\"><div class=\"top\">");
            sb.Append($"<div class=\"tab\">{E(l.Location.Section)}</div><div>");
            sb.Append($"<div class=\"shelf\">{E(l.Location.Kind.ShelfWord)} {l.Location.Shelf}</div>");
            sb.Append($"<div class=\"section\">Sektion {E(l.Location.Section)}</div></div>");
            sb.Append($"<div class=\"qr\">{svg}</div></div>");
            if (l.FirstArtist is string first && l.LastArtist is string last)
            {
                sb.Append($"<div class=\"names first\">Fra {E(first)}</div>");
                sb.Append($"<div class=\"names\" style=\"margin-top:0\">Til {E(last)}</div>");
            }
            else sb.Append("<div class=\"empty\">Tom sektion</div>");
            var word = l.Location.Medium == Medium.Cd ? (l.Count == 1 ? "cd" : "cd'er") : (l.Count == 1 ? "plade" : "plader");
            sb.Append($"<div class=\"count\">{l.Count} {word}</div></div>");
        }
        sb.Append("</div></body></html>");
        return sb.ToString();
    }

    /// <summary>Gemmer skiltene som HTML i en midlertidig mappe og åbner dem i browseren.</summary>
    public static async Task ExportAsync(AppModel model)
    {
        try
        {
            var labels = ShelfLabel.Labels(model.Library);
            var dir = Path.Combine(Path.GetTempPath(), "VinylShelfFinder");
            Directory.CreateDirectory(dir);
            var path = Path.Combine(dir, "Reolskilte.html");
            await File.WriteAllTextAsync(path, Html(labels), Encoding.UTF8);
            // Koden på skiltet gemmes på sektionen (som på Mac), så skiltet også virker på telefonen via kontoen.
            foreach (var l in labels) model.Store.SetScanCode(l.Location.Id, l.ScanCode);
            model.Reload();
            await Windows.System.Launcher.LaunchUriAsync(new Uri(path));
        }
        catch (Exception ex)
        {
            model.ErrorMessage = "Reolskiltene kunne ikke laves: " + ex.Message;
        }
    }
}
