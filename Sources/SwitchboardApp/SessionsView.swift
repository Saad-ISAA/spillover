import SwiftUI
import SwitchboardCore

struct SessionsView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Page(
            title: "Sessions",
            subtitle: "Claude sessions running on this Mac right now, and the account each one is using."
        ) {
            if !model.staleSessions.isEmpty {
                Card {
                    Label(
                        "\(model.staleSessions.count) session\(model.staleSessions.count == 1 ? " is" : "s are") still on an old account",
                        systemImage: "arrow.triangle.2.circlepath"
                    )
                    .font(.headline)
                    .foregroundStyle(.orange)
                    Text("Their folder was assigned to a different account after they started. Start a new chat (or reload the window) to switch.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            Card {
                HStack {
                    Text("Running").font(.headline)
                    Spacer()
                    Button("Refresh") { model.refreshSessions() }
                }
                if model.sessions.isEmpty {
                    Text("No Claude sessions running.").foregroundStyle(.secondary)
                }
                ForEach(model.sessions) { a in
                    SessionRow(assessment: a)
                    if a.id != model.sessions.last?.id { Divider() }
                }
            }

            Text("Switchboard reads only each Claude process's folder and its CLAUDE_CONFIG_DIR / SWITCHBOARD_PROFILE variables. Nothing else from the process is read or stored.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .onAppear { model.refreshSessions() }
    }
}

private struct SessionRow: View {
    @EnvironmentObject var model: AppModel
    let assessment: SessionAssessment

    var body: some View {
        let profile = assessment.actualProfileId.flatMap(model.profile(id:))
        HStack(spacing: 10) {
            if let profile {
                AccountAvatar(profile: profile, size: 22)
            } else {
                Image(systemName: "questionmark.circle").font(.title3).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(assessment.session.cwd.map { ($0 as NSString).lastPathComponent } ?? "Unknown folder")
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(profile?.displayName ?? "Unknown account")
                    if let started = assessment.session.startedAt {
                        Text("· started \(Theme.relative(started, now: model.now))")
                    }
                    Text(verbatim: "· pid \(assessment.session.pid)")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            stateLabel
        }
        .contextMenu {
            if let cwd = assessment.session.cwd {
                Button("Show folder in Finder") { model.revealInFinder(cwd) }
                Button("Open in VS Code") { model.openInVSCode(cwd) }
            }
        }
    }

    @ViewBuilder
    private var stateLabel: some View {
        switch assessment.state {
        case .matches:
            Label("As assigned", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.caption)
        case .stale(let expected):
            Label("Restart for \(model.profile(id: expected)?.displayName ?? expected)", systemImage: "arrow.triangle.2.circlepath")
                .foregroundStyle(.orange)
                .font(.caption)
        case .refusedNow:
            Label("Folder now refused", systemImage: "xmark.octagon.fill").foregroundStyle(.red).font(.caption)
        case .unknownAccount:
            Label("Not a Switchboard account", systemImage: "questionmark.circle").foregroundStyle(.secondary).font(.caption)
                .help("Started with a CLAUDE_CONFIG_DIR that is not one of your accounts. Add it under Accounts → Existing config folder.")
        }
    }
}
