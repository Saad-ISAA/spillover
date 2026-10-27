// Renders the app icon into an .iconset folder. Usage:
//   swift scripts/make-icon.swift <output.iconset>
// then: iconutil -c icns <output.iconset>
//
// The mark: two cups in a cascade. The raised one is full and pours over its rim into the lower
// one, which still has room: work spilling over to the account with room. Flat colour on a matte
// face.
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset")
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func color(_ hex: UInt32) -> NSColor {
    NSColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
}

func render(_ size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    // macOS icon grid: content inset ~10% with a continuous-corner rounded square.
    let inset = size * 0.1
    let rect = NSRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
    color(0x141517).setFill()
    NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.width * 0.225).fill()

    // Two open cups in a cascade: the raised one is full and pours over its rim into the lower
    // one, which still has room.
    let s = rect.width
    let ox = rect.minX, oy = rect.minY
    let w = s * 0.27, h = s * 0.29, wall = s * 0.042, r = s * 0.075
    let teal = color(0x4DB6CC), ink = color(0xEDECE8)

    func cup(x: CGFloat, y: CGFloat, fill: CGFloat) {
        // Liquid first, inside the walls.
        let inner = NSRect(x: x + wall * 0.5, y: y + wall * 0.5, width: w - wall, height: (h - wall * 0.5) * fill)
        teal.setFill()
        NSBezierPath(roundedRect: inner, xRadius: r - wall * 0.5, yRadius: r - wall * 0.5).fill()
        if fill < 1 {
            // Square the liquid's surface.
            NSRect(x: inner.minX, y: inner.minY + r, width: inner.width, height: max(0, inner.height - r)).fill()
        }
        let outline = NSBezierPath()
        outline.move(to: NSPoint(x: x, y: y + h))
        outline.line(to: NSPoint(x: x, y: y + r))
        outline.appendArc(withCenter: NSPoint(x: x + r, y: y + r), radius: r, startAngle: 180, endAngle: 270)
        outline.line(to: NSPoint(x: x + w - r, y: y))
        outline.appendArc(withCenter: NSPoint(x: x + w - r, y: y + r), radius: r, startAngle: 270, endAngle: 360)
        outline.line(to: NSPoint(x: x + w, y: y + h))
        outline.lineWidth = wall
        outline.lineCapStyle = .round
        outline.lineJoinStyle = .round
        ink.setStroke()
        outline.stroke()
    }

    let upper = NSPoint(x: ox + s * 0.15, y: oy + s * 0.47)
    let lower = NSPoint(x: ox + s * 0.56, y: oy + s * 0.17)
    cup(x: upper.x, y: upper.y, fill: 1.0)
    cup(x: lower.x, y: lower.y, fill: 0.42)

    // The spill: a crest over the upper cup's rim, then a stream into the lower cup.
    let crest = NSBezierPath()
    crest.move(to: NSPoint(x: upper.x + wall * 0.5, y: upper.y + h - wall * 0.2))
    crest.curve(
        to: NSPoint(x: upper.x + w + wall * 0.2, y: upper.y + h + wall * 0.25),
        controlPoint1: NSPoint(x: upper.x + w * 0.3, y: upper.y + h + s * 0.05),
        controlPoint2: NSPoint(x: upper.x + w * 0.8, y: upper.y + h + s * 0.06))
    crest.line(to: NSPoint(x: upper.x + wall * 0.5, y: upper.y + h - wall * 0.2))
    teal.setFill()
    crest.fill()

    let stream = NSBezierPath()
    stream.move(to: NSPoint(x: upper.x + w + wall * 0.1, y: upper.y + h + wall * 0.1))
    stream.curve(
        to: NSPoint(x: lower.x + w * 0.5, y: lower.y + h * 0.42),
        controlPoint1: NSPoint(x: upper.x + w + s * 0.11, y: upper.y + h + s * 0.03),
        controlPoint2: NSPoint(x: lower.x + w * 0.5, y: lower.y + h + s * 0.04))
    stream.lineWidth = s * 0.05
    stream.lineCapStyle = .round
    teal.setStroke()
    stream.stroke()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = CGFloat(base * scale)
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        let data = render(px).representation(using: .png, properties: [:])!
        try data.write(to: out.appendingPathComponent(name))
    }
}
print(out.path)
