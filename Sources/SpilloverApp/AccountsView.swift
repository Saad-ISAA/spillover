import SwiftUI
import SpilloverCore

struct AccountsView: View {
    @EnvironmentObject var model: AppModel
    @State private var showingAdd = false

    var body: some View {
        Page(
            title: "Accounts",
            subtitle: "Each account is a separate Claude login. Folders assigned to an account start every Claude session there."
        ) {
            Button {
                showingAdd = true
            } label: {
                Label("Add account", systemImage: "plus")
            }
            .buttonStyle(PrimaryButtonStyle())
        } content: {
            if model.isFirstRun { GettingStarted(showingAdd: $showingAdd) }
            VStack(spacing: 16) {
                ForEach(model.profiles) { p in
                    AccountCard(profile: p)
                }
            }
        }
        .sheet(isPresented: $showingAdd) { AddAccountSheet() }
    }
}

/// First-run checklist with real progress.
private struct GettingStarted: View {
    @EnvironmentObject var model: AppModel
    @Binding var showingAdd: Bool

    var body: some View {
        let steps = [
            done1, done2, !model.routes.isEmpty, model.vscodeConnected,
        ]
        let complete = steps.filter { $0 }.count
        Panel(padding: 20) {
            HStack(alignment: .firstTextBaseline) {
                Text("Getting started").font(TypeScale.section).foregroundStyle(Ink.text)
                Spacer()
                Text("\(complete) of 4 done").font(TypeScale.meta.monospacedDigit()).foregroundStyle(Ink.muted)
            }
            MeterBar(percent: Double(complete) / 4 * 100, height: 4)
            VStack(spacing: 0) {
                step(1, "Add an account for each Claude subscription", done: done1) {
                    Button("Add account") { showingAdd = true }.buttonStyle(QuietButtonStyle())
                }
                Rule()
                step(2, "Log in to each account. A Terminal window opens the official Claude login.", done: done2) { EmptyView() }
                Rule()
                step(3, "Assign project folders to accounts", done: !model.routes.isEmpty) {
                    Button("Go to Folders") { model.selectedSection = .folders }.buttonStyle(QuietButtonStyle())
                }
                Rule()
                step(4, "Connect VS Code so its Claude panel follows your folders", done: model.vscodeConnected) {
                    Button("Go to Setup") { model.selectedSection = .setup }.buttonStyle(QuietButtonStyle())
                }
            }
        }
    }

    private var done1: Bool { model.profiles.count > 1 }
    private var done2: Bool {
        model.profiles.count > 1 && model.profiles.filter { !$0.isDefault }.allSatisfy { model.statuses[$0.id]?.auth != nil }
    }

    private func step<A: View>(_ n: Int, _ text: String, done: Bool, @ViewBuilder action: () -> A) -> some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().strokeBorder(done ? Ink.positive : Ink.border, lineWidth: 1.5).frame(width: 22, height: 22)
                if done {
                    Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Ink.positive)
                } else {
                    Text("\(n)").font(TypeScale.figure(11)).foregroundStyle(Ink.muted)
                }
            }
            Text(text).font(TypeScale.body).foregroundStyle(done ? Ink.muted : Ink.text)
            Spacer()
            if !done { action() }
        }
        .padding(.vertical, 10)
    }
}

private struct AccountCard: View {
    @EnvironmentObject var model: AppModel
    let profile: Profile
    @State private var renaming = false
    @State private var newName = ""
    @State private var confirmRemove = false
    @State private var showSharing = false

