import SwiftUI
import SpilloverCore

/// The menu bar popover. Reading order answers the glance question first: every account's room
/// at once, then where the chosen one is heading; then which folder uses which account.
struct MenuPopover: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @State private var chartKind: UsageWindow.Kind = .sevenDay
    @State private var contentHeight: CGFloat = 420
    /// Documentation renders only: lay the content out without a scroll view.
    var rendersStatically = false

    private var content: some View {
        VStack(alignment: .leading, spacing: 18) {
            notices
            accounts
            if let p = model.focusProfile {
                PacePanel(profile: p, chartKind: $chartKind)
            }
            openNow
            folders
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .padding(.bottom, 16)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if rendersStatically {
                content
            } else {
                ScrollView {
                    content
                        .background(GeometryReader { g in Color.clear.preference(key: ContentHeight.self, value: g.size.height) })
                }
                .frame(height: min(contentHeight, 640))
                .onPreferenceChange(ContentHeight.self) { contentHeight = $0 }
            }
            Rule()
            footer
        }
        .onAppear { if !rendersStatically { model.refreshLimitsIfStale() } }
        .frame(width: 392)
        .background(Ink.sheet)
    }

    // MARK: Header and footer

    private var header: some View {
        HStack(spacing: 8) {
            BrandMark(size: 18)
            Text("Spillover").font(TypeScale.bodyStrong).foregroundStyle(Ink.text)
            Spacer()
            if let last = model.lastCapture {
                Text("Limits \(Fmt.relative(last, now: model.now))")
                    .font(TypeScale.meta)
                    .foregroundStyle(Ink.faint)
                    .help("When Claude last reported limits for any account")
            }
            IconButton(systemName: "arrow.clockwise", help: "Refresh logins, limits and sessions") { model.refreshAll() }
            IconButton(systemName: "macwindow", help: "Open Spillover") { open(.overview) }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var footer: some View {
        HStack {
            Button("Open Spillover") { open(.overview) }
                .buttonStyle(LinkButtonStyle())
            Spacer()
            Button("Quit") { NSApp.terminate(nil) }
                .buttonStyle(.plain)
                .font(TypeScale.meta)
                .foregroundStyle(Ink.muted)
                .keyboardShortcut("q")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: Notices

    @ViewBuilder
    private var notices: some View {
        let stale = model.staleSessions.count
        if model.banner != nil || !model.vscodeConnected || stale > 0 {
            VStack(spacing: 6) {
                if let banner = model.banner {
                    BannerView(banner: banner) { model.banner = nil }
                }
                if stale > 0 {
                    // Held until the sessions restart: a changed assignment is not live in them yet.
                    Notice(icon: "arrow.triangle.2.circlepath", tone: .warning,
                           text: "\(Fmt.plural(stale, "chat")) still on its old account. Move it, and it reopens on the new one with its history.") {
                        Button("Move") { open(.sessions) }.buttonStyle(LinkButtonStyle())
                    }
                }
                if !model.vscodeConnected {
                    Notice(icon: "bolt.horizontal.circle.fill", tone: .warning,
                           text: "VS Code is not connected, so its Claude panel uses your normal account.") {
                        Button("Set up") { open(.setup) }.buttonStyle(LinkButtonStyle())
                    }
                }
            }
        }
    }

    // MARK: Accounts

    private var accounts: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Accounts") {
                Button("Add…") { open(.accounts) }.buttonStyle(LinkButtonStyle())
            }
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: model.profiles.count > 1 ? 2 : 1),
                spacing: 8
            ) {
                ForEach(model.profiles) { p in
                    AccountTile(profile: p, selected: p.id == model.focusProfile?.id) {
                        withAnimation(.snappy(duration: 0.25)) { model.focusedProfileId = p.id }
                    }
                }
            }
        }
    }

    // MARK: Open now

    @ViewBuilder
    private var openNow: some View {
        let windows = model.openWindows
        if !windows.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                SectionHeader(title: "Open now") {
                    Text(Fmt.plural(windows.reduce(0) { $0 + $1.sessions.count }, "chat")).font(TypeScale.meta).foregroundStyle(Ink.faint)
                }
                VStack(spacing: 0) {
                    ForEach(Array(windows.prefix(4).enumerated()), id: \.element.id) { i, w in
                        if i > 0 { Rule() }
                        OpenWindowLine(window: w)
                    }
                }
                if windows.count > 4 {
                    Button("All \(windows.count) open folders") { open(.sessions) }.buttonStyle(LinkButtonStyle())
                }
            }
        }
    }

    // MARK: Folders

    private var folders: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader(title: model.openWindows.isEmpty ? "Folders" : "Other folders") {
                AssignFolderMenu(label: "Assign…").font(TypeScale.meta.weight(.medium))
            }
            let rows = folderRows
            if rows.isEmpty {
                Text("Open a project in VS Code, or choose Assign to give a folder its own account.")
                    .font(TypeScale.meta)
                    .foregroundStyle(Ink.muted)
            }
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element) { i, folder in
                    if i > 0 { Rule() }
                    FolderLine(folder: folder)
                }
            }
            if model.routes.count + model.recentFolders.count > rows.count {
                Button("All folders") { open(.folders) }.buttonStyle(LinkButtonStyle())
            }
        }
    }

    /// Assigned folders first, then recent VS Code folders that are not assigned.
    private var folderRows: [String] {
        let open = Set(model.openWindows.map(\.folder))
        let assigned = model.routes.map(\.folder).filter { !open.contains($0) }
        let recent = model.recentFolders.map(\.path).filter { p in !assigned.contains(p) && !open.contains(p) }
        return Array((assigned + recent).prefix(6))
    }

    private func open(_ section: MainSection) {
        model.selectedSection = section
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }
}

