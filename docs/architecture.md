# Architecture

Spillover is one Swift package with a UI-free core library and three thin executables.

```text
SpilloverCore (library, no UI)
 ├─ spillover          CLI
 ├─ spillover-launch   launcher that runs in place of Claude
 └─ SpilloverApp       menu bar app (SwiftUI)
```

Dependencies point one way: executables depend on the core, never on each other. All rules live in
the core; the executables translate user input into core calls and print or draw the result.

## Single owners

Each concern has exactly one owner. Adding behaviour means extending that owner, not writing a
second implementation elsewhere. `Tests/SpilloverCoreTests/ArchitectureTests.swift` fails when a
second implementation appears.

| Concern | Owner | Enforced by |
| --- | --- | --- |
| Reading the process environment and well-known paths | `Config/SBEnvironment.swift` (`SBEnvironment`, `SBPaths`) | `testOnlyConfigReadsProcessEnvironment` |
| Starting other processes | `Profiles/CommandRunner.swift` (`CommandRunning`) | `testOnlyCommandRunnerStartsProcesses` |
| Replacing the process with Claude (`execve`) | `spillover-launch/main.swift` | `testOnlyTheLauncherExecs` |
| How a profile changes Claude's environment | `Profiles/ProfileEnvironment.swift` | `testOnlyProfileEnvironmentNamesTheConfigVariable` |
| Canonical paths | `Routing/PathNormalizer.swift` | used by every comparison |
| Which folder a route covers | `Routing/RouteTable.swift` | `testOnlyRouteTableMatchesFolders` |
| Which account a folder gets | `Routing/Resolver.swift` | the launcher, CLI and app all call it |
| Owner-only files and atomic writes | `Security/SafeFS.swift` | permission tests |
| Scrubbing text before logs | `Security/Redaction.swift` | `RedactionTests` |
| Editing VS Code settings | `Integrations/JSONCDocument.swift`, `VSCodeInstaller.swift` | `testExecutablesStayThin` |
| Keychain (names only) | `Profiles/KeychainSlot.swift` | `testKeychainIsNeverReadForSecrets` |
| Which account an Auto folder gets | `Routing/AutoPolicy.swift` (policy and `auto.json`), called only by the resolver | `AutoPolicyTests` |
| Moving a conversation's history between accounts | `Sessions/Conversations.swift` (`ConversationStore`) | `ConversationTests` |
| Ending another process (a chat being moved) | `Sessions/SessionControl.swift` | `testOnlySessionControlSignalsProcesses` |
| Network | none — Spillover makes no requests | `testNoNetworkClients` |

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

`SPILLOVER_BYPASS=1` skips the decision. `RealClaudeLocator` never returns Spillover's own
launcher or shim, so a launch cannot loop.

## Usage

Limits are read the way Claude Code's `/usage` reads them, with no message sent:
`AccountUsageFetcher` runs `claude -p /usage --output-format json --no-session-persistence` with
the account's environment, from Spillover's own `tmp/usage-check` folder. That command is local (no
model request, zero tokens); the CLI asks Anthropic for the account's usage with its own login and
caches the answer in the account's `.claude.json` (`cachedUsageUtilization`). Spillover reads only
that key's percentages and reset times. The app does this at launch, every five minutes, on Refresh
and when the menu bar popover opens after a minute or more.

Optionally, in Terminal chats, Claude Code passes `rate_limits` (5-hour, 7-day, spend limit) to the statusline command on stdin.
`spillover statusline` stores them per profile (`usage/<profile>.json`) and then runs the user's
original statusline with the same input. Profile detection: `SPILLOVER_PROFILE` (set by the
launcher), then `CLAUDE_CONFIG_DIR`, then Default.

`LocalUsageScanner` reads `<profile>/projects/**/*.jsonl`, counting only usage fields, deduplicated
by message id.

## Running sessions

