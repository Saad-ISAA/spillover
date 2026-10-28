import Foundation
import XCTest

@testable import SpilloverCore

final class ConversationTests: XCTestCase {
    let id = "1b671a64-40d5-491e-99b0-da01ff1f3341"

    func testConversationIDFromArguments() {
        XCTAssertEqual(ConversationID.from(args: ["--output-format", "x", "--resume=\(id)"]), id)
        XCTAssertEqual(ConversationID.from(args: ["--resume", id]), id)
        XCTAssertEqual(ConversationID.from(args: ["-r", id]), id)
        XCTAssertNil(ConversationID.from(args: ["--resume=../../etc"]))
        XCTAssertNil(ConversationID.from(args: ["--continue"]))
    }

    func testProjectKey() {
        XCTAssertEqual(ConversationStore.projectKey(cwd: "/Users/example/My Code/app.v2"), "-Users-example-My-Code-app-v2")
    }

    private func transcript(_ box: Sandbox, _ profileDir: String, cwd: String, text: String) throws -> URL {
        try box.write("\(profileDir)/projects/\(ConversationStore.projectKey(cwd: cwd))/\(id).jsonl", text)
    }

    func testHandoffCopiesNewestConversationToTarget() throws {
        let box = try Sandbox()
        let store = ProfileStore(env: box.env)
        let work = try store.create(displayName: "work")
        let personal = try store.create(displayName: "personal")
        let cwd = "/Users/example/app"
        try transcript(box, ".spillover/profiles/work", cwd: cwd, text: "{\"a\":1}\n")
        try box.write(".spillover/profiles/work/projects/\(ConversationStore.projectKey(cwd: cwd))/\(id)/sub.jsonl", "s")
        try box.write(".spillover/profiles/work/file-history/\(id)/f1", "v1")

        let conversations = ConversationStore(env: box.env)
        let all = try store.all()
        XCTAssertEqual(try conversations.ensure(id: id, cwd: cwd, target: personal, among: all), .copied(fromProfile: "work"))
        let copied = try XCTUnwrap(conversations.transcript(id: id, cwd: cwd, in: personal))
        XCTAssertEqual(box.read(copied), "{\"a\":1}\n")
        XCTAssertEqual(SafeFS.permissions(of: copied), 0o600)
        XCTAssertTrue(FileManager.default.fileExists(atPath: box.home.path + "/.spillover/profiles/personal/projects/\(ConversationStore.projectKey(cwd: cwd))/\(id)/sub.jsonl"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: box.home.path + "/.spillover/profiles/personal/file-history/\(id)/f1"))
        // Already current: nothing more to copy.
        XCTAssertEqual(try conversations.ensure(id: id, cwd: cwd, target: personal, among: all), .current)
        // The work copy is only overwritten when the other account's copy is newer.
        XCTAssertEqual(try conversations.ensure(id: id, cwd: cwd, target: work, among: all), .current)
        _ = work
    }

    func testHandoffFindsTranscriptWithoutTheFolder() throws {
        let box = try Sandbox()
        let store = ProfileStore(env: box.env)
        _ = try store.create(displayName: "work")
        try transcript(box, ".spillover/profiles/work", cwd: "/elsewhere", text: "x")
        let conversations = ConversationStore(env: box.env)
        XCTAssertEqual(
            try conversations.ensure(id: id, cwd: nil, target: .builtInDefault(), among: try store.all()),
            .copied(fromProfile: "work"))
        XCTAssertNotNil(conversations.transcript(id: id, cwd: "/elsewhere", in: .builtInDefault()))
    }