    var body: some View {
        Panel(padding: 20) {
            HStack(alignment: .top, spacing: 14) {
                Monogram(profile: profile, size: 40)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        if renaming {
                            TextField("Name", text: $newName, onCommit: commitRename)
                                .textFieldStyle(.spillover)
                                .frame(maxWidth: 220)
                        } else {
                            Text(profile.displayName).font(.system(size: 17, weight: .semibold)).foregroundStyle(Ink.text)
                        }
                        if let plan = model.statuses[profile.id]?.auth?.planLabel { Pill(text: plan) }
                        if profile.isDefault { Pill(text: "Your normal login") }
                    }
                    LoginState(status: model.statuses[profile.id])
                    HStack(spacing: 6) {
                        if let org = model.statuses[profile.id]?.auth?.orgName {
                            Text(org).font(TypeScale.meta).foregroundStyle(Ink.muted)
                            Text("·").foregroundStyle(Ink.faint)
                        }
                        Text(profile.configDir.map(Fmt.shortFolder) ?? "~/.claude (Claude's default)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Ink.faint)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                            .help(profile.configDir ?? "~/.claude")
                    }
                }
                Spacer()
                actions
            }

            Rule()

            HStack(alignment: .top, spacing: 32) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Limits").font(TypeScale.metaStrong).foregroundStyle(Ink.muted)
                    limitRow(.fiveHour, "Session")
                    limitRow(.sevenDay, "Week")
                    if let s = model.snapshots[profile.id] {
                        Text("Reported \(Fmt.relative(s.capturedAt, now: model.now))").font(TypeScale.meta).foregroundStyle(Ink.faint)
                    } else {
                        Text(model.checkingLimits.contains(profile.id) ? "Checking this account's limits…" : "No limits reported yet.")
                            .font(TypeScale.meta).foregroundStyle(Ink.faint)
                    }
                }
                .frame(width: 280, alignment: .leading)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Folders").font(TypeScale.metaStrong).foregroundStyle(Ink.muted)
                    let folders = model.folders(for: profile)
                    if folders.isEmpty {
                        Text(profile.isDefault ? "Every folder without an assignment." : "None yet. Assign one under Folders.")
                            .font(TypeScale.body)
                            .foregroundStyle(Ink.muted)
                    }
                    ForEach(folders) { route in
                        HStack(spacing: 6) {
                            Image(systemName: "folder").font(.system(size: 11)).foregroundStyle(Ink.faint)
                            Text(Fmt.shortFolder(route.folder)).font(TypeScale.body).foregroundStyle(Ink.text)
                                .lineLimit(1).truncationMode(.middle)
                        }
                    }
                }
                Spacer(minLength: 0)
            }

            if !profile.isDefault {
                DisclosureGroup(isExpanded: $showSharing) {
                    SharingToggles(profile: profile).padding(.top, 8)
                } label: {
                    Text("Shared from your normal setup").font(TypeScale.body).foregroundStyle(Ink.muted)
                }
            }
        }
        .confirmationDialog(
            "Remove “\(profile.displayName)”?", isPresented: $confirmRemove, titleVisibility: .visible
        ) {
            Button("Remove account", role: .destructive) { model.remove(profile, deleteDirectory: false) }
            if profile.configDir?.contains("/.spillover/profiles/") == true {
                Button("Remove account and its folder", role: .destructive) {
                    model.remove(profile, deleteDirectory: true)
                }
            }
        } message: {
            Text("Its folders go back to \(model.defaultName). The saved login stays in Keychain until you log out.")
        }
    }

    private func limitRow(_ kind: UsageWindow.Kind, _ label: String) -> some View {
        let w = model.window(kind, for: profile)
        let pct = w?.effectivePercentage(at: model.now)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(label).font(TypeScale.body).foregroundStyle(Ink.text)
                Spacer()
                Text(pct.map(Fmt.percent) ?? "–").font(TypeScale.figure(13)).foregroundStyle(Ink.text)
                if let w {
                    Text((pct ?? 0) > 0 ? "resets \(Fmt.moment(w.resetsAt, now: model.now))" : "not started")
                        .font(TypeScale.meta.monospacedDigit()).foregroundStyle(Ink.faint)
                }
            }
            MeterBar(percent: pct, paceFraction: model.forecast(kind, for: profile)?.elapsedFraction, height: 4)
        }
    }

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: 8) {
            switch model.statuses[profile.id] ?? .unknown {
            case .loggedIn:
                Dropdown(title: "Login", look: .chip) {
                    [.action("Log in again…") { model.logIn(profile) }, .action("Log out") { model.logOut(profile) }]
                }
            default:
                Button("Log in…") { model.logIn(profile) }
                    .buttonStyle(PrimaryButtonStyle())
            }
            Dropdown(title: "More", look: .icon("ellipsis")) {
                var items: [DropdownItem] = [
                    .action("Rename") {
                        newName = profile.displayName
                        renaming = true
                    },
                    .action("Show folder in Finder") {
                        model.revealInFinder(profile.configDir ?? model.env.paths.defaultClaudeDir.path)
                    },
                ]
                if !profile.isDefault {
                    items.append(.action("Open Terminal on this account") {
                        model.openShell(profile, in: NSHomeDirectory())
                    })
                    items.append(.divider)
                    items.append(.action("Remove…") { confirmRemove = true })
                }
                return items
            }
        }
    }

    private func commitRename() {
        renaming = false
        let name = newName.trimmingCharacters(in: .whitespaces)
        if !name.isEmpty && name != profile.displayName { model.rename(profile, to: name) }
    }
}

