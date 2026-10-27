import Foundation

/// One recorded reading of an account's limits.
public struct UsagePoint: Codable, Equatable, Sendable {
    public var at: Date
    public var fiveHour: Double?
    public var fiveHourResetsAt: Date?
    public var sevenDay: Double?
    public var sevenDayResetsAt: Date?

    public init(
        at: Date, fiveHour: Double? = nil, fiveHourResetsAt: Date? = nil, sevenDay: Double? = nil,
        sevenDayResetsAt: Date? = nil
    ) {
        self.at = at
        self.fiveHour = fiveHour
        self.fiveHourResetsAt = fiveHourResetsAt
        self.sevenDay = sevenDay
        self.sevenDayResetsAt = sevenDayResetsAt
    }

    public init(snapshot: UsageSnapshot) {
        let five = snapshot.window(.fiveHour)
        let seven = snapshot.window(.sevenDay)
        self.init(
            at: snapshot.capturedAt, fiveHour: five?.usedPercentage, fiveHourResetsAt: five?.resetsAt,
            sevenDay: seven?.usedPercentage, sevenDayResetsAt: seven?.resetsAt)
    }

    public func value(_ kind: UsageWindow.Kind) -> Double? {
        switch kind {
        case .fiveHour: return fiveHour
        case .sevenDay: return sevenDay
        case .spendLimit: return nil
        }
    }

    public func resetsAt(_ kind: UsageWindow.Kind) -> Date? {
        switch kind {
        case .fiveHour: return fiveHourResetsAt
        case .sevenDay: return sevenDayResetsAt
        case .spendLimit: return nil
        }
    }

    func sameReading(as other: UsagePoint) -> Bool {
        fiveHour == other.fiveHour && sevenDay == other.sevenDay
            && fiveHourResetsAt == other.fiveHourResetsAt && sevenDayResetsAt == other.sevenDayResetsAt
    }
}

/// A short, bounded history of each account's limits, so the app can draw how usage moved within
/// the current windows. Written by the statusline capture under `<root>/usage/` (owner-only);
/// only percentages and reset times are kept.
public struct UsageHistory {
    /// Points older than this are dropped (a little more than the weekly window).
    public static let retention: TimeInterval = 8 * 86400
    /// An unchanged reading is recorded again only after this long.
    public static let unchangedInterval: TimeInterval = 15 * 60
    public static let maxPoints = 3000

    private let env: SBEnvironment

    public init(env: SBEnvironment) {
        self.env = env
    }

    func url(for profileId: String) -> URL {
        env.paths.usageDir.appendingPathComponent("\(profileId).history.json")
    }

    public func load(profileId: String) -> [UsagePoint] {
        guard ProfileID.isValid(profileId), let data = try? Data(contentsOf: url(for: profileId)) else {
            return []
        }
        return (try? Self.decoder.decode([UsagePoint].self, from: data)) ?? []
    }

    /// Records a snapshot unless it repeats the last reading within `unchangedInterval`.
    public func record(_ snapshot: UsageSnapshot) throws {
        guard ProfileID.isValid(snapshot.profileId), !snapshot.windows.isEmpty else { return }
        try SafeFS.ensureDir(env.paths.root)
        try SafeFS.ensureDir(env.paths.usageDir)
        try SafeFS.withLock(root: env.paths.root) {
            let points = Self.appending(UsagePoint(snapshot: snapshot), to: load(profileId: snapshot.profileId))
            try SafeFS.writeAtomic(try Self.encoder.encode(points), to: url(for: snapshot.profileId))
        }
    }

    /// Pure merge rule (tested): skip repeats, keep time order, prune old points, cap the count.
    static func appending(_ point: UsagePoint, to existing: [UsagePoint]) -> [UsagePoint] {
        var points = existing
        if let last = points.last, last.sameReading(as: point),
            point.at.timeIntervalSince(last.at) < unchangedInterval
        {
            return points
        }
        points.append(point)
        points.sort { $0.at < $1.at }
        let cutoff = point.at.addingTimeInterval(-retention)
        points.removeAll { $0.at < cutoff }
        if points.count > maxPoints { points.removeFirst(points.count - maxPoints) }
        return points
    }

    private static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        return e
    }

    private static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }
}
