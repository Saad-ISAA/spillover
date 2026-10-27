import Foundation
import XCTest

@testable import SpilloverCore

final class LaunchPlannerTests: XCTestCase {
    private func setup() throws -> (Sandbox, SBEnvironment, URL) {
        let box = try Sandbox()
        let claude = try box.fakeExecutable("tools/claude")
        var env = box.env
        env.processEnv = ["SPILLOVER_REAL_CLAUDE": claude.path, "PATH": "/usr/bin"]
        return (box, env, claude)
    }

    func testUnroutedLeavesEnvironmentUntouched() throws {
        let (box, env, claude) = try setup()
        var base = env.processEnv
        base["CLAUDE_CONFIG_DIR"] = "/user/chosen"
        let decision = LaunchPlanner(env: env).plan(
            LaunchRequest(mode: .editorWrapper, cwd: box.home.path, args: ["--x"], environment: base))
        guard case .exec(let plan, let resolution) = decision else { return XCTFail("\(decision)") }
        XCTAssertEqual(resolution, .unrouted)
        XCTAssertEqual(plan.executable, claude.path)
        XCTAssertEqual(plan.args, ["--x"])
        XCTAssertEqual(plan.environment, base)
    }

    func testRoutedSetsProfileDirectory() throws {
        let (box, env, _) = try setup()
        let service = AppService(env: env)
        let work = try service.profiles.create(displayName: "work")
        let project = try box.mkdir("p")
        try service.assign(folder: project.path, to: work.id)
        let decision = LaunchPlanner(env: env).plan(
            LaunchRequest(mode: .shellShim, cwd: project.path, args: [], environment: env.processEnv))
        guard case .exec(let plan, _) = decision else { return XCTFail("\(decision)") }
        XCTAssertEqual(plan.environment["CLAUDE_CONFIG_DIR"], work.configDir)
        XCTAssertEqual(plan.environment["SPILLOVER_PROFILE"], work.id)
    }

    func testRoutedToDefaultUnsetsDirectory() throws {
        let (box, env, _) = try setup()
        let project = try box.mkdir("p")
        try AppService(env: env).assign(folder: project.path, to: Profile.defaultID)
        var base = env.processEnv
        base["CLAUDE_CONFIG_DIR"] = "/from/extension/setting"
        let decision = LaunchPlanner(env: env).plan(
            LaunchRequest(mode: .editorWrapper, cwd: project.path, args: [], environment: base))
        guard case .exec(let plan, _) = decision else { return XCTFail("\(decision)") }
        XCTAssertNil(plan.environment["CLAUDE_CONFIG_DIR"])
    }

    func testRefusalNeverFallsBackToAnotherAccount() throws {
        let (box, env, _) = try setup()
        let project = try box.mkdir("p")
        try RouteStore(env: env).set(folder: project.path, profileId: "ghost", knownProfileIDs: ["ghost"])
        let decision = LaunchPlanner(env: env).plan(
            LaunchRequest(mode: .editorWrapper, cwd: project.path, args: [], environment: env.processEnv))
        guard case .refuse(let message) = decision else { return XCTFail("expected refusal") }
        XCTAssertTrue(message.contains("ghost"))
    }

    func testBypassSkipsRouting() throws {
        let (box, env, _) = try setup()
        let project = try box.mkdir("p")
        try RouteStore(env: env).set(folder: project.path, profileId: "ghost", knownProfileIDs: ["ghost"])
        var base = env.processEnv
        base["SPILLOVER_BYPASS"] = "1"
        let decision = LaunchPlanner(env: env).plan(
            LaunchRequest(mode: .editorWrapper, cwd: project.path, args: [], environment: base))
        guard case .exec(_, let resolution) = decision else { return XCTFail("\(decision)") }
        XCTAssertEqual(resolution, .unrouted)
    }

    func testLaunchLogHasNoArguments() throws {
        let (box, env, _) = try setup()
        _ = LaunchPlanner(env: env).plan(
            LaunchRequest(
                mode: .editorWrapper, cwd: box.home.path, args: ["--secret-prompt", "do the thing"],
                environment: env.processEnv))
        let log = box.read(env.paths.launchLog)
        XCTAssertTrue(log.contains("result=unrouted"))
        XCTAssertFalse(log.contains("secret-prompt"))
        XCTAssertEqual(SafeFS.permissions(of: env.paths.launchLog), 0o600)
    }

    func testLaunchLogKeepsLongFolderNamesAndCannotBeForged() throws {
        let (box, env, _) = try setup()
        let folder = try box.mkdir("a-very-long-hyphenated-project-folder-name-for-a-client")
        _ = LaunchPlanner(env: env).plan(
            LaunchRequest(mode: .shellShim, cwd: folder.path, args: [], environment: env.processEnv))
        LaunchLog(env: env).append(mode: .shellShim, cwd: "/x\nfake line", profile: "-", outcome: "unrouted")
        let log = box.read(env.paths.launchLog)
        XCTAssertTrue(log.contains("a-very-long-hyphenated-project-folder-name-for-a-client"))
        XCTAssertEqual(log.split(separator: "\n").count, 2)
    }

