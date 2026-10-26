import SwiftUI
import SwitchboardCore

/// The menu bar popover: accounts with live limits, recent folders with one-click assignment.
struct MenuPopover: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let banner = model.banner {
                        BannerView(banner: banner) { model.banner = nil }
                    }
                    if !model.vscodeConnected {
                        setupHint
                    }
                    if !model.staleSessions.isEmpty {
                        staleHint
                    }
                    accounts
                    folders
                }
                .padding(12)
            }
            .frame(maxHeight: 600)
            Divider()
            footer
        }
        .frame(width: 360)
    }

    private var header: some View {
        HStack {
            Image(systemName: "switch.2")
                .foregroundStyle(.tint)
            Text("Switchboard").font(.headline)
            Spacer()
            Button {
                model.refreshAll()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Refresh logins and usage")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var setupHint: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "bolt.horizontal.circle.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 6) {
                Text("VS Code is not connected yet").font(.callout.weight(.medium))
                Text("Until it is, every VS Code window uses your normal account.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Set up…") { open(.setup) }
                    .controlSize(.small)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }

    private var staleHint: some View {
        Button {
            open(.sessions)
        } label: {
            Label(
                "\(model.staleSessions.count) running session\(model.staleSessions.count == 1 ? "" : "s") on an old account — start a new chat to switch",
                systemImage: "arrow.triangle.2.circlepath"
            )
            .font(.caption)
            .foregroundStyle(.orange)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
    }

    private var accounts: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Accounts", action: ("Add", { open(.accounts) }))
            ForEach(model.profiles) { p in
                AccountRow(profile: p)
            }
            if let best = model.bestHeadroom, model.profiles.count > 2 {
                Label("Most headroom: \(best.profile.displayName)", systemImage: "gauge.with.dots.needle.33percent")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var folders: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                SectionHeader(title: "Folders")
                AssignFolderMenu(label: "Assign…")
                    .font(.caption)
            }
            let rows = folderRows
            if rows.isEmpty {
                Text("Open a project in VS Code, or choose “Assign…” to give a folder its own account.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(rows, id: \.self) { folder in
                HStack(spacing: 8) {
                    Image(systemName: "folder").foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 0) {
                        Text((folder as NSString).lastPathComponent).lineLimit(1)
                        Text(Theme.shortFolder((folder as NSString).deletingLastPathComponent))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 8)
                    AccountMenu(folder: folder)
                }
                .contextMenu {
                    Button("Open in VS Code") { model.openInVSCode(folder) }
                    Button("Show in Finder") { model.revealInFinder(folder) }
                }
            }
        }
    }

    /// Assigned folders first, then recent VS Code folders that are not assigned.
    private var folderRows: [String] {
        let assigned = model.routes.map(\.folder)
        let recent = model.recentFolders.map(\.path).filter { p in !assigned.contains(p) }
        return Array((assigned + recent).prefix(12))
    }

    private var footer: some View {
        HStack {
            Button("Open Switchboard") { open(.accounts) }
            Spacer()
            Button("Quit") { NSApp.terminate(nil) }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func open(_ section: MainSection) {
        model.selectedSection = section
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct SectionHeader: View {
    let title: String
    var action: (String, () -> Void)?

    var body: some View {
        HStack {
            Text(title.uppercased())
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
            if let action {
                Button(action.0, action: action.1)
                    .buttonStyle(.borderless)
                    .font(.caption)
            }
        }
    }
}

private struct AccountRow: View {
    @EnvironmentObject var model: AppModel
    let profile: Profile

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            AccountAvatar(profile: profile, size: 24)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(profile.displayName).font(.callout.weight(.medium)).lineLimit(1)
                    if let plan = model.statuses[profile.id]?.auth?.planLabel { PlanBadge(text: plan) }
                    loginIndicator
                    Spacer()
                    let running = model.runningCount(for: profile)
                    if running > 0 {
                        Text("\(running) running")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .help("\(running) Claude session\(running == 1 ? "" : "s") running on this account")
                    }
                    let n = model.folders(for: profile).count
                    if n > 0 {
                        Text("\(n) folder\(n == 1 ? "" : "s")").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                if case .loggedOut = model.statuses[profile.id] {
                    Button("Log in…") { model.logIn(profile) }.controlSize(.small)
                } else if let windows = model.snapshots[profile.id]?.windows.filter({ $0.kind != .spendLimit }),
                    !windows.isEmpty
                {
                    HStack(spacing: 12) {
                        ForEach(windows, id: \.kind) { w in
                            UsageBar(window: w, now: model.now, compact: true)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
        .help(helpText)
    }

    @ViewBuilder
    private var loginIndicator: some View {
        switch model.statuses[profile.id] ?? .unknown {
        case .loggedIn:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.caption)
        case .loggedOut:
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange).font(.caption)
        case .error:
            Image(systemName: "xmark.octagon.fill").foregroundStyle(.red).font(.caption)
        case .unknown, .checking:
            ProgressView().controlSize(.mini)
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
}
