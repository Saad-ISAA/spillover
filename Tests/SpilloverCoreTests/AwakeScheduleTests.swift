import Foundation
import XCTest

@testable import SpilloverCore

final class AwakeScheduleTests: XCTestCase {
    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Riyadh")!
        return c
    }()

    private func at(_ hour: Int, _ minute: Int = 0, day: Int = 29) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    func testAWindowAcrossMidnight() {
        let night = AwakeSchedule(enabled: true, startMinute: 22 * 60, endMinute: 8 * 60)
        XCTAssertTrue(night.isActive(at: at(23), calendar: calendar))
        XCTAssertTrue(night.isActive(at: at(5), calendar: calendar))
        XCTAssertFalse(night.isActive(at: at(8), calendar: calendar))
        XCTAssertFalse(night.isActive(at: at(14), calendar: calendar))
        XCTAssertTrue(night.isActive(at: at(22), calendar: calendar))
        // Ends at 08:00 the same morning; starts again at 22:00.
        XCTAssertEqual(night.nextChange(after: at(5), calendar: calendar), at(8))
        XCTAssertEqual(night.nextChange(after: at(14), calendar: calendar), at(22))
        XCTAssertEqual(night.nextChange(after: at(23), calendar: calendar), at(8, day: 30))
    }

    func testAWindowWithinADayAndAllDay() {
        let day = AwakeSchedule(enabled: true, startMinute: 9 * 60 + 30, endMinute: 18 * 60)
        XCTAssertFalse(day.isActive(at: at(9, 29), calendar: calendar))
        XCTAssertTrue(day.isActive(at: at(9, 30), calendar: calendar))
        XCTAssertFalse(day.isActive(at: at(18), calendar: calendar))
        let always = AwakeSchedule(enabled: true, startMinute: 0, endMinute: 0)
        XCTAssertTrue(always.isActive(at: at(3), calendar: calendar))
        XCTAssertNil(always.nextChange(after: at(3), calendar: calendar))
    }

    func testOffUnlessTurnedOn() throws {
        XCTAssertFalse(AwakeSchedule().isActive(at: at(23), calendar: calendar))
        let box = try Sandbox()
        let store = AwakeScheduleStore(env: box.env)
        XCTAssertEqual(store.current(), AwakeSchedule())
        try store.save(AwakeSchedule(enabled: true, startMinute: 21 * 60, endMinute: 7 * 60, keepScreenOn: true))
        XCTAssertEqual(store.current(), AwakeSchedule(enabled: true, startMinute: 21 * 60, endMinute: 7 * 60, keepScreenOn: true))
        // An unreadable or out-of-range file is treated as off.
        try SafeFS.writeAtomic(Data(#"{"version":1,"enabled":true,"startMinute":5000,"endMinute":60}"#.utf8), to: box.env.paths.root.appendingPathComponent("awake.json"))
        XCTAssertFalse(store.current().enabled)
        try SafeFS.writeAtomic(Data("not json".utf8), to: box.env.paths.root.appendingPathComponent("awake.json"))
        XCTAssertFalse(store.current().enabled)
    }
}
