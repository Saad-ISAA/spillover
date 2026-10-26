import SwiftUI
import SwitchboardCore

struct AccountsView: View {
    @EnvironmentObject var model: AppModel
    @State private var showingAdd = false

    var body: some View {
        Page(
            title: "Accounts",
            subtitle: "Each account is a separate Claude login. Assign folders to an account and every Claude session in that folder uses it."
        ) {
            if model.isFirstRun { GettingStarted(showingAdd: $showingAdd) }

            HStack {
                Button {
                    showingAdd = true
                } label: {
                    Label("Add account", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                if model.legacySetupExists {
                    Button("Import earlier setup") { model.importLegacy() }
                        .help("Adopt accounts and folders from ~/.aibar/routes.tsv")
                }
                Spacer()
            }

            ForEach(model.profiles) { p in
                AccountCard(profile: p)
            }
        }
        .sheet(isPresented: $showingAdd) { AddAccountSheet() }
    }
}

/// First-run checklist.
private struct GettingStarted: View {
    @EnvironmentObject var model: AppModel
    @Binding var showingAdd: Bool

    var body: some View {
        Card {
            Text("Getting started").font(.headline)
            step(1, "Add an account for each Claude subscription", done: model.profiles.count > 1) {
                Button("Add account") { showingAdd = true }
            }
            step(2, "Log in to each account (a Terminal window opens the official Claude login)",
                 done: model.profiles.filter { !$0.isDefault }.allSatisfy { model.statuses[$0.id]?.auth != nil } && model.profiles.count > 1) {
                EmptyView()
            }
            step(3, "Assign project folders to accounts", done: !model.routes.isEmpty) {
                Button("Go to Folders") { model.selectedSection = .folders }
            }
            step(4, "Connect VS Code so its Claude panel follows your folders", done: model.vscodeConnected) {
                Button("Go to Setup") { model.selectedSection = .setup }
            }
        }
    }

    private func step<A: View>(_ n: Int, _ text: String, done: Bool, @ViewBuilder action: () -> A) -> some View {
        HStack(spacing: 10) {
            Image(systemName: done ? "checkmark.circle.fill" : "\(n).circle")
                .foregroundStyle(done ? .green : .secondary)
                .font(.title3)
            Text(text).foregroundStyle(done ? .secondary : .primary)
            Spacer()
            if !done { action().controlSize(.small) }
        }
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
        Card {
            HStack(alignment: .top, spacing: 12) {
                AccountAvatar(profile: profile, size: 36)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        if renaming {
                            TextField("Name", text: $newName, onCommit: commitRename)
                                .textFieldStyle(.roundedBorder)
                                .frame(maxWidth: 220)
                        } else {
                            Text(profile.displayName).font(.title3.weight(.semibold))
                        }
                        if let plan = model.statuses[profile.id]?.auth?.planLabel { PlanBadge(text: plan) }
                        if profile.isDefault { PlanBadge(text: "Your normal login") }
                    }
                    LoginStatusLabel(status: model.statuses[profile.id]).font(.callout)
                    if let org = model.statuses[profile.id]?.auth?.orgName {
                        Text(org).font(.caption).foregroundStyle(.secondary)
                    }
                    Text(profile.configDir.map(Theme.shortFolder) ?? "~/.claude (Claude's default)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                }
                Spacer()
                actions
            }

            Divider()

            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Limits").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    UsageSummary(profile: profile)
                }
                .frame(maxWidth: 300, alignment: .leading)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Folders").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    let folders = model.folders(for: profile)
                    if folders.isEmpty {
                        Text(profile.isDefault ? "Every folder without an assignment." : "None yet")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(folders) { route in
                        Label(Theme.shortFolder(route.folder), systemImage: "folder")
                            .font(.callout)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer()
            }

            if !profile.isDefault {
                DisclosureGroup("Shared from your normal setup", isExpanded: $showSharing) {
                    SharingToggles(profile: profile)
                        .padding(.top, 6)
                }
                .font(.callout)
            }
        }
        .confirmationDialog(
            "Remove “\(profile.displayName)”?", isPresented: $confirmRemove, titleVisibility: .visible
        ) {
            Button("Remove account", role: .destructive) { model.remove(profile, deleteDirectory: false) }
            if profile.configDir?.contains("/.switchboard/profiles/") == true {
                Button("Remove account and its folder", role: .destructive) {
                    model.remove(profile, deleteDirectory: true)
                }
            }
        } message: {
            Text("Its folders go back to the Default account. The saved login stays in Keychain until you log out.")
        }
    }

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: 8) {
            switch model.statuses[profile.id] ?? .unknown {
            case .loggedIn:
                Menu("Account") {
                    Button("Log in again…") { model.logIn(profile) }
                    Button("Log out") { model.logOut(profile) }
                }
                .fixedSize()
            default:
                Button("Log in…") { model.logIn(profile) }
                    .buttonStyle(.borderedProminent)
            }
            if !profile.isDefault {
                Menu {
                    Button("Rename") {
                        newName = profile.displayName
                        renaming = true
                    }
                    if let dir = profile.configDir {
                        Button("Show folder in Finder") { model.revealInFinder(dir) }
                        Button("Open Terminal on this account") {
                            model.openShell(profile, in: NSHomeDirectory())
                        }
                    }
                    Divider()
                    Button("Remove…", role: .destructive) { confirmRemove = true }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
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
        VStack(alignment: .leading, spacing: 4) {
            Text("Linked items stay in sync with your normal ~/.claude. Logins, history and sessions are never shared.")
                .font(.caption)
                .foregroundStyle(.secondary)
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
        VStack(alignment: .leading, spacing: 16) {
            Text("Add a Claude account").font(.title2.weight(.semibold))
            Text("Give it a name you will recognise, such as “Work” or “Personal”.")
                .foregroundStyle(.secondary)
            TextField("Name", text: $name).textFieldStyle(.roundedBorder)

            Picker("", selection: $mode) {
                Text("New login").tag(0)
                Text("Existing config folder").tag(1)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if mode == 0 {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Reuse from your normal setup").font(.callout.weight(.medium))
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
                VStack(alignment: .leading, spacing: 6) {
                    Text("A folder you already use with CLAUDE_CONFIG_DIR. Its login is kept.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack {
                        TextField("/path/to/config", text: $existingDir).textFieldStyle(.roundedBorder)
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
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add") {
                    if mode == 0 {
                        model.createProfile(named: name, shareFromDefault: Array(shared), thenLogIn: logInNow)
                    } else {
                        model.adoptProfile(named: name, directory: existingDir)
                    }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || (mode == 1 && existingDir.isEmpty))
            }
        }
        .padding(24)
        .frame(width: 480)
    }
}
