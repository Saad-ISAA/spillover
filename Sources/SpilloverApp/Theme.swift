import AppKit
import SwiftUI
import SpilloverCore

// Visual language: each account is read like a training watch reads a body — how loaded it is
// and exactly when it recovers. Matte, flat colour (no gradients, no glow), one data hue (teal)
// on the main data element, amber and red only when a limit is at risk, rounded tabular figures.
// Chrome is a quiet stone frame; work sits on a sheet one tone step away, separated by a 1px
// edge and never a shadow. Light and dark follow macOS.

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255, opacity: 1)
    }

    /// A colour that follows the window's light or dark appearance.
    static func adaptive(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(
            nsColor: NSColor(name: nil) { appearance in
                let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                let hex = isDark ? dark : light
                return NSColor(
                    srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                    blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
            })
    }
}

/// Colour tokens. Text tiers hold 4.5:1 on `sheet` and `frame` in both appearances.
enum Ink {
    static let frame = Color.adaptive(0xF3F3F0, 0x0C0D0F)
    static let sheet = Color.adaptive(0xFFFFFF, 0x151619)
    static let raised = Color.adaptive(0xF4F4F1, 0x1D1F22)
    static let active = Color.adaptive(0xEBEBE7, 0x25272B)
    static let border = Color.adaptive(0xE4E4E0, 0x2A2C30)
    static let rule = Color.adaptive(0xEEEEEA, 0x212327)
    static let track = Color.adaptive(0xE8E8E4, 0x2A2C31)

    static let text = Color.adaptive(0x141516, 0xF3F2EE)
    static let muted = Color.adaptive(0x55585C, 0xB3B5B9)
    static let faint = Color.adaptive(0x686B70, 0x8F9297)

    /// The one data hue: the main series, the selected window, a gauge that is fine.
    static let data = Color.adaptive(0x18697D, 0x4DB6CC)
    static let positive = Color.adaptive(0x1E7B4F, 0x3FC07A)
    static let warning = Color.adaptive(0x9A5B0A, 0xE9A23B)
    static let negative = Color.adaptive(0xC4242A, 0xF0646A)

    static let warningWash = Color.adaptive(0xFDF5E6, 0x2A2114)
    static let negativeWash = Color.adaptive(0xFDEDEC, 0x2C1A1C)
    static let positiveWash = Color.adaptive(0xE6F5EC, 0x15261C)

    /// Gauge colour by how full a limit is: data hue while fine, amber from 80%, red from 95%.
    static func load(_ percent: Double) -> Color {
        switch percent {
        case ..<HeadroomAdvisor.warningThreshold: return data
        case ..<95: return warning
        default: return negative
        }
    }

    static func tone(_ t: Tone) -> Color {
        switch t {
        case .neutral: return muted
        case .positive: return positive
        case .warning: return warning
        case .negative: return negative
        case .data: return data
        }
    }

    static func wash(_ t: Tone) -> Color {
        switch t {
        case .neutral, .data: return raised
        case .positive: return positiveWash
        case .warning: return warningWash
        case .negative: return negativeWash
        }
    }
}

enum Tone { case neutral, positive, warning, negative, data }

/// Each account keeps one identity hue everywhere, used only as a pale tint behind its
/// monogram (identity, never data). Hues sit at least 60° apart.
enum Identity {
    private static let hues: [(light: UInt32, dark: UInt32, inkLight: UInt32, inkDark: UInt32)] = [
        (0xDCE8F8, 0x1C2A3D, 0x24508F, 0x9CC0F0),  // blue
        (0xF6DFEA, 0x3A1F2C, 0x8E2F5C, 0xF0A6C8),  // rose
        (0xEFE6D2, 0x332B1C, 0x6B5320, 0xDDC48E),  // khaki
        (0xDDEFE3, 0x1B3125, 0x2C6B45, 0x98D6AE),  // green
        (0xE4E7EC, 0x24282E, 0x3F4A57, 0xC2CAD4),  // slate
    ]

    static func index(for profile: Profile) -> Int {
        if profile.isDefault { return 4 }
        let sum = profile.id.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
        return sum % 4
    }

    static func tint(for profile: Profile) -> Color {
        let h = hues[index(for: profile)]
        return .adaptive(h.light, h.dark)
    }

