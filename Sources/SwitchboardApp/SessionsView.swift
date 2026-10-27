import SwiftUI
import SwitchboardCore

struct SessionsView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Page(
            title: "Sessions",
            subtitle: "\(Fmt.plural(model.sessions.count, "Claude session")) running on this Mac, and the account each one is using."
        ) {
            Button("Refresh") { model.refreshSessions() }.buttonStyle(QuietButtonStyle())
        } content: {
            let stale = model.staleSessions.count
            if stale > 0 {
                Notice(icon: "arrow.triangle.2.circlepath", tone: .warning,
                       text: "\(Fmt.plural(stale, "session")) \(stale == 1 ? "is" : "are") still on an old account. Their folder was assigned to another account after they started. Start a new chat (or reload the window) to switch.")
            }

            byAccount

            VStack(spacing: 0) {
                HStack {
                    Text("Folder").frame(maxWidth: .infinity, alignment: .leading)
                    Text("Account").frame(width: 150, alignment: .leading)
                    Text("Started").frame(width: 90, alignment: .trailing)
                    Text("State").frame(width: 170, alignment: .trailing)
                }
                .font(TypeScale.meta)
                .foregroundStyle(Ink.muted)
                .padding(.bottom, 8)
                Rule()
                if model.sessions.isEmpty {
                    Text("No Claude sessions running.")
                        .font(TypeScale.body)
                        .foregroundStyle(Ink.muted)
                        .frame(maxWidth: .infinity, minHeight: 60)
                }
                ForEach(model.sessions) { a in
                    SessionRow(assessment: a)
                    Rule()
                }
            }

            Text("Switchboard reads only each Claude process's folder and its CLAUDE_CONFIG_DIR / SWITCHBOARD_PROFILE variables. Nothing else from the process is read or stored.")
                .font(TypeScale.meta)
                .foregroundStyle(Ink.faint)
        }
        .onAppear { model.refreshSessions() }
    }

    /// How many sessions each account carries right now.
    private var byAccount: some View {
        HStack(spacing: 0) {
            ForEach(Array(model.profiles.enumerated()), id: \.element.id) { i, p in
                if i > 0 { Rectangle().fill(Ink.border).frame(width: 1) }
                HStack(spacing: 10) {
                    Monogram(profile: p, size: 22)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(p.displayName).font(TypeScale.meta).foregroundStyle(Ink.muted).lineLimit(1)
                        Text("\(model.runningCount(for: p))").font(TypeScale.figure(22, .medium)).foregroundStyle(Ink.text)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
            }
        }
        .frame(height: 64)
        .background(Ink.sheet, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Ink.border))
    }
}

private struct SessionRow: View {
    @EnvironmentObject var model: AppModel
    let assessment: SessionAssessment

    var body: some View {
        let profile = assessment.actualProfileId.flatMap(model.profile(id:))
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(assessment.session.cwd.map(Fmt.folderName) ?? "Unknown folder").font(TypeScale.body).foregroundStyle(Ink.text).lineLimit(1)
                Text(verbatim: "pid \(assessment.session.pid)").font(.system(size: 11, design: .monospaced)).foregroundStyle(Ink.faint)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 6) {
                if let profile { Monogram(profile: profile, size: 18) }
                Text(profile?.displayName ?? "Unknown account").font(TypeScale.body).foregroundStyle(profile == nil ? Ink.muted : Ink.text)
                    .lineLimit(1)
            }
            .frame(width: 150, alignment: .leading)
            Text(assessment.session.startedAt.map { Fmt.relative($0, now: model.now) } ?? "–")
                .font(TypeScale.meta.monospacedDigit())
                .foregroundStyle(Ink.muted)
                .frame(width: 90, alignment: .trailing)
            stateLabel.frame(width: 170, alignment: .trailing)
        }
        .padding(.vertical, 10)
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
            Pill(text: "As assigned", tone: .positive)
        case .stale(let expected):
            Pill(text: "Restart for \(model.profile(id: expected)?.displayName ?? expected)", tone: .warning)
        case .refusedNow:
            Pill(text: "Folder now refused", tone: .negative)
        case .unknownAccount:
            Pill(text: "Not a Switchboard account")
                .help("Started with a CLAUDE_CONFIG_DIR that is not one of your accounts. Add it under Accounts → Existing config folder.")
        }
    }
}
