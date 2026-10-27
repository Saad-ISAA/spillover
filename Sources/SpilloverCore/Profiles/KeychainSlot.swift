import CryptoKit
import Foundation

/// Which macOS Keychain item Claude Code uses for a given config directory.
///
/// Observed behaviour (Claude Code on macOS): the default directory uses the service
/// `Claude Code-credentials`; any other `CLAUDE_CONFIG_DIR` uses
/// `Claude Code-credentials-<first 8 hex of sha256(NFC path)>`. Spillover never copies or reads
/// these items; it only derives the name so it can check existence and spot orphans.
public enum KeychainSlot {
    public static let baseService = "Claude Code-credentials"

    /// `nil` (the Default profile, variable unset) maps to the unsuffixed service.
    public static func serviceName(forConfigDir dir: String?) -> String {
        guard let dir else { return baseService }
        let normalized = dir.precomposedStringWithCanonicalMapping
        let digest = SHA256.hash(data: Data(normalized.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "\(baseService)-\(hex.prefix(8))"
    }
}

/// Read-only Keychain existence checks. Never asks for item data: the `security` tool is invoked
/// without `-w`/`-g`, so no secret is read and no access prompt appears
/// (ArchitectureTests.testKeychainIsNeverReadForSecrets).
public struct KeychainProbe: Sendable {
    private let runner: CommandRunning
    private let securityTool: String

    public init(runner: CommandRunning = SystemCommandRunner(), securityTool: String = "/usr/bin/security") {
        self.runner = runner
        self.securityTool = securityTool
    }

    public func itemExists(service: String) -> Bool {
        runner.run(securityTool, ["find-generic-password", "-s", service], env: nil, timeout: 10)
            .succeeded
    }

    /// Every Claude Code credential service name present in the user's keychains (names only).
    public func claudeServices() -> [String] {
        let result = runner.run(securityTool, ["dump-keychain"], env: nil, timeout: 20)
        guard result.succeeded else { return [] }
        return Self.parseServices(dump: result.stdout)
    }

    /// Parse `"svce"<blob>="Claude Code-credentials-xxxx"` lines out of a keychain dump.
    public static func parseServices(dump: String) -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for line in dump.split(separator: "\n") where line.contains("\"svce\"") {
            guard let open = line.range(of: "=\""), let close = line.lastIndex(of: "\""),
                open.upperBound <= close
            else { continue }
            let name = String(line[open.upperBound..<close])
            if name.hasPrefix(KeychainSlot.baseService), seen.insert(name).inserted {
                ordered.append(name)
            }
        }
        return ordered
    }
}
