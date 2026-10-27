import AppKit
import Foundation
import SpilloverCore

/// Login state of one profile as shown in the UI.
enum ProfileStatus: Equatable {
    case unknown
    case checking
    case loggedIn(AuthStatus)
    case loggedOut
    case error(String)

    var auth: AuthStatus? {
        if case .loggedIn(let s) = self { return s }
        return nil
    }
}

struct Banner: Identifiable, Equatable {
    enum Kind { case info, success, error }
    let id = UUID()
    let kind: Kind
    let text: String
}

/// Everything the views show, loaded from the core library. File reads are cheap and done on the
/// main actor; anything that starts a process (login status, Keychain checks) or walks session
/// logs runs in the background.
@MainActor
final class AppModel: ObservableObject {
    /// For notification actions, which arrive outside the SwiftUI tree.
    static weak var shared: AppModel?

    let env: SBEnvironment
    let service: AppService

    @Published var profiles: [Profile] = []
    @Published var statuses: [String: ProfileStatus] = [:]
    @Published var routes: [Route] = []
    @Published var routesProblem: String?
    @Published var snapshots: [String: UsageSnapshot] = [:]
    @Published var history: [String: [UsagePoint]] = [:]
    /// The account the popover and overview lead with (nil: the one closest to a limit).
    @Published var focusedProfileId: String?
    @Published var reports: [String: UsageReport] = [:]
    @Published var reportDays = 14
    @Published var scanning = false
    @Published var recentFolders: [RecentWorkspaces.Entry] = []
    @Published var editorStatus: [Editor: InstallStatus] = [:]
    @Published var launcherInstalled = false
    @Published var shellConnected = false
    @Published var statuslineOn: [String: Bool] = [:]
    @Published var health: [HealthCheck] = []
    @Published var checkingHealth = false
    @Published var launches: [String] = []
    @Published var banner: Banner?
    @Published var now = Date()
    @Published var selectedSection: MainSection? = .overview
    @Published var sessions: [SessionAssessment] = []
    @Published var autoPolicy = AutoPolicy()
    /// What each installed editor's Claude extension supports (checked after updates too).
    @Published var contracts: [Editor: ExtensionContract] = [:]
    /// Chats being moved to another account, by conversation id.
    @Published var moves: [String: ChatMove] = [:]

    /// Accounts whose limits are being fetched right now.
    @Published var checkingLimits: Set<String> = []
    private var limitsCheckedAt: Date?

    private var timer: Timer?
    private var ticks = 0

