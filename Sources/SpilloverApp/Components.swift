import SwiftUI
import SpilloverCore

// MARK: Identity

/// An account's initial on its pale identity tint.
struct Monogram: View {
    let profile: Profile
    var size: CGFloat = 22

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
            .fill(Identity.tint(for: profile))
            .frame(width: size, height: size)
            .overlay(
                Text(String(profile.displayName.prefix(1)).uppercased())
                    .font(.system(size: size * 0.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(Identity.ink(for: profile))
            )
            .accessibilityHidden(true)
    }
}

// MARK: Gauges

/// A watch-style open arc (270°, gap at the bottom) showing how much of a limit is used.
/// The small tick marks where an even pace would be right now.
struct LoadArc: View {
    let percent: Double?
    var paceFraction: Double?
    var size: CGFloat = 64
    var lineWidth: CGFloat = 7
    var showsValue = true
    var caption: String?

    private let sweep = 0.75

    var body: some View {
        ZStack {
            arc(to: 1).stroke(Ink.track, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            if let percent, percent > 0 {
                arc(to: min(percent, 100) / 100)
                    .stroke(Ink.load(percent), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .animation(.easeOut(duration: 0.35), value: percent)
            }
            if let paceFraction, paceFraction > 0.02, paceFraction < 0.98 {
                paceTick(paceFraction)
            }
            if showsValue {
                VStack(spacing: 0) {
                    Text(percent.map(Fmt.percent) ?? "–")
                        .font(TypeScale.figure(size * 0.26))
                        .foregroundStyle(percent == nil ? Ink.faint : Ink.text)
                    if let caption {
                        Text(caption).font(.system(size: max(9, size * 0.14), weight: .medium))
                            .foregroundStyle(Ink.faint)
                    }
                }
            }
        }
        .frame(width: size, height: size)
    }

    /// Arc from the bottom-left (135°) clockwise through the top to the bottom-right (45°).
    private func arc(to fraction: Double) -> Path {
        Path { p in
            let r = (size - lineWidth) / 2
            p.addArc(
                center: CGPoint(x: size / 2, y: size / 2), radius: r, startAngle: .degrees(135),
                endAngle: .degrees(135 + 360 * sweep * fraction), clockwise: false)
        }
    }

    private func paceTick(_ fraction: Double) -> some View {
        let angle = Angle.degrees(135 + 360 * sweep * fraction)
        let r = (size - lineWidth) / 2
        let inner = r - lineWidth / 2 - 2, outer = r + lineWidth / 2 + 2
        let c = CGPoint(x: size / 2, y: size / 2)
        return Path { p in
            p.move(to: CGPoint(x: c.x + inner * cos(angle.radians), y: c.y + inner * sin(angle.radians)))
            p.addLine(to: CGPoint(x: c.x + outer * cos(angle.radians), y: c.y + outer * sin(angle.radians)))
        }
        .stroke(Ink.text.opacity(0.55), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
    }
}

/// A thin horizontal meter with an optional even-pace tick.
struct MeterBar: View {
    let percent: Double?
    var paceFraction: Double?
    var height: CGFloat = 5

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Ink.track)
                if let percent, percent > 0 {
                    Capsule()
                        .fill(Ink.load(percent))
                        .frame(width: max(height, geo.size.width * min(percent, 100) / 100))
                }
                if let paceFraction, paceFraction > 0.01, paceFraction < 0.99 {
                    Rectangle()
                        .fill(Ink.text.opacity(0.55))
                        .frame(width: 1.5, height: height + 6)
                        .offset(x: geo.size.width * paceFraction - 0.75)
                }
            }
            .frame(maxHeight: .infinity)
        }
        .frame(height: height + 6)
    }
}

// MARK: Small marks

struct Pill: View {
    let text: String
    var tone: Tone = .neutral

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .foregroundStyle(tone == .neutral ? Ink.muted : Ink.tone(tone))
            .background(Ink.wash(tone), in: Capsule())
    }
}

struct StatusDot: View {
    let tone: Tone
    var body: some View {
        Circle().fill(Ink.tone(tone)).frame(width: 6, height: 6).accessibilityHidden(true)
    }
}

/// Login state as a dot and short words.
struct LoginState: View {
    let status: ProfileStatus?
    var showsEmail = true

