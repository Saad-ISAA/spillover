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

    /// URL scheme the editor registers (`vscode://...`).
    public var urlScheme: String {
        switch self {
        case .code: return "vscode"
        case .insiders: return "vscode-insiders"
        case .vscodium: return "vscodium"
        case .cursor: return "cursor"
        case .windsurf: return "windsurf"
        }
    }

    /// Folder under the home directory where the editor keeps its extensions.
    var extensionsDirectoryName: String {
        switch self {
        case .code: return ".vscode"
        case .insiders: return ".vscode-insiders"
        case .vscodium: return ".vscode-oss"
        case .cursor: return ".cursor"
        case .windsurf: return ".windsurf"
        }
    }

    /// The Claude extension's link that reopens a conversation in this editor.
    public func claudeSessionURL(_ conversationId: String) -> URL? {
        guard let id = ConversationID.valid(conversationId) else { return nil }
        return URL(string: "\(urlScheme)://anthropic.claude-code/open?session=\(id)")
    }

    /// Which editor bundled the Claude binary at `executable` (its extensions folder is in the path).
    public static func hosting(executable: String) -> Editor? {
        guard executable.contains("/anthropic.claude-code") else { return nil }
        // Longest folder name first: ".vscode-insiders" before ".vscode".
        return allCases.sorted { $0.extensionsDirectoryName.count > $1.extensionsDirectoryName.count }
            .first { executable.contains("/\($0.extensionsDirectoryName)/extensions/") }
    }

    /// The editor whose app bundle contains `appExecutable` (e.g. its extension host helper).
    public static func owning(appExecutable: String) -> Editor? {
        allCases.first { appExecutable.contains("/\($0.applicationName).app/") }
    }

    /// Editors that have been run on this machine (their user settings directory exists).
    public static func installed(env: SBEnvironment) -> [Editor] {
        allCases.filter {
            FileManager.default.fileExists(atPath: $0.userDirectory(env: env).path)
        }
    }
}