private struct ContentHeight: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// Where the chosen account is heading: the outlook sentence and the pace chart.
private struct PacePanel: View {
    @EnvironmentObject var model: AppModel
    let profile: Profile
    @Binding var chartKind: UsageWindow.Kind

    var body: some View {
        let window = model.window(chartKind, for: profile)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Monogram(profile: profile, size: 18)
                Text("Pace · \(profile.displayName)").font(TypeScale.bodyStrong).foregroundStyle(Ink.text).lineLimit(1)
                Spacer(minLength: 6)
                Segmented(options: [(.sevenDay, "Week"), (.fiveHour, "Session")], selection: $chartKind)
            }
            if let window {
                outlook
                PaceChart(window: window, points: model.history[profile.id] ?? [], now: model.now, height: 116, compact: true)
                legend
            } else {
                Text(emptyText)
                    .font(TypeScale.meta)
                    .foregroundStyle(Ink.muted)
                    .frame(maxWidth: .infinity, minHeight: 60, alignment: .center)
            }
        }
        .padding(14)
        .background(Ink.raised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var emptyText: String {
        if case .loggedOut = model.statuses[profile.id] { return "Log in to \(profile.displayName) to see its limits." }
        return model.checkingLimits.contains(profile.id) ? "Checking this account's limits…" : "No limits reported for this account yet."
    }

    @ViewBuilder
    private var outlook: some View {
        if let f = model.forecast(chartKind, for: profile) {
            let (text, tone) = Outlook.sentence(f, now: model.now)
            Text(text)
                .font(TypeScale.body)
                .foregroundStyle(tone == .neutral ? Ink.muted : Ink.tone(tone))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var legend: some View {
        HStack(spacing: 12) {
            legendItem(dash: nil, "used", color: chartColor)
            legendItem(dash: [2, 3], "even pace", color: Ink.faint)
            legendItem(dash: [4, 3], "forecast", color: chartColor)
            Spacer()
        }
    }

    /// The colour the pace chart draws in (the window's load, or amber when heading over).
    private var chartColor: Color {
        guard let f = model.forecast(chartKind, for: profile) else { return Ink.data }
        if case .runsOut = f.outlook { return Ink.load(max(f.used, 85)) }
        return Ink.load(f.used)
    }

    private func legendItem(dash: [CGFloat]?, _ label: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Path { p in
                p.move(to: CGPoint(x: 0, y: 4))
                p.addLine(to: CGPoint(x: 12, y: 4))
            }
            .stroke(color, style: StrokeStyle(lineWidth: dash == nil ? 2 : 1.5, dash: dash ?? []))
            .frame(width: 12, height: 8)
            Text(label).font(.system(size: 10)).foregroundStyle(Ink.faint)
        }
    }
}

/// One account as a tile in its own colour: the session (outer ring) and week (inner ring), when
/// the session frees up, and how many chats run on it. Tapping picks it for the pace chart.
private struct AccountTile: View {
    @EnvironmentObject var model: AppModel
    let profile: Profile
    let selected: Bool
    let select: () -> Void
    @State private var hovering = false

    var body: some View {
        let five = model.window(.fiveHour, for: profile)?.effectivePercentage(at: model.now)
        let seven = model.window(.sevenDay, for: profile)?.effectivePercentage(at: model.now)
        let live = model.runningCount(for: profile)
        Button(action: select) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Monogram(profile: profile, size: 18)
                    Text(profile.displayName).font(TypeScale.bodyStrong).foregroundStyle(Ink.text).lineLimit(1)
                    Spacer(minLength: 2)
                    if live > 0 {
                        HStack(spacing: 3) {
                            Circle().fill(Ink.positive).frame(width: 6, height: 6)
                            Text("\(live)").font(TypeScale.meta.monospacedDigit()).foregroundStyle(Ink.muted)
                        }
                        .help("\(Fmt.plural(live, "chat")) running on this account")
                    }
                }
                HStack(spacing: 10) {
                    DualRing(session: five, week: seven, size: 54)
                    VStack(alignment: .leading, spacing: 2) {
                        figure("Session", five)
                        figure("Week", seven)
                        if let tag = model.outlookTag(for: profile) {
                            Text(tag.text).font(.system(size: 10, weight: .semibold)).foregroundStyle(Ink.tone(tag.tone)).lineLimit(1)
                        } else {
                            Text(footnote).font(.system(size: 10)).foregroundStyle(Ink.faint).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(Identity.tint(for: profile).opacity(hovering || selected ? 0.75 : 0.5)))
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(selected ? Identity.ink(for: profile).opacity(0.7) : Ink.border.opacity(0.6), lineWidth: selected ? 1.5 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(helpText)
        .accessibilityLabel(accessibility(five: five, seven: seven))
    }

    private func figure(_ label: String, _ value: Double?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(label).font(.system(size: 10, weight: .medium)).foregroundStyle(Ink.muted)
            Text(value.map(Fmt.percent) ?? "–")
                .font(TypeScale.figure(13))
                .foregroundStyle(value.map { $0 >= HeadroomAdvisor.warningThreshold ? Ink.load($0) : Ink.text } ?? Ink.faint)
        }
    }

    private var footnote: String {
        switch model.statuses[profile.id] ?? .unknown {
        case .loggedOut: return "Not logged in"
        case .error: return "Login check failed"
        default:
            if let five = model.window(.fiveHour, for: profile), five.resetsAt > model.now,
                five.effectivePercentage(at: model.now) > 0
            {
                return "frees in \(Fmt.countdown(to: five.resetsAt, now: model.now))"
            }
            if model.checkingLimits.contains(profile.id) { return "checking…" }
            return model.statuses[profile.id]?.auth?.planLabel ?? (profile.isDefault ? "Your normal login" : "")
        }
    }

    private var helpText: String {
        switch model.statuses[profile.id] ?? .unknown {
        case .loggedIn(let s): return s.email.map(Redaction.email) ?? "Logged in"
        case .loggedOut: return "Not logged in"
        case .error(let e): return e
        case .unknown, .checking: return "Checking login…"
        }
    }

    private func accessibility(five: Double?, seven: Double?) -> String {
        var parts = [profile.displayName]
        if let five { parts.append("session \(Fmt.percent(five)) used") }
        if let seven { parts.append("week \(Fmt.percent(seven)) used") }
        return parts.joined(separator: ", ")
    }
}

/// A folder with live chats: which account they are on, and the switch.
private struct OpenWindowLine: View {
    @EnvironmentObject var model: AppModel
    let window: OpenWindow

    var body: some View {
        HStack(spacing: 8) {
            accountMarks
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    AppIconView(editor: window.sessions.first?.session.editor, size: 14)
                    Text(Fmt.folderName(window.folder)).font(TypeScale.body).foregroundStyle(Ink.text).lineLimit(1)
                }
                status
            }
            Spacer(minLength: 8)
            AccountMenu(folder: window.folder)
        }
        .padding(.vertical, 6)
        .contextMenu {
            Button("Open in VS Code") { model.openInVSCode(window.folder) }
            Button("Show in Finder") { model.revealInFinder(window.folder) }
        }
    }

    /// The accounts the chats actually run on (two marks when they differ).
    private var accountMarks: some View {
        let ids = Array(Set(window.sessions.compactMap(\.actualProfileId))).sorted()
        return HStack(spacing: -6) {
            ForEach(ids.prefix(2), id: \.self) { id in
                if let p = model.profile(id: id) { Monogram(profile: p, size: 20) }
            }
            if ids.isEmpty { Image(systemName: "questionmark.circle").foregroundStyle(Ink.faint).frame(width: 20) }
        }
        .frame(width: 26, alignment: .leading)
    }

    @ViewBuilder
    private var status: some View {
        let moves = window.sessions.compactMap { model.move(for: $0) }
        let stale = window.sessions.filter { if case .stale = $0.state { return true } else { return false } }
        if let m = moves.first(where: { $0.inProgress }) {
            let name = model.profile(id: m.toProfileId)?.displayName ?? m.toProfileId
            Text(m.phase == .waiting ? "Moving to \(name) after the current reply…" : "Switching to \(name)…")
                .font(TypeScale.meta).foregroundStyle(Ink.data)
        } else if let failed = moves.first(where: { if case .failed = $0.phase { return true } else { return false } }),
            case .failed(let why) = failed.phase
        {
            Text(why).font(TypeScale.meta).foregroundStyle(Ink.negative).lineLimit(1).help(why)
        } else if let first = stale.first {
            HStack(spacing: 6) {
                Text("\(Fmt.plural(stale.count, "chat")) on the old account").font(TypeScale.meta).foregroundStyle(Ink.warning)
                Button("Move now") { model.restartOnAssignedAccount(first); stale.dropFirst().forEach(model.restartOnAssignedAccount) }
                    .buttonStyle(LinkButtonStyle())
            }
        } else {
            Text("\(Fmt.plural(window.sessions.count, "chat")) · \(accountNames)").font(TypeScale.meta).foregroundStyle(Ink.muted)
        }
    }

    private var accountNames: String {
        let names = Set(window.sessions.compactMap { $0.actualProfileId.flatMap(model.profile(id:))?.displayName })
        return names.isEmpty ? "unknown account" : names.sorted().joined(separator: ", ")
    }
}

/// One folder and the account it uses.
private struct FolderLine: View {
    @EnvironmentObject var model: AppModel
    let folder: String

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(Fmt.folderName(folder)).font(TypeScale.body).foregroundStyle(Ink.text).lineLimit(1)
                Text(Fmt.parentFolder(folder))
                    .font(TypeScale.meta)
                    .foregroundStyle(Ink.faint)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            AccountMenu(folder: folder)
        }
        .padding(.vertical, 6)
        .contextMenu {
            Button("Open in VS Code") { model.openInVSCode(folder) }
            Button("Show in Finder") { model.revealInFinder(folder) }
        }
    }
}

