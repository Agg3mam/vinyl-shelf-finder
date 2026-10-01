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

struct ShelfLabelView: View {
    let label: ShelfLabel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("REOL \(label.location.shelf)")
                        .font(.system(size: 11, weight: .bold)).tracking(2).foregroundColor(.gray)
                    Text("SEKTION \(label.location.section)")
                        .font(.system(size: 24, weight: .heavy)).foregroundColor(.black)
                }
                Spacer()
                if let qr = LabelsPDF.qrCode(label.scanCode) {
                    Image(decorative: qr, scale: 1)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: 62, height: 62)
                }
            }
            Spacer(minLength: 6)
            if let first = label.firstArtist, let last = label.lastArtist {
                // Lange navne skaleres lidt ned, før de afkortes med "…".
                Text(first).font(.system(size: 15, weight: .semibold)).foregroundColor(.black)
                    .lineLimit(1).minimumScaleFactor(0.7)
                Text("→ \(last)").font(.system(size: 15)).foregroundColor(.black)
                    .lineLimit(1).minimumScaleFactor(0.7)
            } else {
                Text("(tom sektion)").font(.system(size: 15)).foregroundColor(.gray)
            }
            // Kernens tal: plader, der står i reolen nu (`Library.onShelfCount`).
            Text(pladerText(label.count)).font(.system(size: 9)).foregroundColor(.gray).padding(.top, 3)
        }
        .padding(14)
        .frame(width: 252, height: 170, alignment: .topLeading)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.gray.opacity(0.6), style: StrokeStyle(lineWidth: 0.75, dash: [4, 3]))
        )
    }
}
