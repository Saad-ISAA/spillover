import AppKit
import SwiftUI

/// The Spillover mark, drawn in code so the app icon, the in-app mark and the menu bar glyph stay
/// one shape: two open cups in a cascade, the upper one pouring over its rim into the lower one.
enum SpillMark {
    /// Draws into the current graphics context, in a square `rect` (y up).
    /// `upper` / `lower`: how full each cup is (0...1). `spilling`: draw the pour.
    static func draw(
        in rect: NSRect, upper: CGFloat, lower: CGFloat, spilling: Bool, line: NSColor, liquid: NSColor,
        wallScale: CGFloat = 0.07
    ) {
        let s = rect.width
        let w = s * 0.4, h = s * 0.4, wall = s * wallScale, r = s * 0.11
        let up = NSPoint(x: rect.minX + s * 0.04, y: rect.minY + s * 0.55)
        let low = NSPoint(x: rect.minX + s * 0.56, y: rect.minY + s * 0.05)

        func cup(_ o: NSPoint, fill: CGFloat) {
            let level = max(0, min(1, fill))
            if level > 0 {
                let inner = NSRect(x: o.x + wall * 0.5, y: o.y + wall * 0.5, width: w - wall, height: (h - wall * 0.5) * level)
                liquid.setFill()
                NSBezierPath(roundedRect: inner, xRadius: max(0, r - wall * 0.5), yRadius: max(0, r - wall * 0.5)).fill()
                if inner.height > r { NSRect(x: inner.minX, y: inner.minY + r, width: inner.width, height: inner.height - r).fill() }
            }
            let outline = NSBezierPath()
            outline.move(to: NSPoint(x: o.x, y: o.y + h))
            outline.line(to: NSPoint(x: o.x, y: o.y + r))
            outline.appendArc(withCenter: NSPoint(x: o.x + r, y: o.y + r), radius: r, startAngle: 180, endAngle: 270)
            outline.line(to: NSPoint(x: o.x + w - r, y: o.y))
            outline.appendArc(withCenter: NSPoint(x: o.x + w - r, y: o.y + r), radius: r, startAngle: 270, endAngle: 360)
            outline.line(to: NSPoint(x: o.x + w, y: o.y + h))
            outline.lineWidth = wall
            outline.lineCapStyle = .round
            outline.lineJoinStyle = .round
            line.setStroke()
            outline.stroke()
        }

        cup(up, fill: upper)
        cup(low, fill: lower)
        guard spilling else { return }
        let stream = NSBezierPath()
        stream.move(to: NSPoint(x: up.x + w, y: up.y + h + wall * 0.2))
        stream.curve(
            to: NSPoint(x: low.x + w * 0.5, y: low.y + max(wall, (h - wall * 0.5) * lower)),
            controlPoint1: NSPoint(x: up.x + w + s * 0.16, y: up.y + h + s * 0.05),
            controlPoint2: NSPoint(x: low.x + w * 0.5, y: low.y + h + s * 0.06))
        stream.lineWidth = s * max(0.06, wallScale * 1.05)
        stream.lineCapStyle = .round
        liquid.setStroke()
        stream.stroke()
    }

    static func image(
        size: CGFloat, upper: CGFloat, lower: CGFloat, spilling: Bool, line: NSColor, liquid: NSColor,
        wallScale: CGFloat = 0.07, template: Bool = false
    ) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            draw(in: rect, upper: upper, lower: lower, spilling: spilling, line: line, liquid: liquid, wallScale: wallScale)
            return true
        }
        image.isTemplate = template
        return image
    }
}

/// The product mark in the app's own colours (follows light and dark).
struct BrandMark: View {
    var size: CGFloat = 18

    var body: some View {
        Image(
            nsImage: SpillMark.image(
                size: size, upper: 1, lower: 0.45, spilling: true, line: .adaptive(0x141516, 0xF3F2EE),
                liquid: .adaptive(0x18697D, 0x4DB6CC), wallScale: 0.08)
        )
        .accessibilityHidden(true)
    }
}

extension NSColor {
    /// A colour that follows the drawing appearance (resolved each time an image is drawn).
    static func adaptive(_ light: UInt32, _ dark: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(
                srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        }
    }
}
