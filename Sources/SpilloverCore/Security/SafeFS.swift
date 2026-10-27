import Foundation

/// Owner-only filesystem primitives: modes, atomic writes, ownership checks and the state lock
/// are decided here, once. All Spillover state is written through this type.
public enum SafeFS {
    public static let dirMode: UInt16 = 0o700
    public static let fileMode: UInt16 = 0o600

    public struct Failure: Error, CustomStringConvertible, LocalizedError {
        public let description: String
        public init(description: String) { self.description = description }
        public var errorDescription: String? { description }
    }

    /// Create a directory (and parents). The mode is applied only to directories this call
    /// creates; existing directories (possibly the user's own) are never re-moded.
    public static func ensureDir(_ url: URL, mode: UInt16 = dirMode) throws {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: url.path, isDirectory: &isDir) {
            guard isDir.boolValue else { throw Failure(description: "\(url.path) is not a folder") }
            return
        }
        try fm.createDirectory(
            at: url, withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: mode)])
        try fm.setAttributes([.posixPermissions: NSNumber(value: mode)], ofItemAtPath: url.path)
    }

    /// Final target of a path when it is a symlink (followed through chains), else the path.
    public static func resolvedTarget(_ url: URL) -> URL {
        guard (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil,
            let real = realpath(url.path, nil)
        else { return url }
        defer { free(real) }
        return URL(fileURLWithPath: String(cString: real))
    }

    /// Write atomically: temp file in the same directory, mode set BEFORE the rename, then replace.
    /// A symlink is followed and its target is written, so dotfile setups keep their links.
    /// `mode` nil keeps the existing file's mode (used for files we do not own, e.g. VS Code settings).
    public static func writeAtomic(_ data: Data, to link: URL, mode: UInt16? = fileMode) throws {
        let url = resolvedTarget(link)
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        let finalMode = mode ?? permissions(of: url) ?? fileMode
        if !fm.fileExists(atPath: dir.path) { try ensureDir(dir) }
        let tmp = dir.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        guard fm.createFile(
            atPath: tmp.path, contents: data,
            attributes: [.posixPermissions: NSNumber(value: finalMode)])
        else { throw Failure(description: "cannot create temp file next to \(url.lastPathComponent)") }
        do {
            if fm.fileExists(atPath: url.path) {
                _ = try fm.replaceItemAt(url, withItemAt: tmp)
            } else {
                try fm.moveItem(at: tmp, to: url)
            }
            try fm.setAttributes([.posixPermissions: NSNumber(value: finalMode)], ofItemAtPath: url.path)
        } catch {
            try? fm.removeItem(at: tmp)
            throw error
        }
    }

    /// POSIX permission bits of a path (following symlinks), or nil if it does not exist.
    public static func permissions(of url: URL) -> UInt16? {
        var st = stat()
        guard stat(url.path, &st) == 0 else { return nil }
        return UInt16(st.st_mode & 0o7777)
    }

    /// True when the path (following symlinks) is owned by the current user.
    public static func isOwnedByCurrentUser(_ url: URL) -> Bool {
        var st = stat()
        guard stat(url.path, &st) == 0 else { return false }
        return st.st_uid == getuid()
    }

    /// Anyone but the owner can write (group-write or other-write bits).
    public static func isWritableByOthers(_ url: URL) -> Bool {
        guard let mode = permissions(of: url) else { return false }
        return mode & 0o022 != 0
    }

    /// Anyone but the owner can read or write (any group/other bit).
    public static func isAccessibleByOthers(_ url: URL) -> Bool {
        guard let mode = permissions(of: url) else { return false }
        return mode & 0o077 != 0
    }

    /// Why a state file (or the folder holding it) cannot be trusted, or nil when it can.
    /// Used before reading anything that decides which account Claude runs with.
    public static func trustProblem(_ url: URL, name: String) -> String? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        if !isOwnedByCurrentUser(url) { return "\(name) is not owned by you" }
        if isWritableByOthers(url) { return "\(name) is writable by other users" }
        return nil
    }

    /// Run `body` holding an exclusive lock on `<root>/.lock`, so the app and the CLI cannot lose
    /// each other's read-modify-write updates.
    public static func withLock<T>(root: URL, _ body: () throws -> T) throws -> T {
        try ensureDir(root)
        let lockPath = root.appendingPathComponent(".lock").path
        let fd = open(lockPath, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { return try body() }
        defer { close(fd) }
        flock(fd, LOCK_EX)
        defer { flock(fd, LOCK_UN) }
        return try body()
    }
}
