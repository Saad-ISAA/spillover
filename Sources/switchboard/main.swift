import Foundation
import SwitchboardCore

let version = "0.1.0"

let help = """
    switchboard \(version) — one Claude subscription per folder, window and terminal.

    Usage:
      switchboard status [--json] [--offline]   Profiles, logins, usage, assigned folders, setup
      switchboard profile list
      switchboard profile create <name>         New isolated profile (then log in)
      switchboard profile adopt <name> <dir>    Register an existing Claude config dir
      switchboard profile login <id> [--terminal]
      switchboard profile logout <id>
      switchboard profile rename <id> <name>
      switchboard profile remove <id> [--unassign] [--delete-dir]
      switchboard profile share <id> <item...> [--from <id>] [--replace]
      switchboard profile unshare <id> <item...>
      switchboard route list
      switchboard route set <folder> <profile>  Folder (and below) uses that profile
      switchboard route unset <folder>
      switchboard route which [folder]          What would Claude use here?
      switchboard install [--editor <name>] [--shell] [--statusline] [--all] [--force]
      switchboard uninstall                     Undo every change to editors and shells
      switchboard usage [--days N]              Limits and local token totals per profile
      switchboard sessions                      Running Claude sessions and their accounts
      switchboard doctor [--no-keychain]        Health checks (read-only)
      switchboard log [N]                       Recent launch decisions
      switchboard import-legacy [routes.tsv]    Import a hand-made routes.tsv setup
      switchboard open <folder> [--editor code] Open a folder in an editor

    Emergency: SWITCHBOARD_BYPASS=1 runs Claude without routing.
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
    case "statusline":
        commands.statusline()
    case "doctor":
        commands.doctor(args)
    case "log":
        commands.log(args)
    case "import-legacy":
        try commands.importLegacy(args)
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
