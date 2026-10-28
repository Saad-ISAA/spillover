import Foundation
import XCTest

@testable import SpilloverCore

final class LimitStopsTests: XCTestCase {
    private let stamp: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private func lines(_ records: [String]) -> Data { Data(records.joined(separator: "\n").utf8) }

    private let limit = #"{"type":"assistant","timestamp":"2026-10-28T21:49:49.000Z","cwd":"/Users/example/Code/shop","entrypoint":"claude-vscode","isSidechain":false,"error":"rate_limit","isApiErrorMessage":true,"message":{"content":[{"type":"text","text":"You've hit your 5-hour limit · resets 1:20am"}]}}"#
    private let prompt = #"{"type":"user","timestamp":"2026-10-28T21:40:00.000Z","cwd":"/Users/example/Code/shop","message":{"content":"build the wallet"}}"#

    func testAChatEndingOnALimitIsStopped() throws {
        let note = #"{"type":"system","timestamp":"2026-10-28T21:49:50.000Z","content":"Remote Control disabled."}"#
        let title = #"{"type":"ai-title","aiTitle":"Flutter app session recovery","sessionId":"x"}"#
        let stop = try XCTUnwrap(LimitStops.stop(tail: lines([prompt, limit, note, title])))
        XCTAssertEqual(stop.at, stamp.date(from: "2026-10-28T21:49:49.000Z"))
        XCTAssertEqual(stop.cwd, "/Users/example/Code/shop")
        XCTAssertEqual(stop.entrypoint, "claude-vscode")
    }

    func testBackgroundNoticesAndSubagentsDoNotContinueIt() {
        let notice = #"{"type":"user","timestamp":"2026-10-28T21:50:10.000Z","message":{"content":"<task-notification> <task-id>a1</task-id> <status>failed</status>"}}"#
        let sub = #"{"type":"assistant","timestamp":"2026-10-28T21:50:20.000Z","isSidechain":true,"message":{"content":[]}}"#
        XCTAssertNotNil(LimitStops.stop(tail: lines([prompt, limit, notice, sub])))
    }

    func testAChatThatWasAnsweredOrResumedIsNotStopped() {
        let resumed = #"{"type":"user","timestamp":"2026-10-28T22:24:32.000Z","message":{"content":"resume all"}}"#
        XCTAssertNil(LimitStops.stop(tail: lines([prompt, limit, resumed])))
        let fine = #"{"type":"assistant","timestamp":"2026-10-28T21:41:00.000Z","message":{"content":[{"type":"text","text":"Done."}]}}"#
        XCTAssertNil(LimitStops.stop(tail: lines([prompt, fine])))
        XCTAssertNil(LimitStops.stop(tail: Data()))
    }

