import SwiftUI
import SwitchboardCore

struct UsageView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Page(
            title: "Usage",
            subtitle: "Session and weekly limits per account, plus token totals from the session logs on this Mac."
        ) {
            if let best = model.bestHeadroom {
                Card {
                    HStack(spacing: 10) {
                        AccountAvatar(profile: best.profile, size: 28)
                        VStack(alignment: .leading) {
                            Text("Most headroom: \(best.profile.displayName)").font(.headline)
                            Text("Its fullest limit is at \(Int((best.peakPercentage ?? 0).rounded()))%. Assign new work there if you are close to a limit elsewhere.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            ForEach(model.profiles) { p in
                Card {
                    HStack {
                        AccountAvatar(profile: p, size: 24)
                        Text(p.displayName).font(.headline)
                        if let plan = model.statuses[p.id]?.auth?.planLabel { PlanBadge(text: plan) }
                        Spacer()
                        Toggle(
                            "Track limits",
                            isOn: Binding(
                                get: { model.statuslineOn[p.id] ?? false },
                                set: { model.setStatusline(p, on: $0) })
                        )
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .help("Adds Switchboard to this account's Claude statusline to record its limits. Your own statusline keeps working.")
                    }
                    UsageSummary(profile: p)
                    if let report = model.reports[p.id] {
                        Divider()
                        LocalReportView(report: report, days: model.reportDays)
                    }
                }
            }

            Card {
                HStack {
                    Text("Token totals").font(.headline)
                    Spacer()
                    Picker("Period", selection: $model.reportDays) {
                        Text("Today").tag(1)
                        Text("7 days").tag(7)
                        Text("30 days").tag(30)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 220)
                    .labelsHidden()
                    Button(model.scanning ? "Scanning…" : "Scan") { model.scanLocalUsage() }
                        .disabled(model.scanning)
                }
                Text("Read from each account's local session logs. Message content is never read into Switchboard's results. Costs appear only if you add prices in ~/.switchboard/prices.json.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text("How limits are captured: Claude Code passes its current rate limits to the statusline command. Switchboard records them per account, so limits refresh whenever you use that account.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .onAppear { if model.reports.isEmpty && !model.scanning { model.scanLocalUsage() } }
        .onChange(of: model.reportDays) { _, _ in model.scanLocalUsage() }
    }
}

private struct LocalReportView: View {
    let report: UsageReport
    let days: Int

    var body: some View {
        if report.total.messages == 0 {
            Text(days == 1 ? "No Claude replies today in this account." : "No Claude replies in the last \(days) days in this account.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            details
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 18) {
                stat("Tokens", Theme.tokens(report.total.total))
                stat("Replies", "\(report.total.messages)")
                stat("Output", Theme.tokens(report.total.output))
                stat("Cache read", Theme.tokens(report.total.cacheRead))
                if report.pricedCostUSD > 0 {
                    stat("Est. cost", String(format: "$%.2f", report.pricedCostUSD) + (report.unpricedModels.isEmpty ? "" : "+"))
                }
            }
            let projects = report.byProject.sorted { $0.value.total > $1.value.total }.prefix(4)
            if !projects.isEmpty {
                Text("Top folders").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(Array(projects), id: \.key) { project, totals in
                    HStack {
                        Text(Theme.shortFolder(project)).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Text(Theme.tokens(totals.total)).monospacedDigit().foregroundStyle(.secondary)
                    }
                    .font(.caption)
                }
            }
            let models = report.byModel.sorted { $0.value.total > $1.value.total }.prefix(3)
            if !models.isEmpty {
                Text("Models: " + models.map { "\($0.key) \(Theme.tokens($0.value.total))" }.joined(separator: " · "))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value).font(.title3.weight(.semibold)).monospacedDigit()
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }
}
