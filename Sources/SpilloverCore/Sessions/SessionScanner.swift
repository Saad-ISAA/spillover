import Darwin
import Foundation

/// A Claude process running right now, as seen from outside.
public struct RunningSession: Equatable, Sendable, Identifiable {
    public let pid: Int32
    public let executable: String
    public let cwd: String?
    /// `CLAUDE_CONFIG_DIR` of the process (nil = unset, i.e. Claude's default directory).
    public let configDir: String?
    /// Set when the session was started through Spillover's launcher.
    public let spilloverProfile: String?
    public let startedAt: Date?
    /// The conversation this process continues (`--resume`), when it says.
    public let conversationId: String?
    public var id: Int32 { pid }

    /// The editor whose Claude extension started this process (nil for terminal sessions).
    public var editor: Editor? { Editor.hosting(executable: executable) }

    public init(
        pid: Int32, executable: String, cwd: String?, configDir: String?, spilloverProfile: String?,
        startedAt: Date?, conversationId: String? = nil
    ) {
        self.pid = pid
        self.executable = executable
        self.cwd = cwd
        self.configDir = configDir
        self.spilloverProfile = spilloverProfile
        self.startedAt = startedAt
        self.conversationId = conversationId
    }
}

/// A running session compared with what the folder's assignment says today.
public struct SessionAssessment: Equatable, Sendable, Identifiable {
    public enum State: Equatable, Sendable {
        /// Running on the account its folder is assigned to (or Default for unassigned folders).
        case matches
        /// The folder's assignment changed after this session started: restart it to switch.
        case stale(expected: String)
        /// The folder's assignment cannot be honoured; new sessions there are refused.
        case refusedNow
        /// Started with a config directory Spillover does not know.
        case unknownAccount
        /// A short background run (a plugin or tool) in a temporary folder. It keeps the account
        /// of the chat that started it and is never moved.
        case background
    }

    public let session: RunningSession
    /// Profile id the session is actually running on (nil when unknown).
    public let actualProfileId: String?
    public let state: State

    public var id: Int32 { session.pid }
}

/// Lists running Claude processes of the current user and reads exactly two environment
/// variables from each (`CLAUDE_CONFIG_DIR`, `SPILLOVER_PROFILE`), its working directory, the
/// conversation id in its arguments and the few flags in `RunningSession.resumeFlagNames`. Every
/// other environment variable and argument is discarded while parsing and never stored.
public struct SessionScanner {
    static let keptVariables: Set<String> = [ProfileEnvironment.configDirKey, ProfileEnvironment.profileKey]

    private let env: SBEnvironment

    public init(env: SBEnvironment) {
        self.env = env
    }

    public func scan() -> [RunningSession] {
        Self.allPIDs().compactMap(Self.session(pid:))
            .sorted { ($0.startedAt ?? .distantPast) > ($1.startedAt ?? .distantPast) }
    }

    /// The Claude session running as `pid` right now, if it is one of this user's.
    static func session(pid: Int32) -> RunningSession? {
        guard pid > 0, let path = executablePath(pid), isClaudeExecutable(path) else { return nil }
        guard let info = basicInfo(pid), info.uid == getuid() else { return nil }
        guard let args = procArgs(pid) else { return nil }
        let parsed = parseProcArgs(args)
        guard isChat(argv: Array(parsed.argv.dropFirst())) else { return nil }
        return RunningSession(
            pid: pid, executable: path, cwd: workingDirectory(pid),
            configDir: parsed.env[ProfileEnvironment.configDirKey],
            spilloverProfile: parsed.env[ProfileEnvironment.profileKey],
            startedAt: info.started, conversationId: ConversationID.from(args: Array(parsed.argv.dropFirst())))
    }

    /// Compare each running session with today's assignments.
    public func assess(_ sessions: [RunningSession]) -> [SessionAssessment] {
        let profiles = (try? ProfileStore(env: env).all()) ?? [Profile.builtInDefault()]
        let resolver = Resolver(env: env)
        let policy = AutoPolicyStore(env: env).current()
        let usage = UsageStore(env: env)
        return sessions.map { s in
            let actual = Self.profileId(for: s, profiles: profiles, caseInsensitive: env.caseInsensitivePaths)
            guard let cwd = s.cwd else {
                return SessionAssessment(session: s, actualProfileId: actual, state: actual == nil ? .unknownAccount : .matches)
            }
            if isTemporaryFolder(cwd) {
                return SessionAssessment(session: s, actualProfileId: actual, state: .background)
            }
            let expected: String
            switch resolver.resolve(cwd: cwd) {
            case .refused:
                return SessionAssessment(session: s, actualProfileId: actual, state: .refusedNow)
            case .unrouted:
                expected = Profile.defaultID
            case .routed(let p, let route):
                // Auto folders: a chat stays where it is until its account is full.
                if route.profileId == Profile.autoID, let actual,
                    !policy.isFull(usage.load(profileId: actual))
                {
                    return SessionAssessment(session: s, actualProfileId: actual, state: .matches)
                }
                expected = p.id
            }
            guard let actual else {
                return SessionAssessment(session: s, actualProfileId: nil, state: .unknownAccount)
            }
            return SessionAssessment(
                session: s, actualProfileId: actual, state: actual == expected ? .matches : .stale(expected: expected))
        }
    }

