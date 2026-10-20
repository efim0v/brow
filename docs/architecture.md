# Architecture

Brow is one SwiftPM package with no dependencies: the notch with its limits and its pet, the Workspaces engine and its screens, one Settings window, and the `brow` command-line tool. The notch panel is Brow's one window besides Settings: Limits and, while Workspaces is on, Projects. Until 0.4 the Workspaces half was a separate app, Grove, in its own repository; it came into this one with its history, so `git log --follow` and `git blame` reach every Grove commit.

## Modules

```
GroveCore            ← no dependencies
   ├── GroveAppKit   ← Workspaces' screens and engine state
   │      └── BrowKit       ← the notch, the limits, the pet, Settings, hosting Workspaces
   │             └── BrowApp       ← main.swift
   └── brow-cli      ← the `brow` tool (`grove` is a second name)
```

| Target | What it is |
|---|---|
| `GroveCore` | Accounts, Keychain credentials, the usage and profile endpoints, token refresh (the notch's), and git, worktrees, cmux, Claude Code sessions, the shared session store, the transcript safety net, session migration and code statistics (Workspaces'). |
| `GroveAppKit` | Workspaces' screens (`RootView` and its routes), their state (`AppState`) and the engine's launch work and cadence (`WorkspacesEngine`). It draws no window of its own and never imports `BrowKit`: what it needs from the app hosting it comes in as values, closures, the host's accounts (`HostAccount`), the `groveHost` and `groveAccent` environment values and the `AccountLimitsProviding` protocol. |
| `BrowKit` | The notch (`NotchPanelController`, its shell `NotchShellView` and sections `NotchSections`, `LimitsSection`, `PanelView`), the limits (`LimitsStore`), the pet (`PetController` and the rest of `Pet/`), the Settings window, and `WorkspacesHost`, Brow's side of Workspaces, with the Projects section (`ProjectsSection`). |
| `BrowApp` | `main.swift`: `--snapshot` and `--cmux-probe`, then the app. |
| `brow-cli` | The command-line tool. |

The module names `GroveCore` and `GroveAppKit` are kept for 0.4.0 so history and blame stay simple; they are internal names, not the product's.

## How Workspaces is hosted

`WorkspacesHost` decides at launch, through `WorkspacesActivation`, whether anything of the engine runs:

- **off** — no engine runs. The one exception is a status line Workspaces captured: Claude Code keeps running the wrapper, which keeps writing `<account>/grove/usage/`, so Settings lists those accounts from Grove's `config.json`, read without an engine (`reloadDormantAccounts`), and offers to give each status line back. That change, and taking out such an account whose folder is gone, is made on an `AppState` built for it alone (`withoutEngine`): not while Grove.app runs, and under the engine's lock. The notch panel has no Projects section. A Brow-only user has no Grove config to read, and stays here until they turn Workspaces on.
- **on** — when Brow's own setting says so, or, before the user has chosen, when `~/Library/Application Support/Grove/config.json` exists. The host creates the state with `capturesByDefault = false` and the engine (`startEngine()`: adopting signed-in folders and Brow's accounts, the first capture read, account names, the 90 s cadence of captures and safety net, the offscreen pre-render), registers the Projects section with the notch panel and puts up the menu-bar item that opens it.
- **paused** — wanted, but Grove.app (`dev.artemefimov.grove3`, or the older `dev.artemefimov.grove`) is running, or another copy of Brow runs Workspaces: a second install, or the build `Scripts/dev-run.sh` starts. No engine runs; Projects says why and offers **Quit Grove** or **Try Again**. Two engines would race on Grove's `config.json` (an atomic replace, the last writer wins) and run two safety nets. Leaving pause, the host reads the config afresh.

Grove.app starting or quitting while Brow runs is seen through NSWorkspace's `runningApplications`, observed: its launch and quit notifications leave out agent apps (`LSUIElement`), which Grove.app is. The engine's 90 s tick checks again before it runs, **Quit Grove** watches the app it asked to quit, and `AppState.mayWrite` refuses a config write in the moment before Workspaces has paused. An action that edits an account's files before it saves the config — the capture switch, Share sessions — asks first and changes nothing when the save would be refused. With Workspaces off, Grove.app running decides nothing, but Settings still waits for it to quit before it changes Grove's files.

Copies of Brow are told apart by a lock rather than by bundle id, since the development build runs as a bare executable with none: an engine holds an advisory lock (`flock`) on `workspaces.lock` beside Grove's `config.json` while it runs (`WorkspacesEngineLock`), and a copy that finds it taken waits. The kernel lets go of the lock when its process exits. The waiting copy tries again when the running apps change, when its panel opens, and on **Try Again**. Giving a status line back while Workspaces is off takes the same lock for the moment of the write.

