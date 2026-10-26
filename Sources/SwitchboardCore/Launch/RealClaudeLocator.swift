import Foundation

public enum LaunchMode: String, Sendable {
    /// Invoked by an editor extension in place of its bundled Claude binary.
    case editorWrapper
    /// Invoked as `claude` through the PATH shim.
    case shellShim
}

/// Finds the Claude executable that Switchboard should hand control to, never one of Switchboard's
/// own entry points (launcher or shim), so a launch can never loop.
public struct RealClaudeLocator {
    private let env: SBEnvironment

    public init(env: SBEnvironment) {
        self.env = env
    }

    /// Extension directories of the VS Code family, newest bundled binary wins.
    static let editorExtensionDirs = [
        ".vscode/extensions", ".vscode-insiders/extensions", ".cursor/extensions",
        ".windsurf/extensions", ".vscode-oss/extensions",
    ]

    public func locate(mode: LaunchMode, baseEnv: [String: String]) -> String? {
        if let forced = baseEnv["SWITCHBOARD_REAL_CLAUDE"], forced.hasPrefix("/"), usable(forced) {
            return forced
        }
        var candidates: [String] = []
        let bundled = newestBundledBinary()
        let pathHits = searchPATH(baseEnv["PATH"] ?? "")
        // Claude Code's native installer location; Homebrew and others are found through PATH.
        let wellKnown = [env.home.appendingPathComponent(".local/bin/claude").path]
        switch mode {
        case .editorWrapper:
            if let bundled { candidates.append(bundled) }
            candidates += wellKnown + pathHits
        case .shellShim:
            candidates += pathHits + wellKnown
            if let bundled { candidates.append(bundled) }
        }
        return candidates.first(where: usable)
    }

    // MARK: Internals

    private func usable(_ path: String) -> Bool {
        guard FileManager.default.isExecutableFile(atPath: path) else { return false }
        return !isOurs(path)
    }

    /// True for the launcher itself and anything inside the shims directory.
    func isOurs(_ path: String) -> Bool {
        let paths = env.paths
        let real = realpathString(path) ?? path
        if real == (realpathString(paths.launcher.path) ?? paths.launcher.path) { return true }
        let shims = realpathString(paths.shimsDir.path) ?? paths.shimsDir.path
        let dir = (path as NSString).deletingLastPathComponent
        let realDir = realpathString(dir) ?? dir
        return realDir == shims || path.hasPrefix(paths.shimsDir.path + "/")
    }

    private func searchPATH(_ pathVar: String) -> [String] {
        pathVar.split(separator: ":", omittingEmptySubsequences: true).map {
            ($0 as NSString).appendingPathComponent("claude")
        }
    }

    private func newestBundledBinary() -> String? {
        var best: (version: [Int], path: String)?
        let fm = FileManager.default
        for rel in Self.editorExtensionDirs {
            let dir = env.home.appendingPathComponent(rel, isDirectory: true)
            guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { continue }
            for name in names where name.hasPrefix("anthropic.claude-code-") {
                let binary = dir.appendingPathComponent(name)
                    .appendingPathComponent("resources/native-binary/claude").path
                guard fm.isExecutableFile(atPath: binary) else { continue }
                let version = Self.parseVersion(name)
                if best == nil || Self.isNewer(version, than: best!.version) {
                    best = (version, binary)
                }
            }
        }
        return best?.path
    }

    /// `anthropic.claude-code-2.1.310-darwin-arm64` -> [2, 1, 310]
    static func parseVersion(_ directoryName: String) -> [Int] {
        let tail = directoryName.dropFirst("anthropic.claude-code-".count)
        let versionPart = tail.prefix { $0.isNumber || $0 == "." }
        return versionPart.split(separator: ".").compactMap { Int($0) }
    }

    static func isNewer(_ a: [Int], than b: [Int]) -> Bool {
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    private func realpathString(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
