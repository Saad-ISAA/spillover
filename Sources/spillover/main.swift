import Foundation
import SpilloverCore

let version = "0.1.6"

let help = """
    spillover \(version) — one Claude subscription per folder, window and terminal.

    Usage:
      spillover status [--json] [--offline]   Profiles, logins, usage, assigned folders, setup
      spillover profile list
      spillover profile create <name>         New isolated profile (then log in)
      spillover profile adopt <name> <dir>    Register an existing Claude config dir
      spillover profile login <id> [--terminal]
      spillover profile logout <id>
      spillover profile rename <id> <name>
      spillover profile remove <id> [--unassign] [--delete-dir]
      spillover profile share <id> <item...> [--from <id>] [--replace]
      spillover profile unshare <id> <item...>
      spillover route list
      spillover route set <folder> <profile>  Folder (and below) uses that profile
      spillover route unset <folder>
      spillover route which [folder]          What would Claude use here?
      spillover install [--editor <name>] [--shell] [--statusline] [--all] [--force]
      spillover uninstall                     Undo every change to editors and shells
      spillover usage [--days N]              Limits and local token totals per profile
      spillover sessions                      Running Claude sessions and their accounts
      spillover stopped                       Chats stopped by a usage limit, and their resume state
      spillover doctor [--no-keychain]        Health checks (read-only)
      spillover log [N]                       Recent launch decisions
      spillover open <folder> [--editor code] Open a folder in an editor

    Emergency: SPILLOVER_BYPASS=1 runs Claude without routing.
    """

let env = SBEnvironment.live()
let args = Args(Array(CommandLine.arguments.dropFirst()))
let commands = Commands(env: env)

do {
    switch args.positional(0) {
    case nil, "help", "-h", "--help":
        print(help)
    case "version", "--version":
        print(version)
    case "status":
        try commands.status(args)
    case "profile", "profiles":
        try commands.profile(args)
    case "route", "routes":
        try commands.route(args)
    case "install":
        try commands.install(args)
    case "uninstall":
        try commands.uninstall(args)
    case "usage":
        try commands.usage(args)
    case "sessions":
        commands.sessions(args)
    case "stopped":
        commands.stopped()
    case "statusline":
        commands.statusline()
    case "doctor":
        commands.doctor(args)
    case "log":
        commands.log(args)
    case "open":
        try commands.open(args)
    case let other?:
        Out.err("Unknown command '\(other)'.\n")
        print(help)
        exit(2)
    }
} catch let CLIError.usage(text) {
    Out.err(text)
    exit(2)
} catch {
    Out.err("error: \(Redaction.scrub(error.localizedDescription))")
    exit(1)
}
