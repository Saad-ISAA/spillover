// Renders the app icon into an .iconset folder. Usage:
//   swift scripts/make-icon.swift <output.iconset>
// then: iconutil -c icns <output.iconset>
//
// The mark: three concentric open meters (270°, gap at the bottom), one per subscription, each
// wired back to a single routing node in the gap. Flat colour on a matte face.
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset")
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func color(_ hex: UInt32) -> NSColor {
    NSColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
}

func point(_ c: NSPoint, _ r: CGFloat, _ degrees: CGFloat) -> NSPoint {
    let a = degrees * .pi / 180
    return NSPoint(x: c.x + r * cos(a), y: c.y + r * sin(a))
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

    // Three subscriptions as three concentric open meters, each wired from its start back to one
    // routing node in the gap at the bottom: one switchboard, several metered lines.
    let c = NSPoint(x: rect.midX, y: rect.midY + rect.height * 0.04)
    let width = rect.width * 0.062
    let gap = width * 1.75
    let outer = rect.width * 0.33
    let start: CGFloat = 225, sweep: CGFloat = 270
    let fills: [CGFloat] = [0.78, 0.52, 0.30]
    let node = NSPoint(x: c.x, y: c.y - outer * 0.98)
    let ink = color(0xF3F2EE)

    for (i, fill) in fills.enumerated() {
        let r = outer - CGFloat(i) * gap
        func arc(to f: CGFloat, _ stroke: NSColor) {
            let p = NSBezierPath()
            p.appendArc(withCenter: c, radius: r, startAngle: start, endAngle: start - sweep * f, clockwise: true)
            p.lineWidth = width
            p.lineCapStyle = .round
            stroke.setStroke()
            p.stroke()
        }
        arc(to: 1, color(0x2A2C31))
        arc(to: fill, i == 0 ? color(0x4DB6CC) : (i == 1 ? color(0x3A93A6) : color(0x2C7383)))

        // The wire from the node to this meter's start.
        let wire = NSBezierPath()
        let a = point(c, r, start)
        wire.move(to: node)
        wire.curve(to: a, controlPoint1: NSPoint(x: node.x - (node.x - a.x) * 0.15, y: node.y), controlPoint2: NSPoint(x: a.x, y: a.y - (a.y - node.y) * 0.55))
        wire.lineWidth = max(1, width * 0.28)
        wire.lineCapStyle = .round
        ink.setStroke()
        wire.stroke()
    }
    let n = width * 0.8
    ink.setFill()
    NSBezierPath(ovalIn: NSRect(x: node.x - n, y: node.y - n, width: n * 2, height: n * 2)).fill()

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
