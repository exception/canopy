// Renders Canopy's app icon set: swift scripts/tools/icon.swift <AppIcon.appiconset>
import AppKit
let out = CommandLine.arguments[1]
func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let inset = s * 0.1, r = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let path = NSBezierPath(roundedRect: r, xRadius: r.width * 0.225, yRadius: r.width * 0.225)
    let sh = NSShadow(); sh.shadowBlurRadius = s * 0.025; sh.shadowOffset = NSSize(width: 0, height: -s * 0.01); sh.shadowColor = .black.withAlphaComponent(0.35); sh.set()
    NSGradient(colors: [NSColor(srgbRed: 0.13, green: 0.14, blue: 0.16, alpha: 1), NSColor(srgbRed: 0.05, green: 0.055, blue: 0.065, alpha: 1)])!.draw(in: path, angle: -90)
    NSShadow().set()
    // soft glow
    let glow = NSGradient(colors: [NSColor(srgbRed: 0.24, green: 0.84, blue: 0.55, alpha: 0.28), .clear])!
    path.addClip()
    glow.draw(fromCenter: NSPoint(x: r.midX, y: r.midY - s * 0.05), radius: 0, toCenter: NSPoint(x: r.midX, y: r.midY), radius: r.width * 0.55, options: [])
    let cfg = NSImage.SymbolConfiguration(pointSize: s * 0.44, weight: .semibold).applying(.init(paletteColors: [NSColor(srgbRed: 0.33, green: 0.89, blue: 0.62, alpha: 1)]))
    if let leaf = NSImage(systemSymbolName: "leaf.fill", accessibilityDescription: nil)?.withSymbolConfiguration(cfg) {
        let sz = leaf.size
        leaf.draw(in: NSRect(x: r.midX - sz.width / 2, y: r.midY - sz.height / 2, width: sz.width, height: sz.height))
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}
var images: [[String: String]] = []
for (pt, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
    let name = "icon_\(pt)x\(pt)\(scale == 2 ? "@2x" : "").png"
    try! render(pt * scale).write(to: URL(fileURLWithPath: "\(out)/\(name)"))
    images.append(["idiom": "mac", "scale": "\(scale)x", "size": "\(pt)x\(pt)", "filename": name])
}
let json = try! JSONSerialization.data(withJSONObject: ["images": images, "info": ["version": 1, "author": "xcode"]], options: .prettyPrinted)
try! json.write(to: URL(fileURLWithPath: "\(out)/Contents.json"))
