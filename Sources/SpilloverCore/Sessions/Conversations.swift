import Foundation

/// The id of the conversation a Claude process continues, from its arguments. The VS Code
/// extension starts every chat as `claude --resume=<id>`; people use `--resume <id>` or `-r <id>`.
public enum ConversationID {
    public static func from(args: [String]) -> String? {
        var i = 0
        while i < args.count {
            let a = args[i]
            if a.hasPrefix("--resume=") { return valid(String(a.dropFirst("--resume=".count))) }
            if (a == "--resume" || a == "-r"), i + 1 < args.count { return valid(args[i + 1]) }
            i += 1
        }
        return nil
    }

    /// Ids name files, so only plain UUID-like strings are accepted (no separators, no dots).
    public static func valid(_ id: String) -> String? {
        guard (8...64).contains(id.count),
            id.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "0123456789abcdefABCDEF-").contains($0) })
        else { return nil }
        return id
    }
}

/// Conversation history lives in each account's own config folder, so a conversation started on
/// one account cannot be resumed on another. Before Claude resumes a conversation on an account,
/// the newest copy is brought there (transcript, its companion folder and its file checkpoints).
/// Files are copied, never parsed; only complete lines of a transcript are copied.
public struct ConversationStore {
    public enum Handoff: Equatable, Sendable {
        /// The target already has the newest copy (or nobody has one).
        case current
        /// Copied from another account. `keptBackup` is set when the target's own copy had
        /// diverged and was kept next to it instead of being lost.
        case copied(fromProfile: String, keptBackup: Bool = false)
    }

    public struct Holder: Equatable, Sendable {
        public let profile: Profile
        public let file: URL
        public let modified: Date
        public let size: UInt64
    }

    private let env: SBEnvironment

    public init(env: SBEnvironment) {
        self.env = env
    }

    public func configDir(for profile: Profile) -> URL {
        URL(fileURLWithPath: profile.configDir ?? env.paths.defaultClaudeDir.path, isDirectory: true)
    }

    /// Claude's folder key for a working directory: every character that is not a letter or a
    /// digit becomes "-".
    public static func projectKey(cwd: String) -> String {
        String(cwd.unicodeScalars.map { s -> Character in
            let v = s.value
            let alnum = (v >= 48 && v <= 57) || (v >= 65 && v <= 90) || (v >= 97 && v <= 122)
            return alnum ? Character(s) : "-"
        })
    }

    /// The transcript of `id` inside one account, if it has one.
    public func transcript(id: String, cwd: String?, in profile: Profile) -> URL? {
        if let direct = directTranscript(id: id, cwd: cwd, in: profile) { return direct }
        return scannedTranscript(id: id, in: profile)
    }

    /// Every account holding a copy of `id`, newest first. The folder scan only runs when no
    /// account has it at the expected place (keeps the launcher fast).
    public func holders(id: String, cwd: String?, among profiles: [Profile]) -> [Holder] {
        guard ConversationID.valid(id) != nil else { return [] }
        var found = profiles.compactMap { p in directTranscript(id: id, cwd: cwd, in: p).flatMap { holder(p, $0) } }
        if found.isEmpty {
            found = profiles.compactMap { p in scannedTranscript(id: id, in: p).flatMap { holder(p, $0) } }
        }
        return found.sorted { $0.modified > $1.modified }
    }

