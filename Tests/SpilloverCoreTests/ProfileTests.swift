import Foundation
import XCTest

@testable import SpilloverCore

final class ProfileStoreTests: XCTestCase {
    func testDefaultAlwaysPresentAndFirst() throws {
        let box = try Sandbox()
        let all = try ProfileStore(env: box.env).all()
        XCTAssertEqual(all.map(\.id), [Profile.defaultID])
        XCTAssertTrue(all[0].isDefault)
    }

    func testRenameDefaultKeepsItUnsetAndOthersIntact() throws {
        let box = try Sandbox()
        let store = ProfileStore(env: box.env)
        let work = try store.create(displayName: "Work")
        try store.rename(id: Profile.defaultID, to: "Personal")
        var all = try store.all()
        XCTAssertEqual(all[0].displayName, "Personal")
        XCTAssertEqual(all[0].id, Profile.defaultID)
        XCTAssertNil(all[0].configDir)
        XCTAssertEqual(all[1].id, work.id)
        XCTAssertEqual(all[1].displayName, "Work")
        XCTAssertEqual(all[1].configDir, work.configDir)
        // Creating another profile keeps the name; renaming back to "Default" clears it.
        _ = try store.create(displayName: "Client")
        XCTAssertEqual(try store.all()[0].displayName, "Personal")
        try store.rename(id: Profile.defaultID, to: "Default")
        all = try store.all()
        XCTAssertEqual(all[0].displayName, "Default")
        XCTAssertFalse(box.read(box.env.paths.profilesFile).contains("defaultName"))
    }

    func testCreateMakesOwnerOnlyDirectoryAndUniqueSlug() throws {
        let box = try Sandbox()
        let store = ProfileStore(env: box.env)
        let a = try store.create(displayName: "Work Account")
        let b = try store.create(displayName: "Work Account")
        XCTAssertEqual(a.id, "work-account")
        XCTAssertEqual(b.id, "work-account-2")
        XCTAssertEqual(SafeFS.permissions(of: URL(fileURLWithPath: a.configDir!)), 0o700)
        XCTAssertEqual(SafeFS.permissions(of: box.env.paths.profilesFile), 0o600)
        XCTAssertEqual(try store.all().count, 3)
    }

    func testReservedAndOddNames() throws {
        let box = try Sandbox()
        let store = ProfileStore(env: box.env)
        XCTAssertNotEqual(try store.create(displayName: "Default").id, "default")
        XCTAssertEqual(try store.create(displayName: "../../etc").id, "etc")
        XCTAssertEqual(try store.create(displayName: "日本").id, "profile")
        XCTAssertThrowsError(try store.create(displayName: "   "))
    }

    func testAdoptRejectsDefaultDirectoryAndDuplicates() throws {
        let box = try Sandbox()
        let store = ProfileStore(env: box.env)
        try box.mkdir(".claude")
        XCTAssertThrowsError(try store.adopt(displayName: "x", directory: box.home.path + "/.claude")) {
            guard case ProfileError.directoryIsDefault = $0 else { return XCTFail("\($0)") }
        }
        let dir = try box.mkdir("elsewhere/acct")
        let p = try store.adopt(displayName: "Acct", directory: dir.path)
        XCTAssertEqual(p.configDir, dir.path)
        XCTAssertThrowsError(try store.adopt(displayName: "again", directory: dir.path + "/"))
        XCTAssertThrowsError(try store.adopt(displayName: "rel", directory: "relative"))
        XCTAssertThrowsError(try store.adopt(displayName: "gone", directory: box.home.path + "/missing"))
    }

    func testRemoveDeletesOnlyOwnDirectories() throws {
        let box = try Sandbox()
        let store = ProfileStore(env: box.env)
        let own = try store.create(displayName: "own")
        let adoptedDir = try box.mkdir("adopted")
        let adopted = try store.adopt(displayName: "adopted", directory: adoptedDir.path)
        try store.remove(id: own.id, deleteDirectory: true)
        try store.remove(id: adopted.id, deleteDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: own.configDir!))
        XCTAssertTrue(FileManager.default.fileExists(atPath: adoptedDir.path))
        XCTAssertThrowsError(try store.remove(id: Profile.defaultID))
    }

    func testCorruptRegistryThrows() throws {
        let box = try Sandbox()
        try SafeFS.ensureDir(box.env.paths.root)
        try SafeFS.writeAtomic(
            Data(#"{"version":1,"profiles":[{"id":"../x","displayName":"x","provider":"claude","configDir":"/x","createdAt":"2026-01-01T00:00:00Z"}]}"#.utf8),
            to: box.env.paths.profilesFile)
        XCTAssertThrowsError(try ProfileStore(env: box.env).all())
    }

    func testIDValidation() {
        XCTAssertTrue(ProfileID.isValid("work-2"))
        XCTAssertFalse(ProfileID.isValid("-work"))
        XCTAssertFalse(ProfileID.isValid("Work"))
        XCTAssertFalse(ProfileID.isValid("a/b"))
        XCTAssertFalse(ProfileID.isValid("a.b"))
        XCTAssertFalse(ProfileID.isValid(String(repeating: "a", count: 41)))
    }
}

final class ProfileEnvironmentTests: XCTestCase {
    func testIsolatedProfileSetsDirectory() {
        let p = Profile(id: "work", displayName: "Work", configDir: "/x/work")
        let env = ProfileEnvironment.apply(p, to: ["PATH": "/bin"])
        XCTAssertEqual(env["CLAUDE_CONFIG_DIR"], "/x/work")
        XCTAssertEqual(env["SPILLOVER_PROFILE"], "work")
        XCTAssertEqual(env["PATH"], "/bin")
    }

