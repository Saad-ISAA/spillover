import Foundation

/// Reads an account's plan limits the way Claude Code's `/usage` does, without sending a message.
///
/// `claude -p /usage` is a local command: it makes no model request (zero turns, zero tokens). The
/// CLI asks Anthropic for the account's usage with its own login and caches the answer in the
/// account's state file (`.claude.json`, key `cachedUsageUtilization`). Spillover then reads only
/// that cache's percentages and reset times; login data never passes through Spillover.
public struct AccountUsageFetcher {
    public static let cacheKey = "cachedUsageUtilization"

    private let env: SBEnvironment
    private let runner: CommandRunning

    public init(env: SBEnvironment, runner: CommandRunning = SystemCommandRunner()) {
        self.env = env
        self.runner = runner
    }

    /// Asks the CLI to refresh the account's usage, then records it. Returns the snapshot, or nil
    /// when the account has no usage to report (not logged in, API key accounts, CLI missing).
    @discardableResult
    public func refresh(_ profile: Profile) -> UsageSnapshot? {
        if let claude = ClaudeCLI(env: env, runner: runner).claudePath() {
            // A private working folder, and no saved session, so the check leaves no history.
            let folder = env.paths.tmpDir.appendingPathComponent("usage-check", isDirectory: true)
            try? SafeFS.ensureDir(env.paths.tmpDir)
            try? SafeFS.ensureDir(folder)
            _ = runner.run(
                claude, ["-p", "/usage", "--output-format", "json", "--no-session-persistence"],
                env: ProfileEnvironment.apply(profile, to: env.processEnv), timeout: 45, stdin: nil,
                directory: folder)
        }
        guard let snapshot = cached(profile) else { return nil }
        return record(snapshot) ? snapshot : UsageStore(env: env).load(profileId: profile.id)
    }

    /// Picks up usage Claude saved for the account since Spillover last looked (the editor's usage
    /// panel, a `/usage` in a chat, another check), without running anything. True when a newer
    /// reading was recorded.
    @discardableResult
    public func follow(_ profile: Profile) -> Bool {
        guard let snapshot = cached(profile) else { return false }
        return record(snapshot)
    }

    /// Keeps the newer reading: one from a chat (statusline) can be newer than Claude's cache.
    private func record(_ snapshot: UsageSnapshot) -> Bool {
        let store = UsageStore(env: env)
        if let current = store.load(profileId: snapshot.profileId), current.capturedAt >= snapshot.capturedAt {
            return false
        }
        try? store.save(snapshot)
        try? UsageHistory(env: env).record(snapshot)
        return true
    }

    /// The account's state file: `<config dir>/.claude.json`, or `~/.claude.json` for Default.
    public func stateFile(for profile: Profile) -> URL {
        if let dir = profile.configDir {
            return URL(fileURLWithPath: dir).appendingPathComponent(".claude.json")
        }
        return env.home.appendingPathComponent(".claude.json")
    }

    /// The usage the CLI last cached for this account, without running anything.
    public func cached(_ profile: Profile) -> UsageSnapshot? {
        guard let data = try? Data(contentsOf: stateFile(for: profile)) else { return nil }
        return Self.parse(stateFile: data, profileId: profile.id)
    }

    /// Only the usage cache is read from the state file; nothing else in it is kept.
    public static func parse(stateFile data: Data, profileId: String) -> UsageSnapshot? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let cache = root[cacheKey] as? [String: Any],
            let fetchedMs = (cache["fetchedAtMs"] as? NSNumber)?.doubleValue,
            let utilization = cache["utilization"] as? [String: Any]
        else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        var windows: [UsageWindow] = []
        for kind in [UsageWindow.Kind.fiveHour, .sevenDay] {
            guard let w = utilization[kind.rawValue] as? [String: Any],
                let used = (w["utilization"] as? NSNumber)?.doubleValue,
                let resets = w["resets_at"] as? String,
                let resetsAt = iso.date(from: resets) ?? plain.date(from: resets)
            else { continue }
            windows.append(UsageWindow(kind: kind, usedPercentage: used, resetsAt: resetsAt))
        }
        guard !windows.isEmpty else { return nil }
        return UsageSnapshot(
            profileId: profileId, capturedAt: Date(timeIntervalSince1970: fetchedMs / 1000), windows: windows)
    }
}