    /// Make sure `target` holds the newest copy of conversation `id` among `profiles`.
    @discardableResult
    public func ensure(id: String, cwd: String?, target: Profile, among profiles: [Profile]) throws -> Handoff {
        guard ConversationID.valid(id) != nil else { return .current }
        let all = holders(id: id, cwd: cwd, among: profiles)
        guard let source = all.first(where: { $0.profile.id != target.id }) else { return .current }
        let existing = all.first { $0.profile.id == target.id }
        if let existing {
            // Copies keep their modification date but file systems round it: an equal-sized
            // file within a second is the same copy, so two accounts never copy back and forth.
            if existing.modified > source.modified.addingTimeInterval(1) { return .current }
            if abs(existing.modified.timeIntervalSince(source.modified)) <= 1, existing.size == source.size {
                return .current
            }
        }

        let projectDir = source.file.deletingLastPathComponent().lastPathComponent
        let targetRoot = configDir(for: target)
        let targetProjects = targetRoot.appendingPathComponent("projects/\(projectDir)", isDirectory: true)
        let targetFile = targetProjects.appendingPathComponent("\(id).jsonl")
        try SafeFS.ensureDir(targetRoot.appendingPathComponent("projects", isDirectory: true))
        try SafeFS.ensureDir(targetProjects)
        guard !isSymlink(targetFile) else { throw SafeFS.Failure(description: "refusing to write through a link: \(targetFile.path)") }

        // The target's copy is only replaced silently when the source simply continues it.
        var keptBackup = false
        if let existing, !extends(source.file, existing.file) {
            let backup = existing.file.deletingLastPathComponent()
                .appendingPathComponent("\(id).jsonl.before-move-\(Int(Date().timeIntervalSince1970))")
            try FileManager.default.copyItem(at: existing.file, to: backup)
            keptBackup = true
        }

        try copyCompleteLines(source.file, to: targetFile)
        try copyTree(
            source.file.deletingLastPathComponent().appendingPathComponent(id, isDirectory: true),
            to: targetProjects.appendingPathComponent(id, isDirectory: true))
        let checkpoints = configDir(for: source.profile).appendingPathComponent("file-history/\(id)", isDirectory: true)
        if isDirectory(checkpoints) {
            try SafeFS.ensureDir(targetRoot.appendingPathComponent("file-history", isDirectory: true))
            try copyTree(checkpoints, to: targetRoot.appendingPathComponent("file-history/\(id)", isDirectory: true))
        }
        return .copied(fromProfile: source.profile.id, keptBackup: keptBackup)
    }

    // MARK: Lookup

    private func directTranscript(id: String, cwd: String?, in profile: Profile) -> URL? {
        guard ConversationID.valid(id) != nil, let cwd else { return nil }
        let url = configDir(for: profile).appendingPathComponent("projects/\(Self.projectKey(cwd: cwd))/\(id).jsonl")
        return isRegularFile(url) ? url : nil
    }

