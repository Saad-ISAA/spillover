import Foundation

/// Which tool a profile belongs to. Provider-neutral on purpose: Codex, Qwen and others add a
/// case and an adapter; the registry and resolver never change.
public enum Provider: String, Codable, Sendable, CaseIterable {
    case claude
}

/// One subscription/account as an isolated config directory.
///
/// `configDir == nil` is the built-in **Default** profile: it means "launch with CLAUDE_CONFIG_DIR
/// UNSET" (Claude's own `~/.claude` and unsuffixed Keychain item). It must never be represented as
/// a variable pointing at `~/.claude`: Claude Code hashes the Keychain service name from a set
/// variable, so an explicit default path reads a different (empty) slot.
public struct Profile: Codable, Equatable, Hashable, Identifiable, Sendable {
    public static let defaultID = "default"

    public var id: String
    public var displayName: String
    public var provider: Provider
    public var configDir: String?
    public var createdAt: Date

    public var isDefault: Bool { configDir == nil }

    public init(
        id: String, displayName: String, provider: Provider = .claude, configDir: String?,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.displayName = displayName
        self.provider = provider
        self.configDir = configDir
        self.createdAt = createdAt
    }

    public static func builtInDefault() -> Profile {
        Profile(
            id: defaultID, displayName: "Default", provider: .claude, configDir: nil,
            createdAt: Date(timeIntervalSince1970: 0))
    }
}

public enum ProfileError: Error, LocalizedError, Equatable {
    case invalidName
    case invalidID(String)
    case reservedID(String)
    case notFound(String)
    case directoryMissing(String)
    case directoryIsDefault(String)
    case directoryAlreadyUsed(String, by: String)
    case notAbsolute(String)
    case cannotRemoveDefault
    case registryCorrupt(String)
    case unsupportedRegistryVersion(Int)

    public var errorDescription: String? {
        switch self {
        case .invalidName: return "Profile name is empty."
        case .invalidID(let id): return "Invalid profile id '\(id)' (use a-z, 0-9 and '-')."
        case .reservedID(let id): return "'\(id)' is reserved."
        case .notFound(let id): return "No profile '\(id)'."
        case .directoryMissing(let p): return "Directory does not exist: \(p)"
        case .directoryIsDefault(let p):
            return "\(p) is Claude's default directory; use the built-in Default profile instead."
        case .directoryAlreadyUsed(let p, let by): return "\(p) is already profile '\(by)'."
        case .notAbsolute(let p): return "Path must be absolute: \(p)"
        case .cannotRemoveDefault: return "The Default profile cannot be removed."
        case .registryCorrupt(let why): return "profiles.json is unreadable: \(why)"
        case .unsupportedRegistryVersion(let v): return "profiles.json version \(v) is not supported."
        }
    }
}

public enum ProfileID {
    /// Lowercase slug: `[a-z0-9][a-z0-9-]{0,39}`. Doubles as a directory name, so it must never
    /// contain separators or dots (no path traversal through a profile id).
    public static func isValid(_ id: String) -> Bool {
        guard !id.isEmpty, id.count <= 40 else { return false }
        let scalars = Array(id.unicodeScalars)
        func ok(_ s: Unicode.Scalar, first: Bool) -> Bool {
            let alnum = (s.value >= 97 && s.value <= 122) || (s.value >= 48 && s.value <= 57)
            return alnum || (!first && s == "-")
        }
        for (i, s) in scalars.enumerated() where !ok(s, first: i == 0) { return false }
        return true
    }

    public static func slug(from name: String) -> String {
        var out = ""
        var lastDash = true
        for ch in name.lowercased() {
            if let a = ch.asciiValue, (a >= 97 && a <= 122) || (a >= 48 && a <= 57) {
                out.append(ch)
                lastDash = false
            } else if !lastDash {
                out.append("-")
                lastDash = true
            }
        }
        while out.hasSuffix("-") { out.removeLast() }
        if out.isEmpty { out = "profile" }
        return String(out.prefix(36))
    }
}
