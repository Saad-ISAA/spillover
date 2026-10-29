import Foundation
import IOKit.pwr_mgt
import SpilloverCore

/// Holds the power assertions that keep the Mac (and, if asked, its screen) from sleeping while
/// the awake schedule is active. macOS drops them by itself when Spillover quits.
@MainActor
final class KeepAwake {
    private var system: IOPMAssertionID?
    private var screen: IOPMAssertionID?
    private static let reason = "Spillover keeps this Mac awake for Claude sessions (Setup → Keep Mac awake)" as CFString

    /// Takes or releases the assertions to match `active` and `keepScreenOn`.
    func apply(active: Bool, keepScreenOn: Bool) {
        system = set(kIOPMAssertionTypePreventUserIdleSystemSleep, on: active, current: system)
        screen = set(kIOPMAssertionTypePreventUserIdleDisplaySleep, on: active && keepScreenOn, current: screen)
    }

    var isHolding: Bool { system != nil }

    private func set(_ type: String, on: Bool, current: IOPMAssertionID?) -> IOPMAssertionID? {
        if on {
            if let current { return current }
            var id = IOPMAssertionID(0)
            let result = IOPMAssertionCreateWithName(type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), Self.reason, &id)
            return result == kIOReturnSuccess ? id : nil
        }
        if let current { IOPMAssertionRelease(current) }
        return nil
    }
}

extension AppModel {
    /// One line on what keeping the Mac awake is doing, or nil when it is off.
    var awakeStatus: String? {
        guard awake.enabled else { return nil }
        let screen = awake.keepScreenOn ? ", screen on too" : ""
        if keepingAwake {
            if let end = awake.nextChange(after: now) {
                return "Keeping this Mac awake until \(Fmt.moment(end, now: now))\(screen)."
            }
            return "Keeping this Mac awake all day\(screen)."
        }
        if let start = awake.nextChange(after: now) {
            return "Keeps this Mac awake from \(Fmt.moment(start, now: now))\(screen)."
        }
        return nil
    }
}
