import Foundation
import XCTest

@testable import SpilloverCore

/// One test per issue found in code review, so none can come back.
final class RegressionTests: XCTestCase {
    // Non-canonical folders in routes.json must still match (never silently fall back).
    func testNonCanonicalRouteFolderStillMatches() throws {
        let box = try Sandbox()
        let work = try ProfileStore(env: box.env).create(displayName: "work")
        let project = try box.mkdir("p/work")
        let raw = """
            {"version":1,"routes":[{"folder":"\(box.home.path)/p/./x/../work/","profileId":"work","createdAt":"2026-01-01T00:00:00Z"}]}
            """
        try SafeFS.writeAtomic(Data(raw.utf8), to: box.env.paths.routesFile)
        guard case .routed(let p, _) = Resolver(env: box.env).resolve(cwd: project.path + "/src") else {
            return XCTFail("expected routed")
        }
        XCTAssertEqual(p.id, work.id)
    }

    // ".." after a symlink is resolved physically, like the shell's `cd -P`.
    func testDotDotAfterSymlinkIsPhysical() throws {
        let box = try Sandbox()
        let target = try box.mkdir("x/y")
        try box.mkdir("a")
        let link = box.home.appendingPathComponent("a/link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let n = PathNormalizer.normalize(link.path + "/../b", caseInsensitive: false)
        XCTAssertEqual(n?.display, target.deletingLastPathComponent().path + "/b")
    }

    private func editorSandbox(_ settings: String) throws -> (Sandbox, URL) {
        let box = try Sandbox()
        try box.mkdir("Library/Application Support/Code/User")
        try box.write("Library/Application Support/Code/User/settings.json", settings)
        try ShellShim(env: box.env).installLauncher(from: try box.fakeExecutable("build/spillover-launch"))
        return (box, Editor.code.settingsFile(env: box.env))
    }

    // A failed uninstall keeps the record so the previous wrapper can still be restored.
    func testFailedUninstallKeepsRecord() throws {
        let (box, url) = try editorSandbox("{\n  \"claudeCode.claudeProcessWrapper\": \"/other/tool\"\n}")
        let installer = VSCodeInstaller(env: box.env)
        try installer.install(editor: .code, force: true)
        let good = box.read(url)
        try Data("{ broken".utf8).write(to: url)
        XCTAssertThrowsError(try installer.uninstall(editor: .code))
        try Data((good + "\n").utf8).write(to: url)  // differs from the recorded hash
        XCTAssertEqual(try installer.uninstall(editor: .code), .restoredValue)
        XCTAssertEqual(try JSONCDocument(box.read(url)).stringValue(forKey: VSCodeInstaller.wrapperKey), "/other/tool")
    }

    // Installing when the setting already points at us never records ourselves as "previous".
    func testAlreadyInstalledWithoutManifestDoesNotRecordItself() throws {
        let box = try Sandbox()
        try box.mkdir("Library/Application Support/Code/User")
        try ShellShim(env: box.env).installLauncher(from: try box.fakeExecutable("build/spillover-launch"))
        let url = try box.write(
            "Library/Application Support/Code/User/settings.json",
            "{\n  \"claudeCode.claudeProcessWrapper\": \(JSONCDocument.quote(box.env.paths.launcher.path))\n}")
        let installer = VSCodeInstaller(env: box.env)
        let record = try installer.install(editor: .code)
        XCTAssertNil(record.previousValueJSON)
        XCTAssertEqual(try installer.uninstall(editor: .code), .removedKey)
        XCTAssertFalse(try JSONCDocument(box.read(url)).hasKey(VSCodeInstaller.wrapperKey))
    }

    func testCorruptManifestIsAnError() throws {
        let (box, _) = try editorSandbox("{}")
        try SafeFS.writeAtomic(Data("not json".utf8), to: box.env.paths.installManifest)
        XCTAssertThrowsError(try VSCodeInstaller(env: box.env).install(editor: .code)) {
            guard case InstallError.manifestUnreadable = $0 else { return XCTFail("\($0)") }
        }
    }

    // Writes follow symlinks: a dotfiles-managed ~/.zshrc stays a link.
    func testWritesFollowSymlinks() throws {
        let box = try Sandbox()
        let real = try box.write("dotfiles/zshrc", "export A=1\n")
        let link = box.home.appendingPathComponent(".zshrc")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        try RCFile.install(block: ShellShim(env: box.env).rcBlock(), at: link)
        XCTAssertNotNil(try? FileManager.default.destinationOfSymbolicLink(atPath: link.path))
        XCTAssertTrue(box.read(real).contains(ShellShim.beginMarker))
        XCTAssertEqual(SafeFS.permissions(of: real), 0o644)
    }

    // Existing folders are never re-moded.
    func testEnsureDirLeavesExistingFoldersAlone() throws {
        let box = try Sandbox()
        let dir = try box.mkdir("mine")
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: dir.path)
        try SafeFS.ensureDir(dir)
        XCTAssertEqual(SafeFS.permissions(of: dir), 0o755)
    }

