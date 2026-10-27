import AppKit
import Foundation
import SwitchboardCore

/// A chat on its way to another account.
struct ChatMove: Equatable {
    enum Phase: Equatable {
        /// Waiting for the current reply to finish (a chat is never moved mid-turn).
        case waiting
        case switching
        case done
        /// The chat was closed before it could be reopened; it continues on the new account the
        /// next time it is opened.
        case closed
        case failed(String)
    }

    let conversationId: String
    let folder: String
    let toProfileId: String
    let automatic: Bool
    var phase: Phase
    var finishedAt: Date?

    var inProgress: Bool { phase == .waiting || phase == .switching }

    /// Automatic moves of the same chat are not retried for a while after one finished or failed.
    func blocksAutomaticRetry(now: Date) -> Bool {
        if inProgress { return true }
        guard let finishedAt else { return false }
        return now.timeIntervalSince(finishedAt) < 10 * 60
    }
}

/// A VS Code window as the app sees it: the folder its chats run in, and those chats.
struct OpenWindow: Identifiable {
    let folder: String
    var sessions: [SessionAssessment]
    var id: String { folder }
}

/// Moving chats between accounts. A move keeps the conversation: its transcript is copied to the
/// new account, the chat's process is ended at a turn boundary, and the editor reopens the
/// conversation, which the launcher now starts on the new account.
extension AppModel {
    /// Chats grouped by the folder that decides their account (the assigned folder, or the
    /// chat's own folder when nothing is assigned).
    var openWindows: [OpenWindow] {
        var order: [String] = []
        var groups: [String: [SessionAssessment]] = [:]
        for a in sessions {
            // Background helpers run Claude from temporary folders; they are not windows.
            guard let cwd = a.session.cwd, !Self.isTemporary(cwd) else { continue }
            var folder = cwd
            if case .routed(_, let route) = resolution(for: cwd) { folder = route.folder }
            if groups[folder] == nil { order.append(folder) }
            groups[folder, default: []].append(a)
        }
        return order.map { OpenWindow(folder: $0, sessions: groups[$0] ?? []) }
    }

    nonisolated static func isTemporary(_ path: String) -> Bool {
        ["/tmp/", "/private/tmp/", "/var/folders/", "/private/var/folders/"].contains { path.hasPrefix($0) }
            || path.hasPrefix(NSTemporaryDirectory())
    }

    /// Give a folder another account and move the chats already open in it.
    func switchWindow(folder: String, to profileId: String) {
        assign(folder: folder, to: profileId)
        moveStaleChats(inside: folder)
    }

    /// Restart one chat that is still on its old account.
    func restartOnAssignedAccount(_ a: SessionAssessment) {
        startMove(a, automatic: false)
    }

    /// Notification action "Move work to …": moves what runs on `from` without rewriting more
    /// assignments than the click implies. Folders assigned to `from` are reassigned; Auto folders
    /// keep Auto (their chats move because `from` ran low); folders pinned to a third account are
    /// left alone; open folders without an assignment that run on `from` get `to`.
    func moveWork(from: String, to: String) {
        var reassign: [String] = []
        var restartOnly: [String] = []
        for r in routes where r.profileId == from { reassign.append(r.folder) }
        for w in openWindows where w.sessions.contains(where: { $0.actualProfileId == from }) {
            switch resolution(for: w.folder) {
            case .unrouted where from == Profile.defaultID:
                reassign.append(w.folder)
            case .routed(_, let route) where route.profileId == Profile.autoID:
                restartOnly.append(w.folder)
            default:
                break
            }
        }
        for f in Set(reassign).sorted() { switchWindow(folder: f, to: to) }
        for f in Set(restartOnly).sorted() { moveStaleChats(inside: f) }
        if reassign.isEmpty && restartOnly.isEmpty {
            show(.info, "Nothing to move: no folder or open chat uses that account right now.")
        }
    }

