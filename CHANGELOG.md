# Changelog

## 0.1.1 (2026-10-28)

Fixes for moving chats between accounts.

- Auto no longer cuts off background subagents and background commands when it moves a chat: a
  chat that had background work running is resumed on the new account ("The account switched,
  please resume all work.") so that work restarts there.
- Auto folders keep one account until it reaches the threshold, instead of picking again on every
  launch, so a window and its chats no longer switch back and forth.
- Open chats move only when their account is actually full, not when a limit is merely forecast
  to run out; a pending move is dropped when the account has room again.
- Moving a chat no longer opens a new VS Code window or a second copy of the chat: it stays in its
  panel and its next message continues on the new account.
- Accounts can share your MCP servers (Accounts → Shared from your normal setup → MCP servers):
  Claude reads them from your normal login's settings; Spillover never copies them.
- Limits are picked up within about 30 seconds of Claude saving them.
- Helper processes (the Chrome extension host, plugin runs in temporary folders) are no longer
  listed or moved as chats.

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
