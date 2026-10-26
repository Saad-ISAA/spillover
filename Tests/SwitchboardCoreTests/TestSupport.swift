import Foundation
import XCTest

@testable import SwitchboardCore

/// A throwaway home directory per test. Nothing outside it is ever touched.
final class Sandbox {
    let root: URL
    let home: URL
    let env: SBEnvironment

    init(processEnv: [String: String] = [:], caseInsensitive: Bool = true) throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("switchboard-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        // Resolve /var -> /private/var so expectations match normalised paths.
        root = URL(fileURLWithPath: PathNormalizer.normalize(base.path, caseInsensitive: false)!.display)
        home = root.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        env = SBEnvironment(home: home, processEnv: processEnv, caseInsensitivePaths: caseInsensitive)
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    func mkdir(_ relative: String) throws -> URL {
        let url = home.appendingPathComponent(relative, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @discardableResult
    func write(_ relative: String, _ text: String, mode: UInt16 = 0o644) throws -> URL {
        let url = home.appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: mode)], ofItemAtPath: url.path)
        return url
    }

    /// An executable shell script standing in for a binary.
    @discardableResult
    func fakeExecutable(_ relative: String) throws -> URL {
        try write(relative, "#!/bin/sh\nexit 0\n", mode: 0o755)
    }

    func read(_ url: URL) -> String {
        (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }
}

/// Records calls and answers with canned results.
final class FakeRunner: CommandRunning, @unchecked Sendable {
    struct Call: Equatable {
        let executable: String
        let args: [String]
        let env: [String: String]?
        let stdin: Data?
    }

    private let lock = NSLock()
    private var _calls: [Call] = []
    var handler: (String, [String]) -> CommandResult = { _, _ in CommandResult(status: 0) }

    var calls: [Call] {
        lock.lock()
        defer { lock.unlock() }
        return _calls
    }

    func run(
        _ executable: String, _ args: [String], env: [String: String]?, timeout: TimeInterval,
        stdin: Data?
    ) -> CommandResult {
        lock.lock()
        _calls.append(Call(executable: executable, args: args, env: env, stdin: stdin))
        lock.unlock()
        return handler(executable, args)
    }

    func runInteractive(_ executable: String, _ args: [String], env: [String: String]?) -> Int32 {
        lock.lock()
        _calls.append(Call(executable: executable, args: args, env: env, stdin: nil))
        lock.unlock()
        return handler(executable, args).status
    }
}