    func testDefaultProfileUnsetsDirectoryNeverPointsAtDotClaude() {
        let env = ProfileEnvironment.apply(
            Profile.builtInDefault(), to: ["CLAUDE_CONFIG_DIR": "/somewhere/else"])
        XCTAssertNil(env["CLAUDE_CONFIG_DIR"])
        XCTAssertEqual(env["SPILLOVER_PROFILE"], Profile.defaultID)
    }
}

final class KeychainSlotTests: XCTestCase {
    func testDefaultUsesUnsuffixedService() {
        XCTAssertEqual(KeychainSlot.serviceName(forConfigDir: nil), "Claude Code-credentials")
    }

    func testHashedServiceName() {
        XCTAssertEqual(
            KeychainSlot.serviceName(forConfigDir: "/Users/example/.spillover/profiles/work"),
            "Claude Code-credentials-91b30f99")
    }

    func testNFCBeforeHashing() {
        XCTAssertEqual(
            KeychainSlot.serviceName(forConfigDir: "/Users/example/Cafe\u{301}"),
            "Claude Code-credentials-c9cf778e")
    }

    func testProbeNeverAsksForSecrets() {
        let runner = FakeRunner()
        let probe = KeychainProbe(runner: runner)
        _ = probe.itemExists(service: "Claude Code-credentials")
        _ = probe.claudeServices()
        for call in runner.calls {
            XCTAssertFalse(call.args.contains("-w"))
            XCTAssertFalse(call.args.contains("-g"))
            XCTAssertFalse(call.args.contains("-d"))
        }
    }

    func testParseDump() {
        let dump = """
            keychain: "/Users/example/Library/Keychains/login.keychain-db"
                "svce"<blob>="Claude Code-credentials"
                "svce"<blob>="Claude Code-credentials-91b30f99"
                "svce"<blob>="Other Service"
                "svce"<blob>="Claude Code-credentials-91b30f99"
            """
        XCTAssertEqual(
            KeychainProbe.parseServices(dump: dump),
            ["Claude Code-credentials", "Claude Code-credentials-91b30f99"])
    }
}

final class ClaudeCLITests: XCTestCase {
    func testParseAuthStatus() {
        let out = """
            some banner
            {
              "loggedIn": true,
              "authMethod": "claude.ai",
              "email": "person@example.com",
              "orgName": "Example Org",
              "subscriptionType": "max"
            }
            """
        let s = ClaudeCLI.parseAuthStatus(out)
        XCTAssertEqual(s?.loggedIn, true)
        XCTAssertEqual(s?.planLabel, "Max")
        XCTAssertNil(ClaudeCLI.parseAuthStatus("not json"))
    }

    func testStatusRunsWithProfileEnvironment() throws {
        let box = try Sandbox()
        let claude = try box.fakeExecutable("bin/claude")
        var env = box.env
        env.processEnv = ["PATH": claude.deletingLastPathComponent().path]
        let runner = FakeRunner()
        runner.handler = { _, _ in CommandResult(status: 0, stdout: #"{"loggedIn": false}"#) }
        let profile = Profile(id: "w", displayName: "W", configDir: "/x/w")
        let result = ClaudeCLI(env: env, runner: runner).authStatus(for: profile)
        XCTAssertEqual(try result.get().loggedIn, false)
        XCTAssertEqual(runner.calls.first?.args, ["auth", "status"])
        XCTAssertEqual(runner.calls.first?.env?["CLAUDE_CONFIG_DIR"], "/x/w")
    }
}

final class ProfileSharingTests: XCTestCase {
    func testShareLinksAndRefusesSecrets() throws {
        let box = try Sandbox()
        try box.write(".claude/settings.json", "{}")
        try box.mkdir(".claude/skills")
        let store = ProfileStore(env: box.env)
        let work = try store.create(displayName: "work")
        let sharing = ProfileSharing(env: box.env)
        let def = Profile.builtInDefault()

        try sharing.share("skills", from: def, to: work)
        XCTAssertEqual(sharing.state(of: "skills", in: work), .linked(to: box.home.path + "/.claude/skills"))
        XCTAssertThrowsError(try sharing.share(".claude.json", from: def, to: work))
        XCTAssertThrowsError(try sharing.share("projects", from: def, to: work))
        XCTAssertThrowsError(try sharing.share("skills", from: work, to: def))

        try box.write(".spillover/profiles/work/settings.json", "{\"x\":1}")
        XCTAssertThrowsError(try sharing.share("settings.json", from: def, to: work))
        try sharing.share("settings.json", from: def, to: work, replace: true)
        let backups = try FileManager.default.contentsOfDirectory(atPath: work.configDir!)
            .filter { $0.hasPrefix("settings.json.spillover-backup-") }
        XCTAssertEqual(backups.count, 1)

        try sharing.unshare("skills", in: work)
        XCTAssertEqual(sharing.state(of: "skills", in: work), .absent)
        XCTAssertTrue(FileManager.default.fileExists(atPath: box.home.path + "/.claude/skills"))
    }

    func testNeverShareWinsOverShareable() {
        for item in ProfileSharing.neverShare {
            XCTAssertFalse(ProfileSharing.isShareable(item), item)
        }
    }
}