    /// Auto folders: move open chats off an account that ran low, at their next idle moment.
    func autoMoveChatsIfNeeded() {
        guard autoPolicy.moveOpenChats else { return }
        for a in sessions {
            guard case .stale(let expected) = a.state, let cwd = a.session.cwd, a.session.editor != nil,
                let id = a.session.conversationId, moves[id]?.blocksAutomaticRetry(now: now) != true,
                case .routed(_, let route) = resolution(for: cwd), route.profileId == Profile.autoID,
                // Never move a chat onto an account that has no room either.
                !autoPolicy.isOutOfRoom(snapshots[expected], now: now)
            else { continue }
            startMove(a, automatic: true)
        }
    }

    /// Keeps Auto away from accounts that are not logged in.
    func syncAutoAvailability() {
        let loggedOut = profiles.filter { if case .loggedOut = statuses[$0.id] { return true } else { return false } }
            .map(\.id).sorted()
        guard loggedOut != autoPolicy.unavailable.sorted() else { return }
        updateAutoPolicy { $0.unavailable = loggedOut }
    }

    func updateAutoPolicy(_ change: (inout AutoPolicy) -> Void) {
        var policy = autoPolicy
        change(&policy)
        do {
            try AutoPolicyStore(env: env).save(policy)
            autoPolicy = policy
        } catch {
            show(.error, error.localizedDescription)
        }
    }

    /// Accounts in Auto's order of preference, for display.
    var autoOrder: [Profile] { autoPolicy.ordered(profiles) }

    func move(for a: SessionAssessment) -> ChatMove? {
        a.session.conversationId.flatMap { moves[$0] }
    }

    // MARK: The move itself

    private func moveStaleChats(inside folder: String) {
        let env = self.env
        Task.detached(priority: .userInitiated) {
            let scanner = SessionScanner(env: env)
            let assessed = scanner.assess(scanner.scan())
            await MainActor.run {
                self.sessions = assessed
                for a in assessed where self.isInside(a.session.cwd, folder: folder) {
                    if case .stale = a.state { self.startMove(a, automatic: false) }
                }
            }
        }
    }

    private func startMove(_ a: SessionAssessment, automatic: Bool) {
        guard case .stale(let expectedID) = a.state, let target = profile(id: expectedID) else { return }
        guard let cwd = a.session.cwd, let editor = a.session.editor else {
            if !automatic {
                show(.info, "Terminal chats keep their account until you start them again (claude -r continues the last one).")
            }
            return
        }
        // The extension's side of a move: chats resumed by id, and a link that reopens one.
        guard let id = a.session.conversationId, let reopen = editor.claudeSessionURL(id),
            contracts[editor]?.reopensChats != false
        else {
            if !automatic {
                show(.info, "This version of the Claude extension cannot reopen a chat for Switchboard. Reload the \(Fmt.folderName(cwd)) window instead: its chats restart on the new account with their history.")
            }
            return
        }
        if moves[id]?.inProgress == true { return }
        // Without the launcher in the editor, a reopened chat would not change account.
        guard editorStatus[editor] == .installed else {
            if !automatic { show(.error, "Connect \(editor.displayName) under Setup first; until then its chats cannot change account.") }
            return
        }
        if case .loggedOut = statuses[target.id] {
            if !automatic { show(.error, "\(target.displayName) is not logged in. Log in under Accounts first.") }
            return
        }
        guard let source = a.actualProfileId.flatMap({ profile(id: $0) }) else { return }
        moves[id] = ChatMove(conversationId: id, folder: cwd, toProfileId: target.id, automatic: automatic, phase: .waiting)

        let env = self.env
        let profiles = self.profiles
        let session = a.session
        Task.detached(priority: .userInitiated) {
            let conversations = ConversationStore(env: env)
            do {
                // Wait for a turn boundary, copy, and check again right before ending the process:
                // a prompt sent during the copy would otherwise be cut off.
                var ready = false
                let deadline = Date().addingTimeInterval(15 * 60)
                while Date() < deadline {
                    guard let transcript = conversations.transcript(id: id, cwd: cwd, in: source) else {
                        throw MoveFailure.transcriptMissing
                    }
                    if Self.isReady(transcript, acceptStalled: !automatic) {
                        try conversations.ensure(id: id, cwd: cwd, target: target, among: profiles)
                        if Self.isReady(transcript, acceptStalled: !automatic) {
                            ready = true
                            break
                        }
                    }
                    try await Task.sleep(nanoseconds: 2_000_000_000)
                }
                guard ready else { throw MoveFailure.stillBusy }

                await MainActor.run { self.moves[id]?.phase = .switching }
                do {
                    try SessionControl.end(session)
                } catch SessionControl.EndError.notTheSameSession {
                    // The chat was closed meanwhile: the copy is in place, nothing else to do.
                    await MainActor.run { self.finishMove(id, .closed, target: target, folder: cwd) }
                    return
                }
                for _ in 0..<25 where SessionControl.isRunning(session.pid) {
                    try? await Task.sleep(nanoseconds: 200_000_000)
                }
                await MainActor.run {
                    // Bring the chat's window forward, then ask the extension to reopen the chat.
                    try? self.service.open(folder: cwd, in: editor)
                }
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                await MainActor.run { _ = NSWorkspace.shared.open(reopen) }

                // Report what really happened: the chat back on the target account, or not.
                let outcome = await Self.confirmReopened(id: id, on: target, env: env)
                await MainActor.run { self.finishMove(id, outcome, target: target, folder: cwd) }
            } catch {
                await MainActor.run {
                    self.finishMove(id, .failed(error.localizedDescription), target: target, folder: cwd)
                }
            }
        }
    }

