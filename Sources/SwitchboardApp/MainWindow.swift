import SwiftUI
import SwitchboardCore

enum MainSection: String, CaseIterable, Identifiable, Hashable {
    case accounts, folders, sessions, usage, setup, health

    var id: String { rawValue }

    var title: String {
        switch self {
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
        case .accounts: return "person.2.fill"
        case .folders: return "folder.fill"
        case .sessions: return "bolt.horizontal.fill"
        case .usage: return "chart.bar.fill"
        case .setup: return "wrench.and.screwdriver.fill"
        case .health: return "stethoscope"
        }
    }
}

struct MainWindow: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        NavigationSplitView {
            List(MainSection.allCases, selection: $model.selectedSection) { section in
                Label(section.title, systemImage: section.icon)
                    .badge(badge(for: section))
                    .tag(section)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190)
        } detail: {
            VStack(spacing: 0) {
                if let banner = model.banner {
                    BannerView(banner: banner) { model.banner = nil }
                        .padding([.horizontal, .top])
                }
                detail
            }
            .toolbar {
                ToolbarItem {
                    Button {
                        model.refreshAll()
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .help("Refresh logins, folders and usage")
                }
            }
        }
        .frame(minWidth: 760, minHeight: 520)
    }

    @ViewBuilder
    private var detail: some View {
        switch model.selectedSection ?? .accounts {
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

/// Shared page chrome: title, subtitle, scrollable content.
struct Page<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.largeTitle.weight(.semibold))
                    Text(subtitle).foregroundStyle(.secondary)
                }
                content
            }
            .padding(24)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Rounded group box used across pages.
struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) { content }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator.opacity(0.5)))
    }
}
