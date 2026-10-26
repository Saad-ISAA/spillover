import Foundation

public enum RouteLoad: Equatable {
    /// No routes file: nothing has been assigned yet.
    case missing
    case loaded([Route])
    /// Unreadable or malformed: callers must fail closed.
    case corrupt(String)
    /// Owned by someone else or writable by others: a tampered routes file could swap accounts.
    case insecure(String)
}

public enum RouteError: Error, LocalizedError, Equatable {
    case notAbsolute(String)
    case folderMissing(String)
    case unknownProfile(String)
    case noSuchRoute(String)
    case unreadable(String)

    public var errorDescription: String? {
        switch self {
        case .notAbsolute(let p): return "Folder must be an absolute path: \(p)"
        case .folderMissing(let p): return "Folder does not exist: \(p)"
        case .unknownProfile(let id): return "No profile '\(id)'."
        case .noSuchRoute(let p): return "No route for \(p)."
        case .unreadable(let why): return "routes.json is unreadable: \(why)"
        }
    }
}

/// Registry of routes (the ONLY reader/writer of routes.json).
public final class RouteStore {
    private struct File: Codable {
        var version: Int
        var routes: [Route]
    }

    private let env: SBEnvironment
    private var paths: SBPaths { env.paths }

    public init(env: SBEnvironment) {
        self.env = env
    }

    // MARK: Read

    /// Load with integrity checks. The launcher uses this directly so it can fail closed.
    public func load() -> RouteLoad {
        let url = paths.routesFile
        // The folder is checked first: if others could write it, they could also delete
        // routes.json to turn routed folders into unrouted ones.
        if let problem = SafeFS.trustProblem(paths.root, name: "the Switchboard folder") {
            return .insecure(problem)
        }
        guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
        if let problem = SafeFS.trustProblem(url, name: "routes.json") { return .insecure(problem) }

        let data: Data
        do { data = try Data(contentsOf: url) } catch { return .corrupt(error.localizedDescription) }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            let file = try decoder.decode(File.self, from: data)
            guard file.version == 1 else { return .corrupt("unsupported version \(file.version)") }
            for route in file.routes
            where PathNormalizer.normalize(route.folder, caseInsensitive: env.caseInsensitivePaths) == nil {
                return .corrupt("route with an invalid folder")
            }
            return .loaded(file.routes)
        } catch {
            return .corrupt("\(error)")
        }
    }

    /// Routes for display/editing; throws instead of returning the failure cases.
    public func routes() throws -> [Route] {
        switch load() {
        case .missing: return []
        case .loaded(let r): return r.sorted { $0.folder < $1.folder }
        case .corrupt(let why), .insecure(let why): throw RouteError.unreadable(why)
        }
    }

    public func routes(referencing profileId: String) throws -> [Route] {
        try routes().filter { $0.profileId == profileId }
    }

    // MARK: Write

    /// Assign `folder` (and everything below it) to a profile. Replaces an existing route for the
    /// same folder. `knownProfileIDs` lets callers validate without this store knowing profiles.
    @discardableResult
    public func set(
        folder: String, profileId: String, knownProfileIDs: Set<String>, requireExisting: Bool = true
    ) throws -> Route {
        guard folder.hasPrefix("/") || folder.hasPrefix("~") else { throw RouteError.notAbsolute(folder) }
        guard
            let normalized = PathNormalizer.normalize(
                folder, caseInsensitive: env.caseInsensitivePaths, home: env.home.path)
        else { throw RouteError.notAbsolute(folder) }
        if requireExisting {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: normalized.display, isDirectory: &isDir),
                isDir.boolValue
            else { throw RouteError.folderMissing(normalized.display) }
        }
        guard knownProfileIDs.contains(profileId) else { throw RouteError.unknownProfile(profileId) }

        return try SafeFS.withLock(root: paths.root) {
            var current = try routes()
            current.removeAll { sameFolder($0.folder, normalized.display) }
            let route = Route(folder: normalized.display, profileId: profileId)
            current.append(route)
            try save(current)
            return route
        }
    }

    public func remove(folder: String) throws {
        guard
            let normalized = PathNormalizer.normalize(
                folder, caseInsensitive: env.caseInsensitivePaths, home: env.home.path)
        else { throw RouteError.notAbsolute(folder) }
        try SafeFS.withLock(root: paths.root) {
            var current = try routes()
            let before = current.count
            current.removeAll { sameFolder($0.folder, normalized.display) }
            guard current.count != before else { throw RouteError.noSuchRoute(normalized.display) }
            try save(current)
        }
    }

    /// Used when a profile is removed: drop every route that points at it.
    public func removeAll(referencing profileId: String) throws {
        try SafeFS.withLock(root: paths.root) {
            let current = try routes()
            let kept = current.filter { $0.profileId != profileId }
            if kept.count != current.count { try save(kept) }
        }
    }

    // MARK: Internals

    /// Compares normalised keys, so legacy non-canonical entries are recognised too.
    private func sameFolder(_ a: String, _ b: String) -> Bool {
        let ci = env.caseInsensitivePaths
        guard let ka = PathNormalizer.normalize(a, caseInsensitive: ci)?.key,
            let kb = PathNormalizer.normalize(b, caseInsensitive: ci)?.key
        else { return a == b }
        return ka == kb
    }

    private func save(_ routes: [Route]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(File(version: 1, routes: routes))
        try SafeFS.ensureDir(paths.root)
        try SafeFS.writeAtomic(data, to: paths.routesFile)
    }
}
