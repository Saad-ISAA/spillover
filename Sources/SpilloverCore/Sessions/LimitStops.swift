import Foundation

/// A chat that stopped because its account hit a usage limit: the last thing in its conversation
/// is Claude's "You've hit your … limit" message. Only main chats count; subagents keep their own
/// transcripts and are restarted by their chat.
public struct LimitStop: Equatable, Sendable {
    public let conversationId: String
    /// The folder the chat runs in.
    public let cwd: String
    /// The chat's title as its panel shows it (renamed title, else the generated one).
    public let title: String?
    public let stoppedAt: Date
    /// The account holding the newest copy of the chat (the one that hit the limit).
    public let profileId: String
    public let transcript: URL
}

/// Finds chats stopped by a usage limit and decides when they can continue. Reads transcripts
/// only; never changes them.
public struct LimitStops {
    /// What a resumed chat is sent.
    public static let message = "Your usage limit has reset. Please resume all work."
    /// How Claude marks a chat that runs in the VS Code panel (the only chats Spillover can type
    /// into; agents and scripted runs use other entrypoints).
    static let editorEntrypoint = "claude-vscode"

    private let env: SBEnvironment

    public init(env: SBEnvironment) {
        self.env = env
    }

    /// Main chats, changed within `within` (a weekly limit can take days to reset), whose newest
    /// copy across accounts ends on a usage limit.
    public func scan(profiles: [Profile], now: Date = Date(), within: TimeInterval = 8 * 86400) -> [LimitStop] {
        var newest: [String: (profile: Profile, file: URL, modified: Date)] = [:]
        let fm = FileManager.default
        for profile in profiles {
            let projects = URL(fileURLWithPath: profile.configDir ?? env.paths.defaultClaudeDir.path, isDirectory: true)
                .appendingPathComponent("projects", isDirectory: true)
            guard let dirs = try? fm.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil) else { continue }
            for dir in dirs {
                let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
                for file in files where file.pathExtension == "jsonl" {
                    let id = file.deletingPathExtension().lastPathComponent
                    guard ConversationID.valid(id) != nil,
                        let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                        now.timeIntervalSince(modified) <= within
                    else { continue }
                    if let seen = newest[id], seen.modified >= modified { continue }
                    newest[id] = (profile, file, modified)
                }
            }
        }
        let marker = Data("\"rate_limit\"".utf8)
        return newest.compactMap { id, copy in
            // Cheap check first: most transcripts never mention a limit near their end.
            let tail = Self.tail(of: copy.file, bytes: 64 * 1024)
            guard tail.range(of: marker) != nil, let stop = Self.stop(tail: tail), let cwd = stop.cwd,
                stop.entrypoint == Self.editorEntrypoint
            else { return nil }
            let title = Self.title(transcript: copy.file)
            return LimitStop(
                conversationId: id, cwd: cwd, title: title, stoppedAt: stop.at, profileId: copy.profile.id,
                transcript: copy.file)
        }
        .sorted { $0.stoppedAt < $1.stoppedAt }
    }

    /// True once the chat has been sent `message` after it stopped (it resumed).
    public static func wasResumed(_ stop: LimitStop, transcript: URL) -> Bool {
        let tail = tail(of: transcript, bytes: 512 * 1024)
        for line in tail.split(separator: 0x0A).reversed() {
            guard line.range(of: Data(message.utf8)) != nil,
                let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                obj["type"] as? String == "user", let at = timestamp(obj), at > stop.stoppedAt
            else { continue }
            return true
        }
        return false
    }

    /// How long after its account has room again a stopped chat is resumed.
    public static let grace: TimeInterval = 60
    /// How long after that it still is. A chat whose account has had room for longer was left
    /// stopped on purpose and is never typed into.
    public static let resumeWindow: TimeInterval = 3 * 3600

    /// Since when the account the chat would run on has had room, or nil while it has none.
    /// The account's reading history dates it: the reset of the last reading after the stop that
    /// was still at the limit, or the first reading after the stop when none was. Without history,
    /// a latest reading that saw the limit gives its window's reset, and one taken after the stop
    /// that shows room counts from when it was taken.
    public static func roomSince(
        _ snapshot: UsageSnapshot?, history: [UsagePoint] = [], after stoppedAt: Date, now: Date = Date()
    ) -> Date? {
        guard let snapshot, snapshot.peakPercentage(at: now) < AutoPolicy.nearlyOutPercentage else { return nil }
        let full = AutoPolicy.nearlyOutPercentage
        let limited = snapshot.windows.filter { $0.effectivePercentage(at: snapshot.capturedAt) >= full }
        if let reset = limited.map(\.resetsAt).max() { return reset }
        let after = history.filter { $0.at > stoppedAt }.sorted { $0.at < $1.at }
        if let lastFull = after.lastIndex(where: { max($0.fiveHour ?? 0, $0.sevenDay ?? 0) >= full }) {
            let point = after[lastFull]
            let resets = UsageWindow.Kind.allCases.filter { (point.value($0) ?? 0) >= full }.compactMap { point.resetsAt($0) }
            if let reset = resets.max() { return reset }
            return after.indices.contains(lastFull + 1) ? after[lastFull + 1].at : nil
        }
        if let first = after.first { return first.at }
        return snapshot.capturedAt > stoppedAt ? snapshot.capturedAt : nil
    }

    /// When the chat is expected to be resumed, while its account still has no room: the reset
    /// of the window that hit the limit, plus the grace period. Nil when that is not known.
    public static func expectedResume(_ snapshot: UsageSnapshot?, now: Date = Date()) -> Date? {
        guard let snapshot else { return nil }
        let limited = snapshot.windows.filter { $0.effectivePercentage(at: now) >= AutoPolicy.nearlyOutPercentage }
        return limited.map(\.resetsAt).max().map { $0.addingTimeInterval(grace) }
    }

    // MARK: Parsing (pure, tested)

    /// The usage-limit stop at the end of a transcript, if that is where the conversation ended.
    /// Records that are not part of the conversation (system notes, titles, background task
    /// notices, subagent lines) do not count as continuing it.
    static func stop(tail: Data) -> (at: Date, cwd: String?, entrypoint: String?)? {
        var last: [String: Any]?
        for line in tail.split(separator: 0x0A) {
            guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                let type = obj["type"] as? String, type == "user" || type == "assistant",
                obj["isSidechain"] as? Bool != true, obj["isMeta"] as? Bool != true
            else { continue }
            if type == "user", isTaskNotice(obj) { continue }
            last = obj
        }
        guard let last, last["type"] as? String == "assistant", last["error"] as? String == "rate_limit",
            let at = timestamp(last)
        else { return nil }
        return (at, last["cwd"] as? String, last["entrypoint"] as? String)
    }

    /// The newest title in a transcript: a renamed title wins over a generated one.
    static func title(tail: Data) -> String? {
        var custom: String?
        var generated: String?
        for line in tail.split(separator: 0x0A) where line.range(of: Data("-title\"".utf8)) != nil {
            guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            if obj["type"] as? String == "custom-title", let t = obj["customTitle"] as? String, !t.isEmpty { custom = t }
            if obj["type"] as? String == "ai-title", let t = obj["aiTitle"] as? String, !t.isEmpty { generated = t }
        }
        return custom ?? generated
    }

    // MARK: Files

    /// The chat's title as its panel shows it.
    public static func title(transcript: URL) -> String? {
        savedTitle(next: transcript) ?? title(tail: tail(of: transcript, bytes: 8 * 1024 * 1024))
    }

    /// A renamed chat also keeps its title next to the transcript (`<id>/custom-title.json`).
    static func savedTitle(next transcript: URL) -> String? {
        let file = transcript.deletingPathExtension().appendingPathComponent("custom-title.json")
        guard let data = try? Data(contentsOf: file),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let t = obj["customTitle"] as? String, !t.isEmpty
        else { return nil }
        return t
    }

    static func tail(of file: URL, bytes: UInt64) -> Data {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return Data() }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > bytes ? size - bytes : 0)
        var data = (try? handle.readToEnd()) ?? Data()
        // Drop the partial first line of a cut-off tail.
        if size > bytes, let nl = data.firstIndex(of: 0x0A) { data = data.subdata(in: (nl + 1)..<data.endIndex) }
        return data
    }

    private static func isTaskNotice(_ obj: [String: Any]) -> Bool {
        let content = (obj["message"] as? [String: Any])?["content"]
        if let text = content as? String { return text.hasPrefix("<task-notification>") }
        if let blocks = content as? [[String: Any]] {
            return blocks.contains { ($0["text"] as? String)?.hasPrefix("<task-notification>") == true }
        }
        return false
    }

    private static let stamp: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static func timestamp(_ obj: [String: Any]) -> Date? {
        (obj["timestamp"] as? String).flatMap { stamp.date(from: $0) }
    }
}

