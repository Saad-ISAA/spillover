# Security policy

## Reporting a vulnerability

Please report security issues privately through GitHub's **Report a vulnerability** (Security
advisories) on this repository rather than in a public issue. Include steps to reproduce and the
version (`spillover version`). We aim to acknowledge reports within a week.

Never include real tokens, Keychain contents or personal data in a report.

## Design summary

- Spillover never reads, copies or stores login tokens. It only checks whether a Keychain item
  with a given name exists.
- It makes no network requests of its own. To read limits it runs the official Claude CLI's local
  `/usage` command, which contacts Anthropic with that account's own login.
- Its files are owner-only; if they become writable by others, every Claude launch is refused until
  fixed.
- A folder assigned to an account never silently falls back to another account.
- Every change to editor settings, shell startup files and Claude settings is backed up and
  reversible.

Details: [docs/threat-model.md](docs/threat-model.md) and the control register in
[docs/security/controls.yaml](docs/security/controls.yaml).
