import Charts
import SwiftUI
import SpilloverCore

/// The signature chart: one limit window from its start to its reset. The solid line is what was
/// used (as recorded), the dotted diagonal is an even pace, and the dashed line is where the
/// current pace leads: to the limit before the reset, or to the projected use at the reset.
struct PaceChart: View {
    let window: UsageWindow
    let points: [UsagePoint]
    let now: Date
    var height: CGFloat = 120
    var compact = false

    private struct Sample: Identifiable {
        let id: Int
        let at: Date
        let value: Double
    }

    var body: some View {
        if let forecast = PaceForecast.forecast(window, now: now) {
            chart(forecast)
                .frame(height: height)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Outlook.sentence(forecast, now: now).text)
        } else {
            Text("This window has reset. The chart starts again with the next Claude reply.")
                .font(TypeScale.meta)
                .foregroundStyle(Ink.muted)
                .frame(maxWidth: .infinity, minHeight: height, alignment: .center)
        }
    }

    private func samples(_ f: PaceForecast) -> [Sample] {
        let recorded = points.compactMap { p -> (Date, Double)? in
            guard let v = p.value(window.kind), let r = p.resetsAt(window.kind),
                abs(r.timeIntervalSince(window.resetsAt)) < 300, p.at >= f.windowStart, p.at <= now
            else { return nil }
            return (p.at, v)
        }
        var out = [(f.windowStart, 0.0)] + recorded
        if let last = out.last, last.1 != window.usedPercentage || last.0 < now.addingTimeInterval(-60) {
            out.append((now, window.usedPercentage))
        }
        return out.enumerated().map { Sample(id: $0.offset, at: $0.element.0, value: $0.element.1) }
    }

    private func forecastEnd(_ f: PaceForecast) -> (Date, Double)? {
        switch f.outlook {
        case .runsOut(let at, _): return (at, 100)
        case .lastsUntilReset(let projected): return (f.resetsAt, projected)
        default: return nil
        }
    }

    private func chart(_ f: PaceForecast) -> some View {
        let runsOut: Bool = { if case .runsOut = f.outlook { return true } else { return false } }()
        let color = Ink.load(runsOut ? max(f.used, 85) : f.used)
        let data = samples(f)
        return Chart {
            LineMark(x: .value("Time", f.windowStart), y: .value("Used", 0), series: .value("Line", "Even pace"))
                .foregroundStyle(Ink.faint.opacity(0.7))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 3]))
            LineMark(x: .value("Time", f.resetsAt), y: .value("Used", 100), series: .value("Line", "Even pace"))
                .foregroundStyle(Ink.faint.opacity(0.7))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 3]))

            ForEach(data) { s in
                // A soft fade under the line so the shape of the week reads at a glance.
                AreaMark(x: .value("Time", s.at), y: .value("Used", s.value))
                    .foregroundStyle(
                        LinearGradient(colors: [color.opacity(0.32), color.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.monotone)
                LineMark(x: .value("Time", s.at), y: .value("Used", s.value), series: .value("Line", "Used"))
                    .foregroundStyle(color)
                    .interpolationMethod(.monotone)
                    .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
            }

            if let end = forecastEnd(f) {
                LineMark(x: .value("Time", now), y: .value("Used", f.used), series: .value("Line", "Forecast"))
                    .foregroundStyle(color)
                    .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                LineMark(x: .value("Time", end.0), y: .value("Used", end.1), series: .value("Line", "Forecast"))
                    .foregroundStyle(color)
                    .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                PointMark(x: .value("Time", end.0), y: .value("Used", end.1))
                    .foregroundStyle(color)
                    .symbol { Circle().strokeBorder(color, lineWidth: 1.5).background(Circle().fill(Ink.sheet)).frame(width: 7, height: 7) }
                    .annotation(position: end.0 > now.addingTimeInterval(f.resetsAt.timeIntervalSince(f.windowStart) * 0.12) ? .topLeading : .topTrailing, spacing: 2) {
                        Text(end.1 >= 100 ? Fmt.moment(end.0, now: now) : "≈\(Fmt.percent(end.1))")
                            .font(.system(size: 10, weight: .semibold).monospacedDigit())
                            .foregroundStyle(color)
                    }
            }

            RuleMark(y: .value("Limit", 100))
                .foregroundStyle(Ink.border)
                .lineStyle(StrokeStyle(lineWidth: 1))
            RuleMark(x: .value("Now", now))
                .foregroundStyle(Ink.faint.opacity(0.5))
                .lineStyle(StrokeStyle(lineWidth: 1))
            PointMark(x: .value("Time", now), y: .value("Used", f.used))
                .foregroundStyle(color)
                .symbol {
                    Circle().fill(color).frame(width: 8, height: 8)
                        .background(Circle().fill(color.opacity(0.22)).frame(width: 18, height: 18))
                }
        }
        .chartXScale(domain: f.windowStart...f.resetsAt)
        .chartYScale(domain: 0...112)
        .chartYAxis {
            AxisMarks(position: .trailing, values: compact ? [0, 100] : [0, 50, 100]) { value in
                AxisGridLine().foregroundStyle(Ink.rule)
                AxisValueLabel {
                    if let v = value.as(Int.self) { Text("\(v)%").font(.system(size: 9)).foregroundStyle(Ink.faint) }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: xTicks(f)) { value in
                AxisValueLabel {
                    if let d = value.as(Date.self) { Text(xLabel(d)).font(.system(size: 9)).foregroundStyle(Ink.faint) }
                }
            }
        }
    }

    private func xTicks(_ f: PaceForecast) -> [Date] {
        let cal = Calendar.current
        var ticks: [Date] = []
        if window.kind == .fiveHour {
            var t = cal.dateInterval(of: .hour, for: f.windowStart)?.end ?? f.windowStart
            while t < f.resetsAt {
                ticks.append(t)
                t = t.addingTimeInterval(3600)
            }
        } else {
            var t = cal.startOfDay(for: f.windowStart.addingTimeInterval(86400))
            while t < f.resetsAt {
                ticks.append(t)
                t = cal.date(byAdding: .day, value: 1, to: t) ?? t.addingTimeInterval(86400)
            }
        }
        return ticks
    }

    private func xLabel(_ d: Date) -> String {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate(window.kind == .fiveHour ? "H" : "EEE")
        return window.kind == .fiveHour ? f.string(from: d) + ":00" : f.string(from: d)
    }
}

