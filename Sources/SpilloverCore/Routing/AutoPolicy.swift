import Foundation

/// How folders assigned to **Auto** pick an account.
///
/// When Claude starts in an Auto folder, the first account in `order` that has room is used; an
/// account has room while its fullest limit is under `threshold` percent and no window is
/// forecast to run out within `runOutMinutes`. When none has room, the least used one is taken
/// (work continues rather than being refused). Open chats on an account that loses its room move
/// at their next idle moment when `moveOpenChats` is on.
public struct AutoPolicy: Codable, Equatable, Sendable {
    public var version = 1
    /// Account ids in order of preference. Empty means every account, in registry order.
    public var order: [String] = []
    public var threshold: Double = 90
    public var runOutMinutes: Double = 30
    public var moveOpenChats = true
    /// Accounts Auto must not use right now (kept up to date by the app: not logged in).
    public var unavailable: [String] = []

    public init(
        order: [String] = [], threshold: Double = 90, runOutMinutes: Double = 30, moveOpenChats: Bool = true,
        unavailable: [String] = []
    ) {
        self.order = order
        self.threshold = threshold
        self.runOutMinutes = runOutMinutes
        self.moveOpenChats = moveOpenChats
        self.unavailable = unavailable
    }

    private enum CodingKeys: String, CodingKey {
        case version, order, threshold, runOutMinutes, moveOpenChats, unavailable
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        order = try c.decodeIfPresent([String].self, forKey: .order) ?? []
        threshold = try c.decodeIfPresent(Double.self, forKey: .threshold) ?? 90
        runOutMinutes = try c.decodeIfPresent(Double.self, forKey: .runOutMinutes) ?? 30
        moveOpenChats = try c.decodeIfPresent(Bool.self, forKey: .moveOpenChats) ?? true
        unavailable = try c.decodeIfPresent([String].self, forKey: .unavailable) ?? []
    }

    /// The accounts Auto may choose from, in preference order: listed, not marked unavailable,
    /// and with their config folder present.
    public func candidates(from profiles: [Profile]) -> [Profile] {
        var ordered = profiles
        if !order.isEmpty {
            let byID = Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, $0) })
            let listed = order.compactMap { byID[$0] }
            if !listed.isEmpty { ordered = listed }
        }
        return ordered.filter { p in
            guard !unavailable.contains(p.id) else { return false }
            guard let dir = p.configDir else { return true }
            var isDir: ObjCBool = false
            return FileManager.default.fileExists(atPath: dir, isDirectory: &isDir) && isDir.boolValue
        }
    }

    /// Every account in preference order, for display (including unavailable ones).
    public func ordered(_ profiles: [Profile]) -> [Profile] {
        guard !order.isEmpty else { return profiles }
        let rank = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
        return profiles.sorted { (rank[$0.id] ?? Int.max) < (rank[$1.id] ?? Int.max) }
    }

    /// True when the account should not take new work (or keep open chats) under this policy.
    public func isOutOfRoom(_ snapshot: UsageSnapshot?, now: Date = Date()) -> Bool {
        guard let snapshot else { return false }
        if snapshot.peakPercentage(at: now) >= threshold { return true }
        for w in snapshot.windows {
            if case .runsOut(let at, _) = PaceForecast.forecast(w, now: now)?.outlook,
                at.timeIntervalSince(now) <= runOutMinutes * 60
            {
                return true
            }
        }
        return false
    }

    /// The account Auto uses right now. `preferring` (the account that already holds a resumed
    /// conversation) wins while it still has room, so a chat does not hop back and forth. Nil
    /// only when no account is usable.
    public func choose(
        profiles: [Profile], snapshots: [String: UsageSnapshot], now: Date = Date(), preferring: String? = nil
    ) -> Profile? {
        let candidates = candidates(from: profiles)
        if let preferring, let p = candidates.first(where: { $0.id == preferring }),
            !isOutOfRoom(snapshots[p.id], now: now)
        {
            return p
        }
        if let roomy = candidates.first(where: { !isOutOfRoom(snapshots[$0.id], now: now) }) { return roomy }
        return candidates.min {
            (snapshots[$0.id]?.peakPercentage(at: now) ?? 0) < (snapshots[$1.id]?.peakPercentage(at: now) ?? 0)
        }
    }
}

public enum AutoPolicyLoad: Equatable {
    case loaded(AutoPolicy)
    case corrupt(String)
    case insecure(String)
}

/// The only reader and writer of `auto.json`. A missing file means the default policy.
public struct AutoPolicyStore {
    private let env: SBEnvironment

    public init(env: SBEnvironment) {
        self.env = env
    }

    public func load() -> AutoPolicyLoad {
        let url = env.paths.autoPolicyFile
        guard FileManager.default.fileExists(atPath: url.path) else { return .loaded(AutoPolicy()) }
        if let problem = SafeFS.trustProblem(url, name: "auto.json") { return .insecure(problem) }
        do {
            let policy = try JSONDecoder().decode(AutoPolicy.self, from: Data(contentsOf: url))
            guard policy.version == 1 else { return .corrupt("unsupported version \(policy.version)") }
            guard policy.threshold > 0, policy.threshold <= 100, policy.runOutMinutes >= 0 else {
                return .corrupt("threshold out of range")
            }
            return .loaded(policy)
        } catch {
            return .corrupt(error.localizedDescription)
        }
    }

    /// For display and editing: the stored policy, or the default when it cannot be read.
    public func current() -> AutoPolicy {
        if case .loaded(let p) = load() { return p }
        return AutoPolicy()
    }

    public func save(_ policy: AutoPolicy) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try SafeFS.ensureDir(env.paths.root)
        try SafeFS.withLock(root: env.paths.root) {
            try SafeFS.writeAtomic(try encoder.encode(policy), to: env.paths.autoPolicyFile)
        }
    }
}
