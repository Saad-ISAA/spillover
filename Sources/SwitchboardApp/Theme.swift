import SwiftUI
import SwitchboardCore

enum Theme {
    /// Stable colour per account so the same account looks the same everywhere.
    static let palette: [Color] = [.blue, .purple, .orange, .teal, .pink, .green, .indigo, .brown, .mint, .cyan]

    static func color(for profile: Profile) -> Color {
        if profile.isDefault { return .gray }
        let sum = profile.id.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
        return palette[sum % palette.count]
    }

    static func usageColor(_ percent: Double) -> Color {
        switch percent {
        case ..<60: return .green
        case ..<HeadroomAdvisor.warningThreshold: return .yellow
        case ..<95: return .orange
        default: return .red
        }
    }

    static func shortFolder(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    static func relative(_ date: Date, now: Date = Date()) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f.localizedString(for: date, relativeTo: now)
    }

    static func countdown(to date: Date, now: Date = Date()) -> String {
        let s = max(0, Int(date.timeIntervalSince(now)))
        if s == 0 { return "reset" }
        let d = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60
        if d > 0 { return "\(d)d \(h)h" }
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }

    static func tokens(_ n: Int) -> String {
        if n >= 1_000_000_000 { return String(format: "%.1fB", Double(n) / 1e9) }
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1e6) }
        if n >= 1_000 { return String(format: "%.1fK", Double(n) / 1e3) }
        return "\(n)"
    }
}
