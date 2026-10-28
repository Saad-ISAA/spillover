import Foundation
import SpilloverCore

// spillover-launch: runs in place of the Claude binary.
//
// - Editors run it via `claudeCode.claudeProcessWrapper` with Claude's own arguments.
// - Shells run it through the `claude` symlink in the shims directory (argv[0] == "claude").
//
// It decides which profile the current folder belongs to, then replaces itself with the real
// Claude process (execve), so stdin/stdout/stderr and signals belong to Claude directly.
// Arguments and every environment entry Spillover does not change are passed on as the original
// bytes, so values that are not valid UTF-8 survive untouched.

let env = SBEnvironment.live()
let invokedAs = (CommandLine.arguments.first.map { ($0 as NSString).lastPathComponent }) ?? ""
let mode: LaunchMode = invokedAs == "claude" ? .shellShim : .editorWrapper
let args = Array(CommandLine.arguments.dropFirst())
let cwd = FileManager.default.currentDirectoryPath

let request = LaunchRequest(
    mode: mode, cwd: cwd, args: args, environment: env.processEnv,
    parentExecutable: SessionScanner.executable(of: getppid()))

switch LaunchPlanner(env: env).plan(request) {
case .refuse(let message):
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(78)  // EX_CONFIG
case .exec(let plan, _):
    // Keys the planner set, changed or removed.
    var changed = Set<String>()
    for (k, v) in plan.environment where env.processEnv[k] != v { changed.insert(k) }
    for k in env.processEnv.keys where plan.environment[k] == nil { changed.insert(k) }

    var cEnv: [UnsafeMutablePointer<CChar>?] = []
    var entry = environ
    while let pointer = entry.pointee {
        let raw = String(cString: pointer)
        let key = raw.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? raw
        if !changed.contains(key) { cEnv.append(pointer) }
        entry += 1
    }
    for key in changed.sorted() {
        if let value = plan.environment[key] { cEnv.append(strdup("\(key)=\(value)")) }
    }
    cEnv.append(nil)

    var cArgs: [UnsafeMutablePointer<CChar>?] = [strdup(plan.executable)]
    // argv[i] is plan.args[i - 1]; the extra arguments go in at plan.extraArgsIndex.
    let insertAt = min(max(plan.extraArgsIndex, 0), Int(CommandLine.argc) - 1) + 1
    for i in 1..<Int(CommandLine.argc) {
        if i == insertAt { for extra in plan.extraArgs { cArgs.append(strdup(extra)) } }
        cArgs.append(CommandLine.unsafeArgv[i])
    }
    if insertAt == Int(CommandLine.argc) { for extra in plan.extraArgs { cArgs.append(strdup(extra)) } }
    cArgs.append(nil)

    execve(plan.executable, &cArgs, &cEnv)

    // Only reached when execve failed.
    let reason = String(cString: strerror(errno))
    FileHandle.standardError.write(
        Data("spillover: could not start \(plan.executable): \(reason)\n".utf8))
    exit(126)
}
