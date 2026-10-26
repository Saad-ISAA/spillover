import Foundation
import XCTest

@testable import SwitchboardCore

final class SessionScannerTests: XCTestCase {
    private func procArgs(exec: String, argv: [String], env: [String]) -> [UInt8] {
        var b: [UInt8] = []
        let argc = UInt32(argv.count)
        b += [UInt8(argc & 0xff), UInt8((argc >> 8) & 0xff), UInt8((argc >> 16) & 0xff), UInt8(argc >> 24)]
        b += Array(exec.utf8) + [0, 0, 0, 0]
        for a in argv { b += Array(a.utf8) + [0] }
        for e in env { b += Array(e.utf8) + [0] }
        b += [0]
        return b
    }

    func testParseKeepsOnlyTwoVariables() {
        let buf = procArgs(
            exec: "/x/claude", argv: ["/x/claude", "--resume", "a b"],
            env: ["HOME=/Users/example", "CLAUDE_CONFIG_DIR=/p/work", "SECRET_TOKEN=abc", "SWITCHBOARD_PROFILE=work"])
        let parsed = SessionScanner.parseProcArgs(buf)
        XCTAssertEqual(parsed.argv, ["/x/claude", "--resume", "a b"])
        XCTAssertEqual(parsed.env, ["CLAUDE_CONFIG_DIR": "/p/work", "SWITCHBOARD_PROFILE": "work"])
    }

    func testParseHandlesTruncatedBuffers() {
        XCTAssertEqual(SessionScanner.parseProcArgs([]).argv, [])
        XCTAssertEqual(SessionScanner.parseProcArgs([1, 0, 0, 0]).argv, [])
    }

    func testAssessment() throws {
        let box = try Sandbox()
        let service = AppService(env: box.env)
        let work = try service.profiles.create(displayName: "work")
        let personal = try service.profiles.create(displayName: "personal")
        let a = try box.mkdir("a")
        let b = try box.mkdir("b")
        let c = try box.mkdir("c")
        try service.assign(folder: a.path, to: work.id)
        try service.assign(folder: b.path, to: personal.id)

        let sessions = [
            RunningSession(pid: 1, executable: "claude", cwd: a.path, configDir: work.configDir, switchboardProfile: "work", startedAt: nil),
            // Folder b was moved to "personal" after this session started on "work".
            RunningSession(pid: 2, executable: "claude", cwd: b.path, configDir: work.configDir, switchboardProfile: "work", startedAt: nil),
            RunningSession(pid: 3, executable: "claude", cwd: c.path, configDir: nil, switchboardProfile: nil, startedAt: nil),
            RunningSession(pid: 4, executable: "claude", cwd: c.path, configDir: "/unknown/dir", switchboardProfile: nil, startedAt: nil),
        ]
        let states = SessionScanner(env: box.env).assess(sessions).map(\.state)
        XCTAssertEqual(states, [.matches, .stale(expected: personal.id), .matches, .unknownAccount])
    }

    func testLiveScanOnlyReturnsClaudeProcessesOfThisUser() throws {
        // Smoke test against the real process table: must not crash and must only list "claude".
        let box = try Sandbox()
        for s in SessionScanner(env: box.env).scan() {
            XCTAssertTrue(SessionScanner.isClaudeExecutable(s.executable))
        }
    }
}