    var body: some View {
        HStack(spacing: 5) {
            switch status ?? .unknown {
            case .unknown, .checking:
                ProgressView().controlSize(.mini).frame(width: 8, height: 8)
                Text("Checking login")
            case .loggedIn(let s):
                StatusDot(tone: .positive)
                Text(showsEmail ? (s.email.map(Redaction.email) ?? "Logged in") : "Logged in")
            case .loggedOut:
                StatusDot(tone: .warning)
                Text("Not logged in")
            case .error(let e):
                StatusDot(tone: .negative)
                Text(e).lineLimit(1)
            }
        }
        .font(TypeScale.meta)
        .foregroundStyle(Ink.muted)
    }
}

/// Section heading: sentence case, with an optional trailing action.
struct SectionHeader<Trailing: View>: View {
    let title: String
    var font: Font = TypeScale.metaStrong
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(font).foregroundStyle(font == TypeScale.metaStrong ? Ink.muted : Ink.text)
            Spacer(minLength: 8)
            trailing
        }
    }
}

extension SectionHeader where Trailing == EmptyView {
    init(title: String, font: Font = TypeScale.metaStrong) {
        self.init(title: title, font: font) { EmptyView() }
    }
}

/// A line of explanation that carries a status: a coloured icon, the words in ink, one action.
struct Notice<Action: View>: View {
    let icon: String
    let tone: Tone
    let text: String
    @ViewBuilder var action: Action

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: icon).foregroundStyle(Ink.tone(tone)).font(.system(size: 12, weight: .semibold))
            Text(text).font(TypeScale.body).foregroundStyle(Ink.text)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            action
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Ink.wash(tone), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

extension Notice where Action == EmptyView {
    init(icon: String, tone: Tone, text: String) {
        self.init(icon: icon, tone: tone, text: text) { EmptyView() }
    }
}

struct BannerView: View {
    let banner: Banner
    let dismiss: () -> Void

    var body: some View {
        Notice(icon: icon, tone: tone, text: banner.text) {
            Button(action: dismiss) { Image(systemName: "xmark").font(.system(size: 10, weight: .bold)) }
                .buttonStyle(.plain)
                .foregroundStyle(Ink.faint)
                .accessibilityLabel("Dismiss")
        }
        .textSelection(.enabled)
    }

    private var icon: String {
        switch banner.kind {
        case .info: return "info.circle.fill"
        case .success: return "checkmark.circle.fill"
        case .error: return "exclamationmark.triangle.fill"
        }
    }

    private var tone: Tone {
        switch banner.kind {
        case .info: return .neutral
        case .success: return .positive
        case .error: return .negative
        }
    }
}

// MARK: Buttons

/// The one filled action on a screen: ink fill, sheet-coloured label.
struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(TypeScale.bodyStrong)
            .foregroundStyle(Ink.sheet)
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(Ink.text.opacity(configuration.isPressed ? 0.8 : 1), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .opacity(isEnabled ? 1 : 0.4)
    }
}

/// Secondary action: sheet fill with a 1px control edge.
struct QuietButtonStyle: ButtonStyle {
    var tone: Tone = .neutral
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(TypeScale.body.weight(.medium))
            .foregroundStyle(tone == .neutral ? Ink.text : Ink.tone(tone))
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(configuration.isPressed ? Ink.active : Ink.sheet, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Ink.border))
            .opacity(isEnabled ? 1 : 0.45)
    }
}

/// Text-only action in the data hue.
struct LinkButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(TypeScale.meta.weight(.medium))
            .foregroundStyle(Ink.data.opacity(configuration.isPressed ? 0.6 : 1))
            .contentShape(Rectangle())
    }
}

