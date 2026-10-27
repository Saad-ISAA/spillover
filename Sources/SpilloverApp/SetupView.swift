import SwiftUI
import SpilloverCore

struct SetupView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var prefs: Preferences
    @State private var confirmUndo = false
    @State private var replaceTarget: Editor?

    var body: some View {
        Page(
            title: "Setup",
            subtitle: "Connect the tools that start Claude. Every change is backed up and can be undone here."
        ) {
            settingRow(
                "Editors",
                "Sets one user setting, claudeCode.claudeProcessWrapper, so every new Claude chat starts in the account assigned to its folder. Nothing else is touched, and a backup is kept."
            ) {
                let editors = Editor.allCases.filter { model.editorStatus[$0] != .editorNotFound }
                VStack(spacing: 0) {
                    if editors.isEmpty {
                        Text("No VS Code family editor found on this Mac.").font(TypeScale.body).foregroundStyle(Ink.muted)
                    }
                    ForEach(Array(editors.enumerated()), id: \.element) { i, editor in
                        if i > 0 { Rule() }
                        EditorRow(editor: editor, replaceTarget: $replaceTarget)
                    }
                }
                Text("After connecting, start a new Claude chat (or reload the window). Open chats keep their account.")
                    .font(TypeScale.meta)
                    .foregroundStyle(Ink.faint)
            }

            settingRow(
                "Terminals",
                "Adds a small block to ~/.zshrc that puts Spillover's claude first on your PATH, so claude in any terminal, including VS Code's, uses the folder's account."
            ) {
                switchLine("Route claude in new terminal windows", isOn: Binding(get: { model.shellConnected }, set: { model.setShell(connected: $0) }))
            }

            settingRow(
                "Auto",
                "Folders set to Auto start new chats on the first account below the threshold. Open chats move when their account runs low, after their current reply, with their history."
            ) {
                AutoSettings()
            }

            settingRow("Limit tracking", "Each account records its limits through its Claude statusline. Your own statusline keeps working.") {
                VStack(spacing: 0) {
                    ForEach(Array(model.profiles.enumerated()), id: \.element.id) { i, p in
                        if i > 0 { Rule() }
                        HStack(spacing: 10) {
                            Monogram(profile: p, size: 20)
                            Text(p.displayName).font(TypeScale.body).foregroundStyle(Ink.text)
                            Spacer()
                            Toggle("", isOn: Binding(get: { model.statuslineOn[p.id] ?? false }, set: { model.setStatusline(p, on: $0) }))
                                .toggleStyle(.switch)
                                .controlSize(.small)
                                .labelsHidden()
                        }
                        .padding(.vertical, 8)
                    }
                }
            }

            settingRow("Preferences", "How Spillover behaves on this Mac.") {
                VStack(spacing: 0) {
                    switchLine("Open Spillover at login", isOn: Binding(
                        get: { prefs.openAtLogin },
                        set: { on in
                            do { try prefs.setOpenAtLogin(on) } catch { model.show(.error, error.localizedDescription) }
                        }))
                    .disabled(!Preferences.isBundled)
                    Rule()
                    switchLine("Notify me at 80% and 95% of a limit", isOn: $prefs.notifyNearLimit)
                        .disabled(!Preferences.isBundled)
                    Rule()
                    switchLine("Show the fullest limit next to the menu bar icon", isOn: $prefs.showPercentInMenuBar)
                    Rule()
                    switchLine("Keep Spillover in the Dock when its window is closed", isOn: $prefs.alwaysInDock)
                }
                if !Preferences.isBundled {
                    Text("Login item and notifications need the app bundle (scripts/build-app.sh).")
                        .font(TypeScale.meta)
                        .foregroundStyle(Ink.faint)
                }
            }

            settingRow("Helpers", "Small programs Spillover runs in place of claude.") {
                HStack(spacing: 6) {
                    StatusDot(tone: model.launcherInstalled ? .positive : .neutral)
                    Text(model.launcherInstalled ? "Installed in ~/.spillover/bin" : "Installed automatically when you connect something")
                        .font(TypeScale.body)
                        .foregroundStyle(Ink.text)
                }
                Text("Emergency switch: set SPILLOVER_BYPASS=1 to run Claude without any routing.")
                    .font(TypeScale.meta)
                    .foregroundStyle(Ink.faint)
            }

            settingRow(
                "Undo everything",
                "Restores your editor settings and ~/.zshrc, turns off limit tracking and removes the helpers. Accounts, their logins and folder assignments are kept."
            ) {
                Button("Undo all changes…") { confirmUndo = true }
                    .buttonStyle(QuietButtonStyle(tone: .negative))
            }
        }
        .confirmationDialog("Undo every change Spillover made?", isPresented: $confirmUndo, titleVisibility: .visible) {
            Button("Undo all changes", role: .destructive) { model.uninstallEverything() }
        } message: {
            Text("Editor settings and ~/.zshrc go back to how they were. Accounts and folder assignments stay.")
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
            Text("Another tool already set claudeCode.claudeProcessWrapper. Spillover will remember it and put it back if you disconnect.")
        }
    }

    /// A settings row: title and description on the left, the controls on the right.
    private func settingRow<C: View>(_ title: String, _ detail: String, @ViewBuilder controls: () -> C) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 32) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(TypeScale.section).foregroundStyle(Ink.text)
                    Text(detail).font(TypeScale.meta).foregroundStyle(Ink.muted).fixedSize(horizontal: false, vertical: true)
                }
                .frame(width: 260, alignment: .leading)
                VStack(alignment: .leading, spacing: 10) { controls() }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(Ink.raised, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .padding(.bottom, 24)
            Rule()
        }
    }

    private func switchLine(_ label: String, isOn: Binding<Bool>) -> some View {
        HStack {
            Text(label).font(TypeScale.body).foregroundStyle(Ink.text)
            Spacer()
            Toggle("", isOn: isOn).toggleStyle(.switch).controlSize(.small).labelsHidden()
        }
        .padding(.vertical, 8)
    }
}

