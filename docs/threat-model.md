# Threat model

## What Switchboard protects

1. **Subscription credentials.** Claude Code's OAuth logins live in the macOS Keychain, one item per
   config directory. Losing one means account takeover.
2. **Correct attribution.** Work done in a folder must be billed to the subscription the user
   assigned. Silently using another account is a correctness and, for team plans, a compliance
   failure.
3. **The user's tool configuration.** VS Code settings, shell startup files and Claude settings
   belong to the user and must survive Switchboard being installed, updated and removed.

## Trust boundaries

```text
User ──► Switchboard app / CLI ──► ~/.switchboard (owner-only files)
                                   │
VS Code extension ──► switchboard-launch ──► reads routes/profiles ──► execs real Claude
Terminal shell ─────► shims/claude ──────┘
Claude Code ──► switchboard statusline (stdin JSON) ──► usage/<profile>.json
```

- Switchboard runs entirely as the user. It has no daemon, no privileged helper and no network
  access.
- The launcher runs on **every** Claude start, so whatever it reads (routes, profiles, its own
  binary) is security-relevant.

## Threats and controls

| Threat | Control | Where |
| --- | --- | --- |
| Switchboard leaks a token (log, crash, UI) | Never reads Keychain item data; only checks item names. Launch log records no arguments. One redaction function for log text. | `KeychainSlot.swift`, `LaunchLog.swift`, `Redaction.swift` |
| Another local user edits routes to swap accounts | Routes and the Switchboard folder must be owned by the user and not group/world-writable; otherwise every launch is refused. | `RouteStore.load` |
| Another local user replaces the launcher | Launcher lives in a `0700` folder; Health reports ownership/permission problems. | `SafeFS`, `Doctor` |
| A broken assignment silently bills another subscription | Fail closed: a routed folder whose profile or directory is missing refuses to start. Unrouted folders are untouched by design. | `Resolver`, `LaunchPlanner` |
| Launch loop (shim executes itself) | Locator excludes the launcher and the shims folder by real path. | `RealClaudeLocator` |
| Crafted folder names (newlines, quotes, `$()`) | No shell parsing of paths; generated scripts quote every value; log lines escape newlines. | `PathNormalizer`, `ShellQuote`, `LaunchLog` |
| Editor settings corrupted by an edit | Byte-preserving JSONC edit of one key; verify before write; timestamped backup; exact restore. | `JSONCDocument`, `VSCodeInstaller` |
| Another tool's wrapper clobbered | Refuse to replace without explicit confirmation; restore it on disconnect. | `VSCodeInstaller` |
| Credentials shared between accounts by mistake | Sharing uses an allow-list; identity, credential and history files are on a never-share list. | `ProfileSharing` |
| An extension update changes the wrapper contract | Health checks the installed extension's setting and its scope. | `ExtensionContract` |
| Supply chain | No third-party dependencies. | `Package.swift` |

## Out of scope

- A local attacker running as the same user (they can read the Keychain through Claude Code itself).
- Remote development hosts (SSH, containers): Claude runs there, outside Switchboard.
- Provider terms of service: Switchboard manages accounts you own; it does not rotate accounts to
  get around limits.
