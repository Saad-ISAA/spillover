import Foundation

/// What Switchboard relies on from the installed Claude Code editor extension, checked at runtime
/// so an extension update that changes the contract is reported instead of failing silently:
///
/// - `claudeCode.claudeProcessWrapper` exists and is machine-scoped (routing the panel);
/// - the extension reopens a conversation from `<scheme>://anthropic.claude-code/open?session=<id>`
///   (moving an open chat to another account);
/// - chats run as `claude --resume=<id>` (checked on running sessions by the app).
public struct ExtensionContract: Equatable, Sendable {
    public enum Finding: Equatable, Sendable {
        case ok
        case extensionNotFound
        /// The wrapper setting no longer exists: routing the editor panel cannot work.
        case wrapperSettingMissing
        /// Scope changed (e.g. became workspace-level). Still works from user settings; noted.
        case wrapperScopeChanged(String)
    }

    public let extensionVersion: String?
    public let finding: Finding
    /// False when this version no longer handles the reopen link: open chats cannot be moved
    /// (new chats still start on the folder's account).
    public let reopensChats: Bool

    public init(extensionVersion: String?, finding: Finding, reopensChats: Bool) {
        self.extensionVersion = extensionVersion
        self.finding = finding
        self.reopensChats = reopensChats
    }

    public static func check(editor: Editor, env: SBEnvironment) -> ExtensionContract {
        check(extensionsDir: env.home.appendingPathComponent("\(editor.extensionsDirectoryName)/extensions", isDirectory: true))
    }

    /// Inspect the newest `anthropic.claude-code-*` in the given extensions directory that the
    /// editor has not marked obsolete.
    public static func check(extensionsDir: URL) -> ExtensionContract {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: extensionsDir.path) else {
            return ExtensionContract(extensionVersion: nil, finding: .extensionNotFound, reopensChats: false)
        }
        let obsolete = RealClaudeLocator.obsoleteNames(extensionsDir)
        var best: (version: [Int], name: String)?
        for name in names where name.hasPrefix("anthropic.claude-code-") && !obsolete.contains(name) {
            let v = RealClaudeLocator.parseVersion(name)
            if best == nil || RealClaudeLocator.isNewer(v, than: best!.version) { best = (v, name) }
        }
        guard let chosen = best else {
            return ExtensionContract(extensionVersion: nil, finding: .extensionNotFound, reopensChats: false)
        }
        let version = chosen.version.map(String.init).joined(separator: ".")
        let folder = extensionsDir.appendingPathComponent(chosen.name)
        let reopens = reopenLinkSupported(extensionFolder: folder)
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("package.json")),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return ExtensionContract(extensionVersion: version, finding: .wrapperSettingMissing, reopensChats: reopens) }
        return ExtensionContract(extensionVersion: version, finding: evaluate(packageJSON: json), reopensChats: reopens)
    }

    static func evaluate(packageJSON json: [String: Any]) -> Finding {
        guard let contributes = json["contributes"] as? [String: Any] else { return .wrapperSettingMissing }
        var sections: [[String: Any]] = []
        if let one = contributes["configuration"] as? [String: Any] { sections = [one] }
        if let many = contributes["configuration"] as? [[String: Any]] { sections = many }
        for section in sections {
            guard let props = section["properties"] as? [String: Any],
                let wrapper = props[VSCodeInstaller.wrapperKey] as? [String: Any]
            else { continue }
            let scope = (wrapper["scope"] as? String) ?? "window"
            return scope == "machine" ? .ok : .wrapperScopeChanged(scope)
        }
        return .wrapperSettingMissing
    }

    // MARK: Reopen link

    nonisolated(unsafe) private static var reopenCache: [String: Bool] = [:]
    private static let cacheLock = NSLock()

    /// True when the extension's code handles the `/open` link with a `session` parameter.
    /// The bundle is a few megabytes, so the answer is cached per extension folder.
    static func reopenLinkSupported(extensionFolder: URL) -> Bool {
        let key = extensionFolder.path
        cacheLock.lock()
        if let cached = reopenCache[key] {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()
        let answer = (try? Data(contentsOf: extensionFolder.appendingPathComponent("extension.js"), options: .mappedIfSafe))
            .map(handlesReopenLink) ?? false
        cacheLock.lock()
        reopenCache[key] = answer
        cacheLock.unlock()
        return answer
    }

    /// Pure check on the extension's code (tested): a URI handler with an `/open` route that
    /// reads a `session` parameter.
    static func handlesReopenLink(_ code: Data) -> Bool {
        code.range(of: Data("registerUriHandler".utf8)) != nil
            && code.range(of: Data("\"/open\"".utf8)) != nil
            && code.range(of: Data("get(\"session\")".utf8)) != nil
    }
}