/// Spillover's own list of chats stopped by a limit: since when each one's account has room, and
/// whether it was resumed. One automatic resume per stop; kept for a week.
public struct LimitResumeLog {
    public struct Entry: Codable, Equatable, Sendable {
        public var stoppedAt: Date
        /// Since when the chat's account has had room (the earliest time seen for this stop).
        public var roomSince: Date?
        /// When it was resumed, or given up on after its last try.
        public var attemptedAt: Date?
        /// "resumed", or why it could not be resumed (so far, while tries remain).
        public var outcome: String?
        /// Failed tries so far, and when the last one was.
        public var tries: Int?
        public var lastTryAt: Date?

        public init(
            stoppedAt: Date, roomSince: Date? = nil, attemptedAt: Date? = nil, outcome: String? = nil,
            tries: Int? = nil, lastTryAt: Date? = nil
        ) {
            self.stoppedAt = stoppedAt
            self.roomSince = roomSince
            self.attemptedAt = attemptedAt
            self.outcome = outcome
            self.tries = tries
            self.lastTryAt = lastTryAt
        }

        /// A try failed and another one will follow.
        public var isRetrying: Bool { attemptedAt == nil && (tries ?? 0) > 0 }
    }

    /// Tries per stop, and the wait between them (a chat can be busy, or VS Code can be mid-update).
    public static let maxTries = 3
    public static let retryInterval: TimeInterval = 120

