// dmg-background <out-dir>
// Draws the installer window background (660×400 pt) at 1x and 2x: a light canvas
// (Finder draws icon labels in black whatever the theme) with a soft canopy-green glow,
// faint leaf veins, a dashed arrow from the app to Applications, and a one-line hint.
import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
let W: CGFloat = 660, H: CGFloat = 400

func hex(_ v: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: a)
}

func render(scale: CGFloat) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W * scale), pixelsHigh: Int(H * scale),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: W, height: H)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    // Canvas and two soft green glows (bottom centre, top right).
    hex(0xEEF2EF).setFill()
    NSRect(x: 0, y: 0, width: W, height: H).fill()
    NSGradient(colors: [hex(0x3DD68C, 0.26), hex(0x3DD68C, 0)])!
        .draw(fromCenter: NSPoint(x: W * 0.5, y: -70), radius: 0, toCenter: NSPoint(x: W * 0.5, y: -70), radius: 430, options: [])
    NSGradient(colors: [hex(0x2AC3DE, 0.10), hex(0x2AC3DE, 0)])!
        .draw(fromCenter: NSPoint(x: W + 40, y: H + 40), radius: 0, toCenter: NSPoint(x: W + 40, y: H + 40), radius: 320, options: [])

    // Dot grid, fading out toward the bottom so the hint stays clean.
    var y: CGFloat = 11
    while y < H {
        hex(0x0E3B26, 0.05 + 0.06 * (y / H)).setFill()
        var x: CGFloat = 11
        while x < W { NSBezierPath(ovalIn: NSRect(x: x - 1, y: y - 1, width: 2, height: 2)).fill(); x += 22 }
        y += 22
    }

    // A large, faint leaf in the bottom-left corner (Canopy's mark), drawn as two arcs and a vein.
    let leaf = NSBezierPath()
    let base = NSPoint(x: -30, y: -40), tip = NSPoint(x: 150, y: 150)
    leaf.move(to: base)
    leaf.curve(to: tip, controlPoint1: NSPoint(x: -20, y: 110), controlPoint2: NSPoint(x: 60, y: 160))
    leaf.curve(to: base, controlPoint1: NSPoint(x: 160, y: 60), controlPoint2: NSPoint(x: 90, y: -30))
    hex(0x3DD68C, 0.10).setFill(); leaf.fill()
    let vein = NSBezierPath(); vein.move(to: base); vein.curve(to: tip, controlPoint1: NSPoint(x: 40, y: 40), controlPoint2: NSPoint(x: 90, y: 100))
    vein.lineWidth = 1.5; hex(0x1FA866, 0.18).setStroke(); vein.stroke()

    // Arrow between the two icons (icons sit at x=165 and x=495, y=200 from the top).
    let ay = H - 205
    hex(0x1FA866).setStroke()
    let arrow = NSBezierPath()
    arrow.move(to: NSPoint(x: 262, y: ay)); arrow.line(to: NSPoint(x: 388, y: ay))
    arrow.lineWidth = 3; arrow.lineCapStyle = .round
    let dash: [CGFloat] = [2, 9]; arrow.setLineDash(dash, count: 2, phase: 0)
    arrow.stroke()
    let head = NSBezierPath()
    head.move(to: NSPoint(x: 384, y: ay + 9)); head.line(to: NSPoint(x: 398, y: ay)); head.line(to: NSPoint(x: 384, y: ay - 9))
    head.lineWidth = 3; head.lineCapStyle = .round; head.lineJoinStyle = .round
    head.stroke()

    func text(_ s: String, size: CGFloat, weight: NSFont.Weight, color: NSColor, y: CGFloat) {
        let p = NSMutableParagraphStyle(); p.alignment = .center
        let a: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color, .paragraphStyle: p]
        NSAttributedString(string: s, attributes: a).draw(in: NSRect(x: 0, y: y, width: W, height: size * 1.4))
    }
    text("Canopy", size: 22, weight: .bold, color: hex(0x15211A), y: H - 62)
    text("A fast, native home for your MongoDB data.", size: 13, weight: .regular, color: hex(0x55605A), y: H - 84)
    text("Drag Canopy to Applications to install", size: 13, weight: .medium, color: hex(0x55605A), y: 42)
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

try! render(scale: 1).write(to: URL(fileURLWithPath: out).appendingPathComponent("background.png"))
try! render(scale: 2).write(to: URL(fileURLWithPath: out).appendingPathComponent("background@2x.png"))
print("wrote \(out)/background.png, background@2x.png")
