import Foundation

/// Registry of profiles. The ONLY reader/writer of profiles.json.
/// The built-in Default profile is virtual and never stored.
public final class ProfileStore {
    private struct File: Codable {
        var version: Int
        var profiles: [Profile]
    }

    private let env: SBEnvironment
    private var paths: SBPaths { env.paths }

    public init(env: SBEnvironment) {
        self.env = env
    }

    // MARK: Read

    /// Default first, then stored profiles in creation order.
    public func all() throws -> [Profile] {
        [Profile.builtInDefault()] + (try load())
    }

    public func profile(id: String) throws -> Profile? {
        try all().first { $0.id == id }
    }

    // MARK: Write

    /// Create a new isolated profile directory under `<appRoot>/profiles/<id>` (mode 0700).
    @discardableResult
    public func create(displayName: String) throws -> Profile {
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw ProfileError.invalidName }
        var stored = try load()
        let id = uniqueID(base: ProfileID.slug(from: name), taken: Set(stored.map(\.id)))
        let dir = paths.profilesDir.appendingPathComponent(id, isDirectory: true)
        try SafeFS.ensureDir(paths.root)
        try SafeFS.ensureDir(paths.profilesDir)
        try SafeFS.ensureDir(dir)
        let profile = Profile(id: id, displayName: name, configDir: dir.path)
        stored.append(profile)
        try save(stored)
        return profile
    }

    /// Register an existing config directory (e.g. one created by the prototype). The directory is
    /// left exactly as it is; only the registry changes.
    @discardableResult
    public func adopt(displayName: String, directory: String) throws -> Profile {
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw ProfileError.invalidName }
        guard directory.hasPrefix("/") else { throw ProfileError.notAbsolute(directory) }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory, isDirectory: &isDir), isDir.boolValue
        else { throw ProfileError.directoryMissing(directory) }

        let key = comparisonKey(directory)
        if key == comparisonKey(paths.defaultClaudeDir.path) {
            throw ProfileError.directoryIsDefault(directory)
        }
        var stored = try load()
        if let clash = stored.first(where: { $0.configDir.map(comparisonKey) == key }) {
            throw ProfileError.directoryAlreadyUsed(directory, by: clash.id)
        }
        let id = uniqueID(base: ProfileID.slug(from: name), taken: Set(stored.map(\.id)))
        // Keep the path string exactly as the user logged in with it (minus trailing slashes):
        // Claude Code derives the Keychain item from this exact string, so canonicalising it
        // (e.g. resolving symlinks) could point the profile at an empty login.
        var exact = directory
        while exact.count > 1 && exact.hasSuffix("/") { exact.removeLast() }
        let profile = Profile(id: id, displayName: name, configDir: exact)
        stored.append(profile)
        try SafeFS.ensureDir(paths.root)
        try save(stored)
        return profile
    }

    public func rename(id: String, to newName: String) throws {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw ProfileError.invalidName }
        if id == Profile.defaultID { throw ProfileError.cannotRemoveDefault }
        var stored = try load()
        guard let i = stored.firstIndex(where: { $0.id == id }) else { throw ProfileError.notFound(id) }
        stored[i].displayName = name
        try save(stored)
    }

    /// Remove from the registry. The directory is only deleted when `deleteDirectory` is true AND it
    /// lives inside Switchboard's own `profiles/` folder (adopted directories are never deleted).
    /// Callers must first make sure no route points at the profile (see `AppService.removeProfile`).
    public func remove(id: String, deleteDirectory: Bool = false) throws {
        if id == Profile.defaultID { throw ProfileError.cannotRemoveDefault }
        var stored = try load()
        guard let i = stored.firstIndex(where: { $0.id == id }) else { throw ProfileError.notFound(id) }
        let removed = stored.remove(at: i)
        try save(stored)
        if deleteDirectory, let dir = removed.configDir, isInsideProfilesDir(dir) {
            try? FileManager.default.removeItem(atPath: dir)
        }
    }

    // MARK: Internals

    private func uniqueID(base: String, taken: Set<String>) -> String {
        var candidate = base
        var n = 2
        while taken.contains(candidate) || candidate == Profile.defaultID || !ProfileID.isValid(candidate) {
            candidate = "\(base.prefix(36))-\(n)"
            n += 1
        }
        return candidate
    }

    private func isInsideProfilesDir(_ dir: String) -> Bool {
        let root = comparisonKey(paths.profilesDir.path)
        let key = comparisonKey(dir)
        return key.hasPrefix(root + "/") && key != root
    }

    private func comparisonKey(_ path: String) -> String {
        PathNormalizer.normalize(path, caseInsensitive: env.caseInsensitivePaths)?.key ?? path
    }

    private func load() throws -> [Profile] {
        let url = paths.profilesFile
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data: Data
        do { data = try Data(contentsOf: url) } catch {
            throw ProfileError.registryCorrupt("\(error.localizedDescription)")
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            let file = try decoder.decode(File.self, from: data)
            guard file.version == 1 else { throw ProfileError.unsupportedRegistryVersion(file.version) }
            for p in file.profiles {
                guard ProfileID.isValid(p.id), p.id != Profile.defaultID else {
                    throw ProfileError.registryCorrupt("bad id '\(p.id)'")
                }
                guard let dir = p.configDir, dir.hasPrefix("/") else {
                    throw ProfileError.registryCorrupt("profile '\(p.id)' has no absolute directory")
                }
            }
            return file.profiles
        } catch let e as ProfileError {
            throw e
        } catch {
            throw ProfileError.registryCorrupt("\(error)")
        }
    }

    private func save(_ profiles: [Profile]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(File(version: 1, profiles: profiles))
        try SafeFS.ensureDir(paths.root)
        try SafeFS.writeAtomic(data, to: paths.profilesFile)
    }
}
