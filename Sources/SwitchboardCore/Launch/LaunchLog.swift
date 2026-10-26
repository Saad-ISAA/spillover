import Foundation

/// Append-only record of every launch decision (mode, folder, profile id, outcome). Contains no
/// credentials and no arguments (prompts may be passed as arguments, so they are never logged).
/// Owner-only file, rotated at ~512 KB.
public struct LaunchLog {
    private let env: SBEnvironment
    static let maxBytes = 512 * 1024

    public init(env: SBEnvironment) {
        self.env = env
    }

    public func append(mode: LaunchMode, cwd: String, profile: String, outcome: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let line = Redaction.scrub(
            "\(stamp) mode=\(mode.rawValue) profile=\(profile) result=\(outcome) cwd=\(cwd)") + "\n"
        let paths = env.paths
        let fm = FileManager.default
        do {
            try SafeFS.ensureDir(paths.root)
            try SafeFS.ensureDir(paths.logsDir)
            rotateIfNeeded(paths.launchLog)
            if !fm.fileExists(atPath: paths.launchLog.path) {
                fm.createFile(
                    atPath: paths.launchLog.path, contents: nil,
                    attributes: [.posixPermissions: NSNumber(value: SafeFS.fileMode)])
            }
            let handle = try FileHandle(forWritingTo: paths.launchLog)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(line.utf8))
        } catch {
            // Logging is best effort and must never block a launch.
        }
    }

    /// Most recent entries, newest last.
    public func tail(_ count: Int) -> [String] {
        guard let text = try? String(contentsOf: env.paths.launchLog, encoding: .utf8) else { return [] }
        return Array(text.split(separator: "\n").suffix(count).map(String.init))
    }

    private func rotateIfNeeded(_ url: URL) {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: url.path),
            let size = attrs[.size] as? NSNumber, size.intValue > Self.maxBytes
        else { return }
        let old = url.appendingPathExtension("1")
        try? fm.removeItem(at: old)
        try? fm.moveItem(at: url, to: old)
    }
}
