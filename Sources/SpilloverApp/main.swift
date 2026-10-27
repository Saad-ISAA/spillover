import AppKit
import SwiftUI
import SpilloverCore
import UserNotifications

// A menu bar app: the Dock icon appears only while the window is open, or always if the user
// asks (DockPresence). Quitting from the Dock or with Command-Q closes the window and keeps the
// menu bar running; "Quit Spillover" in the menu bar (or Option-Command-Q) quits completely.
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    /// Set by the explicit "quit completely" commands.
    @MainActor static var quitRequested = false

    @MainActor static func quitCompletely() {
        quitRequested = true
        NSApp.terminate(nil)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(DockPresence.alwaysShown ? .regular : .accessory)
        if Preferences.isBundled { UNUserNotificationCenter.current().delegate = self }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            if Self.quitRequested || Self.sessionIsEnding() { return .terminateNow }
            DockPresence.retreatToMenuBar()
            return .terminateCancel
        }
    }

    /// Log out, restart and shut down must never be held up by a menu bar app.
    private static func sessionIsEnding() -> Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
            event.eventClass == AEEventClass(kCoreEventClass), event.eventID == AEEventID(kAEQuitApplication),
            let reason = event.attributeDescriptor(forKeyword: AEKeyword(kAEQuitReason))?.enumCodeValue
        else { return false }
        let ending: [OSType] = [
            OSType(kAELogOut), OSType(kAEReallyLogOut), OSType(kAEShowRestartDialog), OSType(kAEShowShutdownDialog),
            OSType(kAERestart), OSType(kAEShutDown),
        ]
        return ending.contains(reason)
    }

    /// Opening the app again (Finder, Spotlight, the Dock icon) brings its window forward.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainActor.assumeIsolated { DockPresence.openMainWindow?() }
        NSApp.activate(ignoringOtherApps: true)
        return false
    }

    /// "Move work to …" on a near-limit notification.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let info = response.notification.request.content.userInfo
        if response.actionIdentifier == LimitNotifier.moveAction, let from = info["from"] as? String,
            let to = info["to"] as? String
        {
            Task { @MainActor in AppModel.shared?.moveWork(from: from, to: to) }
        }
        completionHandler()
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}

struct SpilloverApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel()
    @StateObject private var prefs = Preferences()

    var body: some Scene {
        MenuBarExtra {
            MenuPopover()
                .environmentObject(model)
                .tint(Ink.data)
                .preferredColorScheme(prefs.colorScheme)
        } label: {
            MenuBarLabel()
                .environmentObject(model)
                .environmentObject(prefs)
        }
        .menuBarExtraStyle(.window)

        Window("Spillover", id: "main") {
            MainWindow()
                .environmentObject(model)
                .environmentObject(prefs)
                .preferredColorScheme(prefs.colorScheme)
        }
        .defaultSize(width: 1180, height: 820)
        .commands {
            CommandGroup(replacing: .appTermination) {
                Button("Close to Menu Bar") { DockPresence.retreatToMenuBar() }
                    .keyboardShortcut("q")
                Button("Quit Spillover Completely") { AppDelegate.quitCompletely() }
                    .keyboardShortcut("q", modifiers: [.command, .option])
            }
        }

        // The popover in an ordinary window: used for screenshots and documentation only
        // (opened by SPILLOVER_DEMO_SHOW=popover).
        Window("Spillover Menu", id: "popover-preview") {
            MenuPopover()
                .environmentObject(model)
        }
        .windowResizability(.contentSize)
    }
}

/// Menu bar icon. Also handles `SPILLOVER_DEMO_SHOW` (main[:section] | popover), which opens a
/// window at launch for screenshots.
struct MenuBarLabel: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var prefs: Preferences
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack(spacing: 3) {
            Image(nsImage: MenuBarGlyph.image(alert: (model.peakUsage ?? 0) >= HeadroomAdvisor.warningThreshold))
            if prefs.showPercentInMenuBar, let peak = model.peakUsage {
                Text("\(Int(peak.rounded()))%").monospacedDigit()
            }
        }
            .accessibilityLabel(model.peakUsage.map { "Spillover, fullest limit \(Int($0.rounded())) percent" } ?? "Spillover")
            .onAppear {
                DockPresence.openMainWindow = { openWindow(id: "main") }
                DemoRender.runIfRequested(model: model)
                guard let show = model.env.processEnv["SPILLOVER_DEMO_SHOW"] else {
                    // First launch: open the window so the getting-started checklist is visible.
                    if model.isFirstRun {
                        openWindow(id: "main")
                        NSApp.activate(ignoringOtherApps: true)
                    }
                    return
                }
                if model.env.processEnv["SPILLOVER_DEMO_APPEARANCE"] == "dark" {
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

/// The menu bar icon: the Spillover mark as in the app icon, a full cup pouring into one with
/// room. `alert` adds a dot in the free corner once an account reaches 80% of a limit. A template
/// image, so macOS tints it for light, dark and highlight.
enum MenuBarGlyph {
    static func image(alert: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            SpillMark.draw(in: rect, upper: 1, lower: 0.5, spilling: true, line: .black, liquid: .black, wallScale: 0.11, solid: true)
            if alert {
                let s = rect.width
                NSColor.black.setFill()
                NSBezierPath(ovalIn: NSRect(x: rect.minX + s * 0.08, y: rect.minY + s * 0.08, width: s * 0.26, height: s * 0.26)).fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}

SpilloverApp.main()
