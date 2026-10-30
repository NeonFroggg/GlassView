// Regenerates Resources/AppIcon.icns:  swift scripts/make-icon.swift && iconutil -c icns build-icon/GlassView.iconset -o Resources/AppIcon.icns
import AppKit

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    let s = CGFloat(px)
    let inset = s * 0.098
    let tile = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let w = tile.width
    let tilePath = NSBezierPath(roundedRect: tile, xRadius: w * 0.2237, yRadius: w * 0.2237)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.025,
                  color: NSColor.black.withAlphaComponent(0.35).cgColor)
    NSColor.black.setFill()
    tilePath.fill()
    ctx.restoreGState()

    ctx.saveGState()
    tilePath.addClip()
    NSGradient(colors: [NSColor(red: 0.10, green: 0.62, blue: 0.86, alpha: 1),
                        NSColor(red: 0.36, green: 0.22, blue: 0.78, alpha: 1)])!.draw(in: tile, angle: -60)

    // Back window: the app being looked through.
    let back = NSRect(x: tile.minX + 0.12 * w, y: tile.minY + 0.38 * w, width: 0.52 * w, height: 0.44 * w)
    let backPath = NSBezierPath(roundedRect: back, xRadius: 0.05 * w, yRadius: 0.05 * w)
    NSColor.white.withAlphaComponent(0.95).setFill()
    backPath.fill()
    NSColor(white: 0.78, alpha: 1).setFill()
    for i in 0..<3 {
        let lw = back.width * (i == 2 ? 0.45 : 0.72)
        NSBezierPath(roundedRect: NSRect(x: back.minX + 0.05 * w, y: back.maxY - 0.13 * w - CGFloat(i) * 0.07 * w,
                                         width: lw, height: 0.035 * w), xRadius: 0.0175 * w, yRadius: 0.0175 * w).fill()
    }

    // Front window: the see-through glass pane.
    let front = NSRect(x: tile.minX + 0.30 * w, y: tile.minY + 0.17 * w, width: 0.58 * w, height: 0.46 * w)
    let frontPath = NSBezierPath(roundedRect: front, xRadius: 0.06 * w, yRadius: 0.06 * w)
    NSColor.white.withAlphaComponent(0.26).setFill()
    frontPath.fill()
    NSGradient(colors: [NSColor.white.withAlphaComponent(0.35), NSColor.white.withAlphaComponent(0.0)])!
        .draw(in: frontPath, angle: -70)
    NSColor.white.withAlphaComponent(0.85).setStroke()
    frontPath.lineWidth = 0.014 * w
    frontPath.stroke()
    NSColor.white.withAlphaComponent(0.9).setFill()
    for i in 0..<3 {
        let d = 0.03 * w
        NSBezierPath(ovalIn: NSRect(x: front.minX + 0.04 * w + CGFloat(i) * 0.05 * w,
                                    y: front.maxY - 0.07 * w, width: d, height: d)).fill()
    }
    ctx.restoreGState()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let dir = "build-icon/GlassView.iconset"
try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
let sizes: [(String, Int)] = [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64),
                              ("128x128", 128), ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512),
                              ("512x512", 512), ("512x512@2x", 1024)]
for (name, px) in sizes {
    try! render(px).write(to: URL(fileURLWithPath: "\(dir)/icon_\(name).png"))
}
print("wrote \(dir)")