    /// Claude processes that are not chats: the Chrome extension's native host, and commands such
    /// as `claude mcp serve` or `claude auth status`.
    static func isChat(argv: [String]) -> Bool {
        if argv.contains("--chrome-native-host") { return false }
        let services: Set<String> = ["mcp", "auth", "doctor", "update", "install", "setup-token", "plugin", "config"]
        if let first = argv.first, !first.hasPrefix("-"), services.contains(first) { return false }
        return true
    }

    /// Temporary folders, where plugins and tools run short background Claude jobs.
    func isTemporaryFolder(_ path: String) -> Bool {
        env.temporaryFolders.contains { !$0.isEmpty && path.hasPrefix($0) }
    }

    public static func profileId(for s: RunningSession, profiles: [Profile], caseInsensitive: Bool) -> String? {
        guard let dir = s.configDir, !dir.isEmpty else { return Profile.defaultID }
        let key = PathNormalizer.normalize(dir, caseInsensitive: caseInsensitive)?.key
        return profiles.first { p in
            guard let pd = p.configDir else { return false }
            return PathNormalizer.normalize(pd, caseInsensitive: caseInsensitive)?.key == key
        }?.id
    }

    /// Editor-bundled binaries are named `claude`; the native installer runs versioned files
    /// such as `~/.local/share/claude/versions/2.1.266`.
    static func isClaudeExecutable(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent
        if name == "claude" { return true }
        let parent = (path as NSString).deletingLastPathComponent
        return (parent as NSString).lastPathComponent == "versions"
            && ((parent as NSString).deletingLastPathComponent as NSString).lastPathComponent == "claude"
    }

    // MARK: Parsing (pure, tested)

    /// Parse a `KERN_PROCARGS2` buffer: argc, exec path, padding, argv, then environment strings.
    /// Only `keptVariables` survive.
    static func parseProcArgs(_ buffer: [UInt8]) -> (argv: [String], env: [String: String]) {
        guard buffer.count >= 4 else { return ([], [:]) }
        let argc = Int(buffer[0]) | Int(buffer[1]) << 8 | Int(buffer[2]) << 16 | Int(buffer[3]) << 24
        var i = 4
        // exec path
        while i < buffer.count && buffer[i] != 0 { i += 1 }
        // padding NULs
        while i < buffer.count && buffer[i] == 0 { i += 1 }

        func nextString() -> String? {
            guard i < buffer.count else { return nil }
            let start = i
            while i < buffer.count && buffer[i] != 0 { i += 1 }
            let s = String(decoding: buffer[start..<i], as: UTF8.self)
            i += 1
            return s
        }

        var argv: [String] = []
        for _ in 0..<max(0, argc) {
            guard let a = nextString() else { break }
            argv.append(a)
        }
        var env: [String: String] = [:]
        while let entry = nextString(), !entry.isEmpty {
            guard let eq = entry.firstIndex(of: "=") else { continue }
            let key = String(entry[..<eq])
            if keptVariables.contains(key) {
                env[key] = String(entry[entry.index(after: eq)...])
            }
        }
        return (argv, env)
    }

    // MARK: Darwin

    private static func allPIDs() -> [Int32] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [Int32](repeating: 0, count: Int(count) + 32)
        let filled = pids.withUnsafeMutableBytes { raw in
            proc_listallpids(raw.baseAddress, Int32(raw.count))
        }
        return Array(pids.prefix(Int(max(0, filled))))
    }

    /// Path of the program running as `pid` (nil when it cannot be read).
    public static func executable(of pid: Int32) -> String? { executablePath(pid) }

    private static func executablePath(_ pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let n = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard n > 0 else { return nil }
        return String(cString: buffer)
    }

    private static func basicInfo(_ pid: Int32) -> (uid: uid_t, started: Date?)? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let tv = info.kp_proc.p_un.__p_starttime
        let started = tv.tv_sec > 0 ? Date(timeIntervalSince1970: TimeInterval(tv.tv_sec)) : nil
        return (info.kp_eproc.e_ucred.cr_uid, started)
    }

    private static func procArgs(_ pid: Int32) -> [UInt8]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        return Array(buffer.prefix(size))
    }

    private static func workingDirectory(_ pid: Int32) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        return withUnsafePointer(to: &info.pvi_cdir.vip_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
    }
}
