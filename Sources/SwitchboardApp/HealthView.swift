import SwiftUI
import SwitchboardCore

struct HealthView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Page(title: "Health", subtitle: "Read-only checks of files, permissions, logins, editors and terminals.") {
            HStack {
                Button(model.checkingHealth ? "Checking…" : "Run checks") { model.runHealthChecks() }
                    .disabled(model.checkingHealth)
                Spacer()
            }
            Card {
                if model.health.isEmpty {
                    Text(model.checkingHealth ? "Checking…" : "No results yet.").foregroundStyle(.secondary)
                }
                ForEach(model.health) { check in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: icon(check.status)).foregroundStyle(color(check.status))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(check.title).font(.callout.weight(.medium))
                            Text(check.detail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    }
                }
            }
            Card {
                Text("Recent launches").font(.headline)
                Text("Every time Claude starts through Switchboard: which account it got, or why it was refused. Arguments and prompts are never recorded.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if model.launches.isEmpty {
                    Text("None yet.").foregroundStyle(.secondary)
                }
                ForEach(Array(model.launches.prefix(30).enumerated()), id: \.offset) { _, line in
                    Text(line).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                }
            }
        }
        .onAppear { if model.health.isEmpty { model.runHealthChecks() } }
    }

    private func icon(_ s: HealthCheck.Status) -> String {
        switch s {
        case .ok: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .failure: return "xmark.octagon.fill"
        case .info: return "info.circle"
        }
    }

    private func color(_ s: HealthCheck.Status) -> Color {
        switch s {
        case .ok: return .green
        case .warning: return .orange
        case .failure: return .red
        case .info: return .secondary
        }
    }
}
