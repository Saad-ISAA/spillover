import Foundation
import SwitchboardCore

struct Commands {
    let env: SBEnvironment
    let service: AppService

    init(env: SBEnvironment) {
        self.env = env
        self.service = AppService(env: env)
    }

    // MARK: status

    func status(_ args: Args) throws {
        let profiles = try service.allProfiles()
        let routes = (try? service.routes.routes()) ?? []
        let snapshots = service.usageSnapshots()

        if args.flag("json") {
            struct Row: Encodable {
                let id: String
                let name: String
                let configDir: String?
                let folders: [String]
                let usage: UsageSnapshot?
            }
            try Out.json(
                profiles.map { p in
                    Row(
                        id: p.id, name: p.displayName, configDir: p.configDir,
                        folders: routes.filter { $0.profileId == p.id }.map(\.folder), usage: snapshots[p.id])
                })
            return
        }

        Out.line("Profiles")
        var rows: [[String]] = [["  ID", "NAME", "ACCOUNT", "PLAN", "USAGE", "FOLDERS"]]
        for p in profiles {
            var account = "-"
            var plan = "-"
            if !args.flag("offline") {
                switch service.authStatus(for: p) {
                case .success(let s) where s.loggedIn:
                    account = s.email.map(Redaction.email) ?? "logged in"
                    plan = s.planLabel ?? "-"
                case .success:
                    account = "not logged in"
                case .failure(let e):
                    account = e.localizedDescription
                }
            }
            let usage = snapshots[p.id].map { s in
                s.windows.filter { $0.kind != .spendLimit }
                    .map { "\($0.kind.shortLabel) \(Out.percent($0.effectivePercentage()))" }
                    .joined(separator: " ")
            } ?? "-"
            let folders = routes.filter { $0.profileId == p.id }.count
            rows.append(["  \(p.id)", p.displayName, account, plan, usage.isEmpty ? "-" : usage, "\(folders)"])
        }
        Out.table(rows)

        Out.line()
        Out.line("Assigned folders")
        if routes.isEmpty {
            Out.line("  none — every folder uses the Default account")
        } else {
            Out.table(routes.map { ["  \($0.folder)", "→ \($0.profileId)"] })
        }

        Out.line()
        Out.line("Setup")
        let installer = VSCodeInstaller(env: env)
        for editor in Editor.installed(env: env) {
            Out.line("  \(editor.displayName): \(describe(installer.status(of: editor)))")
        }
        let shim = ShellShim(env: env)
        let rcConnected = shim.defaultRCFiles().contains(where: RCFile.hasBlock(at:))
        Out.line("  Launcher: \(shim.isLauncherInstalled ? "installed" : "not installed")")
        Out.line("  Terminals: \(rcConnected ? "connected" : "not connected")")
    }

    private func describe(_ status: InstallStatus) -> String {
        switch status {
        case .installed: return "connected"
        case .notInstalled: return "not connected"
        case .otherWrapper(let v): return "another wrapper is set (\(v))"
        case .editorNotFound: return "not found"
        }
    }

    // MARK: profile

    func profile(_ args: Args) throws {
        let sub = args.positional(1) ?? "list"
        switch sub {
        case "list":
            let profiles = try service.allProfiles()
            Out.table(
                [["ID", "NAME", "DIRECTORY"]]
                    + profiles.map { [$0.id, $0.displayName, $0.configDir ?? "~/.claude (Claude's default)"] })
        case "create":
            guard let name = args.positional(2) else { throw CLIError.usage("switchboard profile create <name>") }
            let p = try service.profiles.create(displayName: name)
            Out.line("Created profile '\(p.id)' at \(p.configDir ?? "")")
            Out.line("Next: switchboard profile login \(p.id)")
        case "adopt":
            guard let name = args.positional(2), let dir = args.positional(3) else {
                throw CLIError.usage("switchboard profile adopt <name> <existing-config-dir>")
            }
            let p = try service.profiles.adopt(displayName: name, directory: dir)
            Out.line("Adopted \(dir) as profile '\(p.id)' (existing login kept).")
        case "login":
            let p = try requireProfile(args.positional(2))
            if args.flag("terminal") {
                try service.openLoginTerminal(for: p)
                Out.line("Opened Terminal to log in to '\(p.id)'.")
            } else {
                Out.line("Logging in to '\(p.id)'. Your browser will open; use the account you want for this profile.")
                let code = ClaudeCLI(env: env).loginInteractively(profile: p)
                if code != 0 { throw CLIError.failed("login exited with \(code)") }
            }
        case "logout":
            let p = try requireProfile(args.positional(2))
            let code = ClaudeCLI(env: env).logoutInteractively(profile: p)
            if code != 0 { throw CLIError.failed("logout exited with \(code)") }
        case "rename":
            guard let id = args.positional(2), let name = args.positional(3) else {
                throw CLIError.usage("switchboard profile rename <id> <new name>")
            }
            try service.profiles.rename(id: id, to: name)
            Out.line("Renamed '\(id)'.")
        case "remove":
            guard let id = args.positional(2) else {
                throw CLIError.usage("switchboard profile remove <id> [--unassign] [--delete-dir]")
            }
            try service.removeProfile(
                id: id, unassign: args.flag("unassign"), deleteDirectory: args.flag("delete-dir"))
            Out.line("Removed profile '\(id)'. Its Keychain login (if any) is untouched; log out first if you want it gone.")
        case "share", "unshare":
            let p = try requireProfile(args.positional(2))
            let items = Array(args.positionals.dropFirst(3))
            guard !items.isEmpty else {
                throw CLIError.usage(
                    "switchboard profile \(sub) <id> <item...> [--from <id>] [--replace]\nItems: \(ProfileSharing.shareable.joined(separator: ", "))"
                )
            }
            let sharing = ProfileSharing(env: env)
            let source = try requireProfile(args.option("from") ?? Profile.defaultID)
            for item in items {
                if sub == "share" {
                    try sharing.share(item, from: source, to: p, replace: args.flag("replace"))
                    Out.line("\(item): linked from '\(source.id)'")
                } else {
                    try sharing.unshare(item, in: p)
                    Out.line("\(item): unlinked")
                }
            }
        default:
            throw CLIError.usage("Unknown profile command '\(sub)'. See `switchboard help`.")
        }
    }

