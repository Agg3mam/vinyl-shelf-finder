import SwiftUI
import AppKit
import CoreImage
import VinylCore

/// Laver en printbar A4-PDF med ét skilt pr. sektion (8 pr. side) inkl. QR-kode.
@MainActor
enum LabelsPDF {
    static let page = CGSize(width: 595, height: 842)     // A4 i punkter
    static let perPage = 8

    static func write(_ labels: [ShelfLabel], to url: URL) throws {
        var box = CGRect(origin: .zero, size: page)
        guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else {
            throw NSError(domain: "LabelsPDF", code: 1, userInfo: [NSLocalizedDescriptionKey: "Kunne ikke oprette PDF-filen."])
        }
        let pages = stride(from: 0, to: labels.count, by: perPage).map { Array(labels[$0..<min($0 + perPage, labels.count)]) }
        for p in pages {
            let renderer = ImageRenderer(content: LabelPage(labels: p).environment(\.colorScheme, .light))
            renderer.proposedSize = ProposedViewSize(page)
            renderer.render { _, draw in
                ctx.beginPDFPage(nil)
                draw(ctx)
                ctx.endPDFPage()
            }
        }
        ctx.closePDF()
    }

    static func qrCode(_ text: String) -> CGImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let out = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)) else { return nil }
        return CIContext().createCGImage(out, from: out.extent)
    }
}

private struct LabelPage: View {
    let labels: [ShelfLabel]

    var body: some View {
        let columns = [GridItem(.fixed(252), spacing: 14), GridItem(.fixed(252), spacing: 14)]
        LazyVGrid(columns: columns, spacing: 14) {
            ForEach(labels) { ShelfLabelView(label: $0) }
        }
        .padding(.top, 40)
        .frame(width: LabelsPDF.page.width, height: LabelsPDF.page.height, alignment: .top)
        .background(Color.white)
    }
}

/// Skiltet er et skillekort: sektionsbogstavet på en fane i kategoriens farve (sort for de almindelige reoler),
/// reolens navn og QR-kode ved siden af, og fra–til-kunstnerne nederst.
struct ShelfLabelView: View {
    let label: ShelfLabel

    var body: some View {
        let loc = label.location
        let ink = loc.category.map { Color(nsColor: NSColor(hex: $0.colorHex.light)) } ?? .black
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .bottom, spacing: 10) {
                Text(loc.section)
                    .font(.system(size: 40, weight: .bold).width(.condensed))
                    .foregroundColor(.white)
                    .padding(.horizontal, 12).padding(.top, 2)
                    .frame(minWidth: 46)
                    .background(ink, in: UnevenRoundedRectangle(topLeadingRadius: 6, topTrailingRadius: 6))
                VStack(alignment: .leading, spacing: 0) {
                    Text("\(loc.kind.shelfWord) \(loc.shelf)").font(.system(size: 17, weight: .semibold).width(.condensed))
                    Text("Sektion \(loc.section)").font(.system(size: 11)).foregroundColor(.gray)
                }
                .foregroundColor(.black)
                .padding(.bottom, 3)
                Spacer()
                if let qr = LabelsPDF.qrCode(label.scanCode) {
                    Image(decorative: qr, scale: 1)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: 58, height: 58)
                }
            }
            Rectangle().fill(ink).frame(height: 3)
            Spacer(minLength: 6)
            if let first = label.firstArtist, let last = label.lastArtist {
                // Lange navne skaleres lidt ned, før de afkortes med "…".
                Text("Fra \(first)").font(.system(size: 14, weight: .semibold)).foregroundColor(.black)
                    .lineLimit(1).minimumScaleFactor(0.7)
                Text("Til \(last)").font(.system(size: 14)).foregroundColor(.black)
                    .lineLimit(1).minimumScaleFactor(0.7)
            } else {
                Text("Tom sektion").font(.system(size: 14)).foregroundColor(.gray)
            }
            // Kernens tal: plader, der står i reolen nu (`Library.onShelfCount`).
            Text(label.count == 1 ? "1 \(loc.kind.singular)" : "\(label.count) \(loc.kind.plural)").font(.system(size: 9)).foregroundColor(.gray).padding(.top, 3)
        }
        .padding(14)
        .frame(width: 252, height: 170, alignment: .topLeading)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.gray.opacity(0.6), style: StrokeStyle(lineWidth: 0.75, dash: [4, 3]))
        )
    }
}
