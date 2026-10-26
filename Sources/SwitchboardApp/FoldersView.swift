import SwiftUI
import SwitchboardCore

struct FoldersView: View {
    @EnvironmentObject var model: AppModel
    @State private var probePath = ""

    var body: some View {
        Page(
            title: "Folders",
            subtitle: "A folder's account also applies to everything inside it. Folders you have not assigned use your normal (Default) login."
        ) {
            if let problem = model.routesProblem {
                Card {
                    Label("Folder assignments cannot be read", systemImage: "exclamationmark.octagon.fill")
                        .foregroundStyle(.red)
                    Text(problem).font(.callout)
                    Text("Claude refuses to start in any folder until this is fixed, so no session silently uses the wrong account. See Health.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                AssignFolderMenu()
                    .buttonStyle(.borderedProminent)
                Spacer()
            }

            Card {
                Text("Assigned").font(.headline)
                if model.routes.isEmpty {
                    Text("Nothing assigned yet.").foregroundStyle(.secondary)
                }
                ForEach(model.routes) { route in
                    FolderRow(path: route.folder, assigned: true)
                    if route.id != model.routes.last?.id { Divider() }
                }
            }

            let recent = model.recentFolders.filter { r in !model.routes.contains { $0.folder == r.path } }
            if !recent.isEmpty {
                Card {
                    Text("Recently opened in VS Code").font(.headline)
                    ForEach(recent.prefix(15), id: \.path) { entry in
                        FolderRow(path: entry.path, assigned: false)
                    }
                }
            }

            Card {
                Text("Which account will Claude use here?").font(.headline)
                HStack {
                    TextField("Folder path", text: $probePath).textFieldStyle(.roundedBorder)
                    Button("Choose…") { if let p = model.chooseFolder() { probePath = p } }
                }
                if !probePath.isEmpty {
                    ResolutionText(resolution: model.resolution(for: probePath))
                }
            }

            Text("Changes apply to new Claude sessions. A chat that is already open keeps its account until you start a new one.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct FolderRow: View {
    @EnvironmentObject var model: AppModel
    let path: String
    let assigned: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: assigned ? "folder.fill" : "folder")
                .foregroundStyle(assigned ? Color.accentColor : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text((path as NSString).lastPathComponent).lineLimit(1)
                Text(Theme.shortFolder(path))
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.vertical, 2)
    }
}

struct ResolutionText: View {
    let resolution: Resolution

    var body: some View {
        switch resolution {
        case .unrouted:
            Label("No assignment: your normal (Default) login.", systemImage: "person.crop.circle")
        case .routed(let p, let route):
            Label("\(p.displayName) — via \(Theme.shortFolder(route.folder))", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .refused(let refusal):
            Label("Claude would refuse to start: \(refusal.message)", systemImage: "xmark.octagon.fill")
                .foregroundStyle(.red)
        }
    }
}
