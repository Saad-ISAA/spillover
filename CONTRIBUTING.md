# Contributing

Thanks for helping. Start with [docs/development.md](docs/development.md) and
[docs/architecture.md](docs/architecture.md).

- Run `swift test` before opening a pull request. `ArchitectureTests` will tell you if a change
  adds a second implementation of something that already has an owner.
- Keep the core free of UI imports; keep executables thin.
- Bug fixes come with a test that fails before the fix.
- Security-relevant changes (launcher, routing, installers, anything touching Keychain or user
  files) should update [docs/security/controls.yaml](docs/security/controls.yaml) and
  [docs/threat-model.md](docs/threat-model.md).
- Never commit personal paths, emails, tokens or Keychain identifiers in code, tests or docs; use
  `/Users/example/...` style fixtures.
