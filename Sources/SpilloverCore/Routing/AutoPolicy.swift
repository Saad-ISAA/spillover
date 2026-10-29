import Foundation

/// How folders assigned to **Auto** pick an account.
///
/// An Auto folder keeps the account it is on until that account is full (its fullest limit at
/// `threshold` percent), so its window does not switch accounts back and forth. When it needs a
/// new one, the account with the most room is used: of the accounts with room, the one whose
/// fullest limit (session or week) is lowest, with `order` breaking ties. An account has room while
/// it is not full and no window is forecast to run out within `runOutMinutes`. When none has room,
/// the least used one is taken (work continues rather than being refused). Open chats move only when
/// their account is full, at their next idle moment, when `moveOpenChats` is on; a chat with
/// background work running waits for it unless its account is nearly out (`isNearlyOut`).
public struct AutoPolicy: Codable, Equatable, Sendable {
    public var version = 1
    /// Account ids in order of preference, used to break ties between accounts with equal room.
    /// Empty means every account, in registry order.
    public var order: [String] = []
    public var threshold: Double = 90
    public var runOutMinutes: Double = 30
    public var moveOpenChats = true
    /// Accounts Auto must not use right now (kept up to date by the app: not logged in).
    public var unavailable: [String] = []
    /// Send "please resume all work" to a chat in its own panel when it can continue: after a move
    /// that stopped its background work, and once a limit it stopped on has reset. Applies to every
    /// folder. Off until the user turns it on (it needs the Accessibility permission).
    public var resumeChats = false

    public init(
        order: [String] = [], threshold: Double = 90, runOutMinutes: Double = 30, moveOpenChats: Bool = true,
        unavailable: [String] = [], resumeChats: Bool = false
    ) {
        self.order = order
        self.threshold = threshold
        self.runOutMinutes = runOutMinutes
        self.moveOpenChats = moveOpenChats
        self.unavailable = unavailable
        self.resumeChats = resumeChats
    }

    private enum CodingKeys: String, CodingKey {
        case version, order, threshold, runOutMinutes, moveOpenChats, unavailable, resumeChats
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        order = try c.decodeIfPresent([String].self, forKey: .order) ?? []
        threshold = try c.decodeIfPresent(Double.self, forKey: .threshold) ?? 90
        runOutMinutes = try c.decodeIfPresent(Double.self, forKey: .runOutMinutes) ?? 30
        moveOpenChats = try c.decodeIfPresent(Bool.self, forKey: .moveOpenChats) ?? true
        unavailable = try c.decodeIfPresent([String].self, forKey: .unavailable) ?? []
        resumeChats = try c.decodeIfPresent(Bool.self, forKey: .resumeChats) ?? false
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

    /// True when the account has reached the threshold on a limit: Auto leaves it, and open chats
    /// on it move.
    public func isFull(_ snapshot: UsageSnapshot?, now: Date = Date()) -> Bool {
        guard let snapshot else { return false }
        return snapshot.peakPercentage(at: now) >= threshold
    }

    /// True when the account should not be picked for new work: full, or forecast to run out soon.
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

    /// Percentage, and minutes before a forecast run-out, at which an account counts as about to
    /// stop working.
    public static let nearlyOutPercentage: Double = 98
    public static let nearlyOutMinutes: Double = 10

    /// True when the account is about to stop working: nearly at a limit, or forecast to reach one
    /// within minutes. Only then does Auto end a chat whose background work is still running;
    /// below that the chat waits for its work, since ending it stops that work (at that point the
    /// limit would stop it anyway).
    public func isNearlyOut(_ snapshot: UsageSnapshot?, now: Date = Date()) -> Bool {
        guard let snapshot else { return false }
        if snapshot.peakPercentage(at: now) >= Self.nearlyOutPercentage { return true }
        for w in snapshot.windows {
            if case .runsOut(let at, _) = PaceForecast.forecast(w, now: now)?.outlook,
                at.timeIntervalSince(now) <= Self.nearlyOutMinutes * 60
            {
                return true
            }
        }
        return false
    }

    /// The account Auto uses right now. `preferring` (the account that already holds a resumed
    /// conversation) is kept until it is full, then `current` (the folder's account so far), so
    /// neither a chat nor a window hops back and forth. Nil only when no account is usable.
    public func choose(
        profiles: [Profile], snapshots: [String: UsageSnapshot], now: Date = Date(), preferring: String? = nil,
        current: String? = nil
    ) -> Profile? {
        let candidates = candidates(from: profiles)
        // A resumed chat stays on the account that holds it while that account is not full, even
        // when the folder has since moved on (moving it would copy its history and switch its
        // account for nothing). The folder's own account applies to new chats.
        if let preferring, let p = candidates.first(where: { $0.id == preferring }), !isFull(snapshots[p.id], now: now) {
            return p
        }
        if let current, let p = candidates.first(where: { $0.id == current }), !isFull(snapshots[p.id], now: now) {
            return p
        }
        // The most room first: the lowest fullest limit wins; `min` keeps the earlier account in
        // `order` on a tie. An account without a reading yet counts as unused.
        let used = { (p: Profile) in snapshots[p.id]?.peakPercentage(at: now) ?? 0 }
        let byRoom = { (a: Profile, b: Profile) in used(a) < used(b) }
        if let roomy = candidates.filter({ !isOutOfRoom(snapshots[$0.id], now: now) }).min(by: byRoom) { return roomy }
        if let notFull = candidates.filter({ !isFull(snapshots[$0.id], now: now) }).min(by: byRoom) { return notFull }
        return candidates.min(by: byRoom)
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

/// Which account each Auto folder is on, so every launch in the folder (a new chat, a resumed one,
/// the editor's own account check) agrees until that account is full. Advisory: an unreadable or
/// untrusted file is ignored and rebuilt, never a reason to refuse a launch.
public struct AutoChoices {
    private struct File: Codable {
        var version = 1
        /// Assigned folder (as in routes) -> profile id.
        var folders: [String: String] = [:]
    }

    private let env: SBEnvironment

    public init(env: SBEnvironment) {
        self.env = env
    }

    public func current(folder: String) -> String? {
        load().folders[folder]
    }

    /// Records the folder's account when it changed. Failures are ignored (the choice is redone).
    public func record(folder: String, profileId: String) {
        guard current(folder: folder) != profileId else { return }
        try? SafeFS.ensureDir(env.paths.root)
        try? SafeFS.withLock(root: env.paths.root) {
            var file = load()
            file.folders[folder] = profileId
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try SafeFS.writeAtomic(try encoder.encode(file), to: env.paths.autoChoicesFile)
        }
    }

    private func load() -> File {
        let url = env.paths.autoChoicesFile
        guard FileManager.default.fileExists(atPath: url.path), SafeFS.trustProblem(url, name: "auto-choices.json") == nil,
            let data = try? Data(contentsOf: url), let file = try? JSONDecoder().decode(File.self, from: data),
            file.version == 1
        else { return File() }
        return file
    }
}
