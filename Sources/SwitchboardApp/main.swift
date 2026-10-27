import AppKit
import SwiftUI

// Menu bar only: no Dock icon even when running outside an app bundle.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}

struct SwitchboardApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel()
    @StateObject private var prefs = Preferences()

    var body: some Scene {
        MenuBarExtra {
            MenuPopover()
                .environmentObject(model)
        } label: {
            MenuBarLabel()
                .environmentObject(model)
                .environmentObject(prefs)
        }
        .menuBarExtraStyle(.window)

        Window("Switchboard", id: "main") {
            MainWindow()
                .environmentObject(model)
                .environmentObject(prefs)
        }
        .defaultSize(width: 1180, height: 820)

        // The popover in an ordinary window: used for screenshots and documentation only
        // (opened by SWITCHBOARD_DEMO_SHOW=popover).
        Window("Switchboard Menu", id: "popover-preview") {
            MenuPopover()
                .environmentObject(model)
        }
        .windowResizability(.contentSize)
    }
}

/// Menu bar icon. Also handles `SWITCHBOARD_DEMO_SHOW` (main[:section] | popover), which opens a
/// window at launch for screenshots.
struct MenuBarLabel: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var prefs: Preferences
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack(spacing: 3) {
            Image(nsImage: MenuBarGlyph.image(fraction: model.peakUsage.map { $0 / 100 }))
            if prefs.showPercentInMenuBar, let peak = model.peakUsage {
                Text("\(Int(peak.rounded()))%").monospacedDigit()
            }
        }
            .accessibilityLabel(model.peakUsage.map { "Switchboard, fullest limit \(Int($0.rounded())) percent" } ?? "Switchboard")
            .onAppear {
                guard let show = model.env.processEnv["SWITCHBOARD_DEMO_SHOW"] else {
                    // First launch: open the window so the getting-started checklist is visible.
                    if model.isFirstRun {
                        openWindow(id: "main")
                        NSApp.activate(ignoringOtherApps: true)
                    }
                    return
                }
                if model.env.processEnv["SWITCHBOARD_DEMO_APPEARANCE"] == "dark" {
                    NSApp.appearance = NSAppearance(named: .darkAqua)
                } else {
                    NSApp.appearance = NSAppearance(named: .aqua)
                }
                let parts = show.split(separator: ":").map(String.init)
                if parts.first == "popover" {
                    openWindow(id: "popover-preview")
                } else {
                    if parts.count > 1, let section = MainSection(rawValue: parts[1]) {
                        model.selectedSection = section
                    }
                    openWindow(id: "main")
                }
                NSApp.activate(ignoringOtherApps: true)
            }
    }
}

/// The menu bar icon: an open gauge whose filled part is the fullest limit across accounts,
/// around a routing node. A template image, so macOS tints it for light, dark and highlight.
enum MenuBarGlyph {
    static func image(fraction: Double?) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            let center = NSPoint(x: rect.midX, y: rect.midY)
            let radius: CGFloat = 7
            // 270° sweep with the gap at the bottom: from 225° counter-clockwise to -45°.
            func arc(to f: Double, alpha: CGFloat) {
                let path = NSBezierPath()
                path.appendArc(withCenter: center, radius: radius, startAngle: 225, endAngle: 225 - 270 * CGFloat(f), clockwise: true)
                path.lineWidth = 2.2
                path.lineCapStyle = .round
                NSColor.black.withAlphaComponent(alpha).setStroke()
                path.stroke()
            }
            arc(to: 1, alpha: 0.35)
            if let fraction, fraction > 0 { arc(to: min(1, fraction), alpha: 1) }
            NSColor.black.setFill()
            NSBezierPath(ovalIn: NSRect(x: center.x - 2, y: center.y - 2, width: 4, height: 4)).fill()
            return true
        }
        image.isTemplate = true
        return image
    }
}

SwitchboardApp.main()
