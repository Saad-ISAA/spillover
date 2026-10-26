import Foundation

/// Owner-only filesystem primitives (modes and atomic writes are decided here, once).
/// All Switchboard state is written through here so modes and atomicity are decided once.
public enum SafeFS {
    public static let dirMode: UInt16 = 0o700
    public static let fileMode: UInt16 = 0o600

    public struct Failure: Error, CustomStringConvertible {
        public let description: String
    }

    /// Create a directory (and parents) and force owner-only mode on the leaf we own.
    public static func ensureDir(_ url: URL, mode: UInt16 = dirMode) throws {
        let fm = FileManager.default
        try fm.createDirectory(
            at: url, withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: mode)])
        try fm.setAttributes([.posixPermissions: NSNumber(value: mode)], ofItemAtPath: url.path)
    }

    /// Write atomically: temp file in the same directory, mode set BEFORE the rename, then replace.
    /// `mode` nil keeps the existing file's mode (used for files we do not own, e.g. VS Code settings).
    public static func writeAtomic(_ data: Data, to url: URL, mode: UInt16? = fileMode) throws {
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        var finalMode = mode
        if finalMode == nil {
            finalMode = permissions(of: url) ?? fileMode
        }
        if !fm.fileExists(atPath: dir.path) { try ensureDir(dir) }
        let tmp = dir.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        guard fm.createFile(
            atPath: tmp.path, contents: data,
            attributes: [.posixPermissions: NSNumber(value: finalMode ?? fileMode)])
        else { throw Failure(description: "cannot create temp file next to \(url.lastPathComponent)") }
        do {
            if fm.fileExists(atPath: url.path) {
                _ = try fm.replaceItemAt(url, withItemAt: tmp)
            } else {
                try fm.moveItem(at: tmp, to: url)
            }
            try fm.setAttributes(
                [.posixPermissions: NSNumber(value: finalMode ?? fileMode)], ofItemAtPath: url.path)
        } catch {
            try? fm.removeItem(at: tmp)
            throw error
        }
    }

    /// POSIX permission bits of a path, or nil if it does not exist.
    public static func permissions(of url: URL) -> UInt16? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
            let n = attrs[.posixPermissions] as? NSNumber
        else { return nil }
        return n.uint16Value & 0o7777
    }

    /// True when the path is owned by the current user.
    public static func isOwnedByCurrentUser(_ url: URL) -> Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
            let owner = attrs[.ownerAccountID] as? NSNumber
        else { return false }
        return owner.uint32Value == getuid()
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
}
