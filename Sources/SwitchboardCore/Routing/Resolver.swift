import Foundation

public struct Refusal: Equatable, Sendable {
    public enum Code: String, Sendable {
        case routesCorrupt, routesInsecure, registryCorrupt
        case profileMissing, profileDirectoryMissing, badWorkingDirectory
    }

    public let code: Code
    public let message: String
}

public enum Resolution: Equatable, Sendable {
    /// No route covers this folder (or nothing is assigned yet): leave the environment untouched.
    case unrouted
    case routed(profile: Profile, route: Route)
    /// A route exists (or might exist) but cannot be honoured. Never fall back to another account.
    case refused(Refusal)
}

/// The ONE resolver: folder -> account. The VS Code wrapper, the `claude` shim, the CLI and the
/// app all call this; no other code decides which profile a folder gets.
public struct Resolver {
    private let env: SBEnvironment
    private let routeStore: RouteStore
    private let profileStore: ProfileStore

    public init(env: SBEnvironment) {
        self.env = env
        self.routeStore = RouteStore(env: env)
        self.profileStore = ProfileStore(env: env)
    }

    public func resolve(cwd: String) -> Resolution {
        let routes: [Route]
        switch routeStore.load() {
        case .missing:
            return .unrouted
        case .corrupt(let why):
            return .refused(
                Refusal(
                    code: .routesCorrupt,
                    message: "Routes file is unreadable (\(why)). Run `switchboard doctor`."))
        case .insecure(let why):
            return .refused(
                Refusal(
                    code: .routesInsecure,
                    message: "Refusing to trust routes: \(why). Run `switchboard doctor`."))
        case .loaded(let loaded):
            routes = loaded
        }
        if routes.isEmpty { return .unrouted }

        guard
            let path = PathNormalizer.normalize(
                cwd, caseInsensitive: env.caseInsensitivePaths, home: env.home.path)
        else {
            return .refused(
                Refusal(code: .badWorkingDirectory, message: "Cannot interpret working directory."))
        }

        let table = RouteTable(routes: routes, caseInsensitive: env.caseInsensitivePaths)
        guard let route = table.match(path) else { return .unrouted }

        let profile: Profile
        do {
            guard let found = try profileStore.profile(id: route.profileId) else {
                return .refused(
                    Refusal(
                        code: .profileMissing,
                        message:
                            "\(route.folder) is assigned to profile '\(route.profileId)', which no longer exists."
                    ))
            }
            profile = found
        } catch {
            return .refused(
                Refusal(
                    code: .registryCorrupt,
                    message: "Profile registry is unreadable: \(error.localizedDescription)"))
        }

        if let dir = profile.configDir {
            var isDir: ObjCBool = false
            if !FileManager.default.fileExists(atPath: dir, isDirectory: &isDir) || !isDir.boolValue {
                return .refused(
                    Refusal(
                        code: .profileDirectoryMissing,
                        message: "Profile '\(profile.id)' directory is missing: \(dir)"))
            }
        }
        return .routed(profile: profile, route: route)
    }
}
