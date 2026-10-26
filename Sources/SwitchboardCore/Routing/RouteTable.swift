import Foundation

/// One folder -> profile assignment. `folder` is always a `PathNormalizer` display path.
public struct Route: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var folder: String
    public var profileId: String
    public var createdAt: Date
    public var id: String { folder }

    public init(folder: String, profileId: String, createdAt: Date = Date()) {
        self.folder = folder
        self.profileId = profileId
        self.createdAt = createdAt
    }
}

/// The only implementation of "which route covers this path": longest folder prefix wins.
/// (A route for `/work` covers `/work` and `/work/anything/below`, but not `/work-other`.)
public struct RouteTable: Sendable {
    private struct Entry {
        let key: String
        let route: Route
    }

    private let entries: [Entry]

    public init(routes: [Route], caseInsensitive: Bool) {
        entries = routes.map { r in
            Entry(key: caseInsensitive ? r.folder.lowercased() : r.folder, route: r)
        }
    }

    public func match(_ path: NormalizedPath) -> Route? {
        var best: Entry?
        for entry in entries {
            let covers =
                entry.key == "/" || path.key == entry.key || path.key.hasPrefix(entry.key + "/")
            if covers, entry.key.count > (best?.key.count ?? -1) { best = entry }
        }
        return best?.route
    }
}
