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
        case failed(String)
    }

    let conversationId: String
    let folder: String
    let toProfileId: String
    let automatic: Bool
    var phase: Phase

    var inProgress: Bool { phase == .waiting || phase == .switching }
}

/// A VS Code window as Switchboard sees it: the folder its chats run in, and those chats.
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

    /// Restart one chat that is still on its old account.
    func restartOnAssignedAccount(_ a: SessionAssessment) {
        startMove(a, automatic: false)
    }

    /// Notification action: move what is running on `from` (and the folders assigned to it).
    func moveWork(from: String, to: String) {
        var folders = Set(routes.filter { $0.profileId == from }.map(\.folder))
        for w in openWindows where w.sessions.contains(where: { $0.actualProfileId == from }) {
            folders.insert(w.folder)
        }
        for f in folders.sorted() { switchWindow(folder: f, to: to) }
        if folders.isEmpty { show(.info, "Nothing is running on that account right now.") }
    }

    /// Auto folders: move open chats off an account that ran low, at their next idle moment.
    func autoMoveChatsIfNeeded() {
        guard autoPolicy.moveOpenChats else { return }
        for a in sessions {
            guard case .stale = a.state, let cwd = a.session.cwd, a.session.editor != nil,
                let id = a.session.conversationId, moves[id]?.inProgress != true,
                case .routed(_, let route) = resolution(for: cwd), route.profileId == Profile.autoID
            else { continue }
            startMove(a, automatic: true)
        }
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

    /// Accounts in Auto's order of preference (every account when none is set).
    var autoOrder: [Profile] { autoPolicy.candidates(from: profiles) }

    func move(for a: SessionAssessment) -> ChatMove? {
        a.session.conversationId.flatMap { moves[$0] }
    }

    // MARK: The move itself

    private func startMove(_ a: SessionAssessment, automatic: Bool) {
        guard case .stale(let expectedID) = a.state, let target = profile(id: expectedID) else { return }
        guard let id = a.session.conversationId, let cwd = a.session.cwd, let editor = a.session.editor,
            let reopen = editor.claudeSessionURL(id)
        else {
            show(.info, "Terminal chats keep their account until you start them again (claude -r continues the last one).")
            return
        }
        if moves[id]?.inProgress == true { return }
        let source = a.actualProfileId.flatMap { profile(id: $0) }
        moves[id] = ChatMove(conversationId: id, folder: cwd, toProfileId: target.id, automatic: automatic, phase: .waiting)

        let env = self.env
        let profiles = self.profiles
        let session = a.session
        Task.detached(priority: .userInitiated) {
            let conversations = ConversationStore(env: env)
            do {
                // Copy now, and again just before the restart (the chat may grow while we wait).
                try conversations.ensure(id: id, cwd: cwd, target: target, among: profiles)
                let ready = await Self.waitUntilIdle(
                    transcript: source.flatMap { conversations.transcript(id: id, cwd: cwd, in: $0) },
                    acceptStalled: !automatic)
                guard ready else { throw MoveFailure.stillBusy }
                try conversations.ensure(id: id, cwd: cwd, target: target, among: profiles)
                await MainActor.run { self.moves[id]?.phase = .switching }
                try SessionControl.end(session)
                for _ in 0..<25 where SessionControl.isRunning(session.pid) {
                    try? await Task.sleep(nanoseconds: 200_000_000)
                }
                await MainActor.run {
                    // Bring the chat's window forward, then ask the extension to reopen the chat.
                    try? self.service.open(folder: cwd, in: editor)
                }
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                await MainActor.run {
                    NSWorkspace.shared.open(reopen)
                    self.moves[id]?.phase = .done
                    self.show(.success, "\(Fmt.folderName(cwd)) chat moved to \(target.displayName) with its history.")
                }
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                await MainActor.run { self.refreshSessions() }
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                await MainActor.run { if self.moves[id]?.phase == .done { self.moves[id] = nil } }
            } catch {
                await MainActor.run {
                    self.moves[id]?.phase = .failed(error.localizedDescription)
                    self.show(.error, "Could not move the \(Fmt.folderName(cwd)) chat: \(error.localizedDescription)")
                }
            }
        }
    }

    /// Polls the transcript until the chat is between turns. Automatic moves wait for a clean
    /// turn end only; a move the user asked for also accepts a chat that has been quiet a while.
    nonisolated private static func waitUntilIdle(transcript: URL?, acceptStalled: Bool) async -> Bool {
        guard let transcript else { return true }
        let deadline = Date().addingTimeInterval(15 * 60)
        while Date() < deadline {
            switch ConversationActivity.state(transcript: transcript) {
            case .idle: return true
            case .stalled where acceptStalled: return true
            default: try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
        return false
    }

    private func isInside(_ cwd: String?, folder: String) -> Bool {
        guard let cwd else { return false }
        return cwd == folder || cwd.hasPrefix(folder.hasSuffix("/") ? folder : folder + "/")
    }
}

enum MoveFailure: Error, LocalizedError {
    case stillBusy

    var errorDescription: String? {
        "the chat was still working after 15 minutes. It keeps its current account; try again when it is idle."
    }
}
