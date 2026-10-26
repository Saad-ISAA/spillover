import Foundation
import XCTest

@testable import SwitchboardCore

final class StatuslineCaptureTests: XCTestCase {
    let sample = """
        {"model":{"id":"claude-x","display_name":"Model X"},
         "rate_limits":{"five_hour":{"used_percentage":23.4,"resets_at":2000000000},
                        "seven_day":{"used_percentage":70,"resets_at":2000500000}}}
        """

    func testParseRateLimits() throws {
        let s = try XCTUnwrap(StatuslineCapture.parse(Data(sample.utf8), profileId: "work"))
        XCTAssertEqual(s.model, "Model X")
        XCTAssertEqual(s.window(.fiveHour)?.usedPercentage, 23.4)
        XCTAssertEqual(s.window(.sevenDay)?.resetsAt, Date(timeIntervalSince1970: 2_000_500_000))
        XCTAssertNil(s.window(.spendLimit))
    }

    func testNoRateLimitsMeansNoWindows() throws {
        let s = try XCTUnwrap(StatuslineCapture.parse(Data("{}".utf8), profileId: "w"))
        XCTAssertTrue(s.windows.isEmpty)
        XCTAssertNil(StatuslineCapture.parse(Data("nope".utf8), profileId: "w"))
    }

    func testRender() throws {
        let s = try XCTUnwrap(StatuslineCapture.parse(Data(sample.utf8), profileId: "work"))
        let now = Date(timeIntervalSince1970: 1_999_999_000)
        XCTAssertEqual(StatuslineCapture.render(snapshot: s, profileName: "Work", now: now), "Work · 5h 23% · 7d 70%")
        let later = Date(timeIntervalSince1970: 2_000_000_001)
        XCTAssertEqual(StatuslineCapture.render(snapshot: s, profileName: "Work", now: later), "Work · 5h 0% · 7d 70%")
    }

    func testActiveProfileDetection() throws {
        let box = try Sandbox()
        let work = try ProfileStore(env: box.env).create(displayName: "work")
        let capture = StatuslineCapture(env: box.env, runner: FakeRunner())
        XCTAssertEqual(capture.activeProfileID(processEnv: ["SWITCHBOARD_PROFILE": "work"]), "work")
        XCTAssertEqual(capture.activeProfileID(processEnv: ["SWITCHBOARD_PROFILE": "ghost"]), "default")
        XCTAssertEqual(capture.activeProfileID(processEnv: ["CLAUDE_CONFIG_DIR": work.configDir! + "/"]), "work")
        XCTAssertEqual(capture.activeProfileID(processEnv: [:]), "default")
    }

    func testHandleStoresSnapshotAndChainsOriginalCommand() throws {
        let box = try Sandbox()
        try box.fakeExecutable(".switchboard/bin/switchboard")
        let work = try ProfileStore(env: box.env).create(displayName: "work")
        try box.write(
            ".switchboard/profiles/work/settings.json",
            "{\n  \"statusLine\": {\"type\": \"command\", \"command\": \"my-line\"}\n}")
        try StatuslineInstaller(env: box.env).install(for: work)

        let runner = FakeRunner()
        runner.handler = { _, _ in CommandResult(status: 0, stdout: "their line\n") }
        let out = StatuslineCapture(env: box.env, runner: runner)
            .handle(input: Data(sample.utf8), processEnv: ["SWITCHBOARD_PROFILE": "work"])
        XCTAssertEqual(out, "their line")
        XCTAssertEqual(runner.calls.first?.args, ["-c", "my-line"])
        XCTAssertEqual(runner.calls.first?.stdin, Data(sample.utf8))
        XCTAssertEqual(UsageStore(env: box.env).load(profileId: "work")?.window(.sevenDay)?.usedPercentage, 70)
    }
}

final class StatuslineInstallerTests: XCTestCase {
    func testInstallAndRestoreOriginal() throws {
        let box = try Sandbox()
        try box.fakeExecutable(".switchboard/bin/switchboard")
        let work = try ProfileStore(env: box.env).create(displayName: "work")
        let original = "{\n  \"statusLine\": {\"type\": \"command\", \"command\": \"mine\"},\n  \"model\": \"x\"\n}"
        let url = try box.write(".switchboard/profiles/work/settings.json", original)
        let installer = StatuslineInstaller(env: box.env)
        try installer.install(for: work)
        XCTAssertTrue(installer.isInstalled(for: work))
        XCTAssertEqual(installer.chainedCommand(profileId: "work"), "mine")
        try installer.install(for: work)  // idempotent, keeps the recorded original
        XCTAssertEqual(installer.chainedCommand(profileId: "work"), "mine")
        try installer.uninstall(for: work)
        XCTAssertEqual(box.read(url), original)
    }

    func testFollowsSharedSettingsSymlink() throws {
        let box = try Sandbox()
        try box.fakeExecutable(".switchboard/bin/switchboard")
        let shared = try box.write(".claude/settings.json", "{}")
        let work = try ProfileStore(env: box.env).create(displayName: "work")
        try ProfileSharing(env: box.env).share("settings.json", from: .builtInDefault(), to: work)
        try StatuslineInstaller(env: box.env).install(for: work)
        let link = URL(fileURLWithPath: work.configDir!).appendingPathComponent("settings.json")
        XCTAssertNotNil(try? FileManager.default.destinationOfSymbolicLink(atPath: link.path))
        XCTAssertTrue(box.read(shared).contains("statusline"))
    }

