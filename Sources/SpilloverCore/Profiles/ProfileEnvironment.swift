import Foundation

/// The single place that decides how a profile changes the environment of a Claude process.
/// The launcher, the CLI, status checks and the login helper all use this; nothing else touches
/// `CLAUDE_CONFIG_DIR`.
public enum ProfileEnvironment {
    public static let configDirKey = "CLAUDE_CONFIG_DIR"
    /// Set on every routed launch so tools (and statuslines) can see which profile is active.
    public static let profileKey = "SPILLOVER_PROFILE"

    /// Isolated profile -> variable set to its directory. Default profile -> variable REMOVED
    /// (never set to `~/.claude`: that would select a different Keychain item).
    public static func apply(_ profile: Profile, to base: [String: String]) -> [String: String] {
        var env = base
        if let dir = profile.configDir {
            env[configDirKey] = dir
        } else {
            env.removeValue(forKey: configDirKey)
        }
        env[profileKey] = profile.id
        return env
    }
}
