import AppKit
import SwiftUI

/// Documentation only: `SPILLOVER_DEMO_RENDER=<folder>` renders the popover (light and dark) and
/// the menu bar glyph states to PNG files without showing a window, then quits. Lets screenshots
/// be made where window capture is unavailable. AppKit-backed controls (menus, pickers) render as
/// placeholders in this mode.
@MainActor
enum DemoRender {
    static func runIfRequested(model: AppModel) {
        guard let folder = model.env.processEnv["SPILLOVER_DEMO_RENDER"] else { return }
        let out = URL(fileURLWithPath: folder, isDirectory: true)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        // Give background refreshes (logins, sessions, logs) a moment to land.
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            for (name, scheme) in [("light", ColorScheme.light), ("dark", .dark)] {
                let view = MenuPopover(rendersStatically: true).environmentObject(model).environment(\.colorScheme, scheme)
                    .background(scheme == .dark ? Color(white: 0.09) : Color.white)
                write(view, to: out.appendingPathComponent("popover-\(name).png"), appearance: scheme == .dark ? .darkAqua : .aqua)
            }
            let states: [(String, Double?, Double?)] = [("none", nil, nil), ("calm", 35, 10), ("spilling", 92, 18)]
            for (name, fullest, roomiest) in states {
                let glyph = Image(nsImage: MenuBarGlyph.image(fullest: fullest, roomiest: roomiest))
                    .renderingMode(.template).foregroundStyle(.black).frame(width: 18, height: 18)
                    .padding(4).background(Color.white)
                write(glyph, to: out.appendingPathComponent("glyph-\(name).png"), appearance: .aqua, scale: 6)
            }
            write(BrandMark(size: 64).padding(8).background(Color.white), to: out.appendingPathComponent("brand-light.png"), appearance: .aqua)
            write(BrandMark(size: 64).padding(8).background(Color(white: 0.09)), to: out.appendingPathComponent("brand-dark.png"), appearance: .darkAqua)
            NSApp.terminate(nil)
        }
    }

    private static func write<V: View>(_ view: V, to url: URL, appearance: NSAppearance.Name, scale: CGFloat = 2) {
        NSAppearance(named: appearance)?.performAsCurrentDrawingAppearance {
            let renderer = ImageRenderer(content: view)
            renderer.scale = scale
            guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
                let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
            else { return }
            try? png.write(to: url)
        }
    }
}