    func testTitleIsTheRenamedOneElseTheGeneratedOne() throws {
        let ai = #"{"type":"ai-title","aiTitle":"Open_mall platform architecture","sessionId":"x"}"#
        let custom = #"{"type":"custom-title","customTitle":"Open mall","sessionId":"x"}"#
        XCTAssertEqual(LimitStops.title(tail: lines([ai])), "Open_mall platform architecture")
        XCTAssertEqual(LimitStops.title(tail: lines([custom, ai])), "Open mall")
        XCTAssertNil(LimitStops.title(tail: lines([prompt])))

        let box = try Sandbox()
        let transcript = try box.write("projects/p/abc.jsonl", ai)
        XCTAssertEqual(LimitStops.title(transcript: transcript), "Open_mall platform architecture")
        try box.write("projects/p/abc/custom-title.json", #"{"customTitle":"Open mall"}"#)
        XCTAssertEqual(LimitStops.title(transcript: transcript), "Open mall")
    }

    func testScanFindsTheNewestCopyOfEachStoppedChat() throws {
        let box = try Sandbox()
        let store = ProfileStore(env: box.env)
        let work = try store.create(displayName: "work")
        let id = "aa2b4c04-b973-4b65-852b-9336da28ecc1"
        // An older copy on the default account was answered; the newest copy (work) hit the limit.
        try box.write(".claude/projects/-Users-example-Code-shop/\(id).jsonl", prompt)
        let newest = URL(fileURLWithPath: work.configDir!).appendingPathComponent("projects/-Users-example-Code-shop/\(id).jsonl")
        try FileManager.default.createDirectory(at: newest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try lines([prompt, limit, #"{"type":"ai-title","aiTitle":"Wallet","sessionId":"x"}"#]).write(to: newest)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-3600)],
            ofItemAtPath: box.home.appendingPathComponent(".claude/projects/-Users-example-Code-shop/\(id).jsonl").path)

        // An agent run in a worktree (not a chat in a panel) is never picked up.
        let agent = limit.replacingOccurrences(of: "claude-vscode", with: "sdk-py")
        try box.write(".claude/projects/-Users-example-Code-shop--worktrees-a1/1b671a64-40d5-491e-99b0-da01ff1f3341.jsonl", agent)

        let stops = LimitStops(env: box.env).scan(profiles: try store.all())
        XCTAssertEqual(stops.count, 1)
        XCTAssertEqual(stops.first?.conversationId, id)
        XCTAssertEqual(stops.first?.profileId, work.id)
        XCTAssertEqual(stops.first?.title, "Wallet")
        XCTAssertEqual(stops.first?.cwd, "/Users/example/Code/shop")
    }

    func testRoomStartsWhenTheLimitedWindowResets() {
        let stopped = Date(timeIntervalSince1970: 1_000_000)
        let reset = stopped.addingTimeInterval(1800)
        // A reading at the limit: room starts at its window's reset, and is expected a minute later.
        let atLimit = UsageSnapshot(profileId: "a", capturedAt: stopped.addingTimeInterval(60), windows: [
            .init(kind: .fiveHour, usedPercentage: 100, resetsAt: reset),
            .init(kind: .sevenDay, usedPercentage: 40, resetsAt: stopped.addingTimeInterval(5 * 86400)),
        ])
        XCTAssertNil(LimitStops.roomSince(atLimit, after: stopped, now: reset.addingTimeInterval(-10)))
        XCTAssertEqual(LimitStops.expectedResume(atLimit, now: stopped), reset.addingTimeInterval(LimitStops.grace))
        XCTAssertEqual(LimitStops.roomSince(atLimit, after: stopped, now: reset.addingTimeInterval(5)), reset)

        // A reading taken after the stop that shows room (another account, or after the reset).
        let roomy = UsageSnapshot(profileId: "b", capturedAt: stopped.addingTimeInterval(120), windows: [
            .init(kind: .fiveHour, usedPercentage: 20, resetsAt: reset)
        ])
        XCTAssertEqual(LimitStops.roomSince(roomy, after: stopped, now: stopped.addingTimeInterval(130)), roomy.capturedAt)
        // A reading from before the stop proves nothing.
        let old = UsageSnapshot(profileId: "b", capturedAt: stopped.addingTimeInterval(-60), windows: roomy.windows)
        XCTAssertNil(LimitStops.roomSince(old, after: stopped, now: stopped.addingTimeInterval(130)))
        XCTAssertNil(LimitStops.roomSince(nil, after: stopped))
    }

    func testHistoryDatesTheRoomAndOldStopsAreMissed() {
        let stopped = Date(timeIntervalSince1970: 1_000_000)
        let reset = stopped.addingTimeInterval(1800)
        let now = stopped.addingTimeInterval(3 * 86400)
        let latest = UsageSnapshot(profileId: "a", capturedAt: now.addingTimeInterval(-30), windows: [
            .init(kind: .fiveHour, usedPercentage: 3, resetsAt: now.addingTimeInterval(4 * 3600))
        ])
        let history = [
            UsagePoint(at: stopped.addingTimeInterval(-600), fiveHour: 90, fiveHourResetsAt: reset),
            UsagePoint(at: stopped.addingTimeInterval(300), fiveHour: 100, fiveHourResetsAt: reset),
            UsagePoint(at: reset.addingTimeInterval(120), fiveHour: 1, fiveHourResetsAt: reset.addingTimeInterval(5 * 3600)),
        ]
        // The last reading at the limit after the stop dates the room by its window's reset...
        XCTAssertEqual(LimitStops.roomSince(latest, history: history, after: stopped, now: now), reset)
        // ...or the first reading after the stop, when none was at the limit.
        XCTAssertEqual(
            LimitStops.roomSince(latest, history: [history[0], history[2]], after: stopped, now: now), history[2].at)
        // Days later, a stop whose account has long had room is missed, not resumed.
        let entry = LimitResumeLog.Entry(stoppedAt: stopped, roomSince: reset)
        XCTAssertFalse(LimitResumeLog.isDue(entry, now: now))
        XCTAssertTrue(LimitResumeLog.isMissed(entry, now: now))
        XCTAssertTrue(LimitResumeLog.isDue(entry, now: reset.addingTimeInterval(2 * 3600)))
    }

    func testEachStopIsResumedOnceAfterTheGracePeriod() throws {
        let box = try Sandbox()
        try SafeFS.ensureDir(box.env.paths.root)
        let log = LimitResumeLog(env: box.env)
        let stopped = Date().addingTimeInterval(-3600)
        let stop = LimitStop(
            conversationId: "aa2b4c04-b973-4b65-852b-9336da28ecc1", cwd: "/Users/example/Code/shop", title: "Wallet",
            stoppedAt: stopped, profileId: "work", transcript: URL(fileURLWithPath: "/dev/null"))

        // No room yet: not due.
        XCTAssertFalse(LimitResumeLog.isDue(log.note(stop, roomSince: nil)))
        // Room for 30 seconds: still within the grace period.
        let since = Date().addingTimeInterval(-30)
        XCTAssertFalse(LimitResumeLog.isDue(log.note(stop, roomSince: since)))
        // A later reading cannot push the start of the room forward.
        let entry = log.note(stop, roomSince: Date())
        XCTAssertEqual(entry.roomSince.map { Int($0.timeIntervalSince1970) }, Int(since.timeIntervalSince1970))
        XCTAssertTrue(LimitResumeLog.isDue(entry, now: since.addingTimeInterval(LimitStops.grace)))

        // Acted on once, never again for this stop.
        log.recordAttempt(stop, outcome: "resumed")
        XCTAssertFalse(LimitResumeLog.isDue(log.note(stop, roomSince: since), now: Date().addingTimeInterval(3600)))
        XCTAssertEqual(log.entries()[stop.conversationId]?.outcome, "resumed")

        // A new stop of the same chat is a new entry.
        let again = LimitStop(
            conversationId: stop.conversationId, cwd: stop.cwd, title: stop.title, stoppedAt: Date().addingTimeInterval(-60),
            profileId: "work", transcript: stop.transcript)
        let fresh = log.note(again, roomSince: Date().addingTimeInterval(-120))
        XCTAssertNil(fresh.attemptedAt)
        XCTAssertTrue(LimitResumeLog.isDue(fresh))
    }

    func testResumingIsOffUntilTurnedOnAndOlderFilesLoad() throws {
        XCTAssertFalse(AutoPolicy().resumeChats)
        let box = try Sandbox()
        try SafeFS.ensureDir(box.env.paths.root)
        try SafeFS.writeAtomic(Data(#"{"version":1,"threshold":80}"#.utf8), to: box.env.paths.autoPolicyFile)
        guard case .loaded(let p) = AutoPolicyStore(env: box.env).load() else { return XCTFail("expected loaded") }
        XCTAssertFalse(p.resumeChats)
    }

    func testLookingAheadDoesNotChangeTheFoldersAccount() throws {
        let box = try Sandbox()
        let service = AppService(env: box.env)
        let a = try service.profiles.create(displayName: "a")
        _ = try service.profiles.create(displayName: "b")
        let project = try box.mkdir("p")
        try service.assign(folder: project.path, to: Profile.autoID)
        let choices = AutoChoices(env: box.env)
        _ = Resolver(env: box.env).resolve(cwd: project.path, preferring: a.id, record: false)
        XCTAssertNil(choices.current(folder: project.path))
        _ = Resolver(env: box.env).resolve(cwd: project.path, preferring: a.id)
        XCTAssertNotNil(choices.current(folder: project.path))
    }
}
