import Foundation
import XCTest

@testable import SwitchboardCore

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
        try transcript(box, ".switchboard/profiles/work", cwd: cwd, text: "{\"a\":1}\n")
        try box.write(".switchboard/profiles/work/projects/\(ConversationStore.projectKey(cwd: cwd))/\(id)/sub.jsonl", "s")
        try box.write(".switchboard/profiles/work/file-history/\(id)/f1", "v1")

        let conversations = ConversationStore(env: box.env)
        let all = try store.all()
        XCTAssertEqual(try conversations.ensure(id: id, cwd: cwd, target: personal, among: all), .copied(fromProfile: "work"))
        let copied = try XCTUnwrap(conversations.transcript(id: id, cwd: cwd, in: personal))
        XCTAssertEqual(box.read(copied), "{\"a\":1}\n")
        XCTAssertEqual(SafeFS.permissions(of: copied), 0o600)
        XCTAssertTrue(FileManager.default.fileExists(atPath: box.home.path + "/.switchboard/profiles/personal/projects/\(ConversationStore.projectKey(cwd: cwd))/\(id)/sub.jsonl"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: box.home.path + "/.switchboard/profiles/personal/file-history/\(id)/f1"))
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
        try transcript(box, ".switchboard/profiles/work", cwd: "/elsewhere", text: "x")
        let conversations = ConversationStore(env: box.env)
        XCTAssertEqual(
            try conversations.ensure(id: id, cwd: nil, target: .builtInDefault(), among: try store.all()),
            .copied(fromProfile: "work"))
        XCTAssertNotNil(conversations.transcript(id: id, cwd: "/elsewhere", in: .builtInDefault()))
    }

    func testActivityState() {
        let done = #"{"type":"assistant","message":{"stop_reason":"end_turn","content":[]}}"# + "\n" + #"{"type":"ai-title","title":"x"}"#
        let tool = #"{"type":"assistant","message":{"stop_reason":"tool_use"}}"#
        let user = #"{"type":"user","message":{"content":[{"type":"tool_result"}]}}"#
        XCTAssertEqual(ConversationActivity.state(tail: Data(done.utf8), quietFor: 10), .idle)
        XCTAssertEqual(ConversationActivity.state(tail: Data(done.utf8), quietFor: 1), .busy)
        XCTAssertEqual(ConversationActivity.state(tail: Data(tool.utf8), quietFor: 30), .busy)
        XCTAssertEqual(ConversationActivity.state(tail: Data(user.utf8), quietFor: 300), .stalled)
    }

    func testEditorHostingAndSessionURL() {
        XCTAssertEqual(Editor.hosting(executable: "/Users/example/.vscode/extensions/anthropic.claude-code-2.1.310-darwin-arm64/resources/native-binary/claude"), .code)
        XCTAssertEqual(Editor.hosting(executable: "/Users/example/.vscode-insiders/extensions/anthropic.claude-code-1/resources/native-binary/claude"), .insiders)
        XCTAssertNil(Editor.hosting(executable: "/Users/example/.local/share/claude/versions/2.1.266"))
        XCTAssertEqual(Editor.code.claudeSessionURL(id)?.absoluteString, "vscode://anthropic.claude-code/open?session=\(id)")
        XCTAssertNil(Editor.code.claudeSessionURL("../x"))
    }

    func testEndRefusesAReusedPid() {
        let a = RunningSession(pid: 10, executable: "/x/claude", cwd: "/p", configDir: nil, switchboardProfile: nil, startedAt: Date(timeIntervalSince1970: 1), conversationId: id)
        let b = RunningSession(pid: 10, executable: "/x/claude", cwd: "/p", configDir: nil, switchboardProfile: nil, startedAt: Date(timeIntervalSince1970: 2), conversationId: id)
        XCTAssertTrue(SessionControl.isSameChat(a, a))
        XCTAssertFalse(SessionControl.isSameChat(a, b))
        XCTAssertThrowsError(try SessionControl.end(RunningSession(pid: 999_999, executable: "/x/claude", cwd: nil, configDir: nil, switchboardProfile: nil, startedAt: nil)))
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

    func testChoosesFirstAccountWithRoomInOrder() {
        let a = Profile(id: "a", displayName: "A", configDir: "/a")
        let b = Profile(id: "b", displayName: "B", configDir: "/b")
        let c = Profile(id: "c", displayName: "C", configDir: "/c")
        let policy = AutoPolicy(order: ["b", "a", "c"])
        let snaps = ["b": snapshot("b", five: 92), "a": snapshot("a", five: 40)]
        XCTAssertEqual(policy.choose(profiles: [a, b, c], snapshots: snaps, now: now)?.id, "a")
        // Unknown usage counts as room.
        XCTAssertEqual(AutoPolicy(order: ["c", "a"]).choose(profiles: [a, b, c], snapshots: snaps, now: now)?.id, "c")
        // Nobody has room: the least used one.
        let full = ["a": snapshot("a", five: 99), "b": snapshot("b", five: 93), "c": snapshot("c", five: 97)]
        XCTAssertEqual(policy.choose(profiles: [a, b, c], snapshots: full, now: now)?.id, "b")
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
        env.processEnv = ["SWITCHBOARD_REAL_CLAUDE": claude.path, "PATH": "/usr/bin"]
        let service = AppService(env: env)
        let work = try service.profiles.create(displayName: "work")
        let personal = try service.profiles.create(displayName: "personal")
        let project = try box.mkdir("p")
        try service.assign(folder: project.path, to: personal.id)
        let id = "1b671a64-40d5-491e-99b0-da01ff1f3341"
        try box.write(".switchboard/profiles/work/projects/\(ConversationStore.projectKey(cwd: project.path))/\(id).jsonl", "history\n")

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
