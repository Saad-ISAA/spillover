import Foundation

public enum StatuslineError: Error, LocalizedError, Equatable {
    case cliMissing
    case settingsUnreadable(String)

    public var errorDescription: String? {
        switch self {
        case .cliMissing: return "The switchboard CLI is not installed yet (run `switchboard install`)."
        case .settingsUnreadable(let why): return "Cannot edit the profile's settings.json: \(why)"
        }
    }
}

/// Connects a profile's Claude Code `statusLine` to `switchboard statusline`, remembering the
/// user's original statusline so it keeps working (chained) and can be restored exactly.
public struct StatuslineInstaller {
    public static let key = "statusLine"

    private struct Chain: Codable {
        var version = 1
        /// profileId -> original raw JSON value of `statusLine` (absent key = not recorded)
        var originals: [String: String] = [:]
    }

    private let env: SBEnvironment

    public init(env: SBEnvironment) {
        self.env = env
    }

    private var chainFile: URL { env.paths.usageDir.appendingPathComponent("statusline-chain.json") }
    private var cliPath: String { env.paths.binDir.appendingPathComponent("switchboard").path }

    /// The command string written into settings.json.
    public var commandString: String { "\(ShellQuote.quote(cliPath)) statusline" }

    /// settings.json of a profile, following a shared symlink to the real file so sharing survives.
    func settingsURL(for profile: Profile) -> URL {
        let dir = profile.configDir ?? env.paths.defaultClaudeDir.path
        let url = URL(fileURLWithPath: dir).appendingPathComponent("settings.json")
        if let dest = try? FileManager.default.destinationOfSymbolicLink(atPath: url.path) {
            return URL(fileURLWithPath: dest, relativeTo: url.deletingLastPathComponent()).standardized
        }
        return url
    }

    public func isInstalled(for profile: Profile) -> Bool {
        guard let text = try? String(contentsOf: settingsURL(for: profile), encoding: .utf8),
            let doc = try? JSONCDocument(text)
        else { return false }
        return Self.command(inRaw: doc.rawValue(forKey: Self.key)) == commandString
    }

    /// `command` field of a raw `statusLine` JSON object.
    static func command(inRaw raw: String?) -> String? {
        guard let raw, let data = raw.data(using: .utf8),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return obj["command"] as? String
    }

    public func install(for profile: Profile) throws {
        guard FileManager.default.isExecutableFile(atPath: cliPath) else { throw StatuslineError.cliMissing }
        if isInstalled(for: profile) { return }
        let url = settingsURL(for: profile)
        let existed = FileManager.default.fileExists(atPath: url.path)
        let text = existed ? ((try? String(contentsOf: url, encoding: .utf8)) ?? "") : "{}\n"
        let doc: JSONCDocument
        do { doc = try JSONCDocument(text) } catch {
            throw StatuslineError.settingsUnreadable(error.localizedDescription)
        }
        var chain = loadChain()
        if let original = doc.rawValue(forKey: Self.key) {
            chain.originals[profile.id] = original
        } else {
            chain.originals.removeValue(forKey: profile.id)
        }
        try saveChain(chain)
        let value = "{\"type\": \"command\", \"command\": \(JSONCDocument.quote(commandString)), \"padding\": 0}"
        let updated = doc.settingRaw(value, forKey: Self.key)
        try SafeFS.ensureDir(url.deletingLastPathComponent())
        try SafeFS.writeAtomic(Data(updated.utf8), to: url, mode: existed ? nil : SafeFS.fileMode)
    }

    public func uninstall(for profile: Profile) throws {
        let url = settingsURL(for: profile)
        guard let text = try? String(contentsOf: url, encoding: .utf8), let doc = try? JSONCDocument(text),
            isInstalled(for: profile)
        else { return }
        var chain = loadChain()
        let updated: String
        if let original = chain.originals[profile.id] {
            updated = doc.settingRaw(original, forKey: Self.key)
        } else {
            updated = doc.removing(key: Self.key)
        }
        try SafeFS.writeAtomic(Data(updated.utf8), to: url, mode: nil)
        chain.originals.removeValue(forKey: profile.id)
        try saveChain(chain)
    }

    /// The user's original statusline command for this profile, if it was a command.
    public func chainedCommand(profileId: String) -> String? {
        guard let command = Self.command(inRaw: loadChain().originals[profileId]), !command.isEmpty,
            command != commandString
        else { return nil }
        return command
    }

    private func loadChain() -> Chain {
        guard let data = try? Data(contentsOf: chainFile),
            let chain = try? JSONDecoder().decode(Chain.self, from: data)
        else { return Chain() }
        return chain
    }

    private func saveChain(_ chain: Chain) throws {
        try SafeFS.ensureDir(env.paths.root)
        try SafeFS.ensureDir(env.paths.usageDir)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try SafeFS.writeAtomic(try encoder.encode(chain), to: chainFile)
    }
}