    func testResumeKeepsOnlyTheChatsModeAndModelFlags() throws {
        let argv = [
            "--output-format", "stream-json", "--max-thinking-tokens=31999", "--permission-prompt-tool=stdio",
            "--resume=abc", "--setting-sources=user,project,local", "--permission-mode=bypassPermissions",
            "--allow-dangerously-skip-permissions", "--model", "opus", "--debug",
        ]
        XCTAssertEqual(
            RunningSession.resumeFlags(from: argv),
            [
                "--max-thinking-tokens=31999", "--setting-sources=user,project,local", "--permission-mode=bypassPermissions",
                "--allow-dangerously-skip-permissions", "--model", "opus",
            ])

        let box = try Sandbox()
        let runner = FakeRunner()
        let pid = try ChatResumer(env: box.env, runner: runner).resume(
            conversationId: "1b671a64-40d5-491e-99b0-da01ff1f3341", folder: "/Users/example/Code/api",
            flags: ["--permission-mode=bypassPermissions"])
        XCTAssertEqual(pid, 4242)
        let call = try XCTUnwrap(runner.calls.first)
        // Through the launcher, so the folder's account and the history handoff apply.
        XCTAssertEqual(call.executable, box.env.paths.launcher.path)
        XCTAssertEqual(call.directory?.path, "/Users/example/Code/api")
        XCTAssertEqual(
            call.args,
            [
                "--resume", "1b671a64-40d5-491e-99b0-da01ff1f3341", "-p", ChatResumer.message, "--output-format", "json",
                "--permission-mode=bypassPermissions",
            ])
        XCTAssertEqual(ConversationID.from(args: call.args), "1b671a64-40d5-491e-99b0-da01ff1f3341")
    }

    func testBackgroundTasksKeepAChatBusy() {
        let start = ISO8601DateFormatter().date(from: "2026-10-27T21:55:00Z")!
        let agent = #"{"type":"user","timestamp":"2026-10-27T21:58:08.100Z","toolUseResult":{"isAsync":true,"status":"async_launched","agentId":"a08b632472fe3d6b1"}}"#
        let shell = #"{"type":"user","timestamp":"2026-10-27T21:58:09.000Z","toolUseResult":{"stdout":"","backgroundTaskId":"bwpvyvdgf"}}"#
        let older = #"{"type":"user","timestamp":"2026-10-27T20:00:00.000Z","toolUseResult":{"isAsync":true,"agentId":"aold"}}"#
        let reply = #"{"type":"assistant","timestamp":"2026-10-27T21:58:13.000Z","message":{"stop_reason":"end_turn","content":[]}}"#
        let lines = [older, agent, shell, reply].joined(separator: "\n")

        // The reply has finished, but both tasks started by this process are still running.
        XCTAssertEqual(
            ConversationActivity.pendingBackgroundTasks(tail: Data(lines.utf8), since: start),
            ["a08b632472fe3d6b1", "bwpvyvdgf"])

        // Each task reports back with a task notification and a final status.
        let agentDone = #"{"type":"queue-operation","operation":"enqueue","content":"<task-notification>\n<task-id>a08b632472fe3d6b1</task-id>\n<status>completed</status>\n</task-notification>"}"#
        let shellRunning = #"{"type":"queue-operation","content":"<task-notification>\n<task-id>bwpvyvdgf</task-id>\n<status>running</status>\n</task-notification>"}"#
        XCTAssertEqual(
            ConversationActivity.pendingBackgroundTasks(
                tail: Data([lines, agentDone, shellRunning].joined(separator: "\n").utf8), since: start),
            ["bwpvyvdgf"])
        let shellKilled = #"{"type":"user","message":{"content":"<task-notification><task-id>bwpvyvdgf</task-id><status>killed</status></task-notification>"}}"#
        XCTAssertTrue(
            ConversationActivity.pendingBackgroundTasks(
                tail: Data([lines, agentDone, shellKilled].joined(separator: "\n").utf8), since: start
            ).isEmpty)

        // A synchronous subagent (not async) is not a background task.
        let sync = #"{"type":"user","timestamp":"2026-10-27T21:59:00.000Z","toolUseResult":{"isAsync":false,"agentId":"async-no"}}"#
        XCTAssertTrue(ConversationActivity.pendingBackgroundTasks(tail: Data(sync.utf8), since: start).isEmpty)
    }

