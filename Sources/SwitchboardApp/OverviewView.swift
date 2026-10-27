import SwiftUI
import SwitchboardCore

/// The screen's question: which account has room, and is any of them about to run out?
struct OverviewView: View {
    @EnvironmentObject var model: AppModel
    @State private var chartKind: UsageWindow.Kind = .sevenDay

    var body: some View {
        let finding = model.finding
        Page(title: "Overview", subtitle: subtitle(finding), subtitleTone: finding?.tone ?? .neutral) {
            AssignFolderMenu(bordered: true)
        } content: {
            // Column count follows the number of accounts: all in one row when they fit, else
            // two per row, so no face is left alone in a row of empty cells.
            ViewThatFits(in: .horizontal) {
                faces(columns: min(max(model.profiles.count, 1), 4))
                faces(columns: min(max(model.profiles.count, 1), 2))
            }

            HStack(alignment: .top, spacing: 16) {
                pacePanel.frame(maxWidth: .infinity)
                VStack(alignment: .leading, spacing: 16) {
                    headroomPanel
                    sessionsPanel
                }
                .frame(width: 300)
            }
        }
    }

    private func faces(columns: Int) -> some View {
        Grid(horizontalSpacing: 16, verticalSpacing: 16) {
            ForEach(Array(stride(from: 0, to: model.profiles.count, by: columns)), id: \.self) { start in
                GridRow {
                    ForEach(model.profiles[start..<min(start + columns, model.profiles.count)]) { p in
                        AccountFace(profile: p, selected: p.id == model.focusProfile?.id) {
                            withAnimation(.easeOut(duration: 0.2)) { model.focusedProfileId = p.id }
                        }
                        .frame(minWidth: 200)
                    }
                }
            }
        }
    }

    private func subtitle(_ finding: (profile: Profile, text: String, tone: Tone)?) -> String {
        if let finding { return finding.text }
        if let last = model.lastCapture {
            return "Every account has room at its current pace. Limits last reported \(Fmt.relative(last, now: model.now))."
        }
        return "Limits appear here after each account's next Claude reply. Turn on limit tracking under Usage."
    }

    // MARK: Pace

    @ViewBuilder
    private var pacePanel: some View {
        Panel(padding: 20) {
            if let p = model.focusProfile {
                HStack(alignment: .firstTextBaseline) {
                    Text("Pace · \(p.displayName)").font(TypeScale.section).foregroundStyle(Ink.text)
                    Spacer()
                    Picker("Window", selection: $chartKind) {
                        Text("This week").tag(UsageWindow.Kind.sevenDay)
                        Text("This session").tag(UsageWindow.Kind.fiveHour)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
                if let w = model.window(chartKind, for: p) {
                    if let f = model.forecast(chartKind, for: p) {
                        let (text, tone) = Outlook.sentence(f, now: model.now)
                        Text(text).font(TypeScale.body)
                            .foregroundStyle(tone == .neutral ? Ink.muted : Ink.tone(tone))
                        paceFacts(f)
                    }
                    PaceChart(window: w, points: model.history[p.id] ?? [], now: model.now, height: 210)
                    Text("Solid: used, as recorded. Dotted: an even pace to the reset. Dashed: where the current pace leads.")
                        .font(TypeScale.meta)
                        .foregroundStyle(Ink.faint)
                } else {
                    Text("No limit reading for \(p.displayName) yet. It appears after the next Claude reply in this account.")
                        .font(TypeScale.body)
                        .foregroundStyle(Ink.muted)
                        .frame(maxWidth: .infinity, minHeight: 210, alignment: .center)
                }
            }
        }
    }

    private func paceFacts(_ f: PaceForecast) -> some View {
        HStack(spacing: 0) {
            fact("Used", Fmt.percent(f.used))
            divider
            fact("Time gone", Fmt.percent(f.elapsedFraction * 100))
            divider
            fact(f.paceDelta >= 0 ? "Ahead of pace" : "Behind pace", "\(f.paceDelta >= 0 ? "+" : "−")\(Fmt.percent(abs(f.paceDelta)))",
                 tone: f.paceDelta > 10 ? .warning : .neutral)
            divider
            fact("Resets", Fmt.moment(f.resetsAt, now: model.now))
        }
        .padding(.vertical, 10)
        .background(Ink.raised, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var divider: some View { Rectangle().fill(Ink.border).frame(width: 1, height: 30) }

    private func fact(_ label: String, _ value: String, tone: Tone = .neutral) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(TypeScale.meta).foregroundStyle(Ink.muted)
            Text(value).font(TypeScale.figure(18, .medium)).foregroundStyle(tone == .neutral ? Ink.text : Ink.tone(tone))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
    }

    // MARK: Headroom

    private var headroomPanel: some View {
        Panel {
            SectionHeader(title: "Most room first", font: TypeScale.section)
            let ranked = HeadroomAdvisor.rank(profiles: model.profiles, snapshots: model.snapshots, now: model.now)
            VStack(spacing: 10) {
                ForEach(ranked, id: \.profile.id) { r in
                    HStack(spacing: 10) {
                        Monogram(profile: r.profile, size: 20)
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(r.profile.displayName).font(TypeScale.body).foregroundStyle(Ink.text).lineLimit(1)
                                Spacer()
                                Text(r.peakPercentage.map(Fmt.percent) ?? "–")
                                    .font(TypeScale.body.monospacedDigit())
                                    .foregroundStyle(r.peakPercentage == nil ? Ink.faint : Ink.text)
                            }
                            MeterBar(percent: r.peakPercentage, height: 3)
                        }
                    }
                }
            }
            Text("Ranked by each account's fullest limit. Assign new work to the top one.")
                .font(TypeScale.meta)
                .foregroundStyle(Ink.faint)
        }
    }

    private var sessionsPanel: some View {
        Panel {
            SectionHeader(title: "Running now", font: TypeScale.section) {
                Button("View") { model.selectedSection = .sessions }.buttonStyle(LinkButtonStyle())
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(model.sessions.count)").font(TypeScale.figure(26, .medium)).foregroundStyle(Ink.text)
                Text(model.sessions.count == 1 ? "Claude session" : "Claude sessions").font(TypeScale.body).foregroundStyle(Ink.muted)
            }
            let stale = model.staleSessions.count
            if stale > 0 {
                Notice(icon: "arrow.triangle.2.circlepath", tone: .warning, text: "\(Fmt.plural(stale, "session")) on an old account until restarted.")
            } else if !model.sessions.isEmpty {
                Text("All on the account their folder is assigned to.").font(TypeScale.meta).foregroundStyle(Ink.muted)
            }
        }
    }
}

/// One account as a watch face: session and week gauges, when each recovers, this week's load.
private struct AccountFace: View {
    @EnvironmentObject var model: AppModel
    let profile: Profile
    let selected: Bool
    let select: () -> Void
    @State private var hovering = false