    init(env: SBEnvironment = .live()) {
        var env = env
        // Demo homes live in a temporary folder; their made-up chats are chats, not helpers.
        if DemoSessions.isActive(env) { env.temporaryFolders = [] }
        self.env = env
        self.service = AppService(env: env)
        Fmt.home = env.home.path
        Self.shared = self
        refreshInstalledHelpersIfOutdated()
        refreshLocal()
        refreshAuth()
        refreshSessions()
        scanLocalUsage()
        refreshLimits()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.now = Date()
                self.refreshUsageSnapshots()
                self.refreshSessions()
                self.ticks += 1
                // Token totals come from walking session logs: every ten minutes is plenty.
                if self.ticks % 20 == 0 && !self.scanning { self.scanLocalUsage() }
                if self.ticks % 10 == 0 { self.refreshLimits() }
            }
        }
    }

    // MARK: Derived

    var isFirstRun: Bool {
        profiles.count <= 1 && routes.isEmpty && !launcherInstalled
    }

    var vscodeConnected: Bool { editorStatus[.code] == .installed }

    func profile(id: String) -> Profile? { profiles.first { $0.id == id } }

    /// What the user calls their normal login (the built-in Default account, renamable).
    var defaultName: String { profiles.first(where: \.isDefault)?.displayName ?? "Default" }

    func folders(for profile: Profile) -> [Route] { routes.filter { $0.profileId == profile.id } }

    /// Effective profile for any folder (including inherited from a parent route).
    func resolution(for folder: String) -> Resolution { service.resolve(folder: folder) }

    func assignedProfile(for folder: String) -> Profile? {
        if case .routed(let p, _) = resolution(for: folder) { return p }
        return nil
    }

    /// The route set exactly on this folder (not inherited).
    func exactRoute(for folder: String) -> Route? {
        let key = PathNormalizer.normalize(folder, caseInsensitive: env.caseInsensitivePaths)?.key
        return routes.first {
            PathNormalizer.normalize($0.folder, caseInsensitive: env.caseInsensitivePaths)?.key == key
        }
    }

    /// The account to lead with: the one picked by the user, else the one closest to a limit.
    var focusProfile: Profile? {
        if let id = focusedProfileId, let p = profile(id: id) { return p }
        let ranked = HeadroomAdvisor.rank(profiles: profiles, snapshots: snapshots, now: now)
        if let fullest = ranked.last(where: { $0.peakPercentage != nil }) { return fullest.profile }
        return profiles.first { !$0.isDefault } ?? profiles.first
    }

    func window(_ kind: UsageWindow.Kind, for profile: Profile) -> UsageWindow? {
        snapshots[profile.id]?.window(kind)
    }

    func forecast(_ kind: UsageWindow.Kind, for profile: Profile) -> PaceForecast? {
        window(kind, for: profile).flatMap { PaceForecast.forecast($0, now: now) }
    }

    /// The most pressing thing in the data right now, as one sentence (nil when all is calm).
    /// The most urgent finding across accounts: a limit used up, or one heading there early.
    /// `key` identifies it until that window resets, so a dismissal holds only for this finding.
    var finding: (profile: Profile, text: String, tone: Tone, key: String)? {
        var best: (Profile, PaceForecast, Double)?
        for p in profiles {
            if let (f, urgency) = urgentForecast(for: p), urgency > (best?.2 ?? 0) { best = (p, f, urgency) }
        }
        guard let (p, f, _) = best else { return nil }
        let (text, tone) = Outlook.sentence(f, now: now)
        return (
            p, "\(p.displayName): " + text.prefix(1).lowercased() + text.dropFirst(), tone,
            "\(p.id)|\(f.kind.rawValue)|\(Int(f.resetsAt.timeIntervalSince1970))"
        )
    }

    /// An account's most urgent window, if any limit is used up or heading there before it resets.
    func urgentForecast(for p: Profile) -> (PaceForecast, Double)? {
        var best: (PaceForecast, Double)?
        for kind in [UsageWindow.Kind.fiveHour, .sevenDay] {
            guard let f = forecast(kind, for: p) else { continue }
            let urgency: Double
            switch f.outlook {
            case .full: urgency = 3
            case .runsOut(_, let early): urgency = 2 + min(early, 86400 * 7) / (86400 * 7)
            default: continue
            }
            if urgency > (best?.1 ?? 0) { best = (f, urgency) }
        }
        return best
    }

    /// The account's finding in two or three words, for its card.
    func outlookTag(for p: Profile) -> (text: String, tone: Tone)? {
        urgentForecast(for: p).flatMap { Outlook.tag($0.0, now: now) }
    }

    /// The Overview warning the user closed (until that limit resets or another one appears).
    @Published var dismissedFinding: String? = UserDefaults.standard.string(forKey: "dismissedFinding") {
        didSet { UserDefaults.standard.set(dismissedFinding, forKey: "dismissedFinding") }
    }

    /// When the freshest limit reading was taken.
    var lastCapture: Date? { snapshots.values.map(\.capturedAt).max() }

    var bestHeadroom: HeadroomAdvisor.Ranked? {
        HeadroomAdvisor.rank(profiles: profiles, snapshots: snapshots, now: now)
            .first { $0.peakPercentage != nil }
    }

    // MARK: Refresh

    /// Files only: profiles, routes, setup state, usage snapshots, launch log.
    func refreshLocal() {
        do {
            profiles = try service.allProfiles()
            Identity.order = profiles.filter { !$0.isDefault }.map(\.id)
        } catch {
            profiles = [Profile.builtInDefault()]
            show(.error, error.localizedDescription)
        }
        do {
            routes = try service.routes.routes()
            routesProblem = nil
        } catch {
            routes = []
            routesProblem = error.localizedDescription
        }
        let installer = VSCodeInstaller(env: env)
        var editors: [Editor: InstallStatus] = [:]
        for e in Editor.allCases { editors[e] = installer.status(of: e) }
        editorStatus = editors
        let shim = ShellShim(env: env)
        launcherInstalled = shim.isLauncherInstalled
        shellConnected = shim.defaultRCFiles().contains(where: RCFile.hasBlock(at:))
        let statusline = StatuslineInstaller(env: env)
        statuslineOn = Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, statusline.isInstalled(for: $0)) })
        autoPolicy = AutoPolicyStore(env: env).current()
        refreshUsageSnapshots()
        launches = LaunchLog(env: env).tail(50).reversed()
        recentFolders = RecentWorkspaces(env: env).folders(limit: 30)
        refreshContracts()
    }

    /// Re-read the extensions' contract (cheap after the first read of each version).
    func refreshContracts() {
        let env = self.env
        let editors = Editor.allCases.filter { editorStatus[$0] != .editorNotFound }
        Task.detached(priority: .utility) {
            var out: [Editor: ExtensionContract] = [:]
            for e in editors { out[e] = ExtensionContract.check(editor: e, env: env) }
            let found = out
            await MainActor.run { self.contracts = found }
        }
    }

    func refreshUsageSnapshots() {
        snapshots = service.usageSnapshots()
        history = service.usageHistory()
        if UserDefaults.standard.object(forKey: "notifyNearLimit") as? Bool ?? true {
            LimitNotifier.check(snapshots: snapshots, profiles: profiles, policy: autoPolicy, now: now)
        }
    }

    /// Fullest limit across all accounts (for the optional menu bar readout).
    var peakUsage: Double? {
        snapshots.values.map { $0.peakPercentage(at: now) }.max()
    }

    /// Running Claude sessions and whether each still matches its folder's assignment.
    func refreshSessions() {
        let env = self.env
        Task.detached(priority: .utility) {
            let scanner = SessionScanner(env: env)
            let assessed = scanner.assess(DemoSessions.load(env) ?? scanner.scan())
            await MainActor.run {
                self.sessions = assessed
                if !DemoSessions.isActive(env) { self.autoMoveChatsIfNeeded() }
            }
        }
    }

    func runningCount(for profile: Profile) -> Int {
        sessions.filter { $0.actualProfileId == profile.id }.count
    }

    var staleSessions: [SessionAssessment] {
        sessions.filter { if case .stale = $0.state { return true } else { return false } }
    }

    /// Ask the Claude CLI about each profile's login (runs processes, so in the background).
    func refreshAuth() {
        let env = self.env
        for p in profiles {
            statuses[p.id] = .checking
            Task.detached(priority: .utility) {
                let result = ClaudeCLI(env: env).authStatus(for: p)
                let status: ProfileStatus
                switch result {
                case .success(let s): status = s.loggedIn ? .loggedIn(s) : .loggedOut
                case .failure(let e): status = .error(e.localizedDescription)
                }
                await MainActor.run {
                    self.statuses[p.id] = status
                    self.syncAutoAvailability()
                }
            }
        }
    }

    func refreshAll() {
        refreshLocal()
        refreshAuth()
        refreshSessions()
        refreshLimits()
    }

    /// Fetches every account's limits the way /usage does, one account at a time, in the
    /// background. No message is sent and no login data passes through Spillover.
    func refreshLimits() {
        guard checkingLimits.isEmpty, !DemoSessions.isActive(env) else { return }
        let targets = profiles.filter { if case .loggedOut = statuses[$0.id] { return false } else { return true } }
        guard !targets.isEmpty else { return }
        limitsCheckedAt = Date()
        checkingLimits = Set(targets.map(\.id))
        let env = self.env
        Task.detached(priority: .utility) {
            for p in targets {
                AccountUsageFetcher(env: env).refresh(p)
                await MainActor.run {
                    self.checkingLimits.remove(p.id)
                    self.refreshUsageSnapshots()
                }
            }
        }
    }

    /// For views that show limits: refresh when the last check is more than a minute old.
    func refreshLimitsIfStale() {
        if let at = limitsCheckedAt, Date().timeIntervalSince(at) < 60 { return }
        refreshLimits()
    }

    /// Why an account shows no limits yet.
    func limitsHint(for profile: Profile) -> String {
        if case .loggedOut = statuses[profile.id] { return "not logged in" }
        if checkingLimits.contains(profile.id) || statuses[profile.id] == nil { return "checking…" }
        return "no reading"
    }

    func runHealthChecks() {
        checkingHealth = true
        let env = self.env
        Task.detached(priority: .utility) {
            let checks = Doctor(env: env).run()
            await MainActor.run {
                self.health = checks
                self.checkingHealth = false
            }
        }
    }

    func scanLocalUsage() {
        scanning = true
        let env = self.env
        let profiles = self.profiles
        let since = Date().addingTimeInterval(-Double(reportDays) * 86400)
        Task.detached(priority: .utility) {
            let prices = PriceTable.load(env: env)
            var out: [String: UsageReport] = [:]
            for p in profiles {
                out[p.id] = LocalUsageScanner(env: env).scan(profile: p, since: since, prices: prices)
            }
            let finished = out
            await MainActor.run {
                self.reports = finished
                self.scanning = false
            }
        }
    }

    // MARK: Profiles

    func createProfile(named name: String, shareFromDefault items: [String], thenLogIn: Bool) {
        do {
            let p = try service.profiles.create(displayName: name)
            let sharing = ProfileSharing(env: env)
            var skipped: [String] = []
            for item in items {
                do { try sharing.share(item, from: .builtInDefault(), to: p) } catch { skipped.append(item) }
            }
            // Tracking already chosen for the other accounts carries over to the new one.
            if statuslineOn.values.contains(true) { _ = Setup(env: env).connectStatusline(for: p) }
            refreshLocal()
            statuses[p.id] = .loggedOut
            show(.success, "Created “\(p.displayName)”." + (skipped.isEmpty ? "" : " Not shared (missing in \(defaultName)): \(skipped.joined(separator: ", "))."))
            if thenLogIn { logIn(p) }
        } catch {
            show(.error, error.localizedDescription)
        }
    }

    func adoptProfile(named name: String, directory: String) {
        do {
            let p = try service.profiles.adopt(displayName: name, directory: directory)
            refreshAll()
            show(.success, "Added “\(p.displayName)” using its existing login.")
        } catch {
            show(.error, error.localizedDescription)
        }
    }

    func rename(_ profile: Profile, to name: String) {
        do {
            try service.profiles.rename(id: profile.id, to: name)
            refreshLocal()
        } catch {
            show(.error, error.localizedDescription)
        }
    }

    func remove(_ profile: Profile, deleteDirectory: Bool) {
        do {
            try service.removeProfile(id: profile.id, unassign: true, deleteDirectory: deleteDirectory)
            statuses[profile.id] = nil
            refreshLocal()
            show(.info, "Removed “\(profile.displayName)”. Its folders now use \(defaultName).")
        } catch {
            show(.error, error.localizedDescription)
        }
    }

    /// Opens Terminal running the official `claude auth login` inside the profile.
    func logIn(_ profile: Profile) {
        do {
            try service.openLoginTerminal(for: profile)
            show(.info, "Terminal opened. Log in with the account for “\(profile.displayName)”. This updates by itself when you are done.")
            watchForLogin(profile)
        } catch {
            show(.error, error.localizedDescription)
        }
    }

    /// Poll the login state for a few minutes after opening the login Terminal.
    private func watchForLogin(_ profile: Profile) {
        let env = self.env
        Task.detached(priority: .utility) {
            for _ in 0..<36 {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                if case .success(let s) = ClaudeCLI(env: env).authStatus(for: profile), s.loggedIn {
                    await MainActor.run {
                        self.statuses[profile.id] = .loggedIn(s)
                        self.show(.success, "“\(profile.displayName)” is logged in as \(s.email.map(Redaction.email) ?? "your account").")
                    }
                    return
                }
            }
        }
    }

    /// Logs the profile out with the official CLI (removes its saved login).
    func logOut(_ profile: Profile) {
        let env = self.env
        statuses[profile.id] = .checking
        Task.detached(priority: .userInitiated) {
            let cli = ClaudeCLI(env: env)
            var message: String?
            if let claude = cli.claudePath() {
                let result = SystemCommandRunner().run(
                    claude, ["auth", "logout"], env: ProfileEnvironment.apply(profile, to: env.processEnv),
                    timeout: 30)
                if !result.succeeded { message = Redaction.scrub(result.stderr) }
            } else {
                message = ClaudeCLIError.claudeNotFound.localizedDescription
            }
            let failure = message
            await MainActor.run {
                if let failure { self.show(.error, "Log out failed: \(failure)") }
                self.refreshAuth()
            }
        }
    }

    func openShell(_ profile: Profile, in folder: String) {
        do {
            try TerminalLauncher(env: env).openShell(profile: profile, folder: folder)
        } catch {
            show(.error, error.localizedDescription)
        }
    }

    func share(_ item: String, into profile: Profile, enabled: Bool) {
        let sharing = ProfileSharing(env: env)
        do {
            if enabled {
                try sharing.share(item, from: .builtInDefault(), to: profile, replace: true)
            } else {
                try sharing.unshare(item, in: profile)
            }
            objectWillChange.send()
        } catch {
            show(.error, error.localizedDescription)
        }
    }

    // MARK: Folders

    func assign(folder: String, to profileId: String) {
        do {
            let route = try service.assign(folder: folder, to: profileId)
            refreshLocal()
            let name = profileId == Profile.autoID ? "Auto" : (profile(id: profileId)?.displayName ?? profileId)
            show(.success, "\((route.folder as NSString).lastPathComponent) → \(name). New Claude chats there use it.")
        } catch {
            show(.error, error.localizedDescription)
        }
    }

    func unassign(folder: String) {
        do {
            try service.unassign(folder: folder)
            refreshLocal()
        } catch {
            show(.error, error.localizedDescription)
        }
    }

    func chooseFolder() -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose a project folder. Everything inside it will use the account you pick."
        NSApp.activate(ignoringOtherApps: true)
        return panel.runModal() == .OK ? panel.url?.path : nil
    }

    func openInVSCode(_ folder: String) {
        do { try service.open(folder: folder, in: .code) } catch { show(.error, error.localizedDescription) }
    }

    func revealInFinder(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    // MARK: Setup

    /// Where the `spillover` and `spillover-launch` helpers are: `Contents/Helpers` inside the
    /// app bundle, or next to the app binary in a development build.
    private var executablesDir: URL? {
        let helpers = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers", isDirectory: true)
        if FileManager.default.fileExists(atPath: helpers.appendingPathComponent("spillover-launch").path) {
            return helpers
        }
        return Bundle.main.executableURL?.resolvingSymlinksInPath().deletingLastPathComponent()
    }

    /// After an app update, the copies in ~/.spillover/bin must match the bundled helpers.
    /// Only refreshes helpers that were already installed; never installs on its own.
    func refreshInstalledHelpersIfOutdated() {
        guard let dir = executablesDir, ShellShim(env: env).isLauncherInstalled else { return }
        let bundled = dir.appendingPathComponent("spillover-launch")
        guard let new = try? Data(contentsOf: bundled), let old = try? Data(contentsOf: env.paths.launcher),
            new != old
        else { return }
        _ = Setup(env: env).installBinaries(from: dir)
    }

    func installBinariesIfNeeded() -> Bool {
        guard let dir = executablesDir else {
            show(.error, "Cannot locate Spillover's helper programs.")
            return false
        }
        let steps = Setup(env: env).installBinaries(from: dir)
        if let failed = steps.first(where: { !$0.ok }) {
            show(.error, "Could not install helpers: \(failed.detail)")
            return false
        }
        return true
    }

    func connect(editor: Editor, force: Bool = false) {
        guard installBinariesIfNeeded() else { return }
        let step = Setup(env: env).connectEditor(editor, force: force)
        refreshLocal()
        show(step.ok ? .success : .error, step.ok ? "\(editor.displayName) connected. Reload its windows (or start new Claude chats) to apply." : step.detail)
    }

    func disconnect(editor: Editor) {
        let step = Setup(env: env).disconnectEditor(editor)
        refreshLocal()
        show(step.ok ? .info : .error, step.ok ? "\(editor.displayName) disconnected and restored." : step.detail)
    }

    func setShell(connected: Bool) {
        if connected {
            guard installBinariesIfNeeded() else { return }
            let steps = Setup(env: env).connectShell()
            refreshLocal()
            if let bad = steps.first(where: { !$0.ok }) { show(.error, bad.detail) } else {
                show(.success, "Terminals connected. Open a new terminal window to apply.")
            }
        } else {
            let steps = Setup(env: env).disconnectShell()
            refreshLocal()
            if let bad = steps.first(where: { !$0.ok }) { show(.error, bad.detail) }
        }
    }

    func setStatusline(_ profile: Profile, on: Bool) {
        if on { guard installBinariesIfNeeded() else { return } }
        let setup = Setup(env: env)
        let step = on ? setup.connectStatusline(for: profile) : setup.disconnectStatusline(for: profile)
        refreshLocal()
        if !step.ok { show(.error, step.detail) }
    }

    func uninstallEverything() {
        let steps = Setup(env: env).uninstallAll()
        refreshLocal()
        let failures = steps.filter { !$0.ok }
        show(failures.isEmpty ? .info : .error,
             failures.isEmpty ? "Everything Spillover changed has been undone. Accounts and folders are kept." : failures.map(\.detail).joined(separator: "\n"))
    }

    func importLegacy() {
        do {
            let summary = try LegacyImport(env: env).run()
            refreshAll()
            show(.success, "Imported \(summary.adoptedProfiles.count) account(s) and \(summary.routes.count) folder(s).")
        } catch {
            show(.error, "Nothing to import: \(error.localizedDescription)")
        }
    }

    var legacySetupExists: Bool {
        FileManager.default.fileExists(atPath: LegacyImport(env: env).defaultRoutesFile.path)
    }

    // MARK: Banner

    func show(_ kind: Banner.Kind, _ text: String) {
        banner = Banner(kind: kind, text: text)
        let id = banner?.id
        DispatchQueue.main.asyncAfter(deadline: .now() + (kind == .error ? 10 : 6)) { [weak self] in
            if self?.banner?.id == id { self?.banner = nil }
        }
    }
}