    func testActivityState() {
        let done = #"{"type":"assistant","message":{"stop_reason":"end_turn","content":[]}}"# + "\n" + #"{"type":"ai-title","title":"x"}"#
        let tool = #"{"type":"assistant","message":{"stop_reason":"tool_use"}}"#
        let user = #"{"type":"user","message":{"content":[{"type":"tool_result"}]}}"#
        XCTAssertEqual(ConversationActivity.state(tail: Data(done.utf8), quietFor: 10), .idle)
        XCTAssertEqual(ConversationActivity.state(tail: Data(done.utf8), quietFor: 1), .busy)
        XCTAssertEqual(ConversationActivity.state(tail: Data(tool.utf8), quietFor: 30), .busy)
        XCTAssertEqual(ConversationActivity.state(tail: Data(user.utf8), quietFor: 900), .busy)
        let interrupted = #"{"type":"assistant","message":{"stop_reason":null,"content":[{"type":"text"}]}}"#
        XCTAssertEqual(ConversationActivity.state(tail: Data(interrupted.utf8), quietFor: 900), .stalled)
        XCTAssertEqual(ConversationActivity.state(tail: Data(interrupted.utf8), quietFor: 60), .busy)
        let pendingTool = #"{"type":"assistant","message":{"stop_reason":null,"content":[{"type":"tool_use"}]}}"#
        XCTAssertEqual(ConversationActivity.state(tail: Data(pendingTool.utf8), quietFor: 3600), .busy)
        XCTAssertNil(ConversationActivity.state(tail: Data(#"{"type":"ai-title"}"#.utf8), quietFor: 10))
    }

    func testDivergedCopyIsKeptAndPartialLineDropped() throws {
        let box = try Sandbox()
        let store = ProfileStore(env: box.env)
        _ = try store.create(displayName: "work")
        let personal = try store.create(displayName: "personal")
        let cwd = "/Users/example/app"
        let theirs = try transcript(box, ".spillover/profiles/personal", cwd: cwd, text: "{\"p\":1}\n{\"p\":2}\n")
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -600)], ofItemAtPath: theirs.path)
        try transcript(box, ".spillover/profiles/work", cwd: cwd, text: "{\"w\":1}\n{\"w\":2, \"partial")
        let result = try ConversationStore(env: box.env).ensure(id: id, cwd: cwd, target: personal, among: try store.all())
        XCTAssertEqual(result, .copied(fromProfile: "work", keptBackup: true))
        XCTAssertEqual(box.read(theirs), "{\"w\":1}\n")
        let backups = try FileManager.default.contentsOfDirectory(atPath: theirs.deletingLastPathComponent().path)
            .filter { $0.hasPrefix("\(id).jsonl.before-move-") }
        XCTAssertEqual(backups.count, 1)
    }

