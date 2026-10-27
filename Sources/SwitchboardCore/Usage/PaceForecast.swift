import Foundation

/// Where a limit window is heading at the rate it has been used so far.
///
/// The rate is the window's average (percent used / time elapsed since the window started), which
/// is steady and needs no history. Early in a window that average is noisy, so no run-out is
/// predicted until `minimumElapsedFraction` of the window has passed.
public struct PaceForecast: Equatable, Sendable {
    public enum Outlook: Equatable, Sendable {
        /// Too early in the window to say.
        case tooEarly
        /// Nothing used yet.
        case idle
        /// Already at the limit until the reset.
        case full
        /// At this pace the window ends with this much used.
        case lastsUntilReset(projected: Double)
        /// At this pace the limit is reached at `at`, `early` seconds before the reset.
        case runsOut(at: Date, early: TimeInterval)
    }

    public static let minimumElapsedFraction = 0.08

    public let kind: UsageWindow.Kind
    public let used: Double
    public let windowStart: Date
    public let resetsAt: Date
    /// 0...1: how much of the window's time has passed.
    public let elapsedFraction: Double
    /// Percentage points ahead of (positive) or behind (negative) an even pace.
    public let paceDelta: Double
    public let outlook: Outlook

    public static func length(of kind: UsageWindow.Kind) -> TimeInterval? {
        switch kind {
        case .fiveHour: return 5 * 3600
        case .sevenDay: return 7 * 86400
        case .spendLimit: return nil
        }
    }

    /// Nil for windows without a fixed length, and for windows that have already reset (the new
    /// window's start is unknown until the next capture).
    public static func forecast(_ window: UsageWindow, now: Date = Date()) -> PaceForecast? {
        guard let length = length(of: window.kind), now < window.resetsAt else { return nil }
        let start = window.resetsAt.addingTimeInterval(-length)
        let elapsed = min(length, max(60, now.timeIntervalSince(start)))
        let fraction = elapsed / length
        let used = window.usedPercentage
        let outlook: Outlook
        if used >= 100 {
            outlook = .full
        } else if used <= 0 {
            outlook = .idle
        } else if fraction < minimumElapsedFraction {
            outlook = .tooEarly
        } else {
            let rate = used / elapsed
            let hit = now.addingTimeInterval((100 - used) / rate)
            if hit < window.resetsAt {
                outlook = .runsOut(at: hit, early: window.resetsAt.timeIntervalSince(hit))
            } else {
                outlook = .lastsUntilReset(projected: used + rate * window.resetsAt.timeIntervalSince(now))
            }
        }
        return PaceForecast(
            kind: window.kind, used: used, windowStart: start, resetsAt: window.resetsAt,
            elapsedFraction: fraction, paceDelta: used - fraction * 100, outlook: outlook)
    }
}
