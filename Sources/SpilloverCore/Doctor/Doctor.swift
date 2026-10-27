import Foundation

public struct HealthCheck: Equatable, Sendable, Identifiable {
    public enum Status: String, Sendable { case ok, warning, failure, info }

    public let id: String
    public let title: String
    public let status: Status
    public let detail: String
}

/// Read-only health checks: permissions, registry integrity, routing references, editor
/// integration, extension contract, shell shim and Keychain slots. Never changes anything.
public struct Doctor {
    private let env: SBEnvironment
    private let keychain: KeychainProbe?

    /// Pass `keychain: nil` to skip Keychain checks (tests, or when the user opts out).
    public init(env: SBEnvironment, keychain: KeychainProbe? = KeychainProbe()) {
        self.env = env
        self.keychain = keychain
    }

    public func run() -> [HealthCheck] {
        var checks: [HealthCheck] = []
        checks += permissionChecks()
        let (profileChecks, profiles) = registryChecks()
        checks += profileChecks
        checks += routeChecks(profiles: profiles)
        checks += editorChecks()
        checks += shimChecks()
        if let keychain { checks += keychainChecks(profiles: profiles, probe: keychain) }
        return checks
    }

    // MARK: Checks

    private func permissionChecks() -> [HealthCheck] {
        let paths = env.paths
        let fm = FileManager.default
        guard fm.fileExists(atPath: paths.root.path) else {
            return [
                HealthCheck(
                    id: "root", title: "Spillover folder", status: .info,
                    detail: "Not created yet (\(paths.root.path)).")
            ]
        }
        var out: [HealthCheck] = []
        let sensitive = [paths.root, paths.routesFile, paths.profilesFile, paths.binDir, paths.launcher]
        for url in sensitive where fm.fileExists(atPath: url.path) {
            let name = url.lastPathComponent
            if !SafeFS.isOwnedByCurrentUser(url) {
                out.append(
                    HealthCheck(
                        id: "perm.\(name)", title: "Ownership of \(name)", status: .failure,
                        detail: "\(url.path) is not owned by you. Launches are refused until fixed."))
            } else if SafeFS.isWritableByOthers(url) {
                out.append(
                    HealthCheck(
                        id: "perm.\(name)", title: "Permissions of \(name)", status: .failure,
                        detail: "\(url.path) is writable by other users. Fix: chmod go-w \(url.path)"))
            }
        }
        if out.isEmpty {
            out.append(
                HealthCheck(
                    id: "perm", title: "File permissions", status: .ok,
                    detail: "Spillover files are owner-only."))
        }
        return out
    }

    private func registryChecks() -> ([HealthCheck], [Profile]) {
        do {
            let profiles = try ProfileStore(env: env).all()
            var out = [
                HealthCheck(
                    id: "profiles", title: "Profiles", status: .ok,
                    detail: "\(profiles.count) profile(s) including Default.")
            ]
            for p in profiles where !p.isDefault {
                guard let dir = p.configDir else { continue }
                if !FileManager.default.fileExists(atPath: dir) {
                    out.append(
                        HealthCheck(
                            id: "profile.\(p.id).dir", title: "Profile \(p.displayName)", status: .failure,
                            detail: "Directory missing: \(dir). Folders routed to it will refuse to start."))
                } else if SafeFS.isAccessibleByOthers(URL(fileURLWithPath: dir)) {
                    out.append(
                        HealthCheck(
                            id: "profile.\(p.id).perm", title: "Profile \(p.displayName)", status: .warning,
                            detail: "\(dir) is readable by other users. Suggested: chmod 700 \(dir)"))
                }
            }
            return (out, profiles)
        } catch {
            return (
                [
                    HealthCheck(
                        id: "profiles", title: "Profiles", status: .failure,
                        detail: error.localizedDescription)
                ], [Profile.builtInDefault()]
            )
        }
    }

    private func autoChecks(routes: [Route]) -> [HealthCheck] {
        guard routes.contains(where: { $0.profileId == Profile.autoID }) else { return [] }
        switch AutoPolicyStore(env: env).load() {
        case .loaded(let p):
            return [HealthCheck(
                id: "auto", title: "Auto", status: .ok,
                detail: "Auto folders move on at \(Int(p.threshold))%; open chats \(p.moveOpenChats ? "move" : "stay") when an account runs low.")]
        case .corrupt(let why), .insecure(let why):
            return [HealthCheck(
                id: "auto", title: "Auto", status: .failure,
                detail: "auto.json cannot be used (\(why)). Claude refuses to start in Auto folders.")]
        }
    }

    private func routeChecks(profiles: [Profile]) -> [HealthCheck] {
        switch RouteStore(env: env).load() {
        case .missing:
            return [
                HealthCheck(
                    id: "routes", title: "Routes", status: .info,
                    detail: "No folders assigned yet; every folder uses the Default account.")
            ]
        case .corrupt(let why):
            return [
                HealthCheck(
                    id: "routes", title: "Routes", status: .failure,
                    detail: "routes.json is unreadable (\(why)). Routed launches are refused.")
            ]
        case .insecure(let why):
            return [HealthCheck(id: "routes", title: "Routes", status: .failure, detail: why)]
        case .loaded(let routes):
            let ids = Set(profiles.map(\.id))
            var out = [
                HealthCheck(
                    id: "routes", title: "Routes", status: .ok, detail: "\(routes.count) folder(s) assigned.")
            ]
            out += autoChecks(routes: routes)
            for r in routes where !ids.contains(r.profileId) && r.profileId != Profile.autoID {
                out.append(
                    HealthCheck(
                        id: "route.\(r.folder)", title: "Route \(r.folder)", status: .failure,
                        detail: "Points at missing profile '\(r.profileId)'; launches there are refused."))
            }
            for r in routes where !FileManager.default.fileExists(atPath: r.folder) {
                out.append(
                    HealthCheck(
                        id: "route.\(r.folder).missing", title: "Route \(r.folder)", status: .warning,
                        detail: "Folder no longer exists."))
            }
            return out
        }
    }

