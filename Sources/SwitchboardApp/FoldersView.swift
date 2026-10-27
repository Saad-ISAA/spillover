import SwiftUI
import SwitchboardCore

struct FoldersView: View {
    @EnvironmentObject var model: AppModel
    @State private var probePath = ""

    var body: some View {
        Page(
            title: "Folders",
            subtitle: "A folder's account also applies to everything inside it. Folders without an assignment use your normal (Default) login."
        ) {
            AssignFolderMenu(bordered: true)
        } content: {
            if let problem = model.routesProblem {
                Notice(icon: "exclamationmark.octagon.fill", tone: .negative,
                       text: "Folder assignments cannot be read: \(problem) Claude refuses to start in any folder until this is fixed, so no session silently uses the wrong account.") {
                    Button("Health") { model.selectedSection = .health }.buttonStyle(LinkButtonStyle())
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                SectionHeader(title: "Assigned", font: TypeScale.section) {
                    Text(Fmt.plural(model.routes.count, "folder")).font(TypeScale.meta).foregroundStyle(Ink.faint)
                }
                if model.routes.isEmpty {
                    Text("Nothing assigned yet. Every folder uses your normal login.")
                        .font(TypeScale.body)
                        .foregroundStyle(Ink.muted)
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .padding(.horizontal, 12)
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Ink.border, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                }
                VStack(spacing: 0) {
                    ForEach(Array(model.routes.enumerated()), id: \.element.id) { i, route in
                        if i > 0 { Rule() }
                        FolderRow(path: route.folder, assigned: true)
                    }
                }
            }

            let recent = model.recentFolders.filter { r in !model.routes.contains { $0.folder == r.path } }
            if !recent.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    SectionHeader(title: "Recently opened in VS Code", font: TypeScale.section)
                    VStack(spacing: 0) {
                        ForEach(Array(recent.prefix(15).enumerated()), id: \.element.path) { i, entry in
                            if i > 0 { Rule() }
                            FolderRow(path: entry.path, assigned: false)
                        }
                    }
                }
            }

            Panel(padding: 20) {
                Text("Which account will Claude use here?").font(TypeScale.section).foregroundStyle(Ink.text)
                HStack {
                    TextField("Folder path", text: $probePath).textFieldStyle(.roundedBorder)
                    Button("Choose…") { if let p = model.chooseFolder() { probePath = p } }
                        .buttonStyle(QuietButtonStyle())
                }
                if !probePath.isEmpty {
                    ResolutionText(resolution: model.resolution(for: probePath))
                }
            }

            Text("Switching a folder also moves the chats open in it: each waits for its current reply, then reopens on the new account with its history.")
                .font(TypeScale.meta)
                .foregroundStyle(Ink.faint)
        }
    }
}

private struct FolderRow: View {
    @EnvironmentObject var model: AppModel
    let path: String
    let assigned: Bool

    var body: some View {
        HStack(spacing: 12) {
            if let p = model.assignedProfile(for: path) {
                Monogram(profile: p, size: 22)
            } else {
                Image(systemName: "folder").font(.system(size: 13)).foregroundStyle(Ink.faint).frame(width: 22)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(Fmt.folderName(path)).font(TypeScale.body).foregroundStyle(Ink.text).lineLimit(1)
                Text(Fmt.parentFolder(path))
                    .font(TypeScale.meta)
                    .foregroundStyle(Ink.faint)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            AccountMenu(folder: path)
            Menu {
                Button("Open in VS Code") { model.openInVSCode(path) }
                Button("Show in Finder") { model.revealInFinder(path) }
                if let p = model.assignedProfile(for: path) {
                    Button("Open Terminal here as \(p.displayName)") { model.openShell(p, in: path) }
                }
                if assigned {
                    Divider()
                    Button("Remove assignment", role: .destructive) { model.unassign(folder: path) }
                }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More")
        }
        .padding(.vertical, 9)
    }
}

struct ResolutionText: View {
    let resolution: Resolution

    var body: some View {
        switch resolution {
        case .unrouted:
            Notice(icon: "person.crop.circle", tone: .neutral, text: "No assignment: your normal (Default) login.")
        case .routed(let p, let route):
            Notice(icon: "checkmark.circle.fill", tone: .positive, text: "\(p.displayName), via \(Fmt.shortFolder(route.folder)).")
        case .refused(let refusal):
            Notice(icon: "xmark.octagon.fill", tone: .negative, text: "Claude would refuse to start: \(refusal.message)")
        }
    }
}
