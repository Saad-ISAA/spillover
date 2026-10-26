// Renders the app icon into an .iconset folder. Usage:
//   swift scripts/make-icon.swift <output.iconset>
// then: iconutil -c icns <output.iconset>
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset")
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

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
    let path = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.width * 0.225)
    NSGradient(colors: [
        NSColor(calibratedRed: 0.20, green: 0.30, blue: 0.85, alpha: 1),
        NSColor(calibratedRed: 0.55, green: 0.25, blue: 0.85, alpha: 1),
    ])!.draw(in: path, angle: -60)

    // Two switches, one on each "account".
    let trackW = rect.width * 0.56, trackH = rect.width * 0.2
    for (i, on) in [true, false].enumerated() {
        let gap = trackH * 0.8
        let y = i == 0 ? rect.midY + gap / 2 : rect.midY - gap / 2 - trackH
        let track = NSRect(x: rect.midX - trackW / 2, y: y, width: trackW, height: trackH)
        NSColor.white.withAlphaComponent(on ? 0.95 : 0.35).setFill()
        NSBezierPath(roundedRect: track, xRadius: trackH / 2, yRadius: trackH / 2).fill()
        let knobD = trackH * 0.78
        let knobX = on ? track.maxX - knobD - trackH * 0.11 : track.minX + trackH * 0.11
        let knob = NSRect(x: knobX, y: track.midY - knobD / 2, width: knobD, height: knobD)
        (on ? NSColor(calibratedRed: 0.30, green: 0.30, blue: 0.85, alpha: 1) : NSColor.white).setFill()
        NSBezierPath(ovalIn: knob).fill()
    }

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