    func testContinuationReplacesWithoutBackup() throws {
        let box = try Sandbox()
        let store = ProfileStore(env: box.env)
        _ = try store.create(displayName: "work")
        let personal = try store.create(displayName: "personal")
        let cwd = "/Users/example/app"
        let theirs = try transcript(box, ".spillover/profiles/personal", cwd: cwd, text: "{\"a\":1}\n")
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -600)], ofItemAtPath: theirs.path)
        try transcript(box, ".spillover/profiles/work", cwd: cwd, text: "{\"a\":1}\n{\"a\":2}\n")
        XCTAssertEqual(
            try ConversationStore(env: box.env).ensure(id: id, cwd: cwd, target: personal, among: try store.all()),
            .copied(fromProfile: "work", keptBackup: false))
    }

    func testRefusesToWriteThroughALink() throws {
        let box = try Sandbox()
        let store = ProfileStore(env: box.env)
        _ = try store.create(displayName: "work")
        let personal = try store.create(displayName: "personal")
        let cwd = "/Users/example/app"
        try transcript(box, ".spillover/profiles/work", cwd: cwd, text: "x\n")
        let outside = try box.write("outside.txt", "keep")
        let dir = try box.mkdir(".spillover/profiles/personal/projects/\(ConversationStore.projectKey(cwd: cwd))")
        try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent("\(id).jsonl"), withDestinationURL: outside)
        XCTAssertThrowsError(try ConversationStore(env: box.env).ensure(id: id, cwd: cwd, target: personal, among: try store.all()))
        XCTAssertEqual(box.read(outside), "keep")
    }

    func testEditorHostingAndSessionURL() {
        XCTAssertEqual(Editor.hosting(executable: "/Users/example/.vscode/extensions/anthropic.claude-code-2.1.310-darwin-arm64/resources/native-binary/claude"), .code)
        XCTAssertEqual(Editor.hosting(executable: "/Users/example/.vscode-insiders/extensions/anthropic.claude-code-1/resources/native-binary/claude"), .insiders)
        XCTAssertNil(Editor.hosting(executable: "/Users/example/.local/share/claude/versions/2.1.266"))
        XCTAssertEqual(Editor.code.claudeSessionURL(id)?.absoluteString, "vscode://anthropic.claude-code/open?session=\(id)")
        XCTAssertNil(Editor.code.claudeSessionURL("../x"))
    }

    func testEndRefusesAReusedPid() {
        let a = RunningSession(pid: 10, executable: "/x/claude", cwd: "/p", configDir: nil, spilloverProfile: nil, startedAt: Date(timeIntervalSince1970: 1), conversationId: id)
        let b = RunningSession(pid: 10, executable: "/x/claude", cwd: "/p", configDir: nil, spilloverProfile: nil, startedAt: Date(timeIntervalSince1970: 2), conversationId: id)
        XCTAssertTrue(SessionControl.isSameChat(a, a))
        XCTAssertFalse(SessionControl.isSameChat(a, b))
        XCTAssertThrowsError(try SessionControl.end(RunningSession(pid: 999_999, executable: "/x/claude", cwd: nil, configDir: nil, spilloverProfile: nil, startedAt: nil)))
    }
}