**One window.** Workspaces' screens are the Projects section of the notch panel: one width (460 pt of black), one height — the Limits section's own laid-out height, at least 480 pt while there are sections, at most down to 12 pt above the Dock — so switching sections or pushing a screen never moves the outline. `RootView` runs in the `.notch` host there: no window frame, no sheets (the launch form and the delete confirmation are inline), Brow's cream as the accent. Hovered, the panel opens and closes with the pointer; any click inside pins it (`NotchPanelController.pin`), and only then may the non-activating panel become key, so its fields take the keyboard without activating Brow. SwiftUI's `onHover` does not fire in this panel, so the controller's own mouse monitors say which calendar day and which session card the pointer is over (`CalendarHoverTracker`, `NotchCardHover`), and the sections are told when the panel is closed (`groveIsShowing`), so nothing in them moves while they wait, invisible, in the tree. A pinned panel closes on Esc at a section's root, a click outside, the pin, or a hand-off (Go, Resume, Start session, Show in Finder: `AppState.onHandOff`), and every close latches the hover off until the pointer has left the expanded area once (`NotchHoverLatch`). The menu-bar item, **Show Projects** and reopening Brow open it pinned on Projects, with "Show Brow in the notch" off too. Projects marks itself open to the engine (`AppState.isPanelOpen`) only once it has been in view for a quarter of a second, and opening again within 10 s of a refresh does not refresh again.

**What runs.** A session's state is one mapping (`SessionState`) of Claude Code's record in `<account>/sessions/<pid>.json` (`SessionRegistry`), live while `kill(pid, 0)` succeeds and the process started when the record says; there is no `ps` or `lsof` anywhere. A process without a record (an older Claude Code) comes from Brow's look at the kernel's process table (`ProcessTable.claudeCodeFolders`, handed to the engine as `AppState.runningClaude`; tests and renders hand it none) and is given one session: the one its command line names, else the newest unclaimed transcript in its folder. The index (`refreshSessionIndex`) reads each project's newest twelve sessions and any older one that runs; previews are the last 64 KB of a transcript (`TranscriptTail`), cached by inode, size and modification time. While the list is in view, `SessionWatch` follows each account's `sessions/` folder and each live session's process exit (dispatch sources), looks at the live transcripts every 1.5 s and at the processes every 5 s for folders to suggest; the list keeps its order while it is in view (`ProjectsOrder`).

**Agents.** `AgentCommsReader` (GroveCore) reads both ends of every message from what Claude Code writes — `SendMessage` and its result in the sender's transcript, the envelope in the receiver's (`AgentEnvelope`), queued commands, team mailboxes, subagent sidecars — and joins them by `msg_id`, else by sender, receiver and body within two minutes. It reads whole lines from where it left off — never more than a transcript's last 512 KiB at once, so a file new to it, rewritten, or grown while nothing watched is taken up from its end — and never opens an inbox key or a socket. `AgentsObserver` (GroveAppKit) drives it on one serial queue from an FSEvents stream over each account's `projects/`, `sessions/` and `teams/`, only while the notch panel is open (from a quarter of a second on, so a pointer passing over the notch starts nothing) and for 30 s after; a cold start reads the transcripts written in the last half hour, and what is older than an hour is forgotten. `AgentsScene` and `AgentsLayout` turn the graph into what the tab draws, and `AgentsSection` (BrowKit) is the tab, registered beside Projects while Workspaces is wanted; it feeds the switch's dot.

**Accounts.** The pickers list Brow's accounts (`AppState.hostAccounts`, from `LimitsStore.rows`: Brow's order, names, hidden flags and calendar colours), joined to Grove's `AccountConfig` by folder. Grove's account name stays the key sessions, captures, project defaults and launches carry; an account Brow shows that Grove's config lacks is adopted under its email, and one only Grove's config knows stays in it for its old sessions but is offered nowhere. Launches start with Brow's environment (`AppState.launchEnvironment`: `env -u CLAUDE_CONFIG_DIR` for `~/.claude`, `CLAUDE_CONFIG_DIR=…` for the others, and the browser router).

## Files on disk

Nothing moved in 0.4.0. Brow keeps its own folder; Workspaces keeps Grove's.

| Data | Place | Written by |
|---|---|---|
| Brow's settings, Workspaces' on/off and menu-bar item (and 0.4's panel material, kept but no longer read) | `~/Library/Application Support/Brow/config.json` (`.bak` beside it when a value could not be read) | Brow |
| Limits cache, token-refresh bookkeeping | `…/Brow/limits.json`, `…/Brow/token-attempts.json` | Brow |
| The pet's hunger, the readings it has seen, the days it was fed | `…/Brow/pet.json` | Brow |
| Per-account browser profiles | `…/Brow/browser-profiles/<accountKey>/` | the browser router |
| Request pacing | `…/Grove/oauth-usage-ledger.json` | Brow (under Grove's folder for historical reasons) |
| Projects, accounts, safety-net settings | `…/Grove/config.json` (+ `.bak`) | Workspaces; Grove 0.2.2 can still read and write it |
| One engine at a time | `…/Grove/workspaces.lock` (empty; locked while an engine runs) | Workspaces |
| Status-line wrappers | `…/Grove/bin/grove-statusline-<dir>.sh` | Workspaces. Never moved: every captured account's `settings.json` names its script by absolute path |
| Code statistics | `…/Grove/stats/<project>.json` | Workspaces |
| Status-line captures | `<account>/grove/usage/<session>.json` | the wrapper |
| Transcript safety net | `~/.claude/grove/transcripts/<accountKey>/<cwd>/<id>.jsonl` | Workspaces, within Claude Code's retention; put back only on Restore |
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

One subsystem, `dev.artemefimov.brow`. The notch logs under `limits`, `tokens`, `panel` and `notify`, its pet under `pet`; Workspaces under `workspaces` and `perf`; the services both use under `keychain`, `TokenKeeper`, `ClaudeService` and `ProcessRunner`.

```sh
log stream --level info --predicate 'subsystem == "dev.artemefimov.brow"'
```
