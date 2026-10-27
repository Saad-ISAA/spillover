import SwiftUI
import SwitchboardCore

/// The menu bar popover. Reading order answers the glance question first: how loaded is the
/// account that matters, when does it recover, and where is it heading; then every account;
/// then which folder uses which account.
struct MenuPopover: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @State private var chartKind: UsageWindow.Kind = .sevenDay
    @State private var contentHeight: CGFloat = 420

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    notices
                    if let p = model.focusProfile {
                        FocusFace(profile: p, chartKind: $chartKind)
                    }
                    accounts
                    folders
                }
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .padding(.bottom, 16)
                .background(GeometryReader { g in Color.clear.preference(key: ContentHeight.self, value: g.size.height) })
            }
            .frame(height: min(contentHeight, 640))
            .onPreferenceChange(ContentHeight.self) { contentHeight = $0 }
            Rule()
            footer
        }
        .frame(width: 380)
        .background(Ink.sheet)
    }

    // MARK: Header and footer

    private var header: some View {
        HStack(spacing: 8) {
            BrandMark(size: 18)
            Text("Switchboard").font(TypeScale.bodyStrong).foregroundStyle(Ink.text)
            Spacer()
            if let last = model.lastCapture {
                Text("Limits \(Fmt.relative(last, now: model.now))")
                    .font(TypeScale.meta)
                    .foregroundStyle(Ink.faint)
                    .help("When Claude last reported limits for any account")
            }
            IconButton(systemName: "arrow.clockwise", help: "Refresh logins, limits and sessions") { model.refreshAll() }
            IconButton(systemName: "macwindow", help: "Open Switchboard") { open(.overview) }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var footer: some View {
        HStack {
            Button("Open Switchboard") { open(.overview) }
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
                           text: "\(Fmt.plural(stale, "session")) still on the old account. Start a new chat to switch.") {
                        Button("View") { open(.sessions) }.buttonStyle(LinkButtonStyle())
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
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader(title: "Accounts") {
                Button("Add…") { open(.accounts) }.buttonStyle(LinkButtonStyle())
            }
            VStack(spacing: 2) {
                ForEach(model.profiles) { p in
                    AccountRow(profile: p, selected: p.id == model.focusProfile?.id) {
                        withAnimation(.easeOut(duration: 0.2)) { model.focusedProfileId = p.id }
                    }
                }
            }
            if let best = model.bestHeadroom, model.profiles.count > 1, let peak = best.peakPercentage {
                Text("Most room now: \(best.profile.displayName), fullest limit at \(Fmt.percent(peak)).")
                    .font(TypeScale.meta)
                    .foregroundStyle(Ink.muted)
                    .padding(.leading, 2)
            }
        }
    }

    // MARK: Folders

    private var folders: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader(title: "Folders") {
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
        let assigned = model.routes.map(\.folder)
        let recent = model.recentFolders.map(\.path).filter { p in !assigned.contains(p) }
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

/// The focused account read like a watch face: the session gauge, when it recovers, the week,
/// and the pace chart for the chosen window.
private struct FocusFace: View {
    @EnvironmentObject var model: AppModel
    let profile: Profile
    @Binding var chartKind: UsageWindow.Kind

    var body: some View {
        let five = model.window(.fiveHour, for: profile)
        let seven = model.window(.sevenDay, for: profile)
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Monogram(profile: profile, size: 18)
                Text(profile.displayName).font(TypeScale.bodyStrong).foregroundStyle(Ink.text)
                if let plan = model.statuses[profile.id]?.auth?.planLabel { Pill(text: plan) }
                Spacer()
                LoginState(status: model.statuses[profile.id], showsEmail: false)
            }

            if five == nil && seven == nil {
                emptyState
            } else {
                HStack(alignment: .center, spacing: 16) {
                    LoadArc(
                        percent: five.map { $0.effectivePercentage(at: model.now) },
                        paceFraction: model.forecast(.fiveHour, for: profile)?.elapsedFraction,
                        size: 84, lineWidth: 9, caption: "session")
                    VStack(alignment: .leading, spacing: 8) {
                        let reset = Fmt.reset(five, now: model.now)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(reset.value)
                                .font(TypeScale.figure(30))
                                .foregroundStyle(reset.value == "–" ? Ink.faint : Ink.text)
                            Text(reset.value == "–" ? "no session in progress" : "until the session resets")
                                .font(TypeScale.meta)
                                .foregroundStyle(Ink.muted)
                        }
                        weekLine(seven)
                    }
                }
                outlook
                chartSwitcher
                if let w = chartKind == .fiveHour ? five : seven {
                    PaceChart(window: w, points: model.history[profile.id] ?? [], now: model.now, height: 108, compact: true)
                }
            }
        }
        .padding(14)
        .background(Ink.raised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func weekLine(_ seven: UsageWindow?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("Week").font(TypeScale.meta).foregroundStyle(Ink.muted)
                Text(seven.map { Fmt.percent($0.effectivePercentage(at: model.now)) } ?? "–")
                    .font(TypeScale.figure(13))
                    .foregroundStyle(Ink.text)
                Spacer(minLength: 4)
                if let seven {
                    Text("resets \(Fmt.moment(seven.resetsAt, now: model.now))")
                        .font(TypeScale.meta.monospacedDigit())
                        .foregroundStyle(Ink.faint)
                }
            }
            MeterBar(
                percent: seven.map { $0.effectivePercentage(at: model.now) },
                paceFraction: model.forecast(.sevenDay, for: profile)?.elapsedFraction, height: 4)
        }
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

    private var chartSwitcher: some View {
        HStack(spacing: 14) {
            ForEach([UsageWindow.Kind.sevenDay, .fiveHour], id: \.self) { kind in
                Button {
                    withAnimation(.easeOut(duration: 0.2)) { chartKind = kind }
                } label: {
                    VStack(spacing: 3) {
                        Text(kind == .fiveHour ? "Session" : "Week")
                            .font(TypeScale.meta.weight(chartKind == kind ? .semibold : .regular))
                            .foregroundStyle(chartKind == kind ? Ink.text : Ink.muted)
                        Rectangle().fill(chartKind == kind ? Ink.data : .clear).frame(height: 2)
                    }
                    .fixedSize()
                }
                .buttonStyle(.plain)
            }
            Spacer()
            HStack(spacing: 10) {
                legend(dash: nil, "used", color: chartColor)
                legend(dash: [2, 3], "even", color: Ink.faint)
                legend(dash: [4, 3], "forecast", color: chartColor)
            }
        }
    }

    /// The colour the pace chart draws in (the window's load, or amber when heading over).
    private var chartColor: Color {
        guard let f = model.forecast(chartKind, for: profile) else { return Ink.data }
        if case .runsOut = f.outlook { return Ink.load(max(f.used, 85)) }
        return Ink.load(f.used)
    }

    private func legend(dash: [CGFloat]?, _ label: String, color: Color) -> some View {
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

    @ViewBuilder
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 14) {
                LoadArc(percent: nil, size: 64, lineWidth: 7, caption: "session")
                VStack(alignment: .leading, spacing: 4) {
                    if case .loggedOut = model.statuses[profile.id] {
                        Text("Log in to start using this account.").font(TypeScale.body).foregroundStyle(Ink.text)
                        Button("Log in…") { model.logIn(profile) }.buttonStyle(PrimaryButtonStyle())
                    } else if model.statuslineOn[profile.id] == true {
                        Text("Limits appear after the next Claude reply in this account.")
                            .font(TypeScale.body).foregroundStyle(Ink.text)
                    } else {
                        Text("Limit tracking is off for this account.").font(TypeScale.body).foregroundStyle(Ink.text)
                        Button("Track limits") { model.setStatusline(profile, on: true) }.buttonStyle(QuietButtonStyle())
                    }
                }
            }
        }
    }
}

