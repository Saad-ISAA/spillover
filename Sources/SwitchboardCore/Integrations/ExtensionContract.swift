import Foundation

/// What Switchboard relies on from the installed Claude Code editor extension, checked at runtime
/// so an extension update that changes the contract is reported instead of failing silently.
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

    /// Inspect the newest `anthropic.claude-code-*` in the given extensions directory.
    public static func check(extensionsDir: URL) -> ExtensionContract {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: extensionsDir.path) else {
            return ExtensionContract(extensionVersion: nil, finding: .extensionNotFound)
        }
        var best: (version: [Int], name: String)?
        for name in names where name.hasPrefix("anthropic.claude-code-") {
            let v = RealClaudeLocator.parseVersion(name)
            if best == nil || RealClaudeLocator.isNewer(v, than: best!.version) { best = (v, name) }
        }
        guard let chosen = best else {
            return ExtensionContract(extensionVersion: nil, finding: .extensionNotFound)
        }
        let version = chosen.version.map(String.init).joined(separator: ".")
        let manifest = extensionsDir.appendingPathComponent(chosen.name).appendingPathComponent("package.json")
        guard let data = try? Data(contentsOf: manifest),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return ExtensionContract(extensionVersion: version, finding: .wrapperSettingMissing) }
        return ExtensionContract(extensionVersion: version, finding: evaluate(packageJSON: json))
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
}