    private func scannedTranscript(id: String, in profile: Profile) -> URL? {
        guard ConversationID.valid(id) != nil else { return nil }
        let projects = configDir(for: profile).appendingPathComponent("projects", isDirectory: true)
        guard let dirs = try? FileManager.default.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil)
        else { return nil }
        return dirs.lazy.map { $0.appendingPathComponent("\(id).jsonl") }.first(where: isRegularFile)
    }

    private func holder(_ p: Profile, _ file: URL) -> Holder? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: file.path),
            let m = attrs[.modificationDate] as? Date
        else { return nil }
        return Holder(profile: p, file: file, modified: m, size: (attrs[.size] as? NSNumber)?.uint64Value ?? 0)
    }

    // MARK: Files

    private func attributes(_ url: URL) -> [FileAttributeKey: Any]? {
        try? FileManager.default.attributesOfItem(atPath: url.path)
    }

    private func isRegularFile(_ url: URL) -> Bool { attributes(url)?[.type] as? FileAttributeType == .typeRegular }
    private func isDirectory(_ url: URL) -> Bool { attributes(url)?[.type] as? FileAttributeType == .typeDirectory }
    private func isSymlink(_ url: URL) -> Bool { attributes(url)?[.type] as? FileAttributeType == .typeSymbolicLink }

    /// True when `longer` starts with the whole of `shorter` (checked on the last 64 KB of
    /// `shorter`, which is where two diverging copies differ).
    func extends(_ longer: URL, _ shorter: URL) -> Bool {
        guard let a = attributes(longer)?[.size] as? NSNumber, let b = attributes(shorter)?[.size] as? NSNumber
        else { return false }
        let lengthA = a.uint64Value, lengthB = b.uint64Value
        guard lengthA >= lengthB else { return false }
        guard lengthB > 0 else { return true }
        let window = min(lengthB, 64 * 1024)
        guard let x = try? FileHandle(forReadingFrom: longer), let y = try? FileHandle(forReadingFrom: shorter) else {
            return false
        }
        defer {
            try? x.close()
            try? y.close()
        }
        do {
            try x.seek(toOffset: lengthB - window)
            try y.seek(toOffset: lengthB - window)
            return try x.read(upToCount: Int(window)) == y.read(upToCount: Int(window))
        } catch {
            return false
        }
    }

    /// Streams a transcript into place (temp file, then swap) and drops a trailing line that is
    /// still being written. Keeps the source's modification date.
    private func copyCompleteLines(_ from: URL, to: URL) throws {
        guard isRegularFile(from) else { return }
        let fm = FileManager.default
        let tmp = to.deletingLastPathComponent().appendingPathComponent(".\(to.lastPathComponent).\(UUID().uuidString).tmp")
        try fm.copyItem(at: from, to: tmp)
        do {
            try trimToLastNewline(tmp)
            try fm.setAttributes([.posixPermissions: NSNumber(value: SafeFS.fileMode)], ofItemAtPath: tmp.path)
            if let m = attributes(from)?[.modificationDate] as? Date {
                try fm.setAttributes([.modificationDate: m], ofItemAtPath: tmp.path)
            }
            if fm.fileExists(atPath: to.path) { _ = try fm.replaceItemAt(to, withItemAt: tmp) } else { try fm.moveItem(at: tmp, to: to) }
        } catch {
            try? fm.removeItem(at: tmp)
            throw error
        }
    }

    private func trimToLastNewline(_ url: URL) throws {
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        guard size > 0 else { return }
        var end = size
        let chunk: UInt64 = 64 * 1024
        while end > 0 {
            let start = end > chunk ? end - chunk : 0
            try handle.seek(toOffset: start)
            let data = try handle.read(upToCount: Int(end - start)) ?? Data()
            if let i = data.lastIndex(of: 0x0A) {
                let keep = start + UInt64(data.distance(from: data.startIndex, to: i)) + 1
                if keep < size { try handle.truncate(atOffset: keep) }
                return
            }
            end = start
        }
        try handle.truncate(atOffset: 0)
    }

    /// Replaces `to` with a copy of the directory `from`, built next to it first so a failure
    /// never leaves the target half-copied. Symlinks are skipped.
    private func copyTree(_ from: URL, to: URL) throws {
        guard isDirectory(from) else { return }
        let fm = FileManager.default
        let staging = to.deletingLastPathComponent().appendingPathComponent(".\(to.lastPathComponent).\(UUID().uuidString).tmp")
        do {
            try fill(staging, from: from)
            if fm.fileExists(atPath: to.path) { _ = try fm.replaceItemAt(to, withItemAt: staging) } else { try fm.moveItem(at: staging, to: to) }
        } catch {
            try? fm.removeItem(at: staging)
            throw error
        }
    }

    private func fill(_ dir: URL, from: URL) throws {
        try SafeFS.ensureDir(dir)
        for item in try FileManager.default.contentsOfDirectory(at: from, includingPropertiesForKeys: nil) {
            let dest = dir.appendingPathComponent(item.lastPathComponent)
            if isDirectory(item) {
                try fill(dest, from: item)
            } else if isRegularFile(item) {
                try FileManager.default.copyItem(at: item, to: dest)
                try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: SafeFS.fileMode)], ofItemAtPath: dest.path)
            }
        }
    }
}

/// Whether a chat is between turns, judged from the tail of its transcript. Only the record
/// type, its stop reason and the kinds of its content blocks are looked at, never the text.
public enum ConversationActivity {
    public enum State: Equatable, Sendable {
        /// The last reply finished and the file has been quiet for a moment.
        case idle
        case busy
        /// Quiet for a long time after an interrupted turn (not waiting on a tool or a prompt).
        case stalled
    }

    public static let quietSeconds: TimeInterval = 4
    public static let stalledAfter: TimeInterval = 600

    public static func state(transcript: URL, now: Date = Date()) -> State {
        guard let handle = try? FileHandle(forReadingFrom: transcript) else { return .busy }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let modified =
            (try? FileManager.default.attributesOfItem(atPath: transcript.path))?[.modificationDate] as? Date ?? now
        // Read more of the tail when one record is larger than the first window.
        for window: UInt64 in [256 * 1024, 4 * 1024 * 1024] {
            try? handle.seek(toOffset: size > window ? size - window : 0)
            let data = (try? handle.readToEnd()) ?? Data()
            if let s = state(tail: data, quietFor: now.timeIntervalSince(modified)) { return s }
            if size <= window { break }
        }
        return .busy
    }

