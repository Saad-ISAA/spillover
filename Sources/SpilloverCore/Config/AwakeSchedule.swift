import Foundation

/// When Spillover keeps the Mac awake (opt-in), so Claude sessions can run through the night and
/// chats stopped by a limit can be resumed: between `startMinute` and `endMinute` every day, local
/// time. The window may cross midnight (22:00 to 08:00); equal times mean all day.
public struct AwakeSchedule: Codable, Equatable, Sendable {
    public var version = 1
    public var enabled = false
    /// Minutes after midnight, local time.
    public var startMinute = 22 * 60
    public var endMinute = 8 * 60
    /// Also keep the screen from sleeping (otherwise only the Mac itself stays awake).
    public var keepScreenOn = false

    public init(enabled: Bool = false, startMinute: Int = 22 * 60, endMinute: Int = 8 * 60, keepScreenOn: Bool = false) {
        self.enabled = enabled
        self.startMinute = startMinute
        self.endMinute = endMinute
        self.keepScreenOn = keepScreenOn
    }

    private enum CodingKeys: String, CodingKey {
        case version, enabled, startMinute, endMinute, keepScreenOn
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        startMinute = try c.decodeIfPresent(Int.self, forKey: .startMinute) ?? 22 * 60
        endMinute = try c.decodeIfPresent(Int.self, forKey: .endMinute) ?? 8 * 60
        keepScreenOn = try c.decodeIfPresent(Bool.self, forKey: .keepScreenOn) ?? false
    }

    public var isAllDay: Bool { startMinute == endMinute }

    /// True when `date` falls inside the window (whether or not the schedule is turned on).
    public func covers(_ date: Date, calendar: Calendar = .current) -> Bool {
        if isAllDay { return true }
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        let minute = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        if startMinute < endMinute { return minute >= startMinute && minute < endMinute }
        return minute >= startMinute || minute < endMinute
    }

    /// True when the Mac should be kept awake now.
    public func isActive(at date: Date, calendar: Calendar = .current) -> Bool {
        enabled && covers(date, calendar: calendar)
    }

    /// The next time the window starts or ends after `date` (nil when it covers the whole day).
    public func nextChange(after date: Date, calendar: Calendar = .current) -> Date? {
        if isAllDay { return nil }
        let minute = covers(date, calendar: calendar) ? endMinute : startMinute
        let start = calendar.startOfDay(for: date)
        guard let today = calendar.date(byAdding: .minute, value: minute, to: start) else { return nil }
        return today > date ? today : calendar.date(byAdding: .day, value: 1, to: today)
    }
}

/// The only reader and writer of `awake.json`. A missing or unreadable file means the default
/// (off): keeping a Mac awake is never turned on by accident.
public struct AwakeScheduleStore {
    private let env: SBEnvironment

    public init(env: SBEnvironment) {
        self.env = env
    }

    private var url: URL { env.paths.root.appendingPathComponent("awake.json") }

    public func current() -> AwakeSchedule {
        guard FileManager.default.fileExists(atPath: url.path), SafeFS.trustProblem(url, name: "awake.json") == nil,
            let data = try? Data(contentsOf: url),
            let schedule = try? JSONDecoder().decode(AwakeSchedule.self, from: data),
            schedule.version == 1,
            (0..<1440).contains(schedule.startMinute), (0..<1440).contains(schedule.endMinute)
        else { return AwakeSchedule() }
        return schedule
    }

    public func save(_ schedule: AwakeSchedule) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try SafeFS.ensureDir(env.paths.root)
        try SafeFS.withLock(root: env.paths.root) {
            try SafeFS.writeAtomic(try encoder.encode(schedule), to: url)
        }
    }
}
