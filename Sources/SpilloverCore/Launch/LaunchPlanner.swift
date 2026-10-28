import Foundation

public struct LaunchRequest: Sendable {
    public var mode: LaunchMode
    public var cwd: String
    public var args: [String]
    public var environment: [String: String]
    /// The program that started the launcher (an editor's extension host), when known.
    public var parentExecutable: String?

    public init(
        mode: LaunchMode, cwd: String, args: [String], environment: [String: String], parentExecutable: String? = nil
    ) {
        self.mode = mode
        self.cwd = cwd
        self.args = args
        self.environment = environment
        self.parentExecutable = parentExecutable
    }
}

public struct LaunchPlan: Equatable, Sendable {
    public var executable: String
    public var args: [String]
    public var environment: [String: String]
    /// Arguments Spillover adds to Claude's own (which are passed on unchanged).
    public var extraArgs: [String] = []
    /// Where in `args` the extra arguments go: after Claude's own options, never in front of
    /// them. Editors pass the Claude binary as the first argument, and an option that takes
    /// several values would read it as one of them.
    public var extraArgsIndex: Int

    public init(
        executable: String, args: [String], environment: [String: String], extraArgs: [String] = [],
        extraArgsIndex: Int? = nil
    ) {
        self.executable = executable
        self.args = args
        self.environment = environment
        self.extraArgs = extraArgs
        self.extraArgsIndex = extraArgsIndex ?? args.count
    }

    /// The argument list Claude receives.
    public var fullArgs: [String] {
        var all = args
        all.insert(contentsOf: extraArgs, at: min(max(extraArgsIndex, 0), args.count))
        return all
    }
}

public enum LaunchDecision: Equatable, Sendable {
    case exec(LaunchPlan, Resolution)
    /// Do not start Claude; print `message` to stderr and exit non-zero.
    case refuse(String)
}

/// Turns "someone wants to start Claude in this folder" into an exact process to exec. Pure apart
/// from reading the registries and writing the launch log, so it is fully testable.
///
/// Policy:
/// - Folder with a route that can be honoured -> that profile's environment.
/// - Folder with no route (or no routes at all) -> environment untouched (the Default account).
/// - Anything that stops a route being honoured -> refuse. Never silently use another account.
/// - `SPILLOVER_BYPASS=1` is the documented emergency exit: skip routing, run Claude as-is.
public struct LaunchPlanner {
    private let env: SBEnvironment
    private let resolver: Resolver
    private let locator: RealClaudeLocator
    private let log: LaunchLog
    /// Spillover's own resumed run of a conversation, while it runs (process scan by default).
    private let resumedRun: (String) -> RunningSession?

    public init(env: SBEnvironment, resumedRun: ((String) -> RunningSession?)? = nil) {
        self.env = env
        self.resolver = Resolver(env: env)
        self.locator = RealClaudeLocator(env: env)
        self.log = LaunchLog(env: env)
        self.resumedRun = resumedRun ?? { SessionScanner(env: env).resumedRun(of: $0) }
    }