    private func requireProfile(_ id: String?) throws -> Profile {
        guard let id else { throw CLIError.usage("Missing profile id. See `switchboard profile list`.") }
        guard let p = try service.profiles.profile(id: id) else { throw ProfileError.notFound(id) }
        return p
    }

    // MARK: route

    func route(_ args: Args) throws {
        let sub = args.positional(1) ?? "list"
        switch sub {
        case "list":
            let routes = try service.routes.routes()
            if routes.isEmpty { Out.line("No folders assigned. Every folder uses the Default account.") }
            Out.table(routes.map { [$0.folder, "→", $0.profileId] })
        case "set", "assign":
            guard let folder = args.positional(2), let id = args.positional(3) else {
                throw CLIError.usage("switchboard route set <folder> <profile-id|auto>")
            }
            let route = try service.assign(folder: absolute(folder), to: id)
            Out.line("\(route.folder) → \(id)")
            Out.line("New Claude sessions in this folder (and below) use '\(id)'. Running sessions keep their account until restarted.")
        case "unset", "unassign":
            guard let folder = args.positional(2) else { throw CLIError.usage("switchboard route unset <folder>") }
            try service.unassign(folder: absolute(folder))
            Out.line("Unassigned. The folder now uses the Default account (or a parent folder's route).")
        case "which":
            let folder = absolute(args.positional(2) ?? FileManager.default.currentDirectoryPath)
            switch service.resolve(folder: folder) {
            case .unrouted:
                Out.line("\(folder): no route — Claude runs with your normal (Default) account.")
            case .routed(let p, let r):
                Out.line("\(folder): \(p.displayName) [\(p.id)] via \(r.folder)")
            case .refused(let refusal):
                Out.line("\(folder): Claude would REFUSE to start — \(refusal.message)")
            }
        default:
            throw CLIError.usage("Unknown route command '\(sub)'. See `switchboard help`.")
        }
    }

    private func absolute(_ path: String) -> String {
        if path.hasPrefix("/") || path.hasPrefix("~") { return path }
        return (FileManager.default.currentDirectoryPath as NSString).appendingPathComponent(path)
    }

    // MARK: install / uninstall

    func install(_ args: Args) throws {
        let setup = Setup(env: env)
        guard let exe = Bundle.main.executableURL?.resolvingSymlinksInPath() else {
            throw CLIError.failed("cannot locate my own executable")
        }
        var steps = setup.installBinaries(from: exe.deletingLastPathComponent())

        let wantsAll = args.flag("all")
        var editors: [Editor] = []
        if let name = args.option("editor") {
            guard let e = Editor(rawValue: name) else {
                throw CLIError.usage("Unknown editor '\(name)'. One of: \(Editor.allCases.map(\.rawValue).joined(separator: ", "))")
            }
            editors = [e]
        } else if wantsAll || !args.flag("shell") && !args.flag("statusline") {
            editors = Editor.installed(env: env).filter { $0 == .code || wantsAll }
        }
        for editor in editors { steps.append(setup.connectEditor(editor, force: args.flag("force"))) }
        if args.flag("shell") || wantsAll { steps += setup.connectShell() }
        if args.flag("statusline") || wantsAll {
            for p in try service.allProfiles() { steps.append(setup.connectStatusline(for: p)) }
        }
        report(steps)
        Out.line()
        Out.line("Restart Claude sessions (or reload VS Code windows) for routing to take effect.")
    }