/// Tokens per day from the local session logs; today in the data hue, earlier days in grey.
struct DailyTokensChart: View {
    let report: UsageReport
    let days: Int
    var height: CGFloat = 160
    let now: Date

    struct Day: Identifiable {
        let date: Date
        let tokens: Int
        var id: Date { date }
    }

    static func series(_ report: UsageReport, days: Int, now: Date) -> [Day] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        return (0..<days).reversed().compactMap { back -> Day? in
            guard let day = cal.date(byAdding: .day, value: -back, to: today) else { return nil }
            var local = Calendar(identifier: .gregorian)
            local.timeZone = .current
            let comps = local.dateComponents([.year, .month, .day], from: day)
            let key = String(format: "%04d-%02d-%02d", comps.year ?? 0, comps.month ?? 0, comps.day ?? 0)
            return Day(date: day, tokens: report.byDay[key]?.total ?? 0)
        }
    }

    var body: some View {
        let data = Self.series(report, days: days, now: now)
        let today = Calendar.current.startOfDay(for: now)
        Chart(data) { d in
            BarMark(x: .value("Day", d.date, unit: .day), y: .value("Tokens", d.tokens), width: .ratio(0.62))
                .foregroundStyle(d.date == today ? Ink.data : Ink.faint.opacity(0.45))
        }
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 4)) { value in
                AxisGridLine().foregroundStyle(Ink.rule)
                AxisValueLabel {
                    if let v = value.as(Int.self) { Text(Fmt.tokens(v)).font(.system(size: 9)).foregroundStyle(Ink.faint) }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .day, count: days > 14 ? 5 : (days > 7 ? 2 : 1))) { value in
                AxisValueLabel(format: days > 7 ? .dateTime.day().month(.abbreviated) : .dateTime.weekday(.abbreviated))
                    .font(.system(size: 9))
                    .foregroundStyle(Ink.faint)
            }
        }
        .frame(height: height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Tokens per day for the last \(days) days. Today: \(Fmt.tokens(data.last?.tokens ?? 0)).")
    }
}

/// One window's recorded readings over the history (resets show as drops to zero).
struct LimitHistoryChart: View {
    let points: [UsagePoint]
    let kind: UsageWindow.Kind
    let now: Date
    var height: CGFloat = 150

