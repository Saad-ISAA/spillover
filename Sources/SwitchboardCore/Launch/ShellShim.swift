import Foundation

/// Installs the pieces that make plain `claude` in any terminal follow the same routes as the
/// editor: the launcher binary in a stable location, a `claude` symlink to it inside a shims
/// directory, and a guarded block in the shell startup file that puts that directory first on PATH.
public struct ShellShim {
    public static let beginMarker = "# >>> switchboard >>>"
    public static let endMarker = "# <<< switchboard <<<"

    private let env: SBEnvironment

    public init(env: SBEnvironment) {
        self.env = env
    }

    /// Copy the launcher to `<root>/bin/switchboard-launch` (stable path the editor setting points
    /// at, independent of where the build or app bundle lives) and link `shims/claude` to it.
    public func installLauncher(from source: URL) throws {
        let paths = env.paths
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: source.path) else {
            throw SafeFS.Failure(description: "launcher binary not found at \(source.path)")
        }
        try SafeFS.ensureDir(paths.root)
        try SafeFS.ensureDir(paths.binDir)
        try SafeFS.ensureDir(paths.shimsDir)
        let data = try Data(contentsOf: source)
        try SafeFS.writeAtomic(data, to: paths.launcher, mode: 0o755)

        let shim = paths.shimsDir.appendingPathComponent("claude")
        try? fm.removeItem(at: shim)
        try fm.createSymbolicLink(at: shim, withDestinationURL: paths.launcher)
    }

    public func removeLauncher() {
        let paths = env.paths
        let fm = FileManager.default
        try? fm.removeItem(at: paths.shimsDir.appendingPathComponent("claude"))
        try? fm.removeItem(at: paths.launcher)
    }

    public var isLauncherInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: env.paths.launcher.path)
    }

    /// The block written into a shell startup file.
    public func rcBlock() -> String {
        let shims = env.paths.shimsDir.path
        let home = env.home.path
        let shown = shims.hasPrefix(home + "/") ? "$HOME" + shims.dropFirst(home.count) : shims
        return """
            \(Self.beginMarker)
            export PATH="\(shown):$PATH"
            \(Self.endMarker)
            """
    }

    /// Startup files we manage by default (zsh is the macOS default shell).
    public func defaultRCFiles() -> [URL] {
        [env.home.appendingPathComponent(".zshrc")]
    }
}

/// Idempotent marker-block editing for shell startup files. Everything outside the markers is left
/// byte-for-byte as it was.
public enum RCFile {
    public static func install(block: String, at url: URL) throws {
        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let updated = inserting(block: block, into: existing)
        guard updated != existing else { return }
        try SafeFS.writeAtomic(Data(updated.utf8), to: url, mode: nil)
    }

    public static func uninstall(at url: URL) throws {
        guard let existing = try? String(contentsOf: url, encoding: .utf8) else { return }
        let updated = removingBlock(from: existing)
        guard updated != existing else { return }
        try SafeFS.writeAtomic(Data(updated.utf8), to: url, mode: nil)
    }

    public static func hasBlock(at url: URL) -> Bool {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
        return text.contains(ShellShim.beginMarker) && text.contains(ShellShim.endMarker)
    }

    static func inserting(block: String, into text: String) -> String {
        if let range = blockRange(in: text) {
            var copy = text
            copy.replaceSubrange(range, with: block)
            return copy
        }
        var out = text
        if !out.isEmpty && !out.hasSuffix("\n") { out += "\n" }
        if !out.isEmpty { out += "\n" }
        return out + block + "\n"
    }

    static func removingBlock(from text: String) -> String {
        guard var range = blockRange(in: text) else { return text }
        // Also swallow the single blank line we added in front of the block, and its newline.
        var copy = text
        if range.upperBound < copy.endIndex, copy[range.upperBound] == "\n" {
            range = range.lowerBound..<copy.index(after: range.upperBound)
        }
        if range.lowerBound > copy.startIndex {
            let before = copy.index(before: range.lowerBound)
            if copy[before] == "\n", before > copy.startIndex,
                copy[copy.index(before: before)] == "\n"
            {
                range = before..<range.upperBound
            }
        }
        copy.removeSubrange(range)
        return copy
    }

    /// Range from the begin marker through the end marker (excluding the trailing newline).
    private static func blockRange(in text: String) -> Range<String.Index>? {
        guard let begin = text.range(of: ShellShim.beginMarker),
            let end = text.range(of: ShellShim.endMarker, range: begin.upperBound..<text.endIndex)
        else { return nil }
        return begin.lowerBound..<end.upperBound
    }
}