final class AutoPolicyTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_000_000)

    private func snapshot(_ id: String, five: Double, seven: Double = 10) -> UsageSnapshot {
        UsageSnapshot(profileId: id, capturedAt: now, windows: [
            .init(kind: .fiveHour, usedPercentage: five, resetsAt: now.addingTimeInterval(4 * 3600)),
            .init(kind: .sevenDay, usedPercentage: seven, resetsAt: now.addingTimeInterval(5 * 86400)),
        ])
    }

    func testChoosesFirstAccountWithRoomInOrder() throws {
        let box = try Sandbox()
        let a = Profile(id: "a", displayName: "A", configDir: try box.mkdir("a").path)
        let b = Profile(id: "b", displayName: "B", configDir: try box.mkdir("b").path)
        let c = Profile(id: "c", displayName: "C", configDir: try box.mkdir("c").path)
        let policy = AutoPolicy(order: ["b", "a", "c"])
        let snaps = ["b": snapshot("b", five: 92), "a": snapshot("a", five: 40)]
        XCTAssertEqual(policy.choose(profiles: [a, b, c], snapshots: snaps, now: now)?.id, "a")
        // Unknown usage counts as room.
        XCTAssertEqual(AutoPolicy(order: ["c", "a"]).choose(profiles: [a, b, c], snapshots: snaps, now: now)?.id, "c")
        // Nobody has room: the least used one.
        let full = ["a": snapshot("a", five: 99), "b": snapshot("b", five: 93), "c": snapshot("c", five: 97)]
        XCTAssertEqual(policy.choose(profiles: [a, b, c], snapshots: full, now: now)?.id, "b")
    }

    func testSkipsUnavailableAndMissingAccountsAndPrefersHolder() throws {
        let box = try Sandbox()
        let a = Profile(id: "a", displayName: "A", configDir: try box.mkdir("a").path)
        let b = Profile(id: "b", displayName: "B", configDir: try box.mkdir("b").path)
        let gone = Profile(id: "gone", displayName: "Gone", configDir: box.home.path + "/missing")
        let policy = AutoPolicy(order: ["gone", "a", "b"], unavailable: ["a"])
        XCTAssertEqual(policy.choose(profiles: [a, b, gone], snapshots: [:], now: now)?.id, "b")
        XCTAssertNil(AutoPolicy(unavailable: ["a", "b"]).choose(profiles: [a, b], snapshots: [:], now: now))
        // The account already holding a resumed chat keeps it while it has room.
        XCTAssertEqual(AutoPolicy(order: ["a", "b"]).choose(profiles: [a, b], snapshots: [:], now: now, preferring: "b")?.id, "b")
        let full = ["b": snapshot("b", five: 97)]
        XCTAssertEqual(AutoPolicy(order: ["a", "b"]).choose(profiles: [a, b], snapshots: full, now: now, preferring: "b")?.id, "a")
    }

    func testOlderAutoFilesStillLoad() throws {
        let box = try Sandbox()
        try SafeFS.ensureDir(box.env.paths.root)
        try SafeFS.writeAtomic(Data(#"{"version":1,"order":["x"],"threshold":85,"runOutMinutes":30,"moveOpenChats":false}"#.utf8), to: box.env.paths.autoPolicyFile)
        guard case .loaded(let p) = AutoPolicyStore(env: box.env).load() else { return XCTFail("expected loaded") }
        XCTAssertEqual(p.threshold, 85)
        XCTAssertEqual(p.unavailable, [])
    }

    func testForecastRunOutCountsAsOutOfRoom() {
        // 5h window, 4h45m left: 15 minutes in and 60% used runs out in about 10 minutes.
        let s = UsageSnapshot(profileId: "a", capturedAt: now, windows: [
            .init(kind: .fiveHour, usedPercentage: 60, resetsAt: now.addingTimeInterval(4 * 3600 + 30 * 60))
        ])
        XCTAssertTrue(AutoPolicy().isOutOfRoom(s, now: now))
        XCTAssertFalse(AutoPolicy().isOutOfRoom(snapshot("a", five: 20), now: now))
        XCTAssertFalse(AutoPolicy().isOutOfRoom(nil, now: now))
    }

    func testAFolderKeepsItsAccountUntilItIsFull() throws {
        let box = try Sandbox()
        let a = Profile(id: "a", displayName: "A", configDir: try box.mkdir("a").path)
        let b = Profile(id: "b", displayName: "B", configDir: try box.mkdir("b").path)
        let policy = AutoPolicy(order: ["a", "b"])
        // 78% and climbing fast enough to run out within 30 minutes: not full, so nothing moves.
        let climbing = UsageSnapshot(profileId: "b", capturedAt: now, windows: [
            .init(kind: .fiveHour, usedPercentage: 78, resetsAt: now.addingTimeInterval(3 * 3600 + 20 * 60))
        ])
        XCTAssertTrue(policy.isOutOfRoom(climbing, now: now))
        XCTAssertFalse(policy.isFull(climbing, now: now))
        XCTAssertEqual(policy.choose(profiles: [a, b], snapshots: ["b": climbing], now: now, current: "b")?.id, "b")
        // Even though "a" comes first and has room again, the folder stays on "b"...
        XCTAssertEqual(policy.choose(profiles: [a, b], snapshots: [:], now: now, current: "b")?.id, "b")
        // ...until "b" is full.
        XCTAssertEqual(
            policy.choose(profiles: [a, b], snapshots: ["b": snapshot("b", five: 91)], now: now, current: "b")?.id, "a")
    }

    func testResolverRemembersEachAutoFoldersAccount() throws {
        let box = try Sandbox()
        let service = AppService(env: box.env)
        let work = try service.profiles.create(displayName: "work")
        let personal = try service.profiles.create(displayName: "personal")
        let project = try box.mkdir("p")
        try service.assign(folder: project.path, to: Profile.autoID)
        try AutoPolicyStore(env: box.env).save(AutoPolicy(order: [work.id, personal.id]))
        let usage = UsageStore(env: box.env)
        func resolved() -> String? {
            if case .routed(let p, _) = Resolver(env: box.env).resolve(cwd: project.path) { return p.id }
            return nil
        }

        try usage.save(snapshot(work.id, five: 95).withCapture(Date()))
        XCTAssertEqual(resolved(), personal.id)
        // Work's session resets: the folder (its window, chats and account checks) stays put.
        try usage.save(snapshot(work.id, five: 5).withCapture(Date()))
        XCTAssertEqual(resolved(), personal.id)
        // Personal fills up: now it moves on.
        try usage.save(snapshot(personal.id, five: 92).withCapture(Date()))
        XCTAssertEqual(resolved(), work.id)
    }

    func testResolverRoutesAutoFolders() throws {
        let box = try Sandbox()
        let service = AppService(env: box.env)
        let work = try service.profiles.create(displayName: "work")
        let personal = try service.profiles.create(displayName: "personal")
        let project = try box.mkdir("p")
        try service.assign(folder: project.path, to: Profile.autoID)
        try AutoPolicyStore(env: box.env).save(AutoPolicy(order: [work.id, personal.id]))
        try UsageStore(env: box.env).save(snapshot(work.id, five: 95, seven: 10).withCapture(Date()))

        guard case .routed(let p, let route) = Resolver(env: box.env).resolve(cwd: project.path) else {
            return XCTFail("expected routed")
        }
        XCTAssertEqual(p.id, personal.id)
        XCTAssertEqual(route.profileId, Profile.autoID)
    }

    func testUnreadableAutoSettingsFailClosed() throws {
        let box = try Sandbox()
        let service = AppService(env: box.env)
        _ = try service.profiles.create(displayName: "work")
        let project = try box.mkdir("p")
        try service.assign(folder: project.path, to: Profile.autoID)
        try SafeFS.writeAtomic(Data("{ nope".utf8), to: box.env.paths.autoPolicyFile)
        guard case .refused(let r) = Resolver(env: box.env).resolve(cwd: project.path) else { return XCTFail("expected refusal") }
        XCTAssertEqual(r.code, .autoPolicyCorrupt)

        try SafeFS.writeAtomic(Data(#"{"version":1,"order":[],"threshold":90,"runOutMinutes":30,"moveOpenChats":true}"#.utf8), to: box.env.paths.autoPolicyFile)
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o666)], ofItemAtPath: box.env.paths.autoPolicyFile.path)
        guard case .refused(let r2) = Resolver(env: box.env).resolve(cwd: project.path) else { return XCTFail("expected refusal") }
        XCTAssertEqual(r2.code, .autoPolicyInsecure)
    }

    func testAutoIsReservedForProfiles() throws {
        let box = try Sandbox()
        let p = try ProfileStore(env: box.env).create(displayName: "Auto")
        XCTAssertNotEqual(p.id, Profile.autoID)
    }

    func testLauncherHandsOffResumedConversation() throws {
        let box = try Sandbox()
        let claude = try box.fakeExecutable("tools/claude")
        var env = box.env
        env.processEnv = ["SPILLOVER_REAL_CLAUDE": claude.path, "PATH": "/usr/bin"]
        let service = AppService(env: env)
        let work = try service.profiles.create(displayName: "work")
        let personal = try service.profiles.create(displayName: "personal")
        let project = try box.mkdir("p")
        try service.assign(folder: project.path, to: personal.id)
        let id = "1b671a64-40d5-491e-99b0-da01ff1f3341"
        try box.write(".spillover/profiles/work/projects/\(ConversationStore.projectKey(cwd: project.path))/\(id).jsonl", "history\n")

        let decision = LaunchPlanner(env: env).plan(
            LaunchRequest(mode: .editorWrapper, cwd: project.path, args: ["--resume=\(id)"], environment: env.processEnv))
        guard case .exec(let plan, _) = decision else { return XCTFail("\(decision)") }
        XCTAssertEqual(plan.environment["CLAUDE_CONFIG_DIR"], personal.configDir)
        XCTAssertNotNil(ConversationStore(env: env).transcript(id: id, cwd: project.path, in: personal))
        XCTAssertTrue(LaunchLog(env: env).tail(1).first?.contains("+handoff:work") ?? false)
        _ = work
    }
}

