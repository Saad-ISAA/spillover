import AppKit
import Foundation
import SpilloverCore

/// A chat stopped by a usage limit, as the Sessions list shows it.
struct StoppedChat: Identifiable, Equatable {
    let stop: LimitStop
    let entry: LimitResumeLog.Entry
    /// The account the chat will continue on (its own, or Auto's pick); nil when its folder is refused.
    let targetProfileId: String?
    /// When Spillover expects to resume it, while its account has no room yet.
    let expected: Date?

    var id: String { stop.conversationId }
}

/// Resuming chats in their own panel: after Auto moved a chat whose background work stopped with
/// the move, and once a usage limit a chat stopped on has reset (plus a minute's grace). Spillover
/// keeps its own list of stopped chats and acts once per stop; it only types into a chat that is
/// idle with an empty message box, and only after the user has left the keyboard for a moment.
extension AppModel {
    /// Seconds without keyboard or mouse input before Spillover types into a chat.
    static let resumeAfterIdleSeconds: Double = 15

    /// Finds chats stopped by a limit, notes since when each one's account has room, and resumes
    /// the ones that are due. Runs on every refresh; the scan runs in the background.
    func checkStoppedChats() {
        guard !checkingStoppedChats else { return }
        checkingStoppedChats = true
        let env = self.env
        let profiles = self.profiles
        let snapshots = self.snapshots
        Task.detached(priority: .utility) {
            let resolver = Resolver(env: env)
            let log = LimitResumeLog(env: env)
            let history = UsageHistory(env: env)
            var list: [StoppedChat] = []
            var due: [LimitStop] = []
            for stop in LimitStops(env: env).scan(profiles: profiles) {
                var target: String?
                switch resolver.resolve(cwd: stop.cwd, preferring: stop.profileId, record: false) {
                case .routed(let p, _): target = p.id
                case .unrouted: target = Profile.defaultID
                case .refused: target = nil
                }
                let snapshot = target.flatMap { snapshots[$0] }
                let room = target.flatMap { LimitStops.roomSince(snapshot, history: history.load(profileId: $0), after: stop.stoppedAt) }
                let entry = log.note(stop, roomSince: room)
                list.append(
                    StoppedChat(
                        stop: stop, entry: entry, targetProfileId: target,
                        expected: entry.roomSince.map { $0.addingTimeInterval(LimitStops.grace) }
                            ?? LimitStops.expectedResume(snapshot)))
                if LimitResumeLog.isDue(entry) { due.append(stop) }
            }
            let found = list
            let ready = due
            await MainActor.run {
                self.stoppedChats = found
                self.lastStoppedCheck = Date()
                self.checkingStoppedChats = false
                if self.autoPolicy.resumeChats { self.resumeStoppedChats(ready) }
            }
        }
    }

    /// Asks for the permission typing into VS Code needs, then turns resuming on.
    func setResumeChats(_ on: Bool) {
        if on && !ChatSender.isAllowed { ChatSender.requestPermission() }
        updateAutoPolicy { $0.resumeChats = on }
    }

    // MARK: Resuming

    private func resumeStoppedChats(_ due: [LimitStop]) {
        // Demo homes are only looked at, never typed into.
        guard !due.isEmpty, ChatSender.isAllowed, !DemoSessions.isActive(env) else { return }
        // Never type while the user is typing: due chats wait for the next quiet refresh.
        guard ChatSender.secondsSinceUserInput >= Self.resumeAfterIdleSeconds else { return }
        let log = LimitResumeLog(env: env)
        for stop in due {
            let name = Fmt.folderName(stop.cwd)
            guard let title = stop.title else {
                log.recordAttempt(stop, outcome: "its chat title is not known")
                show(.error, "Could not resume the \(name) chat after its limit reset: its title is not known. Send it a message to continue.")
                continue
            }
            do {
                try ChatSender.send(LimitStops.message, toChat: title, conversationId: stop.conversationId, folder: stop.cwd)
                log.recordAttempt(stop, outcome: "resumed")
                confirmResumed(stop, title: title)
            } catch {
                if log.recordFailedTry(stop, reason: error.localizedDescription) {
                    show(.error, "Could not resume “\(title)” (\(name)) after its limit reset: \(error.localizedDescription) Send it a message to continue.")
                }
            }
        }
        checkStoppedChats()
    }

    /// The message went out; the chat's transcript shows within a few seconds whether it took.
    private func confirmResumed(_ stop: LimitStop, title: String) {
        let env = self.env
        let profiles = self.profiles
        Task.detached(priority: .utility) {
            var resumed = false
            for _ in 0..<12 where !resumed {
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                let newest = ConversationStore(env: env).holders(id: stop.conversationId, cwd: stop.cwd, among: profiles).first
                resumed = newest.map { LimitStops.wasResumed(stop, transcript: $0.file) } ?? false
            }
            let took = resumed
            await MainActor.run {
                let name = Fmt.folderName(stop.cwd)
                if took {
                    self.show(.success, "Resumed “\(title)” (\(name)): its limit has reset.")
                } else {
                    self.show(.error, "Sent “\(title)” (\(name)) a message to resume, but it does not show in the chat yet. Check that chat.")
                }
            }
        }
    }

    /// After Auto moved a chat whose background work stopped with its old process: types the
    /// resume message into that chat's panel once the user has left the keyboard (up to ten
    /// minutes). Returns nil when sent, else why not.
    nonisolated static func resumeMovedChat(
        conversationId: String, folder: String, transcript: URL?
    ) async -> String? {
        guard let transcript, let title = LimitStops.title(transcript: transcript) else {
            return "its chat title is not known"
        }
        var quiet = false
        for _ in 0..<120 {
            quiet = await MainActor.run { ChatSender.secondsSinceUserInput >= resumeAfterIdleSeconds }
            if quiet { break }
            try? await Task.sleep(nanoseconds: 5_000_000_000)
        }
        guard quiet else { return "you kept using the keyboard for ten minutes" }
        return await MainActor.run {
            do {
                try ChatSender.send(movedMessage, toChat: title, conversationId: conversationId, folder: folder)
                return nil
            } catch {
                return error.localizedDescription
            }
        }
    }

    nonisolated static let movedMessage = "The account switched. Please resume all work."
}