`Sessions/SessionScanner.swift` lists the user's own `claude` processes with `proc_listallpids`,
`proc_pidpath`, `sysctl(KERN_PROCARGS2)` and `proc_pidinfo(PROC_PIDVNODEPATHINFO)`. While parsing a
process's arguments it keeps exactly two environment variables (`CLAUDE_CONFIG_DIR`,
`SPILLOVER_PROFILE`) and the conversation id (`--resume`), and discards the rest. Each session is
compared with today's resolution of its folder to flag sessions that need moving after a
reassignment (in Auto folders, only when their account ran low).

## Files written

All under `~/.spillover` (override with `SPILLOVER_HOME`), directories `0700`, files `0600`,
written atomically:

```text
profiles.json  routes.json  install-manifest.json  prices.json (user-provided)
profiles/<id>/        isolated Claude config directories
bin/                  spillover-launch, spillover
shims/claude          symlink to the launcher (PATH shim)
logs/launch.log       one line per launch decision, no arguments
backups/              editor settings before each edit
usage/                captured limits and the statusline chain
tmp/                  short-lived Terminal scripts for login
```


## Moving a chat to another account

The VS Code extension starts every chat as `claude --resume=<conversation id>`, and reopens a
conversation through `vscode://anthropic.claude-code/open?session=<id>`. Conversation history lives
in each account's own config folder. A move therefore:

1. copies the conversation's transcript, its companion folder and its file checkpoints into the
   target account (`ConversationStore.ensure`, newest copy wins, byte for byte);
2. waits until the chat is between turns (`ConversationActivity`: the last conversational record is
   a finished assistant reply and the file is quiet; automatic moves accept nothing less);
3. ends that one process (`SessionControl.end`, which re-checks the pid is still the same chat).
   It sends SIGINT, which a chat between turns treats as a clean exit, so the editor shows no
   error; SIGTERM follows only if the process is still running five seconds later;
4. focuses the chat's window and opens the reopen link. The extension shows the conversation at
   once and starts its process when the next message is sent, through the launcher, which routes
   it to the folder's (new) account and copies the transcript again if it changed (the ended
   process appends a final bookkeeping record on exit).

The launcher does step 1 on every resumed launch, so reloading a window after reassigning its
folder also moves its chats with their history. No login data is read, copied or changed.

## Editor and extension lifecycle

| Situation | What happens |
| --- | --- |
| Claude extension updated, window not reloaded | The old extension keeps running in that window. The launcher picks the Claude binary of the calling extension: the editor comes from its parent process (the extension host), the version from `CLAUDE_AGENT_SDK_VERSION`, whose last number matches the extension's (SDK 0.3.310 ↔ 2.1.310). Without it, the newest version the editor has not listed in `.obsolete` wins. |
| Claude extension updated, window reloaded | Chats restart with `--resume`; the launcher routes them by folder and brings their history along. Health re-checks the extension's contract. |
| Extension changes what Spillover relies on | Health reports it: a missing wrapper setting (routing stops), or no reopen link (open chats can no longer be moved live; reloading the window still moves them with their history). Live moves are disabled for that editor instead of failing. |
| VS Code (or Cursor, ...) updated or restarted | The user setting persists; every chat restarts through the launcher on its folder's account, with history. |
| Window closed while a move waits | The chat's process is gone; the move ends as "closed" and the chat continues on the new account, with its history, whenever it is reopened. |
| Window closed and reopened later | Same as reload: resumed through the launcher, on the folder's current account. |
| Several windows on one folder | All of the folder's chats move; the reopen link goes to the window brought forward for that folder. |
| The app is not running | Routing, Auto at chat start and history handoff all happen in the launcher; only live moves and notifications need the app. |
| Editor not connected | Live moves are refused with a pointer to Setup (a reopened chat would not change account). |
| Terminal chats | Not moved automatically; they switch the next time `claude` starts in that folder. |
| Remote windows (SSH, containers) | Not supported: Claude runs on the remote machine, outside Spillover's reach. |
