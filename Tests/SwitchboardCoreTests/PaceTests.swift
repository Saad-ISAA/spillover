import Foundation
import XCTest

@testable import SwitchboardCore

final class UsageHistoryTests: XCTestCase {
    private func point(_ t: TimeInterval, _ five: Double, _ seven: Double = 10) -> UsagePoint {
        UsagePoint(
            at: Date(timeIntervalSince1970: t), fiveHour: five, fiveHourResetsAt: Date(timeIntervalSince1970: 50_000),
            sevenDay: seven, sevenDayResetsAt: Date(timeIntervalSince1970: 900_000))
    }

    func testRepeatsAreSkippedUntilTheIntervalPasses() {
        var points = UsageHistory.appending(point(1000, 20), to: [])
        points = UsageHistory.appending(point(1060, 20), to: points)
        XCTAssertEqual(points.count, 1)
        points = UsageHistory.appending(point(1000 + UsageHistory.unchangedInterval, 20), to: points)
        XCTAssertEqual(points.count, 2)
        points = UsageHistory.appending(point(1000 + UsageHistory.unchangedInterval + 5, 21), to: points)
        XCTAssertEqual(points.count, 3)
    }

    func testOldPointsArePrunedAndOrderKept() {
        let old = point(0, 5)
        let recent = point(UsageHistory.retention + 100, 30)
        let points = UsageHistory.appending(point(UsageHistory.retention + 50, 25), to: [old, recent])
        XCTAssertEqual(points.map(\.fiveHour), [25, 30])
    }

    func testRecordAndLoadRoundTrip() throws {
        let box = try Sandbox()
        let work = try ProfileStore(env: box.env).create(displayName: "work")
        let snapshot = UsageSnapshot(
            profileId: work.id, capturedAt: Date(timeIntervalSince1970: 2_000_000_000),
            windows: [.init(kind: .fiveHour, usedPercentage: 42, resetsAt: Date(timeIntervalSince1970: 2_000_010_000))])
        let history = UsageHistory(env: box.env)
        try history.record(snapshot)
        try history.record(snapshot)
        let loaded = history.load(profileId: work.id)
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.fiveHour, 42)
        XCTAssertNil(loaded.first?.sevenDay)
        XCTAssertEqual(SafeFS.permissions(of: history.url(for: work.id)), 0o600)
    }

    func testStatuslineCaptureRecordsHistory() throws {
        let box = try Sandbox()
        let work = try ProfileStore(env: box.env).create(displayName: "work")
        let input = #"{"rate_limits":{"five_hour":{"used_percentage":12,"resets_at":2000000000}}}"#
        _ = StatuslineCapture(env: box.env, runner: FakeRunner())
            .handle(input: Data(input.utf8), processEnv: ["CLAUDE_CONFIG_DIR": work.configDir!])
        XCTAssertEqual(UsageHistory(env: box.env).load(profileId: work.id).first?.fiveHour, 12)
    }
}

final class PaceForecastTests: XCTestCase {
    let reset = Date(timeIntervalSince1970: 1_000_000)

    private func window(_ used: Double, kind: UsageWindow.Kind = .fiveHour) -> UsageWindow {
        UsageWindow(kind: kind, usedPercentage: used, resetsAt: reset)
    }

    func testRunsOutBeforeReset() throws {
        // 5h window, 2h50m left → 2h10m elapsed with 60% used: 100% after ~1h27m more.
        let now = reset.addingTimeInterval(-(2 * 3600 + 50 * 60))
        let f = try XCTUnwrap(PaceForecast.forecast(window(60), now: now))
        guard case .runsOut(let at, let early) = f.outlook else { return XCTFail("\(f.outlook)") }
        XCTAssertEqual(at.timeIntervalSince(now), 40 * 130 * 60 / 60, accuracy: 1)
        XCTAssertEqual(early, reset.timeIntervalSince(at), accuracy: 0.001)
        XCTAssertGreaterThan(f.paceDelta, 0)
    }

    func testLastsUntilReset() throws {
        // Half the week gone, 20% used: about 40% at the reset.
        let now = reset.addingTimeInterval(-3.5 * 86400)
        let f = try XCTUnwrap(PaceForecast.forecast(window(20, kind: .sevenDay), now: now))
        guard case .lastsUntilReset(let projected) = f.outlook else { return XCTFail("\(f.outlook)") }
        XCTAssertEqual(projected, 40, accuracy: 0.01)
        XCTAssertEqual(f.elapsedFraction, 0.5, accuracy: 0.0001)
        XCTAssertEqual(f.paceDelta, -30, accuracy: 0.01)
    }

    func testEdgeCases() {
        let early = reset.addingTimeInterval(-4.9 * 3600)
        XCTAssertEqual(PaceForecast.forecast(window(10), now: early)?.outlook, .tooEarly)
        XCTAssertEqual(PaceForecast.forecast(window(0), now: early)?.outlook, .idle)
        XCTAssertEqual(PaceForecast.forecast(window(100), now: early)?.outlook, .full)
        XCTAssertNil(PaceForecast.forecast(window(50), now: reset.addingTimeInterval(1)))
        XCTAssertNil(PaceForecast.forecast(window(50, kind: .spendLimit), now: early))
    }
}
