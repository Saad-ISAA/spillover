import Foundation
import XCTest

@testable import SpilloverCore

final class JSONCDocumentTests: XCTestCase {
    let key = "claudeCode.claudeProcessWrapper"

    func testInsertKeepsCommentsAndIgnoresNestedKey() throws {
        let src = "{\n  \"a\": 1, // c\n  \"b\": {\"\(key)\": \"nested\"}\n}\n"
        let doc = try JSONCDocument(src)
        XCTAssertFalse(doc.hasKey(key))
        let out = doc.settingString("/x", forKey: key)
        XCTAssertEqual(
            out, "{\n  \"a\": 1, // c\n  \"b\": {\"\(key)\": \"nested\"},\n  \"\(key)\": \"/x\"\n}\n")
        XCTAssertEqual(try JSONCDocument(out).stringValue(forKey: key), "/x")
    }

    func testReplaceExistingValue() throws {
        let src = "{\n  // comment with \"quotes\" and // slashes\n  \"\(key)\": \"/old\",\n  \"url\": \"http://x//y\"\n}"
        let out = try JSONCDocument(src).settingString("/new", forKey: key)
        XCTAssertEqual(out, src.replacingOccurrences(of: "/old", with: "/new"))
    }

    func testTrailingCommaStyleIsKept() throws {
        let out = try JSONCDocument("{\n  \"a\": 1,\n}").settingString("v", forKey: "k")
        XCTAssertEqual(out, "{\n  \"a\": 1,\n  \"k\": \"v\",\n}")
    }

    func testEmptyObject() throws {
        XCTAssertEqual(try JSONCDocument("{}").settingString("v", forKey: "k"), "{\n  \"k\": \"v\"\n}")
    }

    func testRemoveMiddleLastOnlyAndTrailingComma() throws {
        XCTAssertEqual(
            try JSONCDocument("{\n  \"a\": 1,\n  \"k\": \"v\",\n  \"b\": 2\n}").removing(key: "k"),
            "{\n  \"a\": 1,\n  \"b\": 2\n}")
        XCTAssertEqual(
            try JSONCDocument("{\n  \"a\": 1,\n  \"k\": \"v\"\n}").removing(key: "k"),
            "{\n  \"a\": 1\n}")
        XCTAssertEqual(try JSONCDocument("{\n  \"k\": \"v\"\n}").removing(key: "k"), "{\n}")
        XCTAssertEqual(
            try JSONCDocument("{\n  \"a\": 1,\n  \"k\": \"v\",\n}").removing(key: "k"),
            "{\n  \"a\": 1,\n}")
    }

    func testTabsIndentationIsReused() throws {
        let out = try JSONCDocument("{\n\t\"a\": 1\n}").settingString("v", forKey: "k")
        XCTAssertEqual(out, "{\n\t\"a\": 1,\n\t\"k\": \"v\"\n}")
    }

    func testQuoteEscapes() {
        XCTAssertEqual(JSONCDocument.quote("a\"b\\c\n"), "\"a\\\"b\\\\c\\n\"")
    }

    func testMalformedInputs() {
        XCTAssertThrowsError(try JSONCDocument("[1]"))
        XCTAssertThrowsError(try JSONCDocument("{\"a\": \"unterminated}"))
        XCTAssertThrowsError(try JSONCDocument("{\"a\": 1"))
        XCTAssertThrowsError(try JSONCDocument("{ /* never closed "))
    }

    func testUnicodeContentSurvives() throws {
        let src = "{\n  \"title\": \"Ünïcødé ✓\",\n  \"a\": 1\n}"
        let out = try JSONCDocument(src).settingString("v", forKey: "k")
        XCTAssertTrue(out.hasPrefix("{\n  \"title\": \"Ünïcødé ✓\",\n  \"a\": 1,\n  \"k\": \"v\""))
    }
}

final class VSCodeInstallerTests: XCTestCase {
    private func prepare(settings: String?) throws -> (Sandbox, URL) {
        let box = try Sandbox()
        try box.mkdir("Library/Application Support/Code/User")
        if let settings { try box.write("Library/Application Support/Code/User/settings.json", settings) }
        let launcher = try box.fakeExecutable("build/spillover-launch")
        try ShellShim(env: box.env).installLauncher(from: launcher)
        return (box, Editor.code.settingsFile(env: box.env))
    }

    func testInstallThenUninstallRestoresExactBytes() throws {
        let original = "{\n  // mine\n  \"editor.fontSize\": 13,\n}\n"
        let (box, url) = try prepare(settings: original)
        let installer = VSCodeInstaller(env: box.env)
        XCTAssertEqual(installer.status(of: .code), .notInstalled)
        let record = try installer.install(editor: .code)
        XCTAssertEqual(installer.status(of: .code), .installed)
        XCTAssertNotNil(record.backupPath)
        XCTAssertEqual(box.read(URL(fileURLWithPath: record.backupPath!)), original)
        XCTAssertTrue(box.read(url).contains("// mine"))
        XCTAssertEqual(try installer.uninstall(editor: .code), .restoredExactly)
        XCTAssertEqual(box.read(url), original)
    }