private struct EditorRow: View {
    @EnvironmentObject var model: AppModel
    let editor: Editor
    @Binding var replaceTarget: Editor?

    @ViewBuilder
    private var contractLine: some View {
        if let c = model.contracts[editor] {
            switch c.finding {
            case .extensionNotFound:
                Text("Claude extension not installed").font(TypeScale.meta).foregroundStyle(Ink.faint)
            case .wrapperSettingMissing:
                Text("Claude \(c.extensionVersion ?? "") no longer offers the wrapper setting: routing stops")
                    .font(TypeScale.meta).foregroundStyle(Ink.negative)
            default:
                Text("Claude \(c.extensionVersion ?? "") · " + (c.reopensChats ? "open chats can move" : "open chats move on window reload"))
                    .font(TypeScale.meta).foregroundStyle(c.reopensChats ? Ink.faint : Ink.warning)
            }
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            AppIconView(editor: editor, size: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(editor.displayName).font(TypeScale.body).foregroundStyle(Ink.text)
                contractLine
            }
            Spacer()
            switch model.editorStatus[editor] ?? .notInstalled {
            case .installed:
                Pill(text: "Connected", tone: .positive)
                Button("Disconnect") { model.disconnect(editor: editor) }.buttonStyle(QuietButtonStyle())
            case .notInstalled:
                Button("Connect") { model.connect(editor: editor) }.buttonStyle(PrimaryButtonStyle())
            case .otherWrapper(let value):
                Pill(text: "Another wrapper set", tone: .warning).help(value)
                Button("Replace…") { replaceTarget = editor }.buttonStyle(QuietButtonStyle())
            case .editorNotFound:
                Text("Not found").font(TypeScale.meta).foregroundStyle(Ink.faint)
            }
        }
        .padding(.vertical, 8)
    }
}

private struct AutoSettings: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let order = model.autoOrder
        VStack(alignment: .leading, spacing: 0) {
            Text("Order of preference").font(TypeScale.metaStrong).foregroundStyle(Ink.muted).padding(.bottom, 4)
            ForEach(Array(order.enumerated()), id: \.element.id) { i, p in
                if i > 0 { Rule() }
                HStack(spacing: 10) {
                    Text("\(i + 1)").font(TypeScale.figure(11)).foregroundStyle(Ink.faint).frame(width: 14)
                    Monogram(profile: p, size: 20)
                    Text(p.displayName).font(TypeScale.body).foregroundStyle(Ink.text)
                    Spacer()
                    if model.autoPolicy.unavailable.contains(p.id) {
                        Pill(text: "Not logged in, skipped", tone: .warning)
                    } else if let peak = model.snapshots[p.id]?.peakPercentage(at: model.now) {
                        Text(Fmt.percent(peak)).font(TypeScale.meta.monospacedDigit())
                            .foregroundStyle(model.autoPolicy.isOutOfRoom(model.snapshots[p.id], now: model.now) ? Ink.warning : Ink.faint)
                    }
                    IconButton(systemName: "chevron.up", help: "Prefer \(p.displayName) earlier") { move(i, by: -1) }
                        .disabled(i == 0)
                    IconButton(systemName: "chevron.down", help: "Prefer \(p.displayName) later") { move(i, by: 1) }
                        .disabled(i == order.count - 1)
                }
                .padding(.vertical, 4)
            }
        }
        Rule()
        HStack {
            Text("Move on when an account reaches").font(TypeScale.body).foregroundStyle(Ink.text)
            Spacer()
            Segmented(
                options: [(80, "80%"), (90, "90%"), (95, "95%")],
                selection: Binding(
                    get: { Int(model.autoPolicy.threshold) },
                    set: { v in model.updateAutoPolicy { $0.threshold = Double(v) } }))
        }
        Text("Also when its limit is forecast to run out within \(Int(model.autoPolicy.runOutMinutes)) minutes.")
            .font(TypeScale.meta).foregroundStyle(Ink.faint)
        HStack {
            Text("Move open chats automatically").font(TypeScale.body).foregroundStyle(Ink.text)
            Spacer()
            Toggle("", isOn: Binding(
                get: { model.autoPolicy.moveOpenChats },
                set: { v in model.updateAutoPolicy { $0.moveOpenChats = v } }))
            .toggleStyle(.switch).controlSize(.small).labelsHidden()
        }
        Text("The first time a chat is reopened, VS Code asks whether Claude Code may open the link. Tick “Do not ask me again” so later moves need no click.")
            .font(TypeScale.meta).foregroundStyle(Ink.faint)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func move(_ index: Int, by delta: Int) {
        var ids = model.autoOrder.map(\.id)
        let j = index + delta
        guard ids.indices.contains(j) else { return }
        ids.swapAt(index, j)
        model.updateAutoPolicy { $0.order = ids }
    }
}
