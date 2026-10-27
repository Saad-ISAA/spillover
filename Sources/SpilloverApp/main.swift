import AppKit
import SwiftUI
import SpilloverCore
import UserNotifications

// Menu bar only: no Dock icon even when running outside an app bundle.
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        if Preferences.isBundled { UNUserNotificationCenter.current().delegate = self }
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
        }
        .defaultSize(width: 1180, height: 820)

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
            Image(nsImage: MenuBarGlyph.image(fullest: model.peakUsage, roomiest: model.bestHeadroom?.peakPercentage))
            if prefs.showPercentInMenuBar, let peak = model.peakUsage {
                Text("\(Int(peak.rounded()))%").monospacedDigit()
            }
        }
            .accessibilityLabel(model.peakUsage.map { "Spillover, fullest limit \(Int($0.rounded())) percent" } ?? "Spillover")
            .onAppear {
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

/// The menu bar icon: the Spillover cups. The upper cup fills with the fullest limit across
/// accounts, the lower one with the account that has the most room; the pour appears once an
/// account reaches 80%. A template image, so macOS tints it for light, dark and highlight.
enum MenuBarGlyph {
    static func image(fullest: Double?, roomiest: Double?) -> NSImage {
        let upper = CGFloat((fullest ?? 0) / 100)
        let lower = CGFloat((roomiest ?? 0) / 100)
        return SpillMark.image(
            size: 18, upper: max(upper, 0.12), lower: lower, spilling: (fullest ?? 0) >= HeadroomAdvisor.warningThreshold,
            line: .black, liquid: .black, wallScale: 0.09, template: true)
    }
}

SpilloverApp.main()
