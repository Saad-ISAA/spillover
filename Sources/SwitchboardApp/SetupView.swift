import SwiftUI
import SwitchboardCore

struct SetupView: View {
    @EnvironmentObject var model: AppModel
    @State private var confirmUndo = false
    @State private var replaceTarget: Editor?

    var body: some View {
        Page(
            title: "Setup",
            subtitle: "Connect the tools that start Claude. Every change is backed up and can be undone here."
        ) {
            Card {
                Label("Editors", systemImage: "chevron.left.forwardslash.chevron.right").font(.headline)
                Text("Switchboard sets one user setting, claudeCode.claudeProcessWrapper, so every new Claude chat in the editor starts in the account assigned to its folder. Your other settings are not touched, and a backup is kept.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                let editors = Editor.allCases.filter { model.editorStatus[$0] != .editorNotFound }
                if editors.isEmpty {
                    Text("No VS Code family editor found on this Mac.").foregroundStyle(.secondary)
                }
                ForEach(editors, id: \.self) { editor in
                    EditorRow(editor: editor, replaceTarget: $replaceTarget)
                }
                Text("After connecting, start a new Claude chat (or reload the window). Chats that are already open keep their account.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Card {
                HStack {
                    Label("Terminals", systemImage: "terminal").font(.headline)
                    Spacer()
                    Toggle("", isOn: Binding(get: { model.shellConnected }, set: { model.setShell(connected: $0) }))
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
                Text("Adds a small block to ~/.zshrc that puts Switchboard's `claude` first on your PATH, so `claude` in any terminal (including VS Code's) uses the folder's account. Applies to new terminal windows.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Card {
                Label("Usage tracking", systemImage: "chart.bar").font(.headline)
                Text("Turn on “Track limits” per account on the Usage page.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button("Open Usage") { model.selectedSection = .usage }
            }

            Card {
                Label("Helpers", systemImage: "shippingbox").font(.headline)
                HStack {
                    Image(systemName: model.launcherInstalled ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(model.launcherInstalled ? .green : .secondary)
                    Text(model.launcherInstalled ? "Installed in ~/.switchboard/bin" : "Installed automatically when you connect something")
                }
                Text("Emergency switch: set SWITCHBOARD_BYPASS=1 to run Claude without any routing.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Card {
                Label("Undo everything", systemImage: "arrow.uturn.backward.circle").font(.headline)
                Text("Restores your editor settings and ~/.zshrc, turns off usage tracking, and removes the helpers. Your accounts, their logins and your folder assignments are kept.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button("Undo all changes…", role: .destructive) { confirmUndo = true }
            }
        }
        .confirmationDialog("Undo every change Switchboard made?", isPresented: $confirmUndo, titleVisibility: .visible) {
            Button("Undo all changes", role: .destructive) { model.uninstallEverything() }
        }
        .confirmationDialog(
            "Replace the existing wrapper?", isPresented: Binding(get: { replaceTarget != nil }, set: { if !$0 { replaceTarget = nil } }),
            titleVisibility: .visible
        ) {
            Button("Replace (restored when you disconnect)", role: .destructive) {
                if let e = replaceTarget { model.connect(editor: e, force: true) }
                replaceTarget = nil
            }
        } message: {
            Text("Another tool already set claudeCode.claudeProcessWrapper. Switchboard will remember it and put it back if you disconnect.")
        }
    }
}

private struct EditorRow: View {
    @EnvironmentObject var model: AppModel
    let editor: Editor
    @Binding var replaceTarget: Editor?

    var body: some View {
        HStack {
            Text(editor.displayName)
            Spacer()
            switch model.editorStatus[editor] ?? .notInstalled {
            case .installed:
                Label("Connected", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                Button("Disconnect") { model.disconnect(editor: editor) }
            case .notInstalled:
                Button("Connect") { model.connect(editor: editor) }.buttonStyle(.borderedProminent)
            case .otherWrapper(let value):
                Label("Another wrapper set", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help(value)
                Button("Replace…") { replaceTarget = editor }
            case .editorNotFound:
                Text("Not found").foregroundStyle(.secondary)
            }
        }
    }
}
