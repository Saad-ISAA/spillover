import Foundation

public enum ServiceError: Error, LocalizedError, Equatable {
    case profileInUse(String, folders: [String])

    public var errorDescription: String? {
        switch self {
        case .profileInUse(let id, let folders):
            return "Profile '\(id)' is assigned to \(folders.count) folder(s): \(folders.joined(separator: ", ")). Unassign them first or remove with --unassign."
        }
    }
}

/// The operations the CLI and the menu bar app share. Thin orchestration over the registries;
/// rules that span two registries (a profile in use cannot vanish) live here.
public final class AppService {
    public let env: SBEnvironment
    public let profiles: ProfileStore
    public let routes: RouteStore
    private let runner: CommandRunning

    public init(env: SBEnvironment, runner: CommandRunning = SystemCommandRunner()) {
        self.env = env
        self.runner = runner
        self.profiles = ProfileStore(env: env)
        self.routes = RouteStore(env: env)
    }

    // MARK: Profiles

    public func allProfiles() throws -> [Profile] { try profiles.all() }

    public func removeProfile(id: String, unassign: Bool, deleteDirectory: Bool) throws {
        let using = try routes.routes(referencing: id)
        if !using.isEmpty {
            guard unassign else { throw ServiceError.profileInUse(id, folders: using.map(\.folder)) }
            try routes.removeAll(referencing: id)
        }
        try profiles.remove(id: id, deleteDirectory: deleteDirectory)
    }

    public func authStatus(for profile: Profile) -> Result<AuthStatus, ClaudeCLIError> {
        ClaudeCLI(env: env, runner: runner).authStatus(for: profile)
    }

    public func openLoginTerminal(for profile: Profile) throws {
        guard let claude = ClaudeCLI(env: env, runner: runner).claudePath() else {
            throw ClaudeCLIError.claudeNotFound
        }
        try TerminalLauncher(env: env, runner: runner).openLogin(profile: profile, claudePath: claude)
    }

    // MARK: Routes

    @discardableResult
    public func assign(folder: String, to profileId: String) throws -> Route {
        let ids = Set(try profiles.all().map(\.id))
        return try routes.set(folder: folder, profileId: profileId, knownProfileIDs: ids)
    }

    public func unassign(folder: String) throws {
        try routes.remove(folder: folder)
    }

    public func resolve(folder: String) -> Resolution {
        Resolver(env: env).resolve(cwd: folder)
    }

    // MARK: Editors

    /// Open a folder in an editor. Which account its Claude sessions use is decided by routes.
    public func open(folder: String, in editor: Editor = .code) throws {
        let result = runner.run(
            "/usr/bin/open", ["-a", editor.applicationName, folder], env: nil, timeout: 15)
        guard result.succeeded else {
            throw SafeFS.Failure(description: "could not open \(editor.displayName): \(result.stderr)")
        }
    }

    // MARK: Usage

    public func usageSnapshots() -> [String: UsageSnapshot] {
        let store = UsageStore(env: env)
        var out: [String: UsageSnapshot] = [:]
        for p in (try? profiles.all()) ?? [] {
            if let s = store.load(profileId: p.id) { out[p.id] = s }
        }
        return out
    }

    // MARK: Health

    public func doctor(includeKeychain: Bool = true) -> [HealthCheck] {
        Doctor(env: env, keychain: includeKeychain ? KeychainProbe(runner: runner) : nil).run()
    }
}
