import Foundation

/// The ONE place in the codebase that reads the process environment and resolves well-known
/// locations (the config module). Everything else receives an `SBEnvironment` by value, which is
/// what makes every other module testable against temp directories.
/// Enforcement: ArchitectureTests.testOnlyConfigReadsProcessEnvironment.
public struct SBEnvironment: Sendable {
    /// The user's home directory (`$HOME`).
    public var home: URL
    /// Switchboard's own state root. Default `~/.switchboard`, override with `SWITCHBOARD_HOME`.
    public var appRoot: URL
    /// `~/Library/Application Support` (VS Code family user dirs live below it).
    public var appSupport: URL
    /// Snapshot of the process environment, used as the base when building a launch environment.
    public var processEnv: [String: String]
    /// macOS volumes are case-insensitive by default; path comparison follows this flag.
    public var caseInsensitivePaths: Bool

    public init(
        home: URL,
        appRoot: URL? = nil,
        appSupport: URL? = nil,
        processEnv: [String: String] = [:],
        caseInsensitivePaths: Bool = true
    ) {
        self.home = home
        self.appRoot = appRoot ?? home.appendingPathComponent(".switchboard", isDirectory: true)
        self.appSupport = appSupport
            ?? home.appendingPathComponent("Library/Application Support", isDirectory: true)
        self.processEnv = processEnv
        self.caseInsensitivePaths = caseInsensitivePaths
    }

    /// Build the environment from the real process. Only called from executables' entry points.
    public static func live() -> SBEnvironment {
        let env = ProcessInfo.processInfo.environment
        let home = URL(fileURLWithPath: env["HOME"] ?? NSHomeDirectory(), isDirectory: true)
        var root: URL?
        if let override = env["SWITCHBOARD_HOME"], override.hasPrefix("/") {
            root = URL(fileURLWithPath: override, isDirectory: true)
        }
        // Case sensitivity follows the volume that holds the home folder (APFS can be either).
        let values = try? home.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
        let caseSensitive = values?.volumeSupportsCaseSensitiveNames ?? false
        return SBEnvironment(
            home: home, appRoot: root, processEnv: env, caseInsensitivePaths: !caseSensitive)
    }

    public var paths: SBPaths { SBPaths(env: self) }
}

/// Every location Switchboard reads or writes, derived from one root. Nothing else builds these paths.
public struct SBPaths: Sendable {
    let env: SBEnvironment

    public var root: URL { env.appRoot }
    public var profilesFile: URL { root.appendingPathComponent("profiles.json") }
    public var routesFile: URL { root.appendingPathComponent("routes.json") }
    /// Where isolated Claude config dirs are created by default.
    public var profilesDir: URL { root.appendingPathComponent("profiles", isDirectory: true) }
    public var binDir: URL { root.appendingPathComponent("bin", isDirectory: true) }
    /// The launcher binary VS Code (and the shell shim) execs.
    public var launcher: URL { binDir.appendingPathComponent("switchboard-launch") }
    public var shimsDir: URL { root.appendingPathComponent("shims", isDirectory: true) }
    public var logsDir: URL { root.appendingPathComponent("logs", isDirectory: true) }
    public var launchLog: URL { logsDir.appendingPathComponent("launch.log") }
    public var backupsDir: URL { root.appendingPathComponent("backups", isDirectory: true) }
    public var installManifest: URL { root.appendingPathComponent("install-manifest.json") }
    public var usageDir: URL { root.appendingPathComponent("usage", isDirectory: true) }
    public var autoPolicyFile: URL { root.appendingPathComponent("auto.json") }
    public var tmpDir: URL { root.appendingPathComponent("tmp", isDirectory: true) }

    /// The default Claude Code config dir (`~/.claude`). It is the "Default" profile.
    public var defaultClaudeDir: URL { env.home.appendingPathComponent(".claude", isDirectory: true) }
    /// Where the prototype stored its profiles and routes (`~/.aibar`), for one-shot import.
    public var prototypeRoot: URL { env.home.appendingPathComponent(".aibar", isDirectory: true) }
}