/// Small round icon button for headers (refresh, settings).
struct IconButton: View {
    let systemName: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(hovering ? Ink.text : Ink.muted)
                .frame(width: 26, height: 26)
                .background(hovering ? Ink.active : .clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

// MARK: Folder ↔ account controls

/// "Assign a folder to…": pick the account first, then the folder.
struct AssignFolderMenu: View {
    @EnvironmentObject var model: AppModel
    var label = "Assign a folder…"
    var bordered = false

    var body: some View {
        Dropdown(title: label, look: bordered ? .field : .link, help: "Give a folder its own account") {
            let accounts = model.profiles.filter { !$0.isDefault }
            if accounts.isEmpty { return [.note("Add an account first")] }
            return [.note("Pick the account, then choose the folder")]
                + accounts.map { p in
                    .action("\(p.displayName)…") {
                        if let folder = model.chooseFolder() { model.assign(folder: folder, to: p.id) }
                    }
                }
                + [.divider, .action("Auto (most room)…") {
                    if let folder = model.chooseFolder() { model.assign(folder: folder, to: Profile.autoID) }
                }]
        }
    }
}

/// The account a folder uses, as a compact chip that opens the account picker. Choosing another
/// account also moves the chats already open in that folder.
struct AccountMenu: View {
    @EnvironmentObject var model: AppModel
    let folder: String

    var body: some View {
        let exact = model.exactRoute(for: folder)
        let resolution = model.resolution(for: folder)
        Dropdown(
            title: Self.chipText(exact: exact, resolution: resolution, defaultName: model.defaultName), look: .chip,
            help: Self.helpText(exact: exact, resolution: resolution)
        ) {
            var items: [DropdownItem] = model.profiles.filter { !$0.isDefault }.map { p in
                .action(p.displayName, checked: exact?.profileId == p.id) {
                    model.switchWindow(folder: folder, to: p.id)
                }
            }
            items.append(.divider)
            items.append(.action("Auto (most room)", checked: exact?.profileId == Profile.autoID) {
                model.switchWindow(folder: folder, to: Profile.autoID)
            })
            items.append(.action("\(model.defaultName) (your normal login)", checked: exact?.profileId == Profile.defaultID) {
                model.switchWindow(folder: folder, to: Profile.defaultID)
            })
            if exact != nil {
                items.append(.divider)
                items.append(.action("Remove assignment") { model.unassign(folder: folder) })
            }
            return items
        }
    }

    static func chipText(exact: Route?, resolution: Resolution, defaultName: String = "Default") -> String {
        switch resolution {
        case .unrouted:
            return defaultName
        case .refused:
            return "Blocked"
        case .routed(let p, let route):
            let name = route.profileId == Profile.autoID ? "Auto · \(p.displayName)" : p.displayName
            return exact == nil ? "\(name) · from \(Fmt.folderName(route.folder))" : name
        }
    }

    static func helpText(exact: Route?, resolution: Resolution) -> String {
        switch resolution {
        case .unrouted: return "No assignment: Claude uses your normal login here."
        case .refused(let r): return "Claude refuses to start here: \(r.message)"
        case .routed(let p, let route):
            var text = route.profileId == Profile.autoID
                ? "Auto: new chats start on the account with the most room (now \(p.displayName))."
                : "Claude uses \(p.displayName) here."
            if exact == nil { text += " Inherited from \(Fmt.shortFolder(route.folder))." }
            return text
        }
    }
}

// MARK: Surfaces

/// A bordered panel inside the sheet. No shadow: elevation is the 1px edge.
struct Panel<Content: View>: View {
    var padding: CGFloat = 16
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) { content }
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Ink.sheet, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Ink.border))
    }
}

/// 1px row rule.
struct Rule: View {
    var body: some View { Rectangle().fill(Ink.rule).frame(height: 1) }
}

/// Two concentric rings: the session limit outside, the week inside, each in its load colour,
/// with the session figure in the middle.
struct DualRing: View {
    let session: Double?
    let week: Double?
    var size: CGFloat = 54

    var body: some View {
        let outer = size * 0.12, inner = size * 0.09, gap = size * 0.05
        ZStack {
            ring(session, diameter: size, width: outer)
            ring(week, diameter: size - 2 * (outer + gap), width: inner)
            Text(session.map(Fmt.percent) ?? "–")
                .font(TypeScale.figure(size * 0.2))
                .foregroundStyle(session == nil ? Ink.faint : Ink.text)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private func ring(_ value: Double?, diameter: CGFloat, width: CGFloat) -> some View {
        ZStack {
            Circle().stroke(Ink.track.opacity(0.9), lineWidth: width)
            if let value, value > 0 {
                Circle()
                    .trim(from: 0, to: min(value, 100) / 100)
                    .stroke(Ink.load(value), style: StrokeStyle(lineWidth: width, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.35), value: value)
            }
        }
        .frame(width: diameter - width, height: diameter - width)
    }
}