private extension UsageSnapshot {
    func withCapture(_ date: Date) -> UsageSnapshot {
        var s = self
        s.capturedAt = date
        s.windows = s.windows.map { w in
            var w = w
            w.resetsAt = date.addingTimeInterval(w.kind == .fiveHour ? 4 * 3600 : 5 * 86400)
            return w
        }
        return s
    }
}

final class EditorLifecycleTests: XCTestCase {
    private func bundle(_ box: Sandbox, _ editorDir: String, _ version: String) throws -> URL {
        try box.fakeExecutable("\(editorDir)/extensions/anthropic.claude-code-\(version)-darwin-arm64/resources/native-binary/claude")
    }

    func testWindowNotYetReloadedGetsItsOwnBinary() throws {
        let box = try Sandbox()
        let old = try bundle(box, ".vscode", "2.1.300")
        let new = try bundle(box, ".vscode", "2.1.310")
        try box.write(".vscode/extensions/.obsolete", #"{"anthropic.claude-code-2.1.300-darwin-arm64":true}"#)
        let locator = RealClaudeLocator(env: box.env)
        let host = "/Applications/Visual Studio Code.app/Contents/Frameworks/Code Helper (Plugin).app/Contents/MacOS/Code Helper (Plugin)"
        // The old extension (SDK 0.3.300) still runs in a window that was not reloaded.
        XCTAssertEqual(locator.locate(mode: .editorWrapper, baseEnv: ["CLAUDE_AGENT_SDK_VERSION": "0.3.300"], parentExecutable: host), old.path)
        XCTAssertEqual(locator.locate(mode: .editorWrapper, baseEnv: ["CLAUDE_AGENT_SDK_VERSION": "0.3.310"], parentExecutable: host), new.path)
        // Unknown SDK: the newest version that is not obsolete.
        XCTAssertEqual(locator.locate(mode: .editorWrapper, baseEnv: [:], parentExecutable: host), new.path)
    }

    func testEachEditorUsesItsOwnExtension() throws {
        let box = try Sandbox()
        let code = try bundle(box, ".vscode", "2.1.310")
        let cursor = try bundle(box, ".cursor", "2.1.200")
        let locator = RealClaudeLocator(env: box.env)
        XCTAssertEqual(locator.locate(mode: .editorWrapper, baseEnv: [:], parentExecutable: "/Applications/Cursor.app/Contents/Frameworks/Cursor Helper (Plugin).app/Contents/MacOS/x"), cursor.path)
        XCTAssertEqual(locator.locate(mode: .editorWrapper, baseEnv: [:], parentExecutable: "/Applications/Visual Studio Code.app/Contents/MacOS/x"), code.path)
        // Unknown parent: newest anywhere.
        XCTAssertEqual(locator.locate(mode: .editorWrapper, baseEnv: [:], parentExecutable: nil), code.path)
    }

    func testEditorOwningAnApp() {
        XCTAssertEqual(Editor.owning(appExecutable: "/Applications/Visual Studio Code - Insiders.app/Contents/MacOS/Electron"), .insiders)
        XCTAssertEqual(Editor.owning(appExecutable: "/Applications/Visual Studio Code.app/Contents/MacOS/Electron"), .code)
        XCTAssertNil(Editor.owning(appExecutable: "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal"))
    }

    func testReopenLinkDetection() throws {
        XCTAssertTrue(ExtensionContract.handlesReopenLink(Data(#"x.registerUriHandler({handleUri(O){switch(O.path){case"/open":{let x=R.get("session")"#.utf8)))
        XCTAssertFalse(ExtensionContract.handlesReopenLink(Data(#"x.registerUriHandler({handleUri(O){switch(O.path){case"/install-plugin":{}"#.utf8)))

        let box = try Sandbox()
        try box.write(".vscode/extensions/anthropic.claude-code-2.1.310-darwin-arm64/package.json",
                      #"{"contributes":{"configuration":{"properties":{"claudeCode.claudeProcessWrapper":{"scope":"machine"}}}}}"#)
        try box.write(".vscode/extensions/anthropic.claude-code-2.1.310-darwin-arm64/extension.js", #"registerUriHandler case"/open" get("session")"#)
        let c = ExtensionContract.check(editor: .code, env: box.env)
        XCTAssertEqual(c.finding, .ok)
        XCTAssertEqual(c.extensionVersion, "2.1.310")
        XCTAssertTrue(c.reopensChats)
    }
}
