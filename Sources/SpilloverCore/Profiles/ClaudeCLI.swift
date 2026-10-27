import Foundation

/// Output of `claude auth status` (a JSON object). Only non-secret account facts.
public struct AuthStatus: Codable, Equatable, Sendable {
    public var loggedIn: Bool
    public var authMethod: String?
    public var apiProvider: String?
    public var email: String?
    public var orgName: String?
    public var subscriptionType: String?
    public var projectsDirectory: String?

    public init(
        loggedIn: Bool, authMethod: String? = nil, apiProvider: String? = nil, email: String? = nil,
        orgName: String? = nil, subscriptionType: String? = nil, projectsDirectory: String? = nil
    ) {
        self.loggedIn = loggedIn
        self.authMethod = authMethod
        self.apiProvider = apiProvider
        self.email = email
        self.orgName = orgName
        self.subscriptionType = subscriptionType
        self.projectsDirectory = projectsDirectory
    }

    /// Human plan label: "max" -> "Max".
    public var planLabel: String? {
        guard let s = subscriptionType, !s.isEmpty else { return nil }
        return s.prefix(1).uppercased() + s.dropFirst()
    }
}

public enum ClaudeCLIError: Error, Equatable, LocalizedError {
    case claudeNotFound
    case timedOut
    case failed(String)
    case badOutput

    public var errorDescription: String? {
        switch self {
        case .claudeNotFound: return "Claude Code CLI not found."
        case .timedOut: return "Claude Code did not answer in time."
        case .failed(let why): return "Claude Code failed: \(why)"
        case .badOutput: return "Unexpected output from `claude auth status`."
        }
    }
}

/// Talks to the official Claude Code CLI for account facts. Uses only documented commands and
/// never touches credentials: the CLI reads its own Keychain item.
public struct ClaudeCLI {
    private let env: SBEnvironment
    private let runner: CommandRunning

    public init(env: SBEnvironment, runner: CommandRunning = SystemCommandRunner()) {
        self.env = env
        self.runner = runner
    }

    public func claudePath() -> String? {
        RealClaudeLocator(env: env).locate(mode: .shellShim, baseEnv: env.processEnv)
    }

    public func authStatus(for profile: Profile) -> Result<AuthStatus, ClaudeCLIError> {
        guard let claude = claudePath() else { return .failure(.claudeNotFound) }
        let childEnv = ProfileEnvironment.apply(profile, to: env.processEnv)
        let result = runner.run(claude, ["auth", "status"], env: childEnv, timeout: 20)
        if result.timedOut { return .failure(.timedOut) }
        if let status = Self.parseAuthStatus(result.stdout) { return .success(status) }
        if !result.succeeded {
            return .failure(.failed(Redaction.scrub(String(result.stderr.prefix(300)))))
        }
        return .failure(.badOutput)
    }

    /// Interactive login in the current terminal (CLI use). The CLI handles the browser flow.
    public func loginInteractively(profile: Profile) -> Int32 {
        guard let claude = claudePath() else { return 127 }
        let childEnv = ProfileEnvironment.apply(profile, to: env.processEnv)
        return runner.runInteractive(claude, ["auth", "login"], env: childEnv)
    }

    public func logoutInteractively(profile: Profile) -> Int32 {
        guard let claude = claudePath() else { return 127 }
        let childEnv = ProfileEnvironment.apply(profile, to: env.processEnv)
        return runner.runInteractive(claude, ["auth", "logout"], env: childEnv)
    }

    /// Accepts the JSON object even when surrounded by other output lines.
    public static func parseAuthStatus(_ output: String) -> AuthStatus? {
        guard let start = output.firstIndex(of: "{"), let end = output.lastIndex(of: "}"), start < end
        else { return nil }
        let json = output[start...end]
        return try? JSONDecoder().decode(AuthStatus.self, from: Data(json.utf8))
    }
}
