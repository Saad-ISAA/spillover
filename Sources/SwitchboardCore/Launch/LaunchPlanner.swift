import Foundation

public struct LaunchRequest: Sendable {
    public var mode: LaunchMode
    public var cwd: String
    public var args: [String]
    public var environment: [String: String]

    public init(mode: LaunchMode, cwd: String, args: [String], environment: [String: String]) {
        self.mode = mode
        self.cwd = cwd
        self.args = args
        self.environment = environment
    }
}

public struct LaunchPlan: Equatable, Sendable {
    public var executable: String
    public var args: [String]
    public var environment: [String: String]
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
/// - `SWITCHBOARD_BYPASS=1` is the documented emergency exit: skip routing, run Claude as-is.
public struct LaunchPlanner {
    private let env: SBEnvironment
    private let resolver: Resolver
    private let locator: RealClaudeLocator
    private let log: LaunchLog

    public init(env: SBEnvironment) {
        self.env = env
        self.resolver = Resolver(env: env)
        self.locator = RealClaudeLocator(env: env)
        self.log = LaunchLog(env: env)
    }

    public func plan(_ request: LaunchRequest) -> LaunchDecision {
        let bypass = request.environment["SWITCHBOARD_BYPASS"] == "1"
        let resolution: Resolution = bypass ? .unrouted : resolver.resolve(cwd: request.cwd)

        if case .refused(let refusal) = resolution {
            log.append(
                mode: request.mode, cwd: request.cwd, profile: "-",
                outcome: "refused:\(refusal.code.rawValue)")
            return .refuse(
                "switchboard: \(refusal.message)\n(Set SWITCHBOARD_BYPASS=1 to run Claude without routing.)")
        }

        guard let executable = locator.locate(mode: request.mode, baseEnv: request.environment) else {
            log.append(mode: request.mode, cwd: request.cwd, profile: "-", outcome: "refused:noClaude")
            return .refuse(
                "switchboard: could not find the Claude executable. Install Claude Code or set SWITCHBOARD_REAL_CLAUDE."
            )
        }

        var environment = request.environment
        var profileID = "-"
        var outcome = bypass ? "bypass" : "unrouted"
        if case .routed(let profile, _) = resolution {
            environment = ProfileEnvironment.apply(profile, to: environment)
            profileID = profile.id
            outcome = "routed"
        }
        log.append(mode: request.mode, cwd: request.cwd, profile: profileID, outcome: outcome)
        return .exec(
            LaunchPlan(executable: executable, args: request.args, environment: environment),
            resolution)
    }
}
