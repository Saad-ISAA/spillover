import Foundation

/// One-shot import of an earlier hand-made setup: a `routes.tsv` of `<folder>\t<config dir>` lines
/// (default location `~/.aibar/routes.tsv`). Each distinct config dir is adopted as a profile
/// (left in place, logins untouched) and each folder is assigned to it.
public struct LegacyImport {
    public struct Summary: Equatable, Sendable {
        public var adoptedProfiles: [String] = []
        public var reusedProfiles: [String] = []
        public var routes: [String] = []
        public var skipped: [String] = []
    }

    private let env: SBEnvironment

    public init(env: SBEnvironment) {
        self.env = env
    }

    public var defaultRoutesFile: URL { env.paths.prototypeRoot.appendingPathComponent("routes.tsv") }

    public static func parse(_ text: String) -> [(folder: String, configDir: String)] {
        text.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
            guard parts.count == 2, parts[0].hasPrefix("/"), parts[1].hasPrefix("/") else { return nil }
            return (parts[0], parts[1].trimmingCharacters(in: .whitespaces))
        }
    }

    public func run(routesFile: URL? = nil) throws -> Summary {
        let file = routesFile ?? defaultRoutesFile
        let text = try String(contentsOf: file, encoding: .utf8)
        let service = AppService(env: env)
        var summary = Summary()
        var idByDir: [String: String] = [:]

        for (folder, dir) in Self.parse(text) {
            var id = idByDir[dir]
            if id == nil {
                if let existing = try service.allProfiles().first(where: { $0.configDir == dir }) {
                    id = existing.id
                    summary.reusedProfiles.append(existing.id)
                } else {
                    do {
                        let name = URL(fileURLWithPath: dir).lastPathComponent
                        let p = try service.profiles.adopt(displayName: name, directory: dir)
                        id = p.id
                        summary.adoptedProfiles.append(p.id)
                    } catch {
                        summary.skipped.append("\(dir): \(error.localizedDescription)")
                        continue
                    }
                }
                idByDir[dir] = id
            }
            guard let profileId = id else { continue }
            do {
                let route = try service.assign(folder: folder, to: profileId)
                summary.routes.append("\(route.folder) -> \(profileId)")
            } catch {
                summary.skipped.append("\(folder): \(error.localizedDescription)")
            }
        }
        return summary
    }
}
