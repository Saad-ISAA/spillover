# Architecture

Switchboard is one Swift package with a UI-free core library and three thin executables.

```text
SwitchboardCore (library, no UI)
 ├─ switchboard          CLI
 ├─ switchboard-launch   launcher that runs in place of Claude
 └─ SwitchboardApp       menu bar app (SwiftUI)
```

Dependencies point one way: executables depend on the core, never on each other. All rules live in
the core; the executables translate user input into core calls and print or draw the result.

## Single owners

Each concern has exactly one owner. Adding behaviour means extending that owner, not writing a
second implementation elsewhere. `Tests/SwitchboardCoreTests/ArchitectureTests.swift` fails when a
second implementation appears.

| Concern | Owner | Enforced by |
| --- | --- | --- |
| Reading the process environment and well-known paths | `Config/SBEnvironment.swift` (`SBEnvironment`, `SBPaths`) | `testOnlyConfigReadsProcessEnvironment` |
| Starting other processes | `Profiles/CommandRunner.swift` (`CommandRunning`) | `testOnlyCommandRunnerStartsProcesses` |
| Replacing the process with Claude (`execve`) | `switchboard-launch/main.swift` | `testOnlyTheLauncherExecs` |
| How a profile changes Claude's environment | `Profiles/ProfileEnvironment.swift` | `testOnlyProfileEnvironmentNamesTheConfigVariable` |
| Canonical paths | `Routing/PathNormalizer.swift` | used by every comparison |
| Which folder a route covers | `Routing/RouteTable.swift` | `testOnlyRouteTableMatchesFolders` |
| Which account a folder gets | `Routing/Resolver.swift` | the launcher, CLI and app all call it |
| Owner-only files and atomic writes | `Security/SafeFS.swift` | permission tests |
| Scrubbing text before logs | `Security/Redaction.swift` | `RedactionTests` |
| Editing VS Code settings | `Integrations/JSONCDocument.swift`, `VSCodeInstaller.swift` | `testExecutablesStayThin` |
| Keychain (names only) | `Profiles/KeychainSlot.swift` | `testKeychainIsNeverReadForSecrets` |
| Network | none — Switchboard makes no requests | `testNoNetworkClients` |

## Registries

- **Profiles** (`profiles.json`, `ProfileStore`): accounts. The *Default* profile is virtual: it means
  "run Claude with `CLAUDE_CONFIG_DIR` unset". It is never written as a path to `~/.claude`, because
  Claude Code derives the Keychain item from a set variable, so an explicit default path would read
  a different, empty login.
- **Routes** (`routes.json`, `RouteStore`): folder → profile. Longest folder prefix wins.
- **Install manifest** (`install-manifest.json`): what was changed in which editor settings, the
  previous value and a hash of the edited file, so uninstall can restore bytes exactly.
- **Statusline chain** (`usage/statusline-chain.json`): each profile's original `statusLine`, so it
  keeps running and can be restored.

Adding a provider (Codex, others) means a new `Provider` case and an environment rule in
`ProfileEnvironment`; the registries and the resolver do not change.

## Launch decision

```text
cwd ──► RouteStore.load()
          missing ─────────────────────────────► unrouted (environment untouched)
          corrupt / insecure ──────────────────► refuse
          loaded ──► RouteTable.match(cwd)
                        none ──────────────────► unrouted
                        route ──► profile exists and its directory exists?
                                    no ────────► refuse
                                    yes ───────► routed: apply ProfileEnvironment, exec real Claude
```

`SWITCHBOARD_BYPASS=1` skips the decision. `RealClaudeLocator` never returns Switchboard's own
launcher or shim, so a launch cannot loop.

## Usage

Claude Code passes `rate_limits` (5-hour, 7-day, spend limit) to the statusline command on stdin.
`switchboard statusline` stores them per profile (`usage/<profile>.json`) and then runs the user's
original statusline with the same input. Profile detection: `SWITCHBOARD_PROFILE` (set by the
launcher), then `CLAUDE_CONFIG_DIR`, then Default.

`LocalUsageScanner` reads `<profile>/projects/**/*.jsonl`, counting only usage fields, deduplicated
by message id.

## Running sessions

`Sessions/SessionScanner.swift` lists the user's own `claude` processes with `proc_listallpids`,
`proc_pidpath`, `sysctl(KERN_PROCARGS2)` and `proc_pidinfo(PROC_PIDVNODEPATHINFO)`. While parsing a
process's arguments it keeps exactly two environment variables (`CLAUDE_CONFIG_DIR`,
`SWITCHBOARD_PROFILE`) and discards the rest. Each session is compared with today's resolution of
its folder to flag sessions that need a restart after a reassignment.

## Files written

All under `~/.switchboard` (override with `SWITCHBOARD_HOME`), directories `0700`, files `0600`,
written atomically:

```text
profiles.json  routes.json  install-manifest.json  prices.json (user-provided)
profiles/<id>/        isolated Claude config directories
bin/                  switchboard-launch, switchboard
shims/claude          symlink to the launcher (PATH shim)
logs/launch.log       one line per launch decision, no arguments
backups/              editor settings before each edit
usage/                captured limits and the statusline chain
tmp/                  short-lived Terminal scripts for login
```