    private func editorChecks() -> [HealthCheck] {
        var out: [HealthCheck] = []
        let installer = VSCodeInstaller(env: env)
        let editors = Editor.installed(env: env)
        if editors.isEmpty {
            out.append(
                HealthCheck(
                    id: "editor", title: "Editors", status: .info,
                    detail: "No VS Code family editor found."))
        }
        for editor in editors {
            let status = installer.status(of: editor)
            let check: HealthCheck
            switch status {
            case .installed:
                check = HealthCheck(
                    id: "editor.\(editor.rawValue)", title: editor.displayName, status: .ok,
                    detail: "Claude panel sessions are routed by Spillover.")
            case .notInstalled:
                check = HealthCheck(
                    id: "editor.\(editor.rawValue)", title: editor.displayName, status: .info,
                    detail: "Not connected. Run `spillover install --editor \(editor.rawValue)`.")
            case .otherWrapper(let value):
                check = HealthCheck(
                    id: "editor.\(editor.rawValue)", title: editor.displayName, status: .warning,
                    detail: "Another wrapper is configured: \(value)")
            case .editorNotFound:
                continue
            }
            out.append(check)
        }

        let contract = ExtensionContract.check(editor: .code, env: env)
        if contract.finding != .extensionNotFound {
            out.append(
                HealthCheck(
                    id: "extension-reopen", title: "Moving open chats",
                    status: contract.reopensChats ? .ok : .warning,
                    detail: contract.reopensChats
                        ? "This extension version reopens chats from a link, so open chats can move to another account."
                        : "This extension version does not reopen chats from a link. New chats still start on the folder's account; open chats keep theirs until you start a new chat or reload the window."))
        }
        switch contract.finding {
        case .ok:
            out.append(
                HealthCheck(
                    id: "extension", title: "Claude Code extension \(contract.extensionVersion ?? "")",
                    status: .ok, detail: "Wrapper setting present (machine scope)."))
        case .extensionNotFound:
            out.append(
                HealthCheck(
                    id: "extension", title: "Claude Code extension", status: .info,
                    detail: "Not installed in VS Code."))
        case .wrapperSettingMissing:
            out.append(
                HealthCheck(
                    id: "extension", title: "Claude Code extension \(contract.extensionVersion ?? "")",
                    status: .failure,
                    detail: "This version no longer exposes claudeCode.claudeProcessWrapper; panel routing will not work."))
        case .wrapperScopeChanged(let scope):
            out.append(
                HealthCheck(
                    id: "extension", title: "Claude Code extension \(contract.extensionVersion ?? "")",
                    status: .warning,
                    detail: "Wrapper setting scope is now '\(scope)'. Routing from user settings still applies."))
        }
        return out
    }

    private func shimChecks() -> [HealthCheck] {
        let shim = ShellShim(env: env)
        let rc = shim.defaultRCFiles().first
        let launcherOK = shim.isLauncherInstalled
        let rcOK = rc.map(RCFile.hasBlock(at:)) ?? false
        let detail: String
        let status: HealthCheck.Status
        switch (launcherOK, rcOK) {
        case (true, true):
            status = .ok
            detail = "`claude` in new terminals follows your routes."
        case (true, false):
            status = .info
            detail = "Launcher installed; terminals not connected. Run `spillover install --shell`."
        case (false, _):
            status = .info
            detail = "Launcher not installed. Run `spillover install`."
        }
        return [HealthCheck(id: "shell", title: "Terminals", status: status, detail: detail)]
    }

    private func keychainChecks(profiles: [Profile], probe: KeychainProbe) -> [HealthCheck] {
        var out: [HealthCheck] = []
        var expected = Set<String>()
        for p in profiles {
            let service = KeychainSlot.serviceName(forConfigDir: p.configDir)
            expected.insert(service)
            if !probe.itemExists(service: service) {
                out.append(
                    HealthCheck(
                        id: "keychain.\(p.id)", title: "Login for \(p.displayName)", status: .warning,
                        detail: "No saved login found. Use “Log in” for this profile."))
            }
        }
        let orphans = probe.claudeServices().filter { !expected.contains($0) }
        if !orphans.isEmpty {
            out.append(
                HealthCheck(
                    id: "keychain.orphans", title: "Unused Claude logins in Keychain", status: .info,
                    detail:
                        "\(orphans.count) Keychain item(s) belong to no Spillover profile (often left by other tools or deleted folders). They can be removed in Keychain Access if unneeded."
                ))
        }
        if out.isEmpty {
            out.append(
                HealthCheck(
                    id: "keychain", title: "Logins", status: .ok,
                    detail: "Every profile has a saved login."))
        }
        return out
    }
}