    func testRefusesToReplaceAnotherWrapperUnlessForced() throws {
        let (box, url) = try prepare(settings: "{\n  \"claudeCode.claudeProcessWrapper\": \"/other/tool\"\n}")
        let installer = VSCodeInstaller(env: box.env)
        XCTAssertEqual(installer.status(of: .code), .otherWrapper("\"/other/tool\""))
        XCTAssertThrowsError(try installer.install(editor: .code))
        try installer.install(editor: .code, force: true)
        // The user edits something else afterwards: uninstall restores the old value, keeps the edit.
        let edited = box.read(url).replacingOccurrences(of: "{\n", with: "{\n  \"x\": 1,\n")
        try Data(edited.utf8).write(to: url)
        XCTAssertEqual(try installer.uninstall(editor: .code), .restoredValue)
        let doc = try JSONCDocument(box.read(url))
        XCTAssertEqual(doc.stringValue(forKey: VSCodeInstaller.wrapperKey), "/other/tool")
        XCTAssertEqual(doc.rawValue(forKey: "x"), "1")
    }

    func testUninstallLeavesUserChangedWrapperAlone() throws {
        let (box, url) = try prepare(settings: "{}")
        let installer = VSCodeInstaller(env: box.env)
        try installer.install(editor: .code)
        let changed = try JSONCDocument(box.read(url)).settingString("/their/own", forKey: VSCodeInstaller.wrapperKey)
        try Data(changed.utf8).write(to: url)
        XCTAssertEqual(try installer.uninstall(editor: .code), .leftAlone("/their/own"))
    }

    func testMissingSettingsFileIsCreatedThenKeyRemoved() throws {
        let (box, url) = try prepare(settings: nil)
        let installer = VSCodeInstaller(env: box.env)
        let record = try installer.install(editor: .code)
        XCTAssertNil(record.backupPath)
        XCTAssertEqual(installer.status(of: .code), .installed)
        XCTAssertEqual(try installer.uninstall(editor: .code), .removedKey)
        XCTAssertFalse(try JSONCDocument(box.read(url)).hasKey(VSCodeInstaller.wrapperKey))
    }

    func testEditorAndLauncherPreconditions() throws {
        let box = try Sandbox()
        XCTAssertEqual(VSCodeInstaller(env: box.env).status(of: .cursor), .editorNotFound)
        try box.mkdir("Library/Application Support/Code/User")
        XCTAssertThrowsError(try VSCodeInstaller(env: box.env).install(editor: .code)) {
            XCTAssertEqual($0 as? InstallError, .launcherMissing)
        }
    }

    func testUnparseableSettingsAreNeverTouched() throws {
        let (box, url) = try prepare(settings: "{ \"a\": [1, 2 }")
        XCTAssertThrowsError(try VSCodeInstaller(env: box.env).install(editor: .code))
        XCTAssertEqual(box.read(url), "{ \"a\": [1, 2 }")
    }
}

final class ExtensionContractTests: XCTestCase {
    private func pkg(scope: String?) -> [String: Any] {
        var prop: [String: Any] = ["type": "string"]
        if let scope { prop["scope"] = scope }
        return ["contributes": ["configuration": ["properties": [VSCodeInstaller.wrapperKey: prop]]]]
    }

    func testEvaluate() {
        XCTAssertEqual(ExtensionContract.evaluate(packageJSON: pkg(scope: "machine")), .ok)
        XCTAssertEqual(ExtensionContract.evaluate(packageJSON: pkg(scope: "window")), .wrapperScopeChanged("window"))
        XCTAssertEqual(ExtensionContract.evaluate(packageJSON: ["contributes": [:]]), .wrapperSettingMissing)
    }

    func testCheckPicksNewestExtension() throws {
        let box = try Sandbox()
        let dir = try box.mkdir(".vscode/extensions")
        for (version, scope) in [("2.1.9", "window"), ("2.1.10", "machine")] {
            let data = try JSONSerialization.data(withJSONObject: pkg(scope: scope))
            let ext = try box.mkdir(".vscode/extensions/anthropic.claude-code-\(version)-darwin-arm64")
            try data.write(to: ext.appendingPathComponent("package.json"))
        }
        let result = ExtensionContract.check(extensionsDir: dir)
        XCTAssertEqual(result.extensionVersion, "2.1.10")
        XCTAssertEqual(result.finding, .ok)
    }
}

final class RecentWorkspacesTests: XCTestCase {
    func testParsers() {
        let list = #"{"entries":[{"folderUri":"file:///Users/example/My%20App"},{"fileUri":"file:///x.txt"},{"folderUri":"vscode-remote://ssh-remote%2Bbox/home/x"}]}"#
        let uris = RecentWorkspaces.parseRecentList(list)
        XCTAssertEqual(uris.count, 2)
        XCTAssertEqual(RecentWorkspaces.localPath(fromFileURI: uris[0]), "/Users/example/My App")
        XCTAssertNil(RecentWorkspaces.localPath(fromFileURI: uris[1]))

        let storage = #"{"backupWorkspaces":{"folders":[{"folderUri":"file:///a"}]},"profileAssociations":{"workspaces":{"file:///b":"__default__profile__"}}}"#
        XCTAssertEqual(RecentWorkspaces.parseStorageJSON(Data(storage.utf8)), ["file:///a", "file:///b"])
    }
}