    func testRequiresInstalledCLI() throws {
        let box = try Sandbox()
        XCTAssertThrowsError(try StatuslineInstaller(env: box.env).install(for: .builtInDefault()))
    }
}

final class LocalUsageScannerTests: XCTestCase {
    func testAccumulateDeduplicatesAndFiltersByDate() {
        let lines = [
            #"{"type":"assistant","timestamp":"2026-10-20T10:00:00.000Z","cwd":"/p/a","message":{"id":"m1","model":"claude-x","usage":{"input_tokens":10,"output_tokens":5,"cache_creation_input_tokens":2,"cache_read_input_tokens":100}}}"#,
            #"{"type":"assistant","timestamp":"2026-10-20T10:00:01.000Z","cwd":"/p/a","message":{"id":"m1","model":"claude-x","usage":{"input_tokens":10,"output_tokens":5}}}"#,
            #"{"type":"assistant","timestamp":"2026-10-21T10:00:00Z","cwd":"/p/b","message":{"id":"m2","model":"claude-y","usage":{"input_tokens":1,"output_tokens":1}}}"#,
            #"{"type":"assistant","timestamp":"2026-01-01T00:00:00Z","message":{"id":"old","model":"claude-x","usage":{"input_tokens":999}}}"#,
            #"{"type":"user","message":{"content":"hello"}}"#,
            "not json at all \"usage\"",
        ].joined(separator: "\n")
        var seen = Set<String>()
        var report = UsageReport()
        let since = ISO8601DateFormatter().date(from: "2026-10-01T00:00:00Z")!
        LocalUsageScanner.accumulate(data: Data(lines.utf8), since: since, seen: &seen, into: &report)
        XCTAssertEqual(report.total.messages, 2)
        XCTAssertEqual(report.total.input, 11)
        XCTAssertEqual(report.total.cacheRead, 100)
        XCTAssertEqual(report.byModel["claude-x"]?.total, 117)
        XCTAssertEqual(report.byProject["/p/b"]?.messages, 1)
        XCTAssertEqual(report.byDay.keys.sorted(), ["2026-10-20", "2026-10-21"])
    }

    func testScanAppliesPricesAndReportsUnpriced() throws {
        let box = try Sandbox()
        let work = try ProfileStore(env: box.env).create(displayName: "work")
        let line = #"{"timestamp":"2099-01-01T00:00:00Z","message":{"id":"a","model":"claude-x-1","usage":{"input_tokens":1000000,"output_tokens":1000000}}}"#
        let line2 = #"{"timestamp":"2099-01-01T00:00:00Z","message":{"id":"b","model":"other","usage":{"input_tokens":5}}}"#
        try box.write(".switchboard/profiles/work/projects/-p/s.jsonl", line + "\n" + line2 + "\n")
        let prices = PriceTable(models: ["claude-x": .init(input: 3, output: 15, cacheWrite: nil, cacheRead: nil)])
        let report = LocalUsageScanner(env: box.env).scan(profile: work, since: .distantPast, prices: prices)
        XCTAssertEqual(report.pricedCostUSD, 18, accuracy: 0.0001)
        XCTAssertEqual(report.unpricedModels, ["other"])
    }
}

final class HeadroomAdvisorTests: XCTestCase {
    func testRanking() {
        let now = Date(timeIntervalSince1970: 1000)
        let future = Date(timeIntervalSince1970: 5000)
        let past = Date(timeIntervalSince1970: 10)
        let a = Profile(id: "a", displayName: "A", configDir: "/a")
        let b = Profile(id: "b", displayName: "B", configDir: "/b")
        let c = Profile(id: "c", displayName: "C", configDir: "/c")
        let snaps = [
            "a": UsageSnapshot(profileId: "a", capturedAt: now, windows: [.init(kind: .sevenDay, usedPercentage: 90, resetsAt: future)]),
            // b's window has already reset: effectively empty.
            "b": UsageSnapshot(profileId: "b", capturedAt: now, windows: [.init(kind: .fiveHour, usedPercentage: 99, resetsAt: past)]),
        ]
        let ranked = HeadroomAdvisor.rank(profiles: [a, b, c], snapshots: snaps, now: now)
        XCTAssertEqual(ranked.map(\.profile.id), ["b", "a", "c"])
        XCTAssertNil(ranked[2].peakPercentage)
        XCTAssertTrue(HeadroomAdvisor.isNearLimit(snaps["a"]!, now: now))
    }
}

final class RedactionTests: XCTestCase {
    func testScrubsCredentialShapes() {
        let text = #"key sk-ant-api03-abcdefghijklmnop and {"accessToken": "abc.def"} Bearer abcdefghijklmnopqrstu"#
        let out = Redaction.scrub(text)
        XCTAssertFalse(out.contains("sk-ant-api03"))
        XCTAssertFalse(out.contains("abc.def"))
        XCTAssertFalse(out.contains("abcdefghijklmnopqrstu"))
    }

    func testKeepsPaths() {
        let path = "/Users/example/Documents/Work/some-project-name/sub-folder/another-one"
        XCTAssertEqual(Redaction.scrub("cwd=\(path)"), "cwd=\(path)")
    }

    func testEmailMasking() {
        XCTAssertEqual(Redaction.email("person@example.com"), "p***@example.com")
        XCTAssertEqual(Redaction.email("nobody"), "nobody")
    }
}