/// One account in the popover list. Tapping makes it the focused face.
private struct AccountRow: View {
    @EnvironmentObject var model: AppModel
    let profile: Profile
    let selected: Bool
    let select: () -> Void
    @State private var hovering = false

    var body: some View {
        let five = model.window(.fiveHour, for: profile)
        let seven = model.window(.sevenDay, for: profile)
        Button(action: select) {
            HStack(spacing: 10) {
                Monogram(profile: profile, size: 24)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        Text(profile.displayName).font(TypeScale.bodyStrong).foregroundStyle(Ink.text).lineLimit(1)
                        if model.runningCount(for: profile) > 0 {
                            Text("\(model.runningCount(for: profile)) live")
                                .font(TypeScale.meta)
                                .foregroundStyle(Ink.data)
                                .help("Claude sessions running on this account now")
                        }
                    }
                    subtitle(five: five)
                }
                Spacer(minLength: 6)
                if seven != nil || five != nil {
                    VStack(alignment: .trailing, spacing: 3) {
                        Text("wk \(seven.map { Fmt.percent($0.effectivePercentage(at: model.now)) } ?? "–")")
                            .font(TypeScale.meta.monospacedDigit())
                            .foregroundStyle(Ink.muted)
                        MeterBar(percent: seven.map { $0.effectivePercentage(at: model.now) }, height: 3)
                            .frame(width: 54)
                    }
                    LoadArc(percent: five.map { $0.effectivePercentage(at: model.now) }, size: 32, lineWidth: 4)
                } else if case .loggedOut = model.statuses[profile.id] {
                    Button("Log in…") { model.logIn(profile) }.buttonStyle(QuietButtonStyle())
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(selected ? Ink.active : (hovering ? Ink.raised : .clear), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(helpText)
        .accessibilityLabel(accessibility(five: five, seven: seven))
    }

    @ViewBuilder
    private func subtitle(five: UsageWindow?) -> some View {
        switch model.statuses[profile.id] ?? .unknown {
        case .loggedOut:
            Text("Not logged in").font(TypeScale.meta).foregroundStyle(Ink.warning)
        case .error:
            Text("Login check failed").font(TypeScale.meta).foregroundStyle(Ink.negative)
        default:
            if let five, five.resetsAt > model.now, five.usedPercentage > 0 {
                Text("session frees in \(Fmt.countdown(to: five.resetsAt, now: model.now))")
                    .font(TypeScale.meta.monospacedDigit()).foregroundStyle(Ink.muted)
            } else if let plan = model.statuses[profile.id]?.auth?.planLabel {
                Text(profile.isDefault ? "\(plan) · your normal login" : plan).font(TypeScale.meta).foregroundStyle(Ink.muted)
            } else {
                Text(profile.isDefault ? "Your normal login" : "No limits yet").font(TypeScale.meta).foregroundStyle(Ink.muted)
            }
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

    private func accessibility(five: UsageWindow?, seven: UsageWindow?) -> String {
        var parts = [profile.displayName]
        if let five { parts.append("session \(Fmt.percent(five.effectivePercentage(at: model.now))) used") }
        if let seven { parts.append("week \(Fmt.percent(seven.effectivePercentage(at: model.now))) used") }
        return parts.joined(separator: ", ")
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

/// The product mark: an open gauge with a routing node at its centre.
struct BrandMark: View {
    var size: CGFloat = 18

    var body: some View {
        ZStack {
            LoadArc(percent: 62, size: size, lineWidth: max(2, size * 0.14), showsValue: false)
            Circle().fill(Ink.text).frame(width: size * 0.2, height: size * 0.2)
        }
        .accessibilityHidden(true)
    }
}