    private let url: URL

    public init(env: SBEnvironment) {
        url = env.paths.root.appendingPathComponent("limit-resumes.json")
    }

    public func entries() -> [String: Entry] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([String: Entry].self, from: data)) ?? [:]
    }

    /// Notes what is known about `stop` now and returns its entry. A new stop of the same chat
    /// starts a new entry; room that disappears again (used up by other chats) is forgotten.
    @discardableResult
    public func note(_ stop: LimitStop, roomSince: Date?) -> Entry {
        var all = entries()
        let previous = all[stop.conversationId]
        var entry = previous.flatMap { abs($0.stoppedAt.timeIntervalSince(stop.stoppedAt)) < 1 ? $0 : nil }
            ?? Self.afterResume(previous, newStop: stop.stoppedAt)
        if let roomSince {
            entry.roomSince = min(entry.roomSince ?? roomSince, roomSince)
        } else if entry.attemptedAt == nil {
            entry.roomSince = nil
        }
        all[stop.conversationId] = entry
        save(all)
        return entry
    }

    /// A limit hit right after Spillover resumed the chat means the resume did not take (the chat
    /// was still on the full account, say): it counts as a failed try of the same stop, so the
    /// tries run out instead of resuming the chat again and again.
    static func afterResume(_ previous: Entry?, newStop: Date) -> Entry {
        guard let previous, let resumed = previous.attemptedAt, previous.outcome == "resumed",
            newStop >= resumed, newStop.timeIntervalSince(resumed) < Self.backAtTheLimit
        else { return Entry(stoppedAt: newStop) }
        var entry = Entry(stoppedAt: newStop)
        entry.tries = (previous.tries ?? 0) + 1
        entry.lastTryAt = resumed
        entry.outcome = "it hit the limit again right after it was resumed"
        if (entry.tries ?? 0) >= Self.maxTries { entry.attemptedAt = newStop }
        return entry
    }

    /// How soon after a resume a new limit stop counts as the resume not taking.
    public static let backAtTheLimit: TimeInterval = 300

    public func recordAttempt(_ stop: LimitStop, outcome: String?, at: Date = Date()) {
        var all = entries()
        var entry = all[stop.conversationId] ?? Entry(stoppedAt: stop.stoppedAt)
        entry.attemptedAt = entry.attemptedAt ?? at
        entry.outcome = outcome
        all[stop.conversationId] = entry
        save(all)
    }

    /// Notes a failed try; after the last one the stop is given up on. Returns true when it was
    /// the last.
    @discardableResult
    public func recordFailedTry(_ stop: LimitStop, reason: String, at: Date = Date()) -> Bool {
        var all = entries()
        var entry = all[stop.conversationId] ?? Entry(stoppedAt: stop.stoppedAt)
        entry.tries = (entry.tries ?? 0) + 1
        entry.lastTryAt = at
        entry.outcome = reason
        let last = (entry.tries ?? 0) >= Self.maxTries
        if last { entry.attemptedAt = at }
        all[stop.conversationId] = entry
        save(all)
        return last
    }

    /// True when the stop has not been acted on and its account has had room for the grace period,
    /// but not for longer than the resume window; after a failed try, once the retry wait is over.
    public static func isDue(_ entry: Entry, now: Date = Date()) -> Bool {
        guard entry.attemptedAt == nil, let since = entry.roomSince else { return false }
        if let last = entry.lastTryAt, now.timeIntervalSince(last) < retryInterval { return false }
        let waited = now.timeIntervalSince(since)
        return waited >= LimitStops.grace && waited <= LimitStops.grace + LimitStops.resumeWindow
    }

    /// True when the stop was not acted on and its resume window has passed.
    public static func isMissed(_ entry: Entry, now: Date = Date()) -> Bool {
        guard entry.attemptedAt == nil, let since = entry.roomSince else { return false }
        return now.timeIntervalSince(since) > LimitStops.grace + LimitStops.resumeWindow
    }

    private func save(_ all: [String: Entry]) {
        let cutoff = Date().addingTimeInterval(-7 * 86400)
        let kept = all.filter { $0.value.stoppedAt >= cutoff }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(kept) { try? SafeFS.writeAtomic(data, to: url) }
    }
}
