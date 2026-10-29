# Changelog

## 0.1.6 (unreleased)

- Fixed: resuming a chat after its limit reset failed with "its message box could not be focused"
  when Spillover was in the background (as it is overnight): macOS does not let a background app
  bring VS Code to the front. Spillover now types into the chat without bringing anything to the
  front, so it works while you use other apps or are away, and never takes the screen from you.
  A failed try is retried twice, two minutes apart, and the Overview shows "Retrying".

- The Accessibility permission for resuming chats is checked again every 30 seconds and whenever
  Spillover comes to the front, so its warning clears without a restart, and it explains that
  after an update macOS may need Spillover removed from the Accessibility list and allowed again.

## 0.1.5 (2026-10-29)

- Resume chats automatically (Setup → Auto, off until you turn it on). Spillover types "please
  resume all work" into a chat in its own VS Code panel, and the chat restarts its own subagents
  and background tasks:
  - a minute after a usage limit the chat stopped on resets, in any folder (in an Auto folder,
    as soon as another account has room, with the chat's history copied there);
  - right after Auto moves a chat to another account, so Auto no longer has to wait for the
    chat's background work before moving it.
  The Overview's Auto resume panel shows whether resuming is on and working, and each stopped
  chat with when it resumes (or what happened); Sessions and `spillover stopped` list them too. Spillover only types into
  an idle chat with an empty message box, after you have left the keyboard for a moment, and
  needs the Accessibility permission to do so.

- Fixed: in an Auto folder, a chat you resumed after its account's limit reset was moved to
  another account (and its history copied there) whenever the folder had switched accounts while
  the first one was full. A resumed chat now stays on the account it was on while that account
  has room; the folder's account is used for new chats.

## 0.1.4 (2026-10-28)

- Auto no longer stops a chat's background work (subagents, background commands) when its account
  reaches the threshold: the chat waits until that work is done, then moves at its next pause.
  Only when the account is about to stop working (98% of a limit, or about to run out within 10
  minutes) does a busy chat move anyway; Spillover then says its background work stopped, and
  your next message in that chat continues on the new account.
- Spillover no longer resumes moved chats in a hidden background run. The chat always continues
  in its own VS Code panel, so there is never a second copy of it.

## 0.1.3 (2026-10-28)

- Fixed: after Auto moved a chat that had background work and resumed it on the new account,
  typing in that chat in VS Code started a second copy of it. The copy reported the background
  work as stopped and started it again, so the same subagents ran twice in the same files. While
  a resumed chat is still working, VS Code now shows that it is busy instead of starting it
  again. Sessions lists it as In background, with Take over to stop it and continue in VS Code
  right away, and Spillover tells you when it has finished.

## 0.1.2 (2026-10-28)

- Fixed: with MCP servers shared, every VS Code chat on that account stopped at once with "Claude
  Code process exited with code 1". The editor passes the Claude binary as the first argument, and
  the MCP option placed in front of it read the binary as a second MCP configuration. The option
  now goes after Claude's own arguments, as a single argument. If you turned MCP servers off to
  work around this, turn them on again under Accounts after updating.

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
