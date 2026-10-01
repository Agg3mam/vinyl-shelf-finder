import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}
let cream = rgb(0xF3EBDD), mint = rgb(0x6FD6C6), tealTop = rgb(0x22675F), tealBot = rgb(0x143F3A)
let vinyl = rgb(0x17191A)

func save(_ ctx: CGContext, _ name: String) {
    let img = ctx.makeImage()!
    let d = CGImageDestinationCreateWithURL(URL(fileURLWithPath: name) as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(d, img, nil); CGImageDestinationFinalize(d)
}

/// macOS-ikongitter: 1024-lærred, krop 824×824 med ~185 hjørneradius og en blød skygge.
func canvas(_ draw: (CGContext, CGRect) -> Void) -> CGContext {
    let s = 1024
    let ctx = CGContext(data: nil, width: s, height: s, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let path = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: rgb(0x000000, 0.28))
    ctx.addPath(path); ctx.setFillColor(tealBot); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(path); ctx.clip()
    let g = CGGradient(colorsSpace: nil, colors: [tealTop, tealBot] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(g, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    draw(ctx, body)
    ctx.restoreGState()
    // Fin lys kant øverst (glas-agtig, diskret).
    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: body.insetBy(dx: 1.5, dy: 1.5), cornerWidth: 184, cornerHeight: 184, transform: nil))
    ctx.setStrokeColor(rgb(0xFFFFFF, 0.10)); ctx.setLineWidth(3); ctx.strokePath()
    ctx.restoreGState()
    return ctx
}

func spine(_ ctx: CGContext, x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat, color: CGColor) {
    ctx.addPath(CGPath(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerWidth: w * 0.28, cornerHeight: w * 0.28, transform: nil))
    ctx.setFillColor(color); ctx.fillPath()
}

func disc(_ ctx: CGContext, c: CGPoint, r: CGFloat, label: CGColor) {
    ctx.setFillColor(vinyl); ctx.fillEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
    ctx.setStrokeColor(rgb(0xFFFFFF, 0.07)); ctx.setLineWidth(r * 0.012)
    for f in stride(from: 0.48, through: 0.94, by: 0.075) {
        let rr = r * CGFloat(f); ctx.strokeEllipse(in: CGRect(x: c.x - rr, y: c.y - rr, width: 2 * rr, height: 2 * rr))
    }
    // Lysrefleks (én blød bue).
    ctx.saveGState()
    ctx.addArc(center: c, radius: r * 0.8, startAngle: .pi * 0.62, endAngle: .pi * 0.88, clockwise: false)
    ctx.setStrokeColor(rgb(0xFFFFFF, 0.16)); ctx.setLineWidth(r * 0.05); ctx.setLineCap(.round); ctx.strokePath()
    ctx.restoreGState()
    let lr = r * 0.34
    ctx.setFillColor(label); ctx.fillEllipse(in: CGRect(x: c.x - lr, y: c.y - lr, width: 2 * lr, height: 2 * lr))
    let hr = r * 0.035
    ctx.setFillColor(vinyl); ctx.fillEllipse(in: CGRect(x: c.x - hr, y: c.y - hr, width: 2 * hr, height: 2 * hr))
}

// A: Hylden – pladerygge, én trukket op i mint.
save(canvas { ctx, b in
    let n = 7, w: CGFloat = 54, gap: CGFloat = 26
    let total = CGFloat(n) * w + CGFloat(n - 1) * gap
    let x0 = b.midX - total / 2, base: CGFloat = 300, h: CGFloat = 360
    for i in 0..<n {
        let x = x0 + CGFloat(i) * (w + gap)
        if i == 4 { spine(ctx, x: x, y: base + 90, w: w, h: h, color: mint) }
        else { spine(ctx, x: x, y: base, w: w, h: h, color: cream) }
    }
    ctx.setFillColor(rgb(0xF3EBDD, 0.55)); ctx.fill(CGRect(x: x0 - 30, y: base - 26, width: total + 60, height: 10))
}, "A-hylden.png")

// B: Pladen – vinyl med mint etiket.
save(canvas { ctx, b in
    disc(ctx, c: CGPoint(x: b.midX, y: b.midY), r: 300, label: mint)
}, "B-pladen.png")

// C: Pladen i reolen – en plade trukket halvt op mellem ryggene.
save(canvas { ctx, b in
    let base: CGFloat = 250, h: CGFloat = 300, w: CGFloat = 50, gap: CGFloat = 22
    disc(ctx, c: CGPoint(x: b.midX, y: base + h + 30), r: 215, label: mint)
    let n = 8
    let total = CGFloat(n) * w + CGFloat(n - 1) * gap
    let x0 = b.midX - total / 2
    for i in 0..<n {
        spine(ctx, x: x0 + CGFloat(i) * (w + gap), y: base, w: w, h: h, color: cream)
    }
    ctx.setFillColor(rgb(0xF3EBDD, 0.55)); ctx.fill(CGRect(x: x0 - 30, y: base - 26, width: total + 60, height: 10))
}, "C-pladen-i-reolen.png")
// D: Pladen trækkes op af kassen.
save(canvas { ctx, b in
    disc(ctx, c: CGPoint(x: b.midX, y: 600), r: 235, label: mint)
    let crate = CGRect(x: 232, y: 222, width: 560, height: 300)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: 10), blur: 22, color: rgb(0x000000, 0.25))
    ctx.addPath(CGPath(roundedRect: crate, cornerWidth: 46, cornerHeight: 46, transform: nil))
    ctx.setFillColor(cream); ctx.fillPath()
    ctx.restoreGState()
    // Pladeryggene anes som fine riller i kassens forkant.
    ctx.setStrokeColor(rgb(0xD9CDB8)); ctx.setLineWidth(8); ctx.setLineCap(.round)
    for i in 1...6 {
        let x = crate.minX + crate.width * CGFloat(i) / 7
        ctx.move(to: CGPoint(x: x, y: crate.minY + 62)); ctx.addLine(to: CGPoint(x: x, y: crate.maxY - 62))
    }
    ctx.strokePath()
}, "D-pladekassen.png")
print("ok")
