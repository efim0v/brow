# Architecture

Brow is one SwiftPM package with no dependencies: the notch and its limits, the Workspaces engine and panel, one Settings window, and the `brow` command-line tool. Until 0.4 the Workspaces half was a separate app, Grove, in its own repository; it came into this one with its history, so `git log --follow` and `git blame` reach every Grove commit.

## Modules

```
GroveCore            ← no dependencies
   ├── GroveAppKit   ← the Workspaces panel and engine state
   │      └── BrowKit       ← the notch, the limits, Settings, hosting Workspaces
   │             └── BrowApp       ← main.swift
   └── brow-cli      ← the `brow` tool (`grove` is a second name)
```

| Target | What it is |
|---|---|
| `GroveCore` | Accounts, Keychain credentials, the usage and profile endpoints, token refresh (the notch's), and git, worktrees, cmux, Claude Code sessions, the shared session store, the transcript safety net, session migration and code statistics (Workspaces'). |
| `GroveAppKit` | The Workspaces panel (`WorkspacesMenuBarController`, `RootView` and its screens) and its state (`AppState`). It never imports `BrowKit`: what it needs from the app hosting it comes in as values, closures and the `AccountLimitsProviding` protocol. |
| `BrowKit` | The notch (`NotchPanelController`, `PanelView`), the limits (`LimitsStore`), the Settings window, and `WorkspacesHost`, Brow's side of Workspaces. |
| `BrowApp` | `main.swift`: `--snapshot` and `--cmux-probe`, then the app. |
| `brow-cli` | The command-line tool. |

The module names `GroveCore` and `GroveAppKit` are kept for 0.4.0 so history and blame stay simple; they are internal names, not the product's.

## How Workspaces is hosted

`WorkspacesHost` decides at launch, through `WorkspacesActivation`, whether anything of the engine runs:

- **off** — no `AppState` exists, so not even Grove's `config.json` is read. A Brow-only user stays here until they turn Workspaces on.
- **on** — when Brow's own setting says so, or, before the user has chosen, when `~/Library/Application Support/Grove/config.json` exists. The host creates the state with `capturesByDefault = false`, the menu-bar controller and the engine (`startEngine()`: adopting signed-in folders, the first capture read, account names, the 90 s cadence of captures and safety net, the offscreen pre-render).
- **paused** — wanted, but Grove.app (`dev.artemefimov.grove3`, or the older `dev.artemefimov.grove`) is running. No engine runs; the panel says why and offers **Quit Grove**. Two engines would race on Grove's `config.json` (an atomic replace, the last writer wins) and run two safety nets. Leaving pause, the host reads the config afresh.

The notch panel's Workspaces button collapses the notch and latches its hover off until the pointer has left the expanded area once (`NotchHoverLatch`): the notch's window sits above the Workspaces panel, which opens right under it. The Workspaces panel hangs under its menu-bar item, or at the screen's top-right corner when macOS hides the item (`PanelAnchor`).

## Files on disk

Nothing moved in 0.4.0. Brow keeps its own folder; Workspaces keeps Grove's.

| Data | Place | Written by |
|---|---|---|
| Brow's settings, Workspaces' on/off, menu-bar item and panel material | `~/Library/Application Support/Brow/config.json` (`.bak` beside it when a value could not be read) | Brow |
| Limits cache, token-refresh bookkeeping | `…/Brow/limits.json`, `…/Brow/token-attempts.json` | Brow |
| Per-account browser profiles | `…/Brow/browser-profiles/<accountKey>/` | the browser router |
| Request pacing | `…/Grove/oauth-usage-ledger.json` | Brow (under Grove's folder for historical reasons) |
| Projects, accounts, safety-net settings | `…/Grove/config.json` (+ `.bak`) | Workspaces; Grove 0.2.2 can still read and write it |
| Status-line wrappers | `…/Grove/bin/grove-statusline-<dir>.sh` | Workspaces. Never moved: every captured account's `settings.json` names its script by absolute path |
| Code statistics | `…/Grove/stats/<project>.json` | Workspaces |
| Status-line captures | `<account>/grove/usage/<session>.json` | the wrapper |
| Transcript safety net | `~/.claude/grove/transcripts/<accountKey>/<cwd>/<id>.jsonl` | Workspaces, within Claude Code's retention |
| Shared-store links and backups | `<account>/{file-history,tasks,session-env}`, `projects/<cwd>`; `<account>/grove-backup/` | Workspaces |

## Contracts

These hold the halves together; change one side and the other breaks silently, so change them together.

1. **`accountKey`** — the first 8 hex of `sha256(<expanded config dir, no trailing slash>)`. One number, three users: Claude Code's Keychain item name (`Claude Code-credentials-<key>`), the safety net's folders, and the browser profile folders. It is implemented twice: `GroveCore/Model/Paths.swift` and, in shell, `Resources/brow-browser.sh`. `BrowserRouterContractTests` runs the script's `--print-key` and pins it to the Swift one.
2. **Account folders** — `~/.claude` plus `~/.claude-accounts/*`. Brow's one-click sign-in creates `account-N`; Workspaces adopts any signed-in folder it finds. Workspaces' accounts outside those two places join the notch's scan at run time. A Brow account and a Workspaces account are the same account when they share a config folder (`WorkspacesAccountJoin`).
3. **The browser router** — `Brow.app/Contents/Resources/brow-browser`. Brow's sign-ins and every session Workspaces launches pass it as `BROWSER=`, so `claude auth login` opens the account's own browser profile.
4. **Status-line captures** — written by the wrapper Workspaces installs (`StatuslineInstaller`) for accounts whose capture is on, read by both halves through `UsageReader`. They are what makes the notch's numbers fresh between requests.
5. **Claude Code's own files** — `settings.json`'s `statusLine` (only for accounts with capture on), `.claude.json`'s onboarding stamp and theme, and the merges a migration makes. All of them go through `HotJSONFile`: Claude Code's own lock, a compare-before-swap, no write when nothing changes, and no write at all over a file that does not parse.

## Hot migration and files a running `claude` owns

A session can migrate into an account **while that account is in use**. The target's `.claude.json`, `settings.json` and plugin registries are merged through `HotJSONFile`. Transcripts are copied into the target, never hardlinked across accounts — hardlinks are reserved for the safety net, where exactly one writer exists.

What is still refused, deliberately: anything that would give **one session** two writers (sharing a session that is running; resuming under account B a session that is live under account A).

## Logs

One subsystem, `dev.artemefimov.brow`. The notch logs under `limits`, `tokens`, `panel` and `notify`; Workspaces under `workspaces` and `perf`; the services both use under `keychain`, `TokenKeeper`, `ClaudeService` and `ProcessRunner`.

```sh
log stream --level info --predicate 'subsystem == "dev.artemefimov.brow"'
```
