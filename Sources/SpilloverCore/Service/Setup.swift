import Foundation

/// Installs and removes Spillover's hooks into the user's tools. Every step is explicit,
/// reversible, and reported; nothing here runs without the user asking for it.
public struct Setup {
    public struct Step: Equatable, Sendable {
        public let name: String
        public let ok: Bool
        public let detail: String
    }

    private let env: SBEnvironment

    public init(env: SBEnvironment) {
        self.env = env
    }

    /// Copy `spillover-launch` and `spillover` from `executablesDir` (next to the running CLI or
    /// inside the app bundle) into `<root>/bin`, and create the `claude` shim link.
    public func installBinaries(from executablesDir: URL) -> [Step] {
        var steps: [Step] = []
        let shim = ShellShim(env: env)
        do {
            try shim.installLauncher(from: executablesDir.appendingPathComponent("spillover-launch"))
            steps.append(Step(name: "launcher", ok: true, detail: env.paths.launcher.path))
        } catch {
            steps.append(Step(name: "launcher", ok: false, detail: error.localizedDescription))
        }
        let cliSource = executablesDir.appendingPathComponent("spillover")
        let cliTarget = env.paths.binDir.appendingPathComponent("spillover")
        if FileManager.default.isExecutableFile(atPath: cliSource.path),
            cliSource.standardizedFileURL != cliTarget.standardizedFileURL
        {
            do {
                try SafeFS.writeAtomic(try Data(contentsOf: cliSource), to: cliTarget, mode: 0o755)
                steps.append(Step(name: "cli", ok: true, detail: cliTarget.path))
            } catch {
                steps.append(Step(name: "cli", ok: false, detail: error.localizedDescription))
            }
        }
        return steps
    }

    public func connectEditor(_ editor: Editor, force: Bool = false) -> Step {
        do {
            let record = try VSCodeInstaller(env: env).install(editor: editor, force: force)
            let backup = record.backupPath.map { " (backup: \($0))" } ?? ""
            return Step(name: "editor:\(editor.rawValue)", ok: true, detail: "connected\(backup)")
        } catch {
            return Step(name: "editor:\(editor.rawValue)", ok: false, detail: error.localizedDescription)
        }
    }

    public func disconnectEditor(_ editor: Editor) -> Step {
        do {
            let outcome = try VSCodeInstaller(env: env).uninstall(editor: editor)
            return Step(name: "editor:\(editor.rawValue)", ok: true, detail: "\(outcome)")
        } catch {
            return Step(name: "editor:\(editor.rawValue)", ok: false, detail: error.localizedDescription)
        }
    }

    public func connectShell() -> [Step] {
        let shim = ShellShim(env: env)
        return shim.defaultRCFiles().map { rc in
            do {
                try RCFile.install(block: shim.rcBlock(), at: rc)
                return Step(name: "shell", ok: true, detail: "updated \(rc.path) (open a new terminal)")
            } catch {
                return Step(name: "shell", ok: false, detail: error.localizedDescription)
            }
        }
    }

    public func disconnectShell() -> [Step] {
        ShellShim(env: env).defaultRCFiles().map { rc in
            do {
                try RCFile.uninstall(at: rc)
                return Step(name: "shell", ok: true, detail: "cleaned \(rc.path)")
            } catch {
                return Step(name: "shell", ok: false, detail: error.localizedDescription)
            }
        }
    }

    public func connectStatusline(for profile: Profile) -> Step {
        do {
            try StatuslineInstaller(env: env).install(for: profile)
            return Step(name: "statusline:\(profile.id)", ok: true, detail: "usage capture on")
        } catch {
            return Step(name: "statusline:\(profile.id)", ok: false, detail: error.localizedDescription)
        }
    }

    public func disconnectStatusline(for profile: Profile) -> Step {
        do {
            try StatuslineInstaller(env: env).uninstall(for: profile)
            return Step(name: "statusline:\(profile.id)", ok: true, detail: "restored")
        } catch {
            return Step(name: "statusline:\(profile.id)", ok: false, detail: error.localizedDescription)
        }
    }

    /// Undo everything Spillover installed. Profiles, logins and routes are kept.
    public func uninstallAll() -> [Step] {
        var steps: [Step] = []
        for editor in Editor.allCases where VSCodeInstaller(env: env).status(of: editor) == .installed {
            steps.append(disconnectEditor(editor))
        }
        steps += disconnectShell()
        for p in (try? ProfileStore(env: env).all()) ?? [] where StatuslineInstaller(env: env).isInstalled(for: p) {
            steps.append(disconnectStatusline(for: p))
        }
        ShellShim(env: env).removeLauncher()
        try? FileManager.default.removeItem(at: env.paths.binDir.appendingPathComponent("spillover"))
        steps.append(Step(name: "binaries", ok: true, detail: "removed launcher, shim and CLI copy"))
        return steps
    }
}