    var body: some View {
        let five = model.window(.fiveHour, for: profile)
        let seven = model.window(.sevenDay, for: profile)
        Button(action: select) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Monogram(profile: profile, size: 22)
                    Text(profile.displayName).font(TypeScale.bodyStrong).foregroundStyle(Ink.text).lineLimit(1)
                    Spacer(minLength: 4)
                    if let plan = model.statuses[profile.id]?.auth?.planLabel { Pill(text: plan) }
                }
                HStack(alignment: .top, spacing: 0) {
                    gauge(five, kind: .fiveHour, caption: "session").frame(maxWidth: .infinity)
                    gauge(seven, kind: .sevenDay, caption: "week").frame(maxWidth: .infinity)
                }
                HStack(alignment: .bottom) {
                    WeekStrip(report: model.reports[profile.id], now: model.now, height: 16)
                    Spacer(minLength: 4)
                    VStack(alignment: .trailing, spacing: 0) {
                        Text(weekTokens).font(TypeScale.figure(13, .medium)).foregroundStyle(Ink.text)
                        Text("tokens, 7d").font(TypeScale.meta).foregroundStyle(Ink.faint)
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(hovering && !selected ? Ink.raised : Ink.sheet, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(selected ? Ink.text.opacity(0.75) : Ink.border, lineWidth: selected ? 1.5 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }

    private func gauge(_ w: UsageWindow?, kind: UsageWindow.Kind, caption: String) -> some View {
        let reset = Fmt.reset(w, now: model.now)
        return VStack(spacing: 6) {
            LoadArc(
                percent: w.map { $0.effectivePercentage(at: model.now) },
                paceFraction: model.forecast(kind, for: profile)?.elapsedFraction,
                size: 64, lineWidth: 6, caption: caption)
            VStack(spacing: 0) {
                Text(reset.value)
                    .font(TypeScale.figure(14, .medium))
                    .foregroundStyle(reset.value == "–" ? Ink.faint : Ink.text)
                Text(reset.caption).font(TypeScale.meta).foregroundStyle(Ink.faint)
            }
        }
    }

    private var weekTokens: String {
        guard let r = model.reports[profile.id] else { return "–" }
        return Fmt.tokens(DailyTokensChart.series(r, days: 7, now: model.now).map(\.tokens).reduce(0, +))
    }
}