    func testMissingClaudeRefuses() throws {
        let box = try Sandbox()
        var env = box.env
        env.processEnv = ["PATH": box.home.path + "/empty"]
        let decision = LaunchPlanner(env: env).plan(
            LaunchRequest(mode: .shellShim, cwd: box.home.path, args: [], environment: env.processEnv))
        guard case .refuse = decision else { return XCTFail("expected refusal") }
    }
}

final class RealClaudeLocatorTests: XCTestCase {
    func testVersionParsingAndOrdering() {
        XCTAssertEqual(RealClaudeLocator.parseVersion("anthropic.claude-code-2.1.310-darwin-arm64"), [2, 1, 310])
        XCTAssertTrue(RealClaudeLocator.isNewer([2, 1, 310], than: [2, 1, 99]))
        XCTAssertFalse(RealClaudeLocator.isNewer([2, 1], than: [2, 1, 0]))
    }

    func testEditorModePrefersNewestBundledBinary() throws {
        let box = try Sandbox()
        try box.fakeExecutable(".vscode/extensions/anthropic.claude-code-2.1.9-darwin-arm64/resources/native-binary/claude")
        let newest = try box.fakeExecutable(
            ".vscode/extensions/anthropic.claude-code-2.1.10-darwin-arm64/resources/native-binary/claude")
        let onPath = try box.fakeExecutable("bin/claude")
        let locator = RealClaudeLocator(env: box.env)
        let base = ["PATH": onPath.deletingLastPathComponent().path]
        XCTAssertEqual(locator.locate(mode: .editorWrapper, baseEnv: base), newest.path)
        XCTAssertEqual(locator.locate(mode: .shellShim, baseEnv: base), onPath.path)
    }

    func testNeverReturnsOwnShim() throws {
        let box = try Sandbox()
        let launcher = try box.fakeExecutable("build/spillover-launch")
        try ShellShim(env: box.env).installLauncher(from: launcher)
        let real = try box.fakeExecutable("bin/claude")
        let base = ["PATH": "\(box.env.paths.shimsDir.path):\(real.deletingLastPathComponent().path)"]
        XCTAssertEqual(RealClaudeLocator(env: box.env).locate(mode: .shellShim, baseEnv: base), real.path)
    }
}

final class ShellTests: XCTestCase {
    func testRCBlockInstallIsIdempotentAndReversible() throws {
        let box = try Sandbox()
        let rc = try box.write(".zshrc", "export FOO=1\n# keep me\n")
        let shim = ShellShim(env: box.env)
        try RCFile.install(block: shim.rcBlock(), at: rc)
        try RCFile.install(block: shim.rcBlock(), at: rc)
        let text = box.read(rc)
        XCTAssertEqual(text.components(separatedBy: ShellShim.beginMarker).count, 2)
        XCTAssertTrue(text.contains("$HOME/.spillover/shims"))
        try RCFile.uninstall(at: rc)
        XCTAssertEqual(box.read(rc), "export FOO=1\n# keep me\n")
    }

    func testRCInstallIntoMissingFile() throws {
        let box = try Sandbox()
        let rc = box.home.appendingPathComponent(".zshrc")
        try RCFile.install(block: ShellShim(env: box.env).rcBlock(), at: rc)
        XCTAssertTrue(RCFile.hasBlock(at: rc))
        try RCFile.uninstall(at: rc)
        XCTAssertEqual(box.read(rc), "")
    }

    func testShellQuote() {
        XCTAssertEqual(ShellQuote.quote("a b"), "'a b'")
        XCTAssertEqual(ShellQuote.quote("it's"), "'it'\\''s'")
        XCTAssertEqual(ShellQuote.quote("$(rm -rf ~)"), "'$(rm -rf ~)'")
    }

    func testLoginScriptQuotesEverything() throws {
        let box = try Sandbox()
        let launcher = TerminalLauncher(env: box.env, runner: FakeRunner())
        let p = Profile(id: "w", displayName: "W", configDir: "/x/it's here")
        let body = launcher.scriptBody(profile: p, folder: nil, claudePath: "/bin/claude", command: ["auth", "login"])
        XCTAssertTrue(body.contains("export CLAUDE_CONFIG_DIR='/x/it'\\''s here'"))
        XCTAssertTrue(body.contains("'/bin/claude' 'auth' 'login'"))
        let def = launcher.scriptBody(
            profile: .builtInDefault(), folder: "/p", claudePath: "/bin/claude", command: [])
        XCTAssertTrue(def.contains("unset CLAUDE_CONFIG_DIR"))
    }
}
