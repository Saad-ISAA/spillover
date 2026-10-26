import Foundation

/// Lets an isolated profile reuse configuration from another profile (usually Default) through
/// symlinks, while credentials, history and sessions always stay separate.
public struct ProfileSharing {
    /// Items that may be shared. Anything else is refused.
    public static let shareable: [String] = [
        "settings.json", "CLAUDE.md", "skills", "agents", "commands", "hooks", "plugins",
        "output-styles", "keybindings.json",
    ]

    /// Items that must never be linked between accounts: account identity, credentials,
    /// conversation history and per-session state. Checked even if `shareable` grows.
    public static let neverShare: Set<String> = [
        ".claude.json", ".credentials.json", "projects", "sessions", "history.jsonl", "todos",
        "shell-snapshots", "session-env", "file-history", "statsig", "ide", "backups",
        "paste-cache", "debug", "security", "policy-limits.json", "remote-settings.json",
    ]

    public enum ItemState: Equatable, Sendable {
        case absent
        case local
        case linked(to: String)
    }

    public enum ShareError: Error, Equatable, LocalizedError {
        case notShareable(String)
        case targetIsDefault
        case sameProfile
        case sourceMissing(String)
        case conflict(String)

        public var errorDescription: String? {
            switch self {
            case .notShareable(let i): return "'\(i)' cannot be shared between accounts."
            case .targetIsDefault: return "The Default profile cannot receive shared items."
            case .sameProfile: return "Source and target are the same profile."
            case .sourceMissing(let i): return "The source profile has no '\(i)'."
            case .conflict(let i):
                return "'\(i)' already exists in the target profile. Use replace to keep a backup and link."
            }
        }
    }

    private let env: SBEnvironment

    public init(env: SBEnvironment) {
        self.env = env
    }

    public static func isShareable(_ item: String) -> Bool {
        shareable.contains(item) && !neverShare.contains(item) && !item.contains("/")
            && !item.contains("..")
    }

    func directory(of profile: Profile) -> URL {
        URL(fileURLWithPath: profile.configDir ?? env.paths.defaultClaudeDir.path, isDirectory: true)
    }

    public func state(of item: String, in profile: Profile) -> ItemState {
        let url = directory(of: profile).appendingPathComponent(item)
        let fm = FileManager.default
        if let dest = try? fm.destinationOfSymbolicLink(atPath: url.path) { return .linked(to: dest) }
        return fm.fileExists(atPath: url.path) ? .local : .absent
    }

    /// Link `item` in `target` to the same item in `source`. With `replace`, an existing local
    /// item is renamed to `<item>.switchboard-backup-<timestamp>` first (never deleted).
    public func share(_ item: String, from source: Profile, to target: Profile, replace: Bool = false)
        throws
    {
        guard Self.isShareable(item) else { throw ShareError.notShareable(item) }
        guard !target.isDefault else { throw ShareError.targetIsDefault }
        guard source.id != target.id else { throw ShareError.sameProfile }
        let fm = FileManager.default
        let src = directory(of: source).appendingPathComponent(item)
        guard fm.fileExists(atPath: src.path) else { throw ShareError.sourceMissing(item) }
        let dst = directory(of: target).appendingPathComponent(item)

        switch state(of: item, in: target) {
        case .linked(let existing) where existing == src.path:
            return
        case .linked:
            try fm.removeItem(at: dst)
        case .local:
            guard replace else { throw ShareError.conflict(item) }
            let stamp = Int(Date().timeIntervalSince1970)
            try fm.moveItem(
                at: dst, to: dst.deletingLastPathComponent()
                    .appendingPathComponent("\(item).switchboard-backup-\(stamp)"))
        case .absent:
            break
        }
        try fm.createSymbolicLink(atPath: dst.path, withDestinationPath: src.path)
    }

    /// Remove a link (the source is untouched). Local items are left alone.
    public func unshare(_ item: String, in profile: Profile) throws {
        guard case .linked = state(of: item, in: profile) else { return }
        try FileManager.default.removeItem(at: directory(of: profile).appendingPathComponent(item))
    }
}
