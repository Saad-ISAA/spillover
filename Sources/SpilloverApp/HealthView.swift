import SwiftUI
import SpilloverCore

struct HealthView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let failures = model.health.filter { $0.status == .failure }.count
        let warnings = model.health.filter { $0.status == .warning }.count
        Page(
            title: "Health",
            subtitle: model.health.isEmpty
                ? "Read-only checks of files, permissions, logins, editors and terminals."
                : (failures + warnings == 0 ? "All \(model.health.count) checks pass." : "\(Fmt.plural(failures, "problem")) and \(Fmt.plural(warnings, "warning")) in \(model.health.count) checks."),
            subtitleTone: failures > 0 ? .negative : (warnings > 0 ? .warning : .neutral)
        ) {
            Button(model.checkingHealth ? "Checking…" : "Run checks") { model.runHealthChecks() }
                .buttonStyle(QuietButtonStyle())
                .disabled(model.checkingHealth)
        } content: {
            VStack(spacing: 0) {
                if model.health.isEmpty {
                    Text(model.checkingHealth ? "Checking…" : "No results yet.")
                        .font(TypeScale.body).foregroundStyle(Ink.muted)
                        .frame(maxWidth: .infinity, minHeight: 60)
                }
                ForEach(Array(model.health.enumerated()), id: \.element.id) { i, check in
                    if i > 0 { Rule() }
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Image(systemName: icon(check.status))
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Ink.tone(tone(check.status)))
                            .frame(width: 16)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(check.title).font(TypeScale.bodyStrong).foregroundStyle(Ink.text)
                            Text(check.detail).font(TypeScale.meta).foregroundStyle(Ink.muted).textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 10)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                SectionHeader(title: "Recent launches", font: TypeScale.section)
                Text("Every time Claude starts through Spillover: which account it got, or why it was refused. Arguments and prompts are never recorded.")
                    .font(TypeScale.meta)
                    .foregroundStyle(Ink.muted)
                VStack(alignment: .leading, spacing: 4) {
                    if model.launches.isEmpty {
                        Text("None yet.").font(TypeScale.body).foregroundStyle(Ink.muted)
                    }
                    ForEach(Array(model.launches.prefix(30).enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Ink.text)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Ink.raised, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
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

    private func tone(_ s: HealthCheck.Status) -> Tone {
        switch s {
        case .ok: return .positive
        case .warning: return .warning
        case .failure: return .negative
        case .info: return .neutral
        }
    }
}
