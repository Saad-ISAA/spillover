# Development

```sh
swift build                 # debug build of everything
swift test                  # unit, integration and architecture tests (temp directories only)
scripts/build-app.sh        # release Switchboard.app in dist/
```

Requirements: macOS 14+, Xcode or the Command Line Tools (Swift 6 toolchain; the package uses the
Swift 5 language mode).

## Layout

```text
Sources/SwitchboardCore/
  Config/         SBEnvironment, SBPaths — the only reader of the environment
  Security/       SafeFS (owner-only atomic writes), Redaction
  Profiles/       Profile registry, Keychain slot names, Claude CLI, sharing, command runner
  Routing/        PathNormalizer, RouteTable, RouteStore, Resolver
  Launch/         LaunchPlanner, RealClaudeLocator, LaunchLog, shell shim, Terminal launcher
  Integrations/   JSONC editor, VS Code installer, extension contract, recent workspaces
  Usage/          statusline capture/installer, local token scanner, headroom advisor
  Doctor/         read-only health checks
  Service/        AppService (shared by CLI and app), Setup, legacy import
Sources/switchboard/          CLI
Sources/switchboard-launch/   launcher
Sources/SwitchboardApp/       menu bar app
Tests/SwitchboardCoreTests/   tests, including ArchitectureTests
```

See [architecture.md](architecture.md) for the single-owner rules the tests enforce.

## Trying it without touching your setup

Everything is derived from `$HOME` (and `SWITCHBOARD_HOME`), so a throwaway home is a complete
sandbox:

```sh
DEMO=$(mktemp -d)
mkdir -p "$DEMO/bin" "$DEMO/Code/app"
printf '#!/bin/sh\necho "claude with CLAUDE_CONFIG_DIR=${CLAUDE_CONFIG_DIR:-<unset>}"\n' > "$DEMO/bin/claude"
chmod +x "$DEMO/bin/claude"
export HOME="$DEMO" SWITCHBOARD_REAL_CLAUDE="$DEMO/bin/claude"

.build/debug/switchboard profile create Work
.build/debug/switchboard route set "$DEMO/Code/app" work
cd "$DEMO/Code/app" && "$OLDPWD/.build/debug/switchboard-launch"
```

`SWITCHBOARD_REAL_CLAUDE` points the launcher at a stand-in for Claude.

To look at every screen with realistic sample data (three accounts, limits with a week of
history, a month of token counts), seed a fresh home and capture it in light or dark:

```sh
DEMO=$(mktemp -d)
swift scripts/seed-demo.swift "$DEMO"
scripts/demo-screenshot.sh "$DEMO" popover /tmp/popover.png dark   # or main:overview, main:usage, ...
```

## Conventions

- New behaviour goes into the core's existing owner for that concern (see the table in
  architecture.md). If none fits, add a new owner and a test that keeps it the only one.
- No third-party dependencies without discussion.
- Never read secret Keychain data, never log arguments, never write outside `~/.switchboard`
  except through the installers (which back up and can undo).
