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

    var body: some Scene {
        MenuBarExtra {
            MenuPopover()
                .environmentObject(model)
        } label: {
            MenuBarLabel()
                .environmentObject(model)
        }
        .menuBarExtraStyle(.window)

        Window("Switchboard", id: "main") {
            MainWindow()
                .environmentObject(model)
        }
        .defaultSize(width: 900, height: 640)

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
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(systemName: "switch.2")
            .accessibilityLabel("Switchboard")
            .onAppear {
                guard let show = model.env.processEnv["SWITCHBOARD_DEMO_SHOW"] else {
                    // First launch: open the window so the getting-started checklist is visible.
                    if model.isFirstRun {
                        openWindow(id: "main")
                        NSApp.activate(ignoringOtherApps: true)
                    }
                    return
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

SwitchboardApp.main()
