import Foundation

public enum LaunchMode: String, Sendable {
    /// Invoked by an editor extension in place of its bundled Claude binary.
    case editorWrapper
    /// Invoked as `claude` through the PATH shim.
    case shellShim
}

/// Finds the Claude executable that Spillover should hand control to, never one of Spillover's
/// own entry points (launcher or shim), so a launch can never loop.
public struct RealClaudeLocator {
    private let env: SBEnvironment

    public init(env: SBEnvironment) {
        self.env = env
    }

    /// Extension directories of the VS Code family, newest bundled binary wins.
    /// `parentExecutable`: the process that started the launcher (the editor's extension host),
    /// used to pick the Claude binary bundled with the extension that is actually calling.
    public func locate(mode: LaunchMode, baseEnv: [String: String], parentExecutable: String? = nil) -> String? {
        if let forced = baseEnv["SPILLOVER_REAL_CLAUDE"], forced.hasPrefix("/"), usable(forced) {
            return forced
        }
        var candidates: [String] = []
        let bundled = bundledBinary(
            editor: parentExecutable.flatMap(Editor.owning(appExecutable:)),
            sdkVersion: baseEnv["CLAUDE_AGENT_SDK_VERSION"])
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

    struct Bundled: Equatable {
        let name: String
        let version: [Int]
        let path: String
        let obsolete: Bool
    }

    /// The Claude binary bundled with the calling extension. After an extension update, a window
    /// that has not reloaded still runs the old extension, so the newest binary is not always the
    /// right one: the extension reports its SDK version, whose last number matches its own
    /// (SDK 0.3.310 ships with extension 2.1.310). Without that, the newest version VS Code has not
    /// marked obsolete wins.
    private func bundledBinary(editor: Editor?, sdkVersion: String?) -> String? {
        let all = installedBundles(editors: editor.map { [$0] } ?? Editor.allCases)
        let pool = all.isEmpty && editor != nil ? installedBundles(editors: Editor.allCases) : all
        return Self.choose(pool, sdkVersion: sdkVersion)?.path
    }

    static func choose(_ bundles: [Bundled], sdkVersion: String?) -> Bundled? {
        func newest(_ list: [Bundled]) -> Bundled? {
            list.max { isNewer($1.version, than: $0.version) ? true : false }
        }
        if let sdk = sdkVersion, let patch = sdk.split(separator: ".").last.flatMap({ Int($0) }) {
            if let match = newest(bundles.filter { $0.version.count == 3 && $0.version[2] == patch }) { return match }
        }
        return newest(bundles.filter { !$0.obsolete }) ?? newest(bundles)
    }

    private func installedBundles(editors: [Editor]) -> [Bundled] {
        let fm = FileManager.default
        var out: [Bundled] = []
        for editor in editors {
            let dir = env.home.appendingPathComponent("\(editor.extensionsDirectoryName)/extensions", isDirectory: true)
            guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { continue }
            let obsolete = Self.obsoleteNames(dir)
            for name in names where name.hasPrefix("anthropic.claude-code-") {
                let binary = dir.appendingPathComponent(name).appendingPathComponent("resources/native-binary/claude").path
                guard fm.isExecutableFile(atPath: binary) else { continue }
                out.append(Bundled(name: name, version: Self.parseVersion(name), path: binary, obsolete: obsolete.contains(name)))
            }
        }
        return out
    }

    /// VS Code lists replaced extension folders in `.obsolete` until it next restarts.
    static func obsoleteNames(_ extensionsDir: URL) -> Set<String> {
        guard let data = try? Data(contentsOf: extensionsDir.appendingPathComponent(".obsolete")),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [] }
        return Set(json.keys)
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
