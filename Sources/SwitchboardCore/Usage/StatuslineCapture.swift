import Foundation

/// Captures usage from Claude Code's statusline feed.
///
/// Claude Code runs the configured `statusLine` command with a JSON document on stdin. For
/// subscribers that document carries `rate_limits.five_hour` / `seven_day` (`used_percentage`,
/// `resets_at` in epoch seconds). `switchboard statusline` is installed as that command: it stores
/// the limits for the active profile, then either runs the user's original statusline command with
/// the same input (so their statusline is unchanged) or prints a compact line of its own.
public struct StatuslineCapture {
    private let env: SBEnvironment
    private let runner: CommandRunning

    public init(env: SBEnvironment, runner: CommandRunning = SystemCommandRunner()) {
        self.env = env
        self.runner = runner
    }

    /// Parse the statusline input. Returns nil when there is no usable JSON.
    public static func parse(_ data: Data, profileId: String, now: Date = Date()) -> UsageSnapshot? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var windows: [UsageWindow] = []
        if let limits = root["rate_limits"] as? [String: Any] {
            for kind in UsageWindow.Kind.allCases {
                guard let w = limits[kind.rawValue] as? [String: Any],
                    let used = (w["used_percentage"] as? NSNumber)?.doubleValue,
                    let resets = (w["resets_at"] as? NSNumber)?.doubleValue
                else { continue }
                windows.append(
                    UsageWindow(
                        kind: kind, usedPercentage: used, resetsAt: Date(timeIntervalSince1970: resets)))
            }
        }
        var model: String?
        if let m = root["model"] as? [String: Any] {
            model = (m["display_name"] as? String) ?? (m["id"] as? String)
        }
        return UsageSnapshot(profileId: profileId, capturedAt: now, windows: windows, model: model)
    }

    /// Which profile this Claude process is really running on, decided by its config directory
    /// (the launcher's SWITCHBOARD_PROFILE marker can be inherited by unrouted launches, so it is
    /// not trusted on its own). Nil when the directory belongs to no known profile.
    public func activeProfileID(processEnv: [String: String]) -> String? {
        let store = ProfileStore(env: env)
        let profiles = (try? store.all()) ?? [Profile.builtInDefault()]
        guard let dir = processEnv[ProfileEnvironment.configDirKey], !dir.isEmpty else {
            return Profile.defaultID
        }
        let key = PathNormalizer.normalize(dir, caseInsensitive: env.caseInsensitivePaths)?.key
        return profiles.first { p in
            guard let pd = p.configDir else { return false }
            return PathNormalizer.normalize(pd, caseInsensitive: env.caseInsensitivePaths)?.key == key
        }?.id
    }

    /// Full statusline run: capture, then produce the line to print.
    public func handle(input: Data, processEnv: [String: String]) -> String {
        guard let profileId = activeProfileID(processEnv: processEnv) else {
            // Unknown account: record nothing rather than attribute usage to the wrong profile.
            return "Claude"
        }
        let snapshot = Self.parse(input, profileId: profileId)
        if let snapshot, !snapshot.windows.isEmpty {
            try? UsageStore(env: env).save(snapshot)
            try? UsageHistory(env: env).record(snapshot)
        }
        if let chained = StatuslineInstaller(env: env).chainedCommand(profileId: profileId) {
            let result = runner.run(
                "/bin/sh", ["-c", chained], env: processEnv, timeout: 5, stdin: input)
            return result.stdout.trimmingCharacters(in: .newlines)
        }
        return Self.render(snapshot: snapshot, profileName: profileName(profileId))
    }

    public static func render(snapshot: UsageSnapshot?, profileName: String, now: Date = Date()) -> String {
        var parts = [profileName]
        if let snapshot {
            for w in snapshot.windows where w.kind != .spendLimit {
                parts.append("\(w.kind.shortLabel) \(Int(w.effectivePercentage(at: now).rounded()))%")
            }
        }
        return parts.joined(separator: " · ")
    }

    private func profileName(_ id: String) -> String {
        ((try? ProfileStore(env: env).profile(id: id)) ?? nil)?.displayName ?? id
    }
}
