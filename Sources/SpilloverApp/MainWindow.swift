import SwiftUI
import SpilloverCore

enum MainSection: String, CaseIterable, Identifiable, Hashable {
    case overview, accounts, folders, sessions, usage, setup, health

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: return "Overview"
        case .accounts: return "Accounts"
        case .folders: return "Folders"
        case .sessions: return "Sessions"
        case .usage: return "Usage"
        case .setup: return "Setup"
        case .health: return "Health"
        }
    }

    var icon: String {
        switch self {
        case .overview: return "gauge.with.dots.needle.50percent"
        case .accounts: return "person.2"
        case .folders: return "folder"
        case .sessions: return "bolt.horizontal"
        case .usage: return "chart.bar.xaxis"
        case .setup: return "wrench.and.screwdriver"
        case .health: return "stethoscope"
        }
    }

    static let work: [MainSection] = [.overview, .accounts, .folders, .sessions, .usage]
    static let system: [MainSection] = [.setup, .health]
}

/// Window shell: a stone frame holds the sidebar and toolbar; each section sits on a sheet one
/// tone step away, inset from the window's right and bottom edges.
struct MainWindow: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 240)
        } detail: {
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Ink.sheet, in: UnevenRoundedRectangle(cornerRadii: .init(topLeading: 14, bottomLeading: 14, bottomTrailing: 14, topTrailing: 14), style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Ink.border))
                .padding([.trailing, .bottom], 8)
                .background(Ink.frame)
                .toolbar {
                    ToolbarItem {
                        IconButton(systemName: "arrow.clockwise", help: "Refresh logins, folders, limits and sessions") {
                            model.refreshAll()
                        }
                    }
                }
                .toolbarBackground(Ink.frame, for: .windowToolbar)
        }
        .navigationTitle("")
        .frame(minWidth: 860, minHeight: 600)
    }

    /// Sidebar on the frame: the product, then sections. The active row is a neutral pill.
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                BrandMark(size: 18)
                Text("Spillover").font(TypeScale.bodyStrong).foregroundStyle(Ink.text)
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 14)
            ForEach(MainSection.work) { SidebarRow(section: $0, badge: badge(for: $0)) }
            Text("System")
                .font(TypeScale.metaStrong)
                .foregroundStyle(Ink.faint)
                .padding(.horizontal, 10)
                .padding(.top, 18)
                .padding(.bottom, 4)
            ForEach(MainSection.system) { SidebarRow(section: $0, badge: badge(for: $0)) }
            Spacer()
            if let last = model.lastCapture {
                Text("Limits reported \(Fmt.relative(last, now: model.now))")
                    .font(TypeScale.meta)
                    .foregroundStyle(Ink.faint)
                    .padding(.horizontal, 10)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Ink.frame)
    }

    @ViewBuilder
    private var detail: some View {
        switch model.selectedSection ?? .overview {
        case .overview: OverviewView()
        case .accounts: AccountsView()
        case .folders: FoldersView()
        case .sessions: SessionsView()
        case .usage: UsageView()
        case .setup: SetupView()
        case .health: HealthView()
        }
    }

    private func badge(for section: MainSection) -> Int {
        switch section {
        case .setup: return model.vscodeConnected ? 0 : 1
        case .sessions: return model.staleSessions.count
        case .health: return model.health.filter { $0.status == .failure }.count
        default: return 0
        }
    }
}

private struct SidebarRow: View {
    @EnvironmentObject var model: AppModel
    let section: MainSection
    let badge: Int
    @State private var hovering = false

    var body: some View {
        let active = (model.selectedSection ?? .overview) == section
        Button {
            model.selectedSection = section
        } label: {
            HStack(spacing: 9) {
                Image(systemName: section.icon)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(active ? Ink.text : Ink.muted)
                    .frame(width: 18)
                Text(section.title)
                    .font(TypeScale.body.weight(active ? .semibold : .regular))
                    .foregroundStyle(active ? Ink.text : Ink.muted)
                Spacer()
                if badge > 0 {
                    Text("\(badge)")
                        .font(TypeScale.metaStrong.monospacedDigit())
                        .foregroundStyle(Ink.warning)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(active ? Ink.active : (hovering ? Ink.active.opacity(0.5) : .clear), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(active ? .isSelected : [])
    }
}

/// Section page on the sheet: a noun title, one line about the data, actions on the right.
struct Page<Content: View, Actions: View>: View {
    let title: String
    let subtitle: String
    var subtitleTone: Tone = .neutral
    @ViewBuilder var actions: Actions
    @ViewBuilder var content: Content
    @EnvironmentObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(title).font(TypeScale.title).foregroundStyle(Ink.text)
                            .accessibilityAddTraits(.isHeader)
                        Text(subtitle)
                            .font(TypeScale.body)
                            .foregroundStyle(subtitleTone == .neutral ? Ink.muted : Ink.tone(subtitleTone))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 12)
                    HStack(spacing: 8) { actions }
                }
                if let banner = model.banner {
                    BannerView(banner: banner) { model.banner = nil }
                }
                content
            }
            .padding(28)
            .frame(maxWidth: 1080, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollContentBackground(.hidden)
    }
}

extension Page where Actions == EmptyView {
    init(title: String, subtitle: String, subtitleTone: Tone = .neutral, @ViewBuilder content: () -> Content) {
        self.init(title: title, subtitle: subtitle, subtitleTone: subtitleTone, actions: { EmptyView() }, content: content)
    }
}