    func uninstall(_ args: Args) throws {
        report(Setup(env: env).uninstallAll())
        Out.line("Profiles, logins and folder assignments were kept. Delete ~/.switchboard to remove them too.")
    }

    private func report(_ steps: [Setup.Step]) {
        for s in steps { Out.line("\(s.ok ? "✓" : "✗") \(s.name): \(s.detail)") }
    }

    // MARK: usage

    func usage(_ args: Args) throws {
        let days = Int(args.option("days") ?? "7") ?? 7
        let since = Date().addingTimeInterval(-Double(days) * 86400)
        let prices = PriceTable.load(env: env)
        let snapshots = service.usageSnapshots()
        for p in try service.allProfiles() {
            Out.line("\(p.displayName) [\(p.id)]")
            if let s = snapshots[p.id], !s.windows.isEmpty {
                for w in s.windows {
                    Out.line("  \(w.kind.label): \(Out.percent(w.effectivePercentage())) used, resets \(Out.relative(w.resetsAt))")
                }
                Out.line("  (captured \(Out.relative(s.capturedAt)))")
            } else {
                Out.line("  limits: not captured yet (run `switchboard install --statusline`, then use Claude)")
            }
            let report = LocalUsageScanner(env: env).scan(profile: p, since: since, prices: prices)
            var line = "  last \(days)d: \(Out.tokens(report.total.total)) tokens in \(report.total.messages) replies"
            if !prices.models.isEmpty {
                line += String(format: ", ~$%.2f", report.pricedCostUSD)
                if !report.unpricedModels.isEmpty { line += " (+ unpriced models)" }
            }
            Out.line(line)
            let top = report.byProject.sorted { $0.value.total > $1.value.total }.prefix(3)
            for (project, totals) in top { Out.line("    \(Out.tokens(totals.total))  \(project)") }
        }
        let ranked = HeadroomAdvisor.rank(profiles: try service.allProfiles(), snapshots: snapshots)
        if let best = ranked.first, best.peakPercentage != nil {
            Out.line()
            Out.line("Most headroom right now: \(best.profile.displayName)")
        }
    }

    // MARK: sessions

    func sessions(_ args: Args) {
        let scanner = SessionScanner(env: env)
        let assessed = scanner.assess(scanner.scan())
        if assessed.isEmpty {
            Out.line("No Claude sessions running.")
            return
        }
        var rows: [[String]] = [["PID", "ACCOUNT", "STATE", "FOLDER"]]
        for a in assessed {
            let state: String
            switch a.state {
            case .matches: state = "ok"
            case .stale(let expected): state = "restart → \(expected)"
            case .refusedNow: state = "folder refused now"
            case .unknownAccount: state = "unknown account"
            }
            rows.append([
                "\(a.session.pid)", a.actualProfileId ?? "?", state, a.session.cwd ?? "?",
            ])
        }
        Out.table(rows)
    }

    // MARK: statusline (called by Claude Code)

    func statusline() {
        let input = FileHandle.standardInput.readDataToEndOfFile()
        let line = StatuslineCapture(env: env).handle(input: input, processEnv: env.processEnv)
        print(line)
    }

    // MARK: doctor / log / import / open

    func doctor(_ args: Args) {
        for check in service.doctor(includeKeychain: !args.flag("no-keychain")) {
            let mark: String
            switch check.status {
            case .ok: mark = "✓"
            case .warning: mark = "!"
            case .failure: mark = "✗"
            case .info: mark = "·"
            }
            Out.line("\(mark) \(check.title): \(check.detail)")
        }
    }

    func log(_ args: Args) {
        let n = Int(args.positional(1) ?? "20") ?? 20
        let lines = LaunchLog(env: env).tail(n)
        if lines.isEmpty { Out.line("No launches recorded yet.") }
        lines.forEach { Out.line($0) }
    }

    func importLegacy(_ args: Args) throws {
        let importer = LegacyImport(env: env)
        let file = args.positional(1).map { URL(fileURLWithPath: $0) }
        let summary = try importer.run(routesFile: file)
        summary.adoptedProfiles.forEach { Out.line("✓ adopted profile \($0)") }
        summary.reusedProfiles.forEach { Out.line("· reused profile \($0)") }
        summary.routes.forEach { Out.line("✓ \($0)") }
        summary.skipped.forEach { Out.line("✗ skipped \($0)") }
    }

    func open(_ args: Args) throws {
        guard let folder = args.positional(1) else { throw CLIError.usage("switchboard open <folder> [--editor code]") }
        let editor = Editor(rawValue: args.option("editor") ?? "code") ?? .code
        let path = absolute(folder)
        if case .unrouted = service.resolve(folder: path) {
            Out.line("Note: \(path) has no route; Claude there uses your Default account.")
        }
        try service.open(folder: path, in: editor)
    }
}
