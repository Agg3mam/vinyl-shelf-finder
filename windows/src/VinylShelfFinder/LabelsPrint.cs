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
            .top { display: flex; justify-content: space-between; align-items: flex-start; }
            .shelf { font-size: 11px; font-weight: 700; letter-spacing: 2px; color: #777; }
            .section { font-size: 24px; font-weight: 800; }
            .qr svg { width: 22mm; height: 22mm; display: block; }
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
            sb.Append("<div class=\"label\"><div class=\"top\"><div>");
            sb.Append($"<div class=\"shelf\">{E(l.Location.Medium.ShelfWord().ToUpperInvariant())} {l.Location.Shelf}</div>");
            sb.Append($"<div class=\"section\">SEKTION {E(l.Location.Section)}</div></div>");
            sb.Append($"<div class=\"qr\">{svg}</div></div>");
            if (l.FirstArtist is string first && l.LastArtist is string last)
            {
                sb.Append($"<div class=\"names first\">{E(first)}</div>");
                sb.Append($"<div class=\"names\" style=\"margin-top:0\">→ {E(last)}</div>");
            }
            else sb.Append("<div class=\"empty\">(tom sektion)</div>");
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
            await Windows.System.Launcher.LaunchUriAsync(new Uri(path));
        }
        catch (Exception ex)
        {
            model.ErrorMessage = "Reolskiltene kunne ikke laves: " + ex.Message;
        }
    }
}