/// Toggles for linking skills/settings/etc. from the Default profile.
private struct SharingToggles: View {
    @EnvironmentObject var model: AppModel
    let profile: Profile

    var body: some View {
        let sharing = ProfileSharing(env: model.env)
        VStack(alignment: .leading, spacing: 8) {
            Text("Linked items stay in sync with your normal ~/.claude. Logins, history and sessions are never shared.")
                .font(TypeScale.meta)
                .foregroundStyle(Ink.muted)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), alignment: .leading)], alignment: .leading) {
                ForEach(ProfileSharing.shareable, id: \.self) { item in
                    let state = sharing.state(of: item, in: profile)
                    let available = sharing.state(of: item, in: .builtInDefault()) != .absent
                    Toggle(
                        item,
                        isOn: Binding(
                            get: { if case .linked = state { return true } else { return false } },
                            set: { model.share(item, into: profile, enabled: $0) }))
                    .toggleStyle(.checkbox)
                    .font(TypeScale.body)
                    .disabled(!available)
                    .help(available ? (state == .local ? "This account has its own copy; linking keeps a backup of it." : "") : "Not present in ~/.claude")
                }
            }
        }
    }
}

struct AddAccountSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var mode = 0
    @State private var existingDir = ""
    @State private var shared: Set<String> = ["skills", "commands", "agents", "CLAUDE.md", "plugins", "hooks"]
    @State private var logInNow = true

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Add a Claude account").font(TypeScale.title).foregroundStyle(Ink.text)
                Text("Give it a name you will recognise, such as “Work” or “Personal”.")
                    .font(TypeScale.body)
                    .foregroundStyle(Ink.muted)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Name").font(TypeScale.bodyStrong).foregroundStyle(Ink.text)
                TextField("Work", text: $name).textFieldStyle(.spillover)
            }

            Segmented(options: [(0, "New login"), (1, "Existing config folder")], selection: $mode)

            if mode == 0 {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Reuse from your normal setup").font(TypeScale.bodyStrong).foregroundStyle(Ink.text)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), alignment: .leading)], alignment: .leading) {
                        ForEach(ProfileSharing.shareable, id: \.self) { item in
                            Toggle(item, isOn: Binding(
                                get: { shared.contains(item) },
                                set: { if $0 { shared.insert(item) } else { shared.remove(item) } }))
                            .toggleStyle(.checkbox)
                        }
                    }
                    Toggle("Open the login now", isOn: $logInNow)
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("A folder you already use with CLAUDE_CONFIG_DIR. Its login is kept.")
                        .font(TypeScale.meta)
                        .foregroundStyle(Ink.muted)
                    HStack {
                        TextField("/path/to/config", text: $existingDir).textFieldStyle(.spillover)
                        Button("Choose…") {
                            let panel = NSOpenPanel()
                            panel.canChooseDirectories = true
                            panel.canChooseFiles = false
                            panel.showsHiddenFiles = true
                            if panel.runModal() == .OK, let p = panel.url?.path { existingDir = p }
                        }
                    }
                }
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(QuietButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button("Add account") {
                    if mode == 0 {
                        model.createProfile(named: name, shareFromDefault: Array(shared), thenLogIn: logInNow)
                    } else {
                        model.adoptProfile(named: name, directory: existingDir)
                    }
                    dismiss()
                }
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || (mode == 1 && existingDir.isEmpty))
            }
        }
        .padding(24)
        .frame(width: 480)
        .background(Ink.sheet)
    }
}
