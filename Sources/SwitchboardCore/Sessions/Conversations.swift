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
/// the newest copy is copied there (transcript, its companion folder and its file checkpoints).
/// Files are copied byte for byte; their content is never read or interpreted here.
public struct ConversationStore {
    public enum Handoff: Equatable, Sendable {
        /// The target already has the newest copy (or nobody has one).
        case current
        case copied(fromProfile: String)
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
        guard ConversationID.valid(id) != nil else { return nil }
        let projects = configDir(for: profile).appendingPathComponent("projects", isDirectory: true)
        let fm = FileManager.default
        if let cwd {
            let direct = projects.appendingPathComponent(Self.projectKey(cwd: cwd)).appendingPathComponent("\(id).jsonl")
            if isRegularFile(direct) { return direct }
        }
        guard let dirs = try? fm.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil) else { return nil }
        for dir in dirs {
            let candidate = dir.appendingPathComponent("\(id).jsonl")
            if isRegularFile(candidate) { return candidate }
        }
        return nil
    }

    /// Make sure `target` holds the newest copy of conversation `id` among `profiles`.
    @discardableResult
    public func ensure(id: String, cwd: String?, target: Profile, among profiles: [Profile]) throws -> Handoff {
        guard ConversationID.valid(id) != nil else { return .current }
        let targetFile = transcript(id: id, cwd: cwd, in: target)
        var newest: (profile: Profile, file: URL, modified: Date)?
        for p in profiles where p.id != target.id {
            guard let file = transcript(id: id, cwd: cwd, in: p), let m = modified(file) else { continue }
            if m > (newest?.modified ?? .distantPast) { newest = (p, file, m) }
        }
        guard let source = newest else { return .current }
        if let targetFile, let tm = modified(targetFile) {
            // Copies keep their modification date, but file systems round it: treat an equal-sized
            // file within a second as the same copy, so two accounts never copy back and forth.
            if tm > source.modified.addingTimeInterval(1) { return .current }
            if abs(tm.timeIntervalSince(source.modified)) <= 1, size(targetFile) == size(source.file) { return .current }
        }

        let projectDir = source.file.deletingLastPathComponent().lastPathComponent
        let sourceRoot = configDir(for: source.profile)
        let targetRoot = configDir(for: target)
        let targetProjects = targetRoot.appendingPathComponent("projects/\(projectDir)", isDirectory: true)
        try SafeFS.ensureDir(targetRoot.appendingPathComponent("projects", isDirectory: true))
        try SafeFS.ensureDir(targetProjects)

        try copyFile(source.file, to: targetProjects.appendingPathComponent("\(id).jsonl"))
        try copyTree(
            source.file.deletingLastPathComponent().appendingPathComponent(id, isDirectory: true),
            to: targetProjects.appendingPathComponent(id, isDirectory: true))
        let checkpoints = sourceRoot.appendingPathComponent("file-history/\(id)", isDirectory: true)
        if isDirectory(checkpoints) {
            try SafeFS.ensureDir(targetRoot.appendingPathComponent("file-history", isDirectory: true))
            try copyTree(checkpoints, to: targetRoot.appendingPathComponent("file-history/\(id)", isDirectory: true))
        }
        return .copied(fromProfile: source.profile.id)
    }

    // MARK: Files

    private func modified(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    private func size(_ url: URL) -> UInt64? {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.uint64Value
    }

    private func isRegularFile(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType == .typeRegular
    }

    private func isDirectory(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType == .typeDirectory
    }

    /// Copies a regular file (never a symlink), keeping its modification date.
    private func copyFile(_ from: URL, to: URL) throws {
        guard isRegularFile(from) else { return }
        let data = try Data(contentsOf: from)
        try SafeFS.writeAtomic(data, to: to)
        if let m = modified(from) {
            try FileManager.default.setAttributes([.modificationDate: m], ofItemAtPath: to.path)
        }
    }

    /// Replaces `to` with a copy of the directory `from` (regular files and folders only).
    private func copyTree(_ from: URL, to: URL) throws {
        guard isDirectory(from) else { return }
        let fm = FileManager.default
        if fm.fileExists(atPath: to.path) { try fm.removeItem(at: to) }
        try SafeFS.ensureDir(to)
        for item in try fm.contentsOfDirectory(at: from, includingPropertiesForKeys: nil) {
            let dest = to.appendingPathComponent(item.lastPathComponent)
            if isDirectory(item) { try copyTree(item, to: dest) } else { try copyFile(item, to: dest) }
        }
    }
}

/// Whether a chat is between turns, judged from the tail of its transcript: the last
/// conversational record is the assistant's finished reply and the file has been quiet for a
/// moment. Only the record type and stop reason are looked at, never the text.
public enum ConversationActivity {
    public enum State: Equatable, Sendable {
        case idle
        case busy
        /// Quiet for a long time but not cleanly finished (interrupted, or waiting on a prompt).
        case stalled
    }

    public static let quietSeconds: TimeInterval = 4
    public static let stalledAfter: TimeInterval = 120

    public static func state(transcript: URL, now: Date = Date()) -> State {
        guard let handle = try? FileHandle(forReadingFrom: transcript) else { return .busy }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let window: UInt64 = 256 * 1024
        try? handle.seek(toOffset: size > window ? size - window : 0)
        let data = (try? handle.readToEnd()) ?? Data()
        let modified =
            (try? FileManager.default.attributesOfItem(atPath: transcript.path))?[.modificationDate] as? Date ?? now
        return state(tail: data, quietFor: now.timeIntervalSince(modified))
    }

    /// Pure rule (tested).
    static func state(tail: Data, quietFor: TimeInterval) -> State {
        var finished = false
        for line in tail.split(separator: 0x0A).reversed() {
            guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                let type = obj["type"] as? String
            else { continue }
            guard type == "assistant" || type == "user" else { continue }
            if type == "assistant", let message = obj["message"] as? [String: Any],
                let stop = message["stop_reason"] as? String
            {
                finished = ["end_turn", "stop_sequence", "max_tokens"].contains(stop)
            }
            break
        }
        if finished && quietFor >= quietSeconds { return .idle }
        if quietFor >= stalledAfter { return .stalled }
        return .busy
    }
}
