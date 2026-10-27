import Foundation

public struct UsageWindow: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case spendLimit = "spend_limit"

        public var label: String {
            switch self {
            case .fiveHour: return "Session (5h)"
            case .sevenDay: return "Weekly (7d)"
            case .spendLimit: return "Spend limit"
            }
        }

        public var shortLabel: String {
            switch self {
            case .fiveHour: return "5h"
            case .sevenDay: return "7d"
            case .spendLimit: return "$"
            }
        }
    }

    public var kind: Kind
    /// 0...100 (can exceed 100 for spend limits once exceeded).
    public var usedPercentage: Double
    public var resetsAt: Date

    public init(kind: Kind, usedPercentage: Double, resetsAt: Date) {
        self.kind = kind
        self.usedPercentage = usedPercentage
        self.resetsAt = resetsAt
    }

    /// After the reset time the window is empty again, whatever the last capture said.
    public func effectivePercentage(at now: Date = Date()) -> Double {
        now >= resetsAt ? 0 : usedPercentage
    }
}

/// Last known usage for one profile, captured from Claude Code's statusline feed.
public struct UsageSnapshot: Codable, Equatable, Sendable {
    public var profileId: String
    public var capturedAt: Date
    public var windows: [UsageWindow]
    public var model: String?

    public init(profileId: String, capturedAt: Date, windows: [UsageWindow], model: String? = nil) {
        self.profileId = profileId
        self.capturedAt = capturedAt
        self.windows = windows
        self.model = model
    }

    public func window(_ kind: UsageWindow.Kind) -> UsageWindow? {
        windows.first { $0.kind == kind }
    }

    /// The fullest window right now (what limits you first).
    public func peakPercentage(at now: Date = Date()) -> Double {
        windows.map { $0.effectivePercentage(at: now) }.max() ?? 0
    }
}

/// Reads and writes snapshots under `<root>/usage/` (owner-only).
public struct UsageStore {
    private let env: SBEnvironment

    public init(env: SBEnvironment) {
        self.env = env
    }

    func url(for profileId: String) -> URL {
        env.paths.usageDir.appendingPathComponent("\(profileId).json")
    }

    public func save(_ snapshot: UsageSnapshot) throws {
        guard ProfileID.isValid(snapshot.profileId) else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        try SafeFS.ensureDir(env.paths.root)
        try SafeFS.ensureDir(env.paths.usageDir)
        try SafeFS.writeAtomic(try encoder.encode(snapshot), to: url(for: snapshot.profileId))
    }

    public func load(profileId: String) -> UsageSnapshot? {
        guard ProfileID.isValid(profileId), let data = try? Data(contentsOf: url(for: profileId)) else {
            return nil
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(UsageSnapshot.self, from: data)
    }
}
