import Foundation

/// POSIX single-quote escaping for text embedded in a generated shell script.
public enum ShellQuote {
    public static func quote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// Opens Terminal.app on a profile: for the guided login and for "open a shell here as account X".
/// Generates a short-lived `.command` script (owner-only) and asks macOS to open it, so no
/// AppleScript or automation permission is required.
public struct TerminalLauncher {
    private let env: SBEnvironment
    private let runner: CommandRunning

    public init(env: SBEnvironment, runner: CommandRunning = SystemCommandRunner()) {
        self.env = env
        self.runner = runner
    }

    /// The script body (exposed for tests).
    public func scriptBody(profile: Profile, folder: String?, claudePath: String, command: [String])
        -> String
    {
        var lines = ["#!/bin/zsh"]
        if let dir = profile.configDir {
            lines.append("export \(ProfileEnvironment.configDirKey)=\(ShellQuote.quote(dir))")
        } else {
            lines.append("unset \(ProfileEnvironment.configDirKey)")
        }
        lines.append("export \(ProfileEnvironment.profileKey)=\(ShellQuote.quote(profile.id))")
        if let folder { lines.append("cd \(ShellQuote.quote(folder)) || exit 1") }
        if command.isEmpty {
            lines.append("exec \"${SHELL:-/bin/zsh}\" -l")
        } else {
            let cmd = ([claudePath] + command).map(ShellQuote.quote).joined(separator: " ")
            lines.append(cmd)
            lines.append("status=$?")
            lines.append("echo")
            lines.append("echo \"Finished (exit $status). You can close this window.\"")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Guided login: runs the official `claude auth login` inside the profile's config directory.
    @discardableResult
    public func openLogin(profile: Profile, claudePath: String) throws -> URL {
        try open(
            profile: profile, folder: nil, claudePath: claudePath, command: ["auth", "login"],
            name: "login-\(profile.id)")
    }

    /// A shell in `folder` with the profile's environment.
    @discardableResult
    public func openShell(profile: Profile, folder: String) throws -> URL {
        try open(
            profile: profile, folder: folder, claudePath: "", command: [], name: "shell-\(profile.id)")
    }

    private func open(
        profile: Profile, folder: String?, claudePath: String, command: [String], name: String
    ) throws -> URL {
        let paths = env.paths
        try SafeFS.ensureDir(paths.root)
        try SafeFS.ensureDir(paths.tmpDir)
        let script = paths.tmpDir.appendingPathComponent("\(name).command")
        let body = scriptBody(profile: profile, folder: folder, claudePath: claudePath, command: command)
        try SafeFS.writeAtomic(Data(body.utf8), to: script, mode: 0o700)
        let result = runner.run("/usr/bin/open", [script.path], env: nil, timeout: 15)
        guard result.succeeded else {
            throw SafeFS.Failure(description: "could not open Terminal: \(result.stderr)")
        }
        return script
    }
}
