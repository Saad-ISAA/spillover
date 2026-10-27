import Foundation
import XCTest

/// Structural rules, enforced by scanning the source tree. Each rule names the one file allowed to
/// do something; a second implementation anywhere else fails the test.
final class ArchitectureTests: XCTestCase {
    private struct SourceFile {
        let relativePath: String
        let text: String
    }

    private static let sourcesRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // SwitchboardCoreTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // package root
        .appendingPathComponent("Sources", isDirectory: true)

    private func sources() -> [SourceFile] {
        let root = Self.sourcesRoot
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
            return []
        }
        var files: [SourceFile] = []
        for case let url as URL in walker where url.pathExtension == "swift" {
            let rel = String(url.path.dropFirst(root.path.count + 1))
            files.append(SourceFile(relativePath: rel, text: (try? String(contentsOf: url, encoding: .utf8)) ?? ""))
        }
        return files
    }

    /// Lines of code with `//` comments stripped (good enough for the patterns checked here).
    private func codeLines(_ text: String) -> [String] {
        text.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            let s = String(line)
            if let r = s.range(of: "//") { return String(s[..<r.lowerBound]) }
            return s
        }
    }

    private func offenders(containing needle: String, allowed: Set<String>) -> [String] {
        sources().filter { file in
            !allowed.contains(file.relativePath) && codeLines(file.text).contains { $0.contains(needle) }
        }.map(\.relativePath)
    }

    func testSourcesAreFound() {
        XCTAssertGreaterThan(sources().count, 20, "source scan found nothing; check sourcesRoot")
    }

    func testOnlyConfigReadsProcessEnvironment() {
        let allowed: Set = ["SwitchboardCore/Config/SBEnvironment.swift"]
        XCTAssertEqual(offenders(containing: "ProcessInfo.processInfo.environment", allowed: allowed), [])
        XCTAssertEqual(offenders(containing: "getenv(", allowed: allowed), [])
    }

    func testOnlyCommandRunnerStartsProcesses() {
        XCTAssertEqual(
            offenders(containing: "Process()", allowed: ["SwitchboardCore/Profiles/CommandRunner.swift"]), [])
    }

    func testOnlySessionControlSignalsProcesses() {
        XCTAssertEqual(
            offenders(containing: "kill(", allowed: ["SwitchboardCore/Sessions/SessionControl.swift"]), [])
    }

    func testOnlyTheLauncherExecs() {
        XCTAssertEqual(offenders(containing: "execve(", allowed: ["switchboard-launch/main.swift"]), [])
        XCTAssertEqual(offenders(containing: "execv(", allowed: []), [])
        XCTAssertEqual(offenders(containing: "posix_spawn", allowed: []), [])
    }

    func testOnlyProfileEnvironmentNamesTheConfigVariable() {
        XCTAssertEqual(
            offenders(
                containing: "\"CLAUDE_CONFIG_DIR\"",
                allowed: ["SwitchboardCore/Profiles/ProfileEnvironment.swift"]), [])
    }

    func testKeychainIsNeverReadForSecrets() {
        for file in sources() {
            for line in codeLines(file.text) where line.contains("find-generic-password") || line.contains("dump-keychain") {
                XCTAssertFalse(line.contains("\"-w\""), file.relativePath)
                XCTAssertFalse(line.contains("\"-g\""), file.relativePath)
                XCTAssertFalse(line.contains("\"-d\""), file.relativePath)
            }
            XCTAssertFalse(file.text.contains("SecItemCopyMatching"), "\(file.relativePath) reads Keychain items")
            XCTAssertFalse(file.text.contains("kSecReturnData"), "\(file.relativePath) reads Keychain secrets")
        }
    }

    func testNoNetworkClients() {
        // Switchboard makes no network requests of its own (no telemetry, no undocumented APIs).
        XCTAssertEqual(offenders(containing: "URLSession", allowed: []), [])
        XCTAssertEqual(offenders(containing: "URLRequest", allowed: []), [])
    }

    func testOnlyRouteTableMatchesFolders() {
        // Folder-prefix matching lives in RouteTable; anything else would be a second resolver.
        XCTAssertEqual(
            offenders(containing: "entry.key + \"/\"", allowed: ["SwitchboardCore/Routing/RouteTable.swift"]), [])
    }

    func testExecutablesStayThin() {
        // Executables hold no routing logic of their own: they never construct the stores directly.
        for file in sources() where !file.relativePath.hasPrefix("SwitchboardCore/") {
            XCTAssertFalse(file.text.contains("RouteTable("), file.relativePath)
            XCTAssertFalse(file.text.contains("JSONCDocument("), file.relativePath)
        }
    }

    func testCoreDoesNotImportUIFrameworks() {
        for file in sources() where file.relativePath.hasPrefix("SwitchboardCore/") {
            XCTAssertFalse(file.text.contains("import SwiftUI"), file.relativePath)
            XCTAssertFalse(file.text.contains("import AppKit"), file.relativePath)
        }
    }
}
