# Changelog

## 0.1.0 (2026-10-27)

First public release.

- Assign each project folder to a Claude subscription. Every Claude session started in that
  folder (VS Code's Claude panel, VS Code's terminal, any other terminal) uses that account.
- Move open VS Code chats to another account with their history, after the current reply.
- Auto folders: new chats start on the account with the most room; open chats move on when an
  account reaches 90% (configurable).
- Session and weekly limits for every account, read the way `/usage` does, with pace forecasts,
  short warnings and optional notifications at 80% and 95%.
- Token totals per day, model and folder from local session logs.
- Running sessions: which chat is on which account, with a move button when one is behind.
- Menu bar popover with every account at a glance; light, dark or system appearance.
- Every change to editor and shell settings is backed up and can be undone in one step.
