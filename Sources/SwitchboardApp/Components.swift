import SwiftUI
import SwitchboardCore

/// Coloured initial used wherever an account is shown.
struct AccountAvatar: View {
    let profile: Profile
    var size: CGFloat = 22

    var body: some View {
        let initial = profile.isDefault ? "D" : String(profile.displayName.prefix(1)).uppercased()
        Circle()
            .fill(Theme.color(for: profile).gradient)
            .frame(width: size, height: size)
            .overlay(
                Text(initial)
                    .font(.system(size: size * 0.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
            )
            .accessibilityHidden(true)
    }
}

struct PlanBadge: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.quaternary, in: Capsule())
            .foregroundStyle(.secondary)
    }
}

/// One usage window: label, bar, percentage and reset countdown.
struct UsageBar: View {
    let window: UsageWindow
    let now: Date
    var compact = false

    var body: some View {
        let pct = window.effectivePercentage(at: now)
        VStack(alignment: .leading, spacing: compact ? 2 : 4) {
            HStack(spacing: 4) {
                Text(compact ? window.kind.shortLabel : window.kind.label)
                    .font(compact ? .caption2 : .caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Text("\(Int(pct.rounded()))%")
                    .font((compact ? Font.caption2 : Font.caption).monospacedDigit().weight(.medium))
                if !compact || pct > 0 {
                    Text("· \(Theme.countdown(to: window.resetsAt, now: now))")
                        .font((compact ? Font.caption2 : Font.caption).monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule()
                        .fill(Theme.usageColor(pct).gradient)
                        .frame(width: max(3, geo.size.width * min(pct, 100) / 100))
                }
            }
            .frame(height: compact ? 4 : 6)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(window.kind.label) \(Int(pct.rounded())) percent used, resets in \(Theme.countdown(to: window.resetsAt, now: now))")
    }
}

/// Usage windows for a profile, or a hint when nothing has been captured yet.
struct UsageSummary: View {
    @EnvironmentObject var model: AppModel
    let profile: Profile
    var compact = false

    var body: some View {
        if let snapshot = model.snapshots[profile.id], !snapshot.windows.isEmpty {
            VStack(alignment: .leading, spacing: compact ? 4 : 8) {
                ForEach(snapshot.windows.filter { $0.kind != .spendLimit }, id: \.kind) { w in
                    UsageBar(window: w, now: model.now, compact: compact)
                }
                if !compact {
                    Text("Updated \(Theme.relative(snapshot.capturedAt, now: model.now))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        } else if model.statuslineOn[profile.id] == true {
            Text("Usage appears after the next Claude reply in this account.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        } else {
            Text("Usage tracking off")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }
}

struct LoginStatusLabel: View {
    let status: ProfileStatus?

    var body: some View {
        switch status ?? .unknown {
        case .unknown, .checking:
            Label("Checking…", systemImage: "ellipsis.circle").foregroundStyle(.secondary)
        case .loggedIn(let s):
            Label(s.email.map(Redaction.email) ?? "Logged in", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .loggedOut:
            Label("Not logged in", systemImage: "exclamationmark.circle.fill").foregroundStyle(.orange)
        case .error(let e):
            Label(e, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
        }
    }
}

struct BannerView: View {
    let banner: Banner
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon).foregroundStyle(tint)
            Text(banner.text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Spacer(minLength: 0)
            Button(action: dismiss) { Image(systemName: "xmark") }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Dismiss")
        }
        .padding(10)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(tint.opacity(0.3)))
    }

    private var icon: String {
        switch banner.kind {
        case .info: return "info.circle.fill"
        case .success: return "checkmark.circle.fill"
        case .error: return "exclamationmark.triangle.fill"
        }
    }

    private var tint: Color {
        switch banner.kind {
        case .info: return .blue
        case .success: return .green
        case .error: return .red
        }
    }
}

/// "Assign a folder to…": pick the account first, then the folder.
struct AssignFolderMenu: View {
    @EnvironmentObject var model: AppModel
    var label = "Assign a folder…"

    var body: some View {
        Menu(label) {
            let accounts = model.profiles.filter { !$0.isDefault }
            if accounts.isEmpty {
                Text("Add an account first")
            }
            ForEach(accounts) { p in
                Button("\(p.displayName)…") {
                    if let folder = model.chooseFolder() { model.assign(folder: folder, to: p.id) }
                }
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
}

/// Picker of accounts for a folder, with "Default" meaning "no route".
struct AccountMenu: View {
    @EnvironmentObject var model: AppModel
    let folder: String

    var body: some View {
        let exact = model.exactRoute(for: folder)
        let effective = model.assignedProfile(for: folder)
        Menu {
            ForEach(model.profiles.filter { !$0.isDefault }) { p in
                Button {
                    model.assign(folder: folder, to: p.id)
                } label: {
                    if exact?.profileId == p.id { Label(p.displayName, systemImage: "checkmark") } else { Text(p.displayName) }
                }
            }
            Divider()
            Button("Default account (your normal login)") {
                model.assign(folder: folder, to: Profile.defaultID)
            }
            if exact != nil {
                Button("Remove assignment", role: .destructive) { model.unassign(folder: folder) }
            }
        } label: {
            // Plain text: menu labels drop composite content (avatars) on macOS.
            if let effective {
                Text(exact == nil ? "\(effective.displayName) (inherited)" : effective.displayName)
            } else {
                Text("Default")
            }
        }
        .menuStyle(.button)
        .buttonStyle(.bordered)
        .controlSize(.small)
        .tint(effective.map(Theme.color(for:)))
        .fixedSize()
        .help("Which account Claude uses in this folder")
    }
}