    static func ink(for profile: Profile) -> Color {
        let h = hues[index(for: profile)]
        return .adaptive(h.inkLight, h.inkDark)
    }
}

/// Type roles. Figures are SF Rounded with tabular digits; everything else is the system face.
enum TypeScale {
    static func figure(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .rounded).monospacedDigit()
    }

    static let title = Font.system(size: 22, weight: .semibold)
    static let section = Font.system(size: 15, weight: .semibold)
    static let body = Font.system(size: 13)
    static let bodyStrong = Font.system(size: 13, weight: .semibold)
    static let meta = Font.system(size: 11)
    static let metaStrong = Font.system(size: 11, weight: .semibold)
}

/// Text formatting shared by every screen.
enum Fmt {
    static func shortFolder(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    static func folderName(_ path: String) -> String { (path as NSString).lastPathComponent }

    static func parentFolder(_ path: String) -> String {
        shortFolder((path as NSString).deletingLastPathComponent)
    }

    static func relative(_ date: Date, now: Date = Date()) -> String {
        if abs(now.timeIntervalSince(date)) < 45 { return "just now" }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f.localizedString(for: date, relativeTo: now)
    }

    /// "2h 14m", "3d 4h", "12m".
    static func duration(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        let d = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60
        if d > 0 { return h > 0 ? "\(d)d \(h)h" : "\(d)d" }
        if h > 0 { return "\(h)h \(m)m" }
        return "\(max(m, 1))m"
    }

    static func countdown(to date: Date, now: Date = Date()) -> String {
        date <= now ? "now" : duration(date.timeIntervalSince(now))
    }

    /// Time to a window's reset, or a dash when nothing is used (the window has not started).
    static func reset(_ w: UsageWindow?, now: Date) -> (value: String, caption: String) {
        guard let w else { return ("–", "no reading") }
        if w.effectivePercentage(at: now) <= 0 { return ("–", "not started") }
        return (countdown(to: w.resetsAt, now: now), "to reset")
    }

    /// "14:05" today, "Thu 14:05" this week, "12 Nov" later.
    static func moment(_ date: Date, now: Date = Date()) -> String {
        let cal = Calendar.current
        let f = DateFormatter()
        if cal.isDate(date, inSameDayAs: now) {
            f.setLocalizedDateFormatFromTemplate("Hm")
        } else if abs(date.timeIntervalSince(now)) < 6 * 86400 {
            f.setLocalizedDateFormatFromTemplate("EEEHm")
        } else {
            f.setLocalizedDateFormatFromTemplate("dMMM")
        }
        return f.string(from: date)
    }

    static func percent(_ value: Double) -> String { "\(Int(value.rounded()))%" }

    static func tokens(_ n: Int) -> String {
        if n >= 1_000_000_000 { return String(format: "%.1fB", Double(n) / 1e9) }
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1e6) }
        if n >= 1_000 { return String(format: "%.1fK", Double(n) / 1e3) }
        return "\(n)"
    }

    static func plural(_ n: Int, _ word: String) -> String { "\(n) \(word)\(n == 1 ? "" : "s")" }
}

/// Plain-language reading of a forecast, with the tone it should carry.
enum Outlook {
    static func sentence(_ f: PaceForecast, now: Date) -> (text: String, tone: Tone) {
        let window = f.kind == .fiveHour ? "session limit" : "weekly limit"
        switch f.outlook {
        case .full:
            return ("The \(window) is used up until \(Fmt.moment(f.resetsAt, now: now)).", .negative)
        case .runsOut(let at, let early):
            let tone: Tone = early > (f.kind == .fiveHour ? 1800 : 6 * 3600) ? .negative : .warning
            return ("At this pace the \(window) runs out \(Fmt.moment(at, now: now)), \(Fmt.duration(early)) before it resets.", tone)
        case .lastsUntilReset(let projected):
            return ("At this pace about \(Fmt.percent(projected)) of the \(window) is used by the reset.", .neutral)
        case .idle:
            return ("Nothing used in this \(f.kind == .fiveHour ? "session" : "week") yet.", .neutral)
        case .tooEarly:
            return ("Too early in this \(f.kind == .fiveHour ? "session" : "week") to forecast.", .neutral)
        }
    }
}
