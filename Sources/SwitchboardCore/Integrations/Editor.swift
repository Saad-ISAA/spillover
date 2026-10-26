import Foundation

/// VS Code family editors that can host the Claude Code extension.
public enum Editor: String, CaseIterable, Codable, Sendable {
    case code, insiders, vscodium, cursor, windsurf

    public var displayName: String {
        switch self {
        case .code: return "Visual Studio Code"
        case .insiders: return "Visual Studio Code - Insiders"
        case .vscodium: return "VSCodium"
        case .cursor: return "Cursor"
        case .windsurf: return "Windsurf"
        }
    }

    /// Folder under `~/Library/Application Support`.
    var supportDirectoryName: String {
        switch self {
        case .code: return "Code"
        case .insiders: return "Code - Insiders"
        case .vscodium: return "VSCodium"
        case .cursor: return "Cursor"
        case .windsurf: return "Windsurf"
        }
    }

    /// Application name for `open -a`.
    public var applicationName: String { displayName }

    public func userDirectory(env: SBEnvironment) -> URL {
        env.appSupport.appendingPathComponent(supportDirectoryName, isDirectory: true)
            .appendingPathComponent("User", isDirectory: true)
    }

    public func settingsFile(env: SBEnvironment) -> URL {
        userDirectory(env: env).appendingPathComponent("settings.json")
    }

    /// Editors that have been run on this machine (their user settings directory exists).
    public static func installed(env: SBEnvironment) -> [Editor] {
        allCases.filter {
            FileManager.default.fileExists(atPath: $0.userDirectory(env: env).path)
        }
    }
}