    /// Pure rule (tested). Nil when the tail holds no conversational record at all.
    static func state(tail: Data, quietFor: TimeInterval) -> State? {
        for line in tail.split(separator: 0x0A).reversed() {
            guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                let type = obj["type"] as? String, type == "assistant" || type == "user"
            else { continue }
            let message = obj["message"] as? [String: Any]
            if type == "assistant" {
                let stop = message?["stop_reason"] as? String
                if ["end_turn", "stop_sequence", "max_tokens"].contains(stop ?? "") {
                    return quietFor >= quietSeconds ? .idle : .busy
                }
                // A tool call is running or waiting for permission: never interrupt it.
                if stop == "tool_use" || contentKinds(message).contains("tool_use") { return .busy }
            } else if contentKinds(message).contains("tool_result") {
                // A tool just returned; the model is working on its next step.
                return .busy
            }
            return quietFor >= stalledAfter ? .stalled : .busy
        }
        return nil
    }

    private static func contentKinds(_ message: [String: Any]?) -> Set<String> {
        guard let content = message?["content"] as? [[String: Any]] else { return [] }
        return Set(content.compactMap { $0["type"] as? String })
    }

    /// Background tasks (subagents and shell commands started to run in the background) launched
    /// since `since` that have not reported back yet. They live inside the chat's process, so a
    /// chat with any of them is never ended, even when its last reply has finished. Tasks from
    /// before `since` (an earlier process) ended with that process and are ignored.
    public static func pendingBackgroundTasks(transcript: URL, since: Date?) -> Set<String> {
        guard let handle = try? FileHandle(forReadingFrom: transcript) else { return [] }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let window: UInt64 = 8 * 1024 * 1024
        try? handle.seek(toOffset: size > window ? size - window : 0)
        return pendingBackgroundTasks(tail: (try? handle.readToEnd()) ?? Data(), since: since)
    }

    /// Pure rule (tested). A launch is a tool result naming an async `agentId` or a
    /// `backgroundTaskId`; a finish is a task notification for that id with a final status.
    static func pendingBackgroundTasks(tail: Data, since: Date?) -> Set<String> {
        var launched = Set<String>()
        var finished = Set<String>()
        let launchMarkers = [Data("\"agentId\"".utf8), Data("\"backgroundTaskId\"".utf8)]
        let notice = Data("task-notification".utf8)
        let stamp = ISO8601DateFormatter()
        stamp.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        for line in tail.split(separator: 0x0A) {
            let mayLaunch = launchMarkers.contains { line.range(of: $0) != nil }
            let mayFinish = line.range(of: notice) != nil
            guard mayLaunch || mayFinish,
                let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any]
            else { continue }
            if mayLaunch, let result = obj["toolUseResult"] as? [String: Any] {
                let id = (result["isAsync"] as? Bool == true ? result["agentId"] as? String : nil)
                    ?? result["backgroundTaskId"] as? String
                let at = (obj["timestamp"] as? String).flatMap(stamp.date(from:))
                var current = true
                if let since, let at { current = at >= since.addingTimeInterval(-2) }
                if let id, current { launched.insert(id) }
            }
            if mayFinish, let text = String(data: line, encoding: .utf8) {
                finished.formUnion(finishedTaskIDs(in: text))
            }
        }
        return launched.subtracting(finished)
    }

    private static let finishedNotice = try! NSRegularExpression(
        pattern: #"<task-id>([^<]+)</task-id>(?:(?!<task-notification>).)*?<status>(completed|failed|stopped|killed)</status>"#,
        options: [.dotMatchesLineSeparators])

    private static func finishedTaskIDs(in text: String) -> Set<String> {
        let range = NSRange(text.startIndex..., in: text)
        return Set(
            finishedNotice.matches(in: text, range: range).compactMap { m in
                Range(m.range(at: 1), in: text).map { String(text[$0]) }
            })
    }
}
