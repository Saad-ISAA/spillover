import AppKit
import Foundation
import ServiceManagement
import SwiftUI
import SpilloverCore
import UserNotifications

/// App-only preferences (UI behaviour). Routing state never lives here; it lives in ~/.spillover.
@MainActor
final class Preferences: ObservableObject {
    private let defaults = UserDefaults.standard

    @Published var showPercentInMenuBar: Bool {
        didSet { defaults.set(showPercentInMenuBar, forKey: "showPercentInMenuBar") }
    }

    @Published var notifyNearLimit: Bool {
        didSet {
            defaults.set(notifyNearLimit, forKey: "notifyNearLimit")
            if notifyNearLimit { LimitNotifier.requestAuthorization() }
        }
    }

    /// Keep the Dock icon after the window closes (it always shows while the window is open).
    @Published var alwaysInDock: Bool {
        didSet {
            defaults.set(alwaysInDock, forKey: "alwaysInDock")
            DockPresence.alwaysShown = alwaysInDock
        }
    }

    @Published private(set) var openAtLogin: Bool

    init() {
        showPercentInMenuBar = defaults.object(forKey: "showPercentInMenuBar") as? Bool ?? false
        notifyNearLimit = defaults.object(forKey: "notifyNearLimit") as? Bool ?? true
        let dock = defaults.object(forKey: "alwaysInDock") as? Bool ?? false
        alwaysInDock = dock
        openAtLogin = Self.isBundled && SMAppService.mainApp.status == .enabled
        DockPresence.alwaysShown = dock
    }

    /// Login items and notifications need a real app bundle (not a bare development binary).
    nonisolated static var isBundled: Bool { Bundle.main.bundleIdentifier != nil }

    func setOpenAtLogin(_ on: Bool) throws {
        guard Self.isBundled else { return }
        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        openAtLogin = SMAppService.mainApp.status == .enabled
    }
}

/// The Dock icon: shown while the Spillover window is open (so the window can be found with
/// Command-Tab and the Dock), or always if the user asks; otherwise the app lives in the menu bar.
@MainActor
enum DockPresence {
    static var alwaysShown = false { didSet { update() } }
    private static var windowOpen = false
    /// Opens the main window; set by a view that can open windows.
    static var openMainWindow: (() -> Void)?

    static func windowDidOpen() {
        windowOpen = true
        update()
    }

    static func windowDidClose() {
        windowOpen = false
        update()
    }

    private static func update() {
        let policy: NSApplication.ActivationPolicy = alwaysShown || windowOpen ? .regular : .accessory
        guard NSApp != nil, NSApp.activationPolicy() != policy else { return }
        NSApp.setActivationPolicy(policy)
        if policy == .regular { NSApp.activate(ignoringOtherApps: true) }
    }
}

/// Posts a notification once per account, limit window and threshold, with a one-click action
/// that moves that account's folders and open chats to the account with the most room.
enum LimitNotifier {
    static let thresholds: [Double] = [80, 95]
    static let moveAction = "move"
    private static var categories: [String: UNNotificationCategory] = [:]

    /// Action buttons carry their title, so there is one category per target account.
    private static func category(movingTo target: Profile) -> String {
        let id = "near-limit-\(target.id)"
        if categories[id] == nil {
            let action = UNNotificationAction(identifier: moveAction, title: "Move work to \(target.displayName)", options: [])
            categories[id] = UNNotificationCategory(identifier: id, actions: [action], intentIdentifiers: [], options: [])
            UNUserNotificationCenter.current().setNotificationCategories(Set(categories.values))
        }
        return id
    }

    static func requestAuthorization() {
        guard Preferences.isBundled else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func check(snapshots: [String: UsageSnapshot], profiles: [Profile], policy: AutoPolicy, now: Date = Date()) {
        guard Preferences.isBundled else { return }
        let defaults = UserDefaults.standard
        var sent = Set(defaults.stringArray(forKey: "sentLimitNotifications") ?? [])
        for p in profiles {
            guard let s = snapshots[p.id] else { continue }
            for w in s.windows where w.kind != .spendLimit {
                let pct = w.effectivePercentage(at: now)
                guard let threshold = thresholds.last(where: { pct >= $0 }) else { continue }
                let key = "\(p.id)|\(w.kind.rawValue)|\(Int(w.resetsAt.timeIntervalSince1970))|\(Int(threshold))"
                guard !sent.contains(key) else { continue }
                sent.insert(key)
                let content = UNMutableNotificationContent()
                content.title = "\(p.displayName): \(Int(pct.rounded()))% of \(w.kind.label.lowercased()) used"
                let others = profiles.filter { $0.id != p.id }
                if let target = policy.choose(profiles: others, snapshots: snapshots, now: now),
                    !policy.isOutOfRoom(snapshots[target.id], now: now)
                {
                    content.body = "Resets in \(Fmt.countdown(to: w.resetsAt, now: now)). \(target.displayName) has the most room."
                    content.categoryIdentifier = category(movingTo: target)
                    content.userInfo = ["from": p.id, "to": target.id]
                } else {
                    content.body = "Resets in \(Fmt.countdown(to: w.resetsAt, now: now)). No other account has much room either."
                }
                UNUserNotificationCenter.current().add(
                    UNNotificationRequest(identifier: key, content: content, trigger: nil))
            }
        }
        // Keep the memory small: only keys whose window has not reset yet matter.
        let live = sent.filter { key in
            let parts = key.split(separator: "|")
            guard parts.count == 4, let t = Double(parts[2]) else { return false }
            return Date(timeIntervalSince1970: t) > now
        }
        defaults.set(Array(live), forKey: "sentLimitNotifications")
    }
}
