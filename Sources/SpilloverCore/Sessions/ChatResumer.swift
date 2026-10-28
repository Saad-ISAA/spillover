import Foundation

/// Continues a chat without the editor, after Spillover ended it to change its account while it
/// still had background work (subagents, background commands) running: those stop with the old
/// process, so the chat is resumed on the folder's new account with a short message asking it to
/// pick its work up again. The run goes through Spillover's launcher, so the folder's account and
/// the history handoff apply exactly as for a chat the editor starts, and it keeps running until
/// its own background work has finished. Until then the launcher refuses to start the chat a
/// second time from the editor (two processes would run the same background tasks at once).
public struct ChatResumer {
    public static let message = "The account switched, please resume all work."

    private let env: SBEnvironment
    private let runner: CommandRunning

    public init(env: SBEnvironment, runner: CommandRunning = SystemCommandRunner()) {
        self.env = env
        self.runner = runner
    }

    /// The launch: `--resume <id> -p <message>` plus the chat's own permission and model flags.
    public static func arguments(conversationId: String, flags: [String]) -> [String] {
        ["--resume", conversationId, "-p", message, "--output-format", "json"] + flags
    }

    /// Starts the resumed run in `folder` and returns its pid.
    @discardableResult
    public func resume(conversationId: String, folder: String, flags: [String]) throws -> Int32 {
        try runner.spawnDetached(
            env.paths.launcher.path, Self.arguments(conversationId: conversationId, flags: flags),
            env: Self.environment(env.processEnv), directory: URL(fileURLWithPath: folder, isDirectory: true))
    }

    /// The resumed run's environment: Spillover's own, marked as a resumed run.
    public static func environment(_ base: [String: String]) -> [String: String] {
        var out = base
        out[ProfileEnvironment.resumedRunKey] = "1"
        return out
    }
}
