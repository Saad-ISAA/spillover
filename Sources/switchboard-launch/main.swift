import Foundation
import SwitchboardCore

// switchboard-launch: runs in place of the Claude binary.
//
// - Editors run it via `claudeCode.claudeProcessWrapper` with Claude's own arguments.
// - Shells run it through the `claude` symlink in the shims directory (argv[0] == "claude").
//
// It decides which profile the current folder belongs to, then replaces itself with the real
// Claude process (execve), so stdin/stdout/stderr and signals belong to Claude directly.

let env = SBEnvironment.live()
let invokedAs = (CommandLine.arguments.first.map { ($0 as NSString).lastPathComponent }) ?? ""
let mode: LaunchMode = invokedAs == "claude" ? .shellShim : .editorWrapper
let args = Array(CommandLine.arguments.dropFirst())
let cwd = FileManager.default.currentDirectoryPath

let request = LaunchRequest(mode: mode, cwd: cwd, args: args, environment: env.processEnv)

switch LaunchPlanner(env: env).plan(request) {
case .refuse(let message):
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(78)  // EX_CONFIG
case .exec(let plan, _):
    let argv = [plan.executable] + plan.args
    let envp = plan.environment.map { "\($0.key)=\($0.value)" }

    var cArgs: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) } + [nil]
    var cEnv: [UnsafeMutablePointer<CChar>?] = envp.map { strdup($0) } + [nil]
    execve(plan.executable, &cArgs, &cEnv)

    // Only reached when execve failed.
    let reason = String(cString: strerror(errno))
    FileHandle.standardError.write(
        Data("switchboard: could not start \(plan.executable): \(reason)\n".utf8))
    exit(126)
}