    private func finishMove(_ id: String, _ phase: ChatMove.Phase, target: Profile, folder: String) {
        moves[id]?.phase = phase
        moves[id]?.finishedAt = Date()
        let name = Fmt.folderName(folder)
        switch phase {
        case .done:
            show(.success, "\(name) chat moved to \(target.displayName) with its history.")
        case .closed:
            show(.info, "The \(name) chat was closed. It continues on \(target.displayName), with its history, when you reopen it.")
        case .failed(let why):
            show(.error, "Could not move the \(name) chat: \(why)")
        default:
            break
        }
        refreshSessions()
    }

    nonisolated private static func isReady(_ transcript: URL, acceptStalled: Bool) -> Bool {
        switch ConversationActivity.state(transcript: transcript) {
        case .idle: return true
        case .stalled: return acceptStalled
        case .busy: return false
        }
    }

    /// Looks for the conversation running again, for up to 20 seconds.
    nonisolated private static func confirmReopened(id: String, on target: Profile, env: SBEnvironment) async -> ChatMove.Phase {
        let profiles = (try? ProfileStore(env: env).all()) ?? []
        for _ in 0..<20 {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard let s = SessionScanner(env: env).scan().first(where: { $0.conversationId == id }) else { continue }
            let actual = SessionScanner.profileId(for: s, profiles: profiles, caseInsensitive: env.caseInsensitivePaths)
            if actual == target.id { return .done }
            return .failed("it reopened on \(actual ?? "an unknown account") instead. Is the editor connected under Setup?")
        }
        return .closed
    }

    private func isInside(_ cwd: String?, folder: String) -> Bool {
        guard let cwd,
            let c = PathNormalizer.normalize(cwd, caseInsensitive: env.caseInsensitivePaths)?.key,
            let f = PathNormalizer.normalize(folder, caseInsensitive: env.caseInsensitivePaths)?.key
        else { return false }
        return c == f || c.hasPrefix(f.hasSuffix("/") ? f : f + "/")
    }
}

enum MoveFailure: Error, LocalizedError {
    case stillBusy
    case transcriptMissing

    var errorDescription: String? {
        switch self {
        case .stillBusy:
            return "the chat was still working after 15 minutes. It keeps its current account; try again when it is idle."
        case .transcriptMissing:
            return "its conversation file was not found, so it was left running on its current account."
        }
    }
}
