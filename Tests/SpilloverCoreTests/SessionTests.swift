import Foundation
import XCTest

@testable import SpilloverCore

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

    func testParseKeepsOnlyKnownVariables() {
        let buf = procArgs(
            exec: "/x/claude", argv: ["/x/claude", "--resume", "a b"],
            env: [
                "HOME=/Users/example", "CLAUDE_CONFIG_DIR=/p/work", "SECRET_TOKEN=abc", "SPILLOVER_PROFILE=work",
                "SPILLOVER_RESUMED_RUN=1",
            ])
        let parsed = SessionScanner.parseProcArgs(buf)
        XCTAssertEqual(parsed.argv, ["/x/claude", "--resume", "a b"])
        XCTAssertEqual(
            parsed.env, ["CLAUDE_CONFIG_DIR": "/p/work", "SPILLOVER_PROFILE": "work", "SPILLOVER_RESUMED_RUN": "1"])
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
            RunningSession(pid: 1, executable: "claude", cwd: a.path, configDir: work.configDir, spilloverProfile: "work", startedAt: nil),
            // Folder b was moved to "personal" after this session started on "work".
            RunningSession(pid: 2, executable: "claude", cwd: b.path, configDir: work.configDir, spilloverProfile: "work", startedAt: nil),
            RunningSession(pid: 3, executable: "claude", cwd: c.path, configDir: nil, spilloverProfile: nil, startedAt: nil),
            RunningSession(pid: 4, executable: "claude", cwd: c.path, configDir: "/unknown/dir", spilloverProfile: nil, startedAt: nil),
        ]
        let states = SessionScanner(env: box.env).assess(sessions).map(\.state)
        XCTAssertEqual(states, [.matches, .stale(expected: personal.id), .matches, .unknownAccount])
    }

    func testHelpersAreNotChats() throws {
        XCTAssertFalse(SessionScanner.isChat(argv: ["--chrome-native-host"]))
        XCTAssertFalse(SessionScanner.isChat(argv: ["mcp", "serve"]))
        XCTAssertFalse(SessionScanner.isChat(argv: ["auth", "status", "--json"]))
        XCTAssertTrue(SessionScanner.isChat(argv: ["--output-format", "stream-json", "--resume=abc"]))
        XCTAssertTrue(SessionScanner.isChat(argv: []))

        // A run in a temporary folder keeps the account of the chat that started it.
        let box = try Sandbox()
        let tmp = try box.mkdir("tmp/plugin-run")
        var env = box.env
        env.temporaryFolders = [box.home.appendingPathComponent("tmp").path + "/"]
        let work = try ProfileStore(env: env).create(displayName: "work")
        let run = RunningSession(
            pid: 9, executable: "claude", cwd: tmp.path, configDir: work.configDir, spilloverProfile: nil, startedAt: nil)
        XCTAssertEqual(SessionScanner(env: env).assess([run]).map(\.state), [.background])
    }

    func testLiveScanOnlyReturnsClaudeProcessesOfThisUser() throws {
        // Smoke test against the real process table: must not crash and must only list "claude".
        let box = try Sandbox()
        for s in SessionScanner(env: box.env).scan() {
            XCTAssertTrue(SessionScanner.isClaudeExecutable(s.executable))
        }
    }
}