    // profiles.json gets the same trust checks as routes.json.
    func testWritableProfilesFileRefusesRoutedLaunch() throws {
        let box = try Sandbox()
        let service = AppService(env: box.env)
        let work = try service.profiles.create(displayName: "work")
        let project = try box.mkdir("p")
        try service.assign(folder: project.path, to: work.id)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o666)], ofItemAtPath: box.env.paths.profilesFile.path)
        guard case .refused(let r) = Resolver(env: box.env).resolve(cwd: project.path) else {
            return XCTFail("expected refusal")
        }
        XCTAssertEqual(r.code, .registryCorrupt)
    }

    // A writable Spillover folder refuses even when routes.json is missing (it could be deleted).
    func testWritableRootRefusesEvenWithoutRoutes() throws {
        let box = try Sandbox()
        try SafeFS.ensureDir(box.env.paths.root)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o777)], ofItemAtPath: box.env.paths.root.path)
        guard case .refused(let r) = Resolver(env: box.env).resolve(cwd: box.home.path) else {
            return XCTFail("expected refusal")
        }
        XCTAssertEqual(r.code, .routesInsecure)
    }

    func testUnbalancedMarkersAreRefused() throws {
        let box = try Sandbox()
        let rc = try box.write(".zshrc", "a\n\(ShellShim.beginMarker)\nmine\n")
        XCTAssertThrowsError(try RCFile.install(block: ShellShim(env: box.env).rcBlock(), at: rc))
        XCTAssertThrowsError(try RCFile.uninstall(at: rc))
        XCTAssertEqual(box.read(rc), "a\n\(ShellShim.beginMarker)\nmine\n")
    }

    func testRCBlockEscapesUnusualRoots() throws {
        let box = try Sandbox()
        let env = SBEnvironment(home: box.home, appRoot: URL(fileURLWithPath: "/opt/sw$x`y\"z"))
        let block = ShellShim(env: env).rcBlock()
        XCTAssertTrue(block.contains(#"export PATH="/opt/sw\$x\`y\"z/shims:$PATH""#), block)
    }

    func testLaunchLogEscapesTerminalSequences() {
        XCTAssertEqual(LaunchLog.escapeControlCharacters("a\u{1B}[31mb\nc"), "a\\u{1b}[31mb\\u{a}c")
    }

    // VS Code uses the LAST of duplicate keys, so edits must target it too.
    func testDuplicateKeysTargetTheLastOne() throws {
        let src = "{\n  \"k\": \"first\",\n  \"k\": \"second\"\n}"
        let doc = try JSONCDocument(src)
        XCTAssertEqual(doc.stringValue(forKey: "k"), "second")
        XCTAssertEqual(doc.settingString("new", forKey: "k"), "{\n  \"k\": \"first\",\n  \"k\": \"new\"\n}")
    }

    func testNativeInstallerSessionsAreRecognised() {
        XCTAssertTrue(SessionScanner.isClaudeExecutable("/Users/example/.local/share/claude/versions/2.1.266"))
        XCTAssertTrue(SessionScanner.isClaudeExecutable("/x/resources/native-binary/claude"))
        XCTAssertFalse(SessionScanner.isClaudeExecutable("/usr/bin/versions/1.0"))
        XCTAssertFalse(SessionScanner.isClaudeExecutable("/usr/bin/claude-helper"))
    }
}
