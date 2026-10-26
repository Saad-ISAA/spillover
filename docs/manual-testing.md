# Manual test checklist

Automated tests cover the core with temporary directories. These steps check the parts that need a
real Mac, real Claude subscriptions and a real VS Code. You need two Claude subscriptions (two
different logins) to test routing end to end.

Build and open the app:

```sh
scripts/build-app.sh
open dist/Switchboard.app
```

## 1. First launch

- [ ] The main window opens by itself with the *Getting started* checklist.
- [ ] A Switchboard icon is in the menu bar; there is no Dock icon.
- [ ] *Accounts* shows *Default* with your current login (masked email, plan).

## 2. Accounts

- [ ] *Add account* → name "Work", keep the default shared items, *Open the login now* on → *Add*.
- [ ] A Terminal window runs `claude auth login`; log in with subscription A in the browser.
- [ ] Within a few seconds the app shows "Work" as logged in with A's (masked) email and plan.
- [ ] Repeat for "Personal" with subscription B.
- [ ] In Terminal: `CLAUDE_CONFIG_DIR=~/.switchboard/profiles/work claude auth status` shows A;
      the same for `personal` shows B; plain `claude auth status` still shows your Default login.

Already have hand-made `CLAUDE_CONFIG_DIR` folders? Test *Add account → Existing config folder*
instead; the existing login must be kept.

## 3. Folders

- [ ] *Folders → Assign a folder… → Work…* → choose project folder X.
- [ ] Assign project folder Y to Personal.
- [ ] *Which account will Claude use here?* → X/subfolder shows Work "via X"; an unassigned folder
      shows *No assignment*.

## 4. VS Code panel

- [ ] *Setup → Visual Studio Code → Connect*. If another wrapper was set, the app asks before
      replacing it.
- [ ] Open X and Y in two VS Code windows (`code -n X`, `code -n Y`).
- [ ] In each window start a new Claude chat, send "hi", open *Account & Usage*: X shows
      subscription A, Y shows B.
- [ ] *Sessions* lists both chats with the right account and "As assigned".
- [ ] *Health → Recent launches* shows `routed` entries for both folders.
- [ ] An unassigned folder's window still uses the Default login.

## 5. Reassignment

- [ ] Reassign Y to Work. *Sessions* marks Y's running chat "Restart for Work" and the popover
      shows the stale-session hint.
- [ ] Start a new chat in Y: it is on A now; the hint disappears.

## 6. Refusal (fail closed)

- [ ] Rename `~/.switchboard/profiles/personal` temporarily, assign a folder to Personal, start a
      chat there: Claude refuses with a message naming the missing folder. Other folders still work.
- [ ] `SWITCHBOARD_BYPASS=1 claude` in that folder starts Claude without routing.
- [ ] Rename the folder back.

## 7. Terminals

- [ ] *Setup → Terminals* on; open a new terminal.
- [ ] `cd X && claude auth status` → A; `cd Y && claude auth status` → assigned account;
      elsewhere → Default.
- [ ] VS Code's integrated terminal behaves the same.

## 8. Usage

- [ ] *Usage → Track limits* on for Work and Personal (your own statusline, if any, still shows).
- [ ] After a Claude reply in each account, the popover shows 5h / 7d bars for it.
- [ ] *Usage → Scan* shows token totals and top folders.
- [ ] *Setup → Preferences*: open at login, notifications, menu bar percentage.

## 9. Undo

- [ ] *Setup → Undo all changes*.
- [ ] VS Code `settings.json` and `~/.zshrc` are back to their previous contents (compare with the
      backup in `~/.switchboard/backups`), and each account's `settings.json` has its old
      `statusLine`.
- [ ] New Claude chats use the Default login everywhere again. Accounts and folder assignments are
      still listed in the app.

## 10. Health

- [ ] *Health → Run checks* shows no failures on a working setup.
- [ ] `chmod 666 ~/.switchboard/routes.json` → Health reports it and new chats in any folder are
      refused. `chmod 600 ~/.switchboard/routes.json` restores normal behaviour.
