import SwiftUI
import SpilloverCore

/// Usage analytics for one account at a time: tokens per day, the limit history, and where the
/// tokens went (models and folders).
struct UsageView: View {
    @EnvironmentObject var model: AppModel
    @State private var profileId: String?
    @State private var historyKind: UsageWindow.Kind = .sevenDay

    var body: some View {
        let profile = selectedProfile
        Page(
            title: "Usage",
            subtitle: "Token totals from this Mac's session logs, and the limits Claude reported, for one account at a time."
        ) {
            Button(model.scanning ? "Scanning…" : "Rescan logs") { model.scanLocalUsage() }
                .buttonStyle(QuietButtonStyle())
                .disabled(model.scanning)
        } content: {
            controls(profile)
            if let profile {
                let report = model.reports[profile.id]
                totals(report)
                HStack(alignment: .top, spacing: 16) {
                    Panel(padding: 20) {
                        SectionHeader(title: "Tokens per day", font: TypeScale.section) {
                            Text("today in teal").font(TypeScale.meta).foregroundStyle(Ink.faint)
                        }
                        if let report, report.total.messages > 0 {
                            DailyTokensChart(report: report, days: model.reportDays, height: 268, now: model.now)
                        } else {
                            empty(report == nil ? "Reading session logs…" : "No Claude replies in this account in the last \(model.reportDays) days.")
                        }
                    }
                    .frame(maxWidth: .infinity)
                    VStack(spacing: 16) {
                        Panel(padding: 20) {
                            SectionHeader(title: "By model", font: TypeScale.section)
                            let models = (report?.byModel ?? [:]).sorted { $0.value.total > $1.value.total }.prefix(4)
                            if models.isEmpty { empty("No models yet.") }
                            BarList(rows: models.map { .init(id: $0.key, label: $0.key, detail: nil, value: $0.value.total) })
                        }
                        Panel(padding: 20) {
                            SectionHeader(title: "Top folders", font: TypeScale.section)
                            let projects = (report?.byProject ?? [:]).sorted { $0.value.total > $1.value.total }.prefix(4)
                            if projects.isEmpty { empty("No folders yet.") }
                            BarList(rows: projects.map {
                                .init(id: $0.key, label: Fmt.folderName($0.key), detail: Fmt.parentFolder($0.key), value: $0.value.total)
                            })
                        }
                    }
                    .frame(width: 300)
                }
                Panel(padding: 20) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Limit over the last 7 days").font(TypeScale.section).foregroundStyle(Ink.text)
                        Spacer()
                        Segmented(options: [(.sevenDay, "Weekly"), (.fiveHour, "Session")], selection: $historyKind)
                    }
                    LimitHistoryChart(points: model.history[profile.id] ?? [], kind: historyKind, now: model.now, height: 170)
                    Text("Drops to zero are resets. The dashed line marks 80%, where Spillover warns you.")
                        .font(TypeScale.meta)
                        .foregroundStyle(Ink.faint)
                }
                Text("Limits come from Claude Code's statusline, which reports them with every reply, so a quiet account's reading can be old. Message content is never read; costs appear only if you add prices in ~/.spillover/prices.json.")
                    .font(TypeScale.meta)
                    .foregroundStyle(Ink.faint)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onChange(of: model.reportDays) { _, _ in model.scanLocalUsage() }
    }

    private var selectedProfile: Profile? {
        if let profileId, let p = model.profile(id: profileId) { return p }
        return model.focusProfile
    }

    private func controls(_ profile: Profile?) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 4) {
                ForEach(model.profiles) { p in
                    Button {
                        profileId = p.id
                    } label: {
                        HStack(spacing: 6) {
                            Monogram(profile: p, size: 16)
                            Text(p.displayName).font(TypeScale.body.weight(p.id == profile?.id ? .semibold : .regular))
                                .fixedSize()
                        }
                        .foregroundStyle(p.id == profile?.id ? Ink.text : Ink.muted)
                        .padding(.horizontal, 10)
                        .frame(height: 28)
                        .background(p.id == profile?.id ? Ink.active : .clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack(spacing: 16) {
            Segmented(options: [(7, "7 days"), (14, "14 days"), (30, "30 days")], selection: $model.reportDays)
            Spacer()
            if let profile {
                Toggle("Live limits in Terminal chats", isOn: Binding(
                    get: { model.statuslineOn[profile.id] ?? false },
                    set: { model.setStatusline(profile, on: $0) }))
                .toggleStyle(.switch)
                .controlSize(.small)
                .font(TypeScale.body)
                .help("Limits are checked every few minutes anyway. This also records them after every reply in Terminal chats, through Claude's statusline; your own statusline keeps working.")
            }
            }
        }
    }

    private func totals(_ report: UsageReport?) -> some View {
        HStack(spacing: 0) {
            kpi("Tokens", report.map { Fmt.tokens($0.total.total) }, lead: true)
            Rectangle().fill(Ink.border).frame(width: 1)
            kpi("Replies", report.map { "\($0.total.messages)" })
            Rectangle().fill(Ink.border).frame(width: 1)
            kpi("Output", report.map { Fmt.tokens($0.total.output) })
            Rectangle().fill(Ink.border).frame(width: 1)
            kpi("Cache read", report.map { Fmt.tokens($0.total.cacheRead) })
            Rectangle().fill(Ink.border).frame(width: 1)
            kpi("Est. cost", report.flatMap { r in
                r.pricedCostUSD > 0 ? String(format: "$%.2f", r.pricedCostUSD) + (r.unpricedModels.isEmpty ? "" : "+") : nil
            }, hint: "Add prices in ~/.spillover/prices.json to see an estimate")
        }
        .frame(height: 76)
        .background(Ink.sheet, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Ink.border))
    }

    private func kpi(_ label: String, _ value: String?, lead: Bool = false, hint: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(TypeScale.meta).foregroundStyle(Ink.muted)
            Text(value ?? "–")
                .font(TypeScale.figure(lead ? 26 : 20, lead ? .semibold : .regular))
                .foregroundStyle(value == nil ? Ink.faint : Ink.text)
        }
        .help(value == nil ? (hint ?? "") : "")
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 18)
    }

    private func empty(_ text: String) -> some View {
        Text(text)
            .font(TypeScale.body)
            .foregroundStyle(Ink.muted)
            .frame(maxWidth: .infinity, minHeight: 120, alignment: .center)
    }
}
