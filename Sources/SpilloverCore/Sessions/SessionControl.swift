import Darwin
import Foundation

/// The only code that signals another process. It ends one Claude chat process so the editor can
/// start it again (through the launcher, on the folder's current account) and resume it.
public enum SessionControl {
    public enum EndError: Error, Equatable, LocalizedError {
        /// The process is gone or is no longer the chat that was chosen (pids are reused).
        case notTheSameSession
        case signalFailed(Int32)

        public var errorDescription: String? {
            switch self {
            case .notTheSameSession: return "That Claude session is no longer running."
            case .signalFailed(let e): return "Could not stop the Claude session (\(String(cString: strerror(e))))."
            }
        }
    }

    /// Ends `session` after checking that its pid still belongs to the same chat: same executable,
    /// same folder, same conversation, same user. It is sent SIGINT, which a chat between turns
    /// handles as a clean exit; the editor then shows no error. `force` sends SIGTERM instead, for a
    /// chat that did not exit (the editor reports that exit as an error until the chat reopens).
    public static func end(_ session: RunningSession, force: Bool = false) throws {
        guard let current = SessionScanner.session(pid: session.pid), isSameChat(session, current) else {
            throw EndError.notTheSameSession
        }
        if kill(session.pid, force ? SIGTERM : SIGINT) != 0 { throw EndError.signalFailed(errno) }
    }

    /// True while a process with this pid exists.
    public static func isRunning(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    static func isSameChat(_ a: RunningSession, _ b: RunningSession) -> Bool {
        a.pid == b.pid && a.executable == b.executable && a.cwd == b.cwd && a.conversationId == b.conversationId
            && a.startedAt == b.startedAt
    }
}