    private struct Sample: Identifiable {
        let id: Int
        let at: Date
        let value: Double
    }

    var body: some View {
        let samples = points.enumerated().compactMap { i, p -> Sample? in
            guard let v = p.value(kind) else { return nil }
            let reset = p.resetsAt(kind)
            // A reading taken after its window reset counts as an empty window.
            return Sample(id: i, at: p.at, value: (reset.map { p.at >= $0 } ?? false) ? 0 : v)
        }
        if samples.count < 2 {
            Text("History builds up as you use this account. Each Claude reply adds a reading.")
                .font(TypeScale.meta)
                .foregroundStyle(Ink.muted)
                .frame(maxWidth: .infinity, minHeight: height)
        } else {
            Chart(samples) { s in
                LineMark(x: .value("Time", s.at), y: .value("Used", s.value))
                    .foregroundStyle(Ink.data)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineJoin: .round))
                    .interpolationMethod(.linear)
                RuleMark(y: .value("Warning", HeadroomAdvisor.warningThreshold))
                    .foregroundStyle(Ink.warning.opacity(0.5))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
            .chartXScale(domain: now.addingTimeInterval(-7 * 86400)...now)
            .chartYScale(domain: 0...105)
            .chartYAxis {
                AxisMarks(position: .trailing, values: [0, 25, 50, 75, 100]) { value in
                    AxisGridLine().foregroundStyle(Ink.rule)
                    AxisValueLabel {
                        if let v = value.as(Int.self) { Text("\(v)%").font(.system(size: 9)).foregroundStyle(Ink.faint) }
                    }
                }
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .day)) { _ in
                    AxisValueLabel(format: .dateTime.weekday(.abbreviated)).font(.system(size: 9)).foregroundStyle(Ink.faint)
                }
            }
            .frame(height: height)
        }
    }
}

/// A ranked list where each row carries a thin proportional bar: grey, the top row in ink.
struct BarList: View {
    struct Row: Identifiable {
        let id: String
        let label: String
        let detail: String?
        let value: Int
    }

    let rows: [Row]

    var body: some View {
        let top = max(1, rows.map(\.value).max() ?? 1)
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { i, row in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(row.label).font(TypeScale.body).foregroundStyle(Ink.text).lineLimit(1).truncationMode(.middle)
                        if let detail = row.detail {
                            Text(detail).font(TypeScale.meta).foregroundStyle(Ink.faint).lineLimit(1).truncationMode(.middle)
                        }
                        Spacer(minLength: 8)
                        Text(Fmt.tokens(row.value)).font(TypeScale.body.monospacedDigit()).foregroundStyle(i == 0 ? Ink.text : Ink.muted)
                    }
                    GeometryReader { geo in
                        Capsule()
                            .fill(i == 0 ? Ink.text : Ink.faint.opacity(0.45))
                            .frame(width: max(2, geo.size.width * CGFloat(row.value) / CGFloat(top)), height: 2)
                    }
                    .frame(height: 2)
                }
            }
        }
    }
}

/// Seven small day bars with day initials: this week's load at a glance (today in the data hue).
struct WeekStrip: View {
    let report: UsageReport?
    let now: Date
    var height: CGFloat = 28

    var body: some View {
        let days = report.map { DailyTokensChart.series($0, days: 7, now: now) } ?? []
        let top = max(1, days.map(\.tokens).max() ?? 1)
        HStack(alignment: .bottom, spacing: 5) {
            ForEach(Array(days.enumerated()), id: \.element.id) { i, d in
                VStack(spacing: 3) {
                    ZStack(alignment: .bottom) {
                        RoundedRectangle(cornerRadius: 1.5).fill(Ink.track).frame(height: height)
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(i == days.count - 1 ? Ink.data : Ink.faint.opacity(0.55))
                            .frame(height: d.tokens == 0 ? 0 : max(2, height * CGFloat(d.tokens) / CGFloat(top)))
                    }
                    .frame(width: 8)
                    Text(dayInitial(d.date)).font(.system(size: 9, weight: .medium)).foregroundStyle(Ink.faint)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Tokens per day this week")
    }

    private func dayInitial(_ d: Date) -> String {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEEEE")
        return f.string(from: d)
    }
}
