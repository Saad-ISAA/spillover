import Foundation

public struct CommandResult: Sendable, Equatable {
    public var status: Int32
    public var stdout: String
    public var stderr: String
    public var timedOut: Bool

    public init(status: Int32, stdout: String = "", stderr: String = "", timedOut: Bool = false) {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
        self.timedOut = timedOut
    }

    public var succeeded: Bool { status == 0 && !timedOut }
}

/// The only way Switchboard starts another process (single entry point; fakes implement this in
/// tests). `Process` is not used anywhere else in the codebase (ArchitectureTests).
public protocol CommandRunning: Sendable {
    /// Run to completion with captured output. `env` replaces the environment when non-nil.
    func run(
        _ executable: String, _ args: [String], env: [String: String]?, timeout: TimeInterval,
        stdin: Data?
    ) -> CommandResult

    /// Run with the caller's terminal attached (interactive login). Returns the exit status.
    func runInteractive(_ executable: String, _ args: [String], env: [String: String]?) -> Int32
}

extension CommandRunning {
    public func run(
        _ executable: String, _ args: [String], env: [String: String]?, timeout: TimeInterval
    ) -> CommandResult {
        run(executable, args, env: env, timeout: timeout, stdin: nil)
    }
}

public struct SystemCommandRunner: CommandRunning {
    public init() {}

    private final class Box: @unchecked Sendable {
        let lock = NSLock()
        var data = Data()
        func set(_ d: Data) {
            lock.lock()
            data = d
            lock.unlock()
        }
        func get() -> Data {
            lock.lock()
            defer { lock.unlock() }
            return data
        }
    }

    public func run(
        _ executable: String, _ args: [String], env: [String: String]?, timeout: TimeInterval,
        stdin: Data?
    ) -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        if let env { process.environment = env }
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        let input = stdin.map { _ in Pipe() }
        if let input {
            process.standardInput = input
        } else {
            process.standardInput = FileHandle.nullDevice
        }

        do { try process.run() } catch {
            return CommandResult(status: -1, stderr: "\(error.localizedDescription)")
        }
        if let input, let stdin {
            DispatchQueue.global().async {
                try? input.fileHandleForWriting.write(contentsOf: stdin)
                try? input.fileHandleForWriting.close()
            }
        }

        let outBox = Box()
        let errBox = Box()
        let readers = DispatchGroup()
        readers.enter()
        DispatchQueue.global().async {
            outBox.set(out.fileHandleForReading.readDataToEndOfFile())
            readers.leave()
        }
        readers.enter()
        DispatchQueue.global().async {
            errBox.set(err.fileHandleForReading.readDataToEndOfFile())
            readers.leave()
        }

        let exited = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            process.waitUntilExit()
            exited.signal()
        }
        var timedOut = false
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            process.terminate()
            _ = exited.wait(timeout: .now() + 2)
        }
        _ = readers.wait(timeout: .now() + 2)

        return CommandResult(
            status: process.isRunning ? -1 : process.terminationStatus,
            stdout: String(decoding: outBox.get(), as: UTF8.self),
            stderr: String(decoding: errBox.get(), as: UTF8.self),
            timedOut: timedOut)
    }

    public func runInteractive(
        _ executable: String, _ args: [String], env: [String: String]?
    ) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        if let env { process.environment = env }
        process.standardInput = FileHandle.standardInput
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError
        do { try process.run() } catch { return -1 }
        process.waitUntilExit()
        return process.terminationStatus
    }
}