    public func plan(_ request: LaunchRequest) -> LaunchDecision {
        let bypass = request.environment["SPILLOVER_BYPASS"] == "1"
        let conversation = bypass ? nil : ConversationID.from(args: request.args)
        let profiles = (try? ProfileStore(env: env).all()) ?? [Profile.builtInDefault()]
        // A resumed chat in an Auto folder stays on the account that already has it, while it has room.
        let holder = conversation.flatMap {
            ConversationStore(env: env).holders(id: $0, cwd: request.cwd, among: profiles).first?.profile.id
        }
        let resolution: Resolution = bypass ? .unrouted : resolver.resolve(cwd: request.cwd, preferring: holder)

        // A chat Spillover resumed by itself runs its background work in that process; a second
        // copy started from the editor would run the same tasks again, in the same files.
        if let conversation, request.environment[ProfileEnvironment.resumedRunKey] != "1",
            let running = resumedRun(conversation)
        {
            log.append(mode: request.mode, cwd: request.cwd, profile: "-", outcome: "refused:resumedRunning")
            return .refuse(Self.resumedRunMessage(running))
        }

        if case .refused(let refusal) = resolution {
            log.append(
                mode: request.mode, cwd: request.cwd, profile: "-",
                outcome: "refused:\(refusal.code.rawValue)")
            return .refuse(
                "spillover: \(refusal.message)\n(Set SPILLOVER_BYPASS=1 to run Claude without routing.)")
        }

        guard
            let executable = locator.locate(
                mode: request.mode, baseEnv: request.environment, parentExecutable: request.parentExecutable)
        else {
            log.append(mode: request.mode, cwd: request.cwd, profile: "-", outcome: "refused:noClaude")
            return .refuse(
                "spillover: could not find the Claude executable. Install Claude Code or set SPILLOVER_REAL_CLAUDE."
            )
        }

        var environment = request.environment
        var profileID = "-"
        var outcome = bypass ? "bypass" : "unrouted"
        var target = Profile.builtInDefault()
        if case .routed(let profile, let route) = resolution {
            environment = ProfileEnvironment.apply(profile, to: environment)
            profileID = profile.id
            outcome = route.profileId == Profile.autoID ? "routed:auto" : "routed"
            target = profile
        }
        if let conversation {
            outcome += handOff(conversation, cwd: request.cwd, to: target, among: profiles)
        }
        // An account that shares MCP servers gets them for chats (not for commands such as
        // `claude auth status`), unless the launch already chooses its MCP configuration.
        // One `--opt=value` token at the end (before a `--`), so it can neither take nor give up
        // a neighbouring argument.
        var extraArgs: [String] = []
        if let mcp = ProfileSharing(env: env).sharedMcpConfig(for: target),
            SessionScanner.isChat(argv: Self.claudeArgs(request)),
            !request.args.contains(where: { $0.hasPrefix("--mcp-config") || $0 == "--strict-mcp-config" })
        {
            extraArgs = ["--mcp-config=\(mcp.path)"]
            outcome += "+mcp"
        }
        log.append(mode: request.mode, cwd: request.cwd, profile: profileID, outcome: outcome)
        return .exec(
            LaunchPlan(
                executable: executable, args: request.args, environment: environment, extraArgs: extraArgs,
                extraArgsIndex: request.args.firstIndex(of: "--") ?? request.args.count),
            resolution)
    }

    static func resumedRunMessage(_ run: RunningSession) -> String {
        let since = run.startedAt.map { " since " + DateFormatter.localizedString(from: $0, dateStyle: .none, timeStyle: .short) } ?? ""
        return """
            spillover: this chat is still working in the background\(since) (pid \(run.pid)). Spillover moved it to \
            another account and resumed it there, and its background tasks run in that process, so it \
            cannot be opened a second time. Send your message again when it has finished, or choose \
            Take over for this chat under Sessions in Spillover to stop it and continue here.
            """
    }

    /// Claude's arguments without the Claude binary that editors pass first to the wrapper.
    static func claudeArgs(_ request: LaunchRequest) -> [String] {
        guard request.mode == .editorWrapper, let first = request.args.first, first.hasPrefix("/"),
            (first as NSString).lastPathComponent.hasPrefix("claude")
        else { return request.args }
        return Array(request.args.dropFirst())
    }

    /// A resumed conversation must exist in the account it starts on: copy the newest copy there
    /// (a chat moved to another account keeps its context). Never blocks the launch.
    private func handOff(_ conversation: String, cwd: String, to target: Profile, among profiles: [Profile]) -> String {
        do {
            switch try ConversationStore(env: env).ensure(id: conversation, cwd: cwd, target: target, among: profiles) {
            case .current: return ""
            case .copied(let from, let keptBackup): return "+handoff:\(from)" + (keptBackup ? "+backup" : "")
            }
        } catch {
            // Claude still starts; say why the earlier history may be missing.
            FileHandleWarning.write(
                "spillover: could not bring this conversation's history to '\(target.id)': \(error.localizedDescription)")
            return "+handoff-failed"
        }
    }
}

/// Launcher warnings go to stderr, which the editor shows in its Claude output log.
enum FileHandleWarning {
    static func write(_ text: String) {
        FileHandle.standardError.write(Data((text + "\n").utf8))
    }
}
