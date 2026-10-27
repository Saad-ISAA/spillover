import Foundation

/// Advisory only: ranks profiles by remaining headroom. It never reassigns anything; the user
/// decides (a route change is always an explicit action).
public struct HeadroomAdvisor {
    public struct Ranked: Equatable, Sendable {
        public let profile: Profile
        /// Fullest window right now, nil when no usage has been captured yet.
        public let peakPercentage: Double?
        public let capturedAt: Date?
    }

    public static let warningThreshold = 80.0

    /// Known usage first, least used first; profiles without data last (in their given order).
    public static func rank(
        profiles: [Profile], snapshots: [String: UsageSnapshot], now: Date = Date()
    ) -> [Ranked] {
        let ranked = profiles.map { p -> Ranked in
            let s = snapshots[p.id]
            return Ranked(profile: p, peakPercentage: s?.peakPercentage(at: now), capturedAt: s?.capturedAt)
        }
        let known = ranked.filter { $0.peakPercentage != nil }.sorted {
            ($0.peakPercentage ?? 0) < ($1.peakPercentage ?? 0)
        }
        let unknown = ranked.filter { $0.peakPercentage == nil }
        return known + unknown
    }

    public static func isNearLimit(_ snapshot: UsageSnapshot, now: Date = Date()) -> Bool {
        snapshot.peakPercentage(at: now) >= warningThreshold
    }
}
