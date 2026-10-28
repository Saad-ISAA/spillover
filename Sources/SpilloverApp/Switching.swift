import AppKit
import Foundation
import SpilloverCore

/// A chat on its way to another account.
struct ChatMove: Equatable {
    enum Phase: Equatable {
        /// Waiting for the current reply to finish (a chat is never moved mid-turn).
        case waiting
        case switching
        case done
        /// Moved with background work running: that work stopped with the old process, and the
        /// chat was resumed on the new account to pick it up again.
        case resumed
        /// The chat was closed before it could be ended; it continues on the new account the
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
/// new account and the chat's process is ended at a turn boundary with no background task
/// running; the chat stays in its panel and its next message starts it on the new account.
extension AppModel {
    /// Chats grouped by the folder that decides their account (the assigned folder, or the
    /// chat's own folder when nothing is assigned).
    var openWindows: [OpenWindow] {
        var order: [String] = []
        var groups: [String: [SessionAssessment]] = [:]
        for a in sessions {
            // Background helpers run Claude from temporary folders; they are not windows.
            guard let cwd = a.session.cwd, a.state != .background else { continue }
            var folder = cwd
            if case .routed(_, let route) = resolution(for: cwd) { folder = route.folder }
            if groups[folder] == nil { order.append(folder) }
            groups[folder, default: []].append(a)
        }
        return order.map { OpenWindow(folder: $0, sessions: groups[$0] ?? []) }
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
        for a in sessions where !a.session.resumedBySpillover {
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

    /// Stop a chat Spillover resumed in the background, so it can continue in the editor. Its
    /// background tasks stop with it; the chat can be asked to pick them up again there.
    func takeOver(_ a: SessionAssessment) {
        guard a.session.resumedBySpillover else { return }
        do {
            try SessionControl.end(a.session)
            let name = a.session.cwd.map(Fmt.folderName) ?? "That"
            show(.info, "\(name) chat stopped in the background. Continue it in VS Code; its background work stopped too, so ask it to pick that up again.")
        } catch {
            show(.error, error.localizedDescription)
        }
        refreshSessions()
    }

    /// Tells when a chat resumed in the background has finished and can be opened in the editor.
    func noteFinishedResumedRuns(before: [SessionAssessment], now: [SessionAssessment]) {
        let running = Set(now.map(\.session.pid))
        for a in before where a.session.resumedBySpillover && !running.contains(a.session.pid) {
            let name = a.session.cwd.map(Fmt.folderName) ?? "A"
            show(.success, "\(name) chat finished its background work. Continue it in VS Code: its next message picks up where it left off.")
        }
    }

    func move(for a: SessionAssessment) -> ChatMove? {
        a.session.conversationId.flatMap { moves[$0] }
    }

    // MARK: The move itself

    private func moveStaleChats(inside folder: String) {
        let env = self.env
        Task.detached(priority: .userInitiated) {
            let scanner = SessionScanner(env: env)
            let assessed = scanner.assess(DemoSessions.load(env) ?? scanner.scan())
            await MainActor.run {
                self.sessions = assessed
                for a in assessed where self.isInside(a.session.cwd, folder: folder) {
                    if case .stale = a.state { self.startMove(a, automatic: false) }
                }
            }
        }
    }

    private func startMove(_ a: SessionAssessment, automatic: Bool) {
        guard !DemoSessions.isActive(env), !a.session.resumedBySpillover else { return }
        guard case .stale(let expectedID) = a.state, let target = profile(id: expectedID) else { return }
        guard let cwd = a.session.cwd, let editor = a.session.editor else {
            if !automatic {
                show(.info, "Terminal chats keep their account until you start them again (claude -r continues the last one).")
            }
            return
        }
        // The extension resumes a chat by its id when its next message is sent.
        guard let id = a.session.conversationId else {
            if !automatic {
                show(.info, "Reload the \(Fmt.folderName(cwd)) window instead: its chats restart on the new account with their history.")
            }
            return
        }
        if moves[id]?.inProgress == true { return }
        // Without the launcher in the editor, a restarted chat would not change account.
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
                // Background tasks (subagents, background commands) live in the chat's process and
                // stop with it. A manual move waits for them. An automatic move (the account is
                // full) does not: it ends the chat at the turn boundary and resumes it on the new
                // account, which restarts that work there.
                var ready = false
                var hadBackgroundWork = false
                let deadline = Date().addingTimeInterval(automatic ? 6 * 3600 : 15 * 60)
                while Date() < deadline {
                    // An automatic move is dropped once the chat's account has room again.
                    if automatic, !(await MainActor.run { self.isStillBehind(session.pid) }) {
                        await MainActor.run { self.moves[id] = nil }
                        return
                    }
                    guard let transcript = conversations.transcript(id: id, cwd: cwd, in: source) else {
                        throw MoveFailure.transcriptMissing
                    }
                    let waitsForTasks = !automatic
                    if Self.isReady(transcript, since: session.startedAt, acceptStalled: !automatic, waitsForTasks: waitsForTasks) {
                        try conversations.ensure(id: id, cwd: cwd, target: target, among: profiles)
                        if Self.isReady(transcript, since: session.startedAt, acceptStalled: !automatic, waitsForTasks: waitsForTasks) {
                            hadBackgroundWork = !ConversationActivity.pendingBackgroundTasks(
                                transcript: transcript, since: session.startedAt
                            ).isEmpty
                            ready = true
                            break
                        }
                    }
                    try await Task.sleep(nanoseconds: 5_000_000_000)
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
                if SessionControl.isRunning(session.pid) {
                    try? SessionControl.end(session, force: true)
                    for _ in 0..<25 where SessionControl.isRunning(session.pid) {
                        try? await Task.sleep(nanoseconds: 200_000_000)
                    }
                }
                // Nothing is opened in the editor: a chat ended this way keeps its conversation in
                // its panel, and its next message starts it again through the launcher on the
                // folder's account. (Opening the folder or a session link could open a second
                // window or a second copy of the chat in whichever window is in front.)
                if hadBackgroundWork {
                    try ChatResumer(env: env).resume(conversationId: id, folder: cwd, flags: session.resumeFlags)
                    await MainActor.run { self.finishMove(id, .resumed, target: target, folder: cwd) }
                    return
                }
                let outcome = await Self.confirmNotWrongAccount(id: id, on: target, env: env)
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
            // The extension asks which account it is on once per window, so its Account panel
            // keeps the old email until the window reloads; the chat itself is already moved.
            show(.success, "\(name) chat moved to \(target.displayName) with its history: its next message runs there. Claude's Account panel shows the new email after you reload the window.")
        case .resumed:
            show(.success, "\(name) chat moved to \(target.displayName). Its background work had to stop, so Spillover resumed it there (\"\(ChatResumer.message)\"). It keeps working in the background, listed under Sessions; the chat opens again in VS Code when it is done, or choose Take over there.")
        case .closed:
            show(.info, "The \(name) chat was closed. It continues on \(target.displayName), with its history, when you reopen it.")
        case .failed(let why):
            show(.error, "Could not move the \(name) chat: \(why)")
        default:
            break
        }
        refreshSessions()
    }

    nonisolated private static func isReady(
        _ transcript: URL, since: Date?, acceptStalled: Bool, waitsForTasks: Bool
    ) -> Bool {
        if waitsForTasks, !ConversationActivity.pendingBackgroundTasks(transcript: transcript, since: since).isEmpty {
            return false
        }
        switch ConversationActivity.state(transcript: transcript) {
        case .idle: return true
        case .stalled: return acceptStalled
        case .busy: return false
        }
    }

    /// The chat starts again only when its next message is sent, through the launcher, on the
    /// folder's account. So no process is the usual outcome; a process for this chat that does
    /// start within 20 seconds must be on the target account.
    nonisolated private static func confirmNotWrongAccount(id: String, on target: Profile, env: SBEnvironment) async -> ChatMove.Phase {
        let profiles = (try? ProfileStore(env: env).all()) ?? []
        for _ in 0..<20 {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard let s = SessionScanner(env: env).scan().first(where: { $0.conversationId == id }) else { continue }
            let actual = SessionScanner.profileId(for: s, profiles: profiles, caseInsensitive: env.caseInsensitivePaths)
            if actual == target.id { return .done }
            return .failed("it restarted on \(actual ?? "an unknown account") instead. Is the editor connected under Setup?")
        }
        return .done
    }

    /// True while the chat with this pid still runs on an account its folder has moved away from.
    private func isStillBehind(_ pid: Int32) -> Bool {
        guard let a = sessions.first(where: { $0.session.pid == pid }) else { return true }
        if case .stale = a.state { return true }
        return false
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
            return "the chat (or a background task it started) was still working. It keeps its current account; try again when it is idle."
        case .transcriptMissing:
            return "its conversation file was not found, so it was left running on its current account."
        }
    }
}
