English · [Русский](README.ru.md) · [简体中文](README.zh-CN.md)

Website: [efimov.page/brow](https://efimov.page/brow/)

# Brow — Claude Code usage limits in the MacBook notch, and workspaces for parallel sessions

[![CI](https://github.com/efim0v/brow/actions/workflows/ci.yml/badge.svg)](https://github.com/efim0v/brow/actions/workflows/ci.yml)
[![Latest release](https://img.shields.io/github/v/release/efim0v/brow)](https://github.com/efim0v/brow/releases/latest)
[![License: GPL-3.0](https://img.shields.io/github/license/efim0v/brow)](LICENSE)
[![Platform: macOS 26+ · Apple silicon](https://img.shields.io/badge/platform-macOS%2026%2B%20%C2%B7%20Apple%20silicon-lightgrey)](#requirements)

A macOS app for people who run [Claude Code](https://claude.com/claude-code) on several accounts at once. It does two things:

- **The notch shows the usage and rate limits of every account**: the 5-hour limit, the weekly limit, and when each resets. One click signs you in to an account in a browser profile that belongs to that account alone.
- **Workspaces, in the menu bar, runs parallel Claude Code sessions on a product split across several repositories**: one folder of git worktrees per feature, all on one branch, and a session moves to the account that still has room.

The notch is for looking, Workspaces is for working. Brow works with a single account too: it picks up `~/.claude` by itself and shows that account's limits, and Workspaces stays off until you use it.

**[Download Brow for macOS](https://github.com/efim0v/brow/releases/latest/download/Brow.zip)** or `brew install --cask efim0v/tap/brow` · macOS 26 or later, Apple silicon · [install notes](#install)

> **Coming from Grove?** Grove is now part of Brow. Brow finds your Grove projects and accounts and runs them in Workspaces; [here is what changes](#coming-from-grove).

### Which account still has room

Hover the notch: every account's 5-hour and weekly limits open out of it. Copy an account's launch command and Claude Code starts as that account.

<p align="center"><picture>
  <source media="(prefers-reduced-motion: reduce)" srcset="docs/media/brow-hero-v1.png">
  <source type="image/webp" srcset="docs/media/brow-hero-v1.webp">
  <img src="docs/media/brow-hero-v1.png" width="840" alt="Hovering the notch opens the limits of every account; the launch command of the account with room is copied and Claude Code starts as that account">
</picture></p>

### When each limit resets

The calendar marks every account's weekly resets and subscription renewals. Point at a day to see what frees up.

<p align="center"><picture>
  <source media="(prefers-reduced-motion: reduce)" srcset="docs/media/brow-calendar-v1.png">
  <source type="image/webp" srcset="docs/media/brow-calendar-v1.webp">
  <img src="docs/media/brow-calendar-v1.png" width="840" alt="The reset calendar: pointing at a day shows which account's weekly limit resets or which subscription renews">
</picture></p>

### Sign in again in one click

When an account's sign-in expires, the key next to it starts `claude auth login` for that account and opens the browser profile that belongs to it, already signed in to that account. Other accounts stay signed in.

<p align="center"><picture>
  <source media="(prefers-reduced-motion: reduce)" srcset="docs/media/brow-signin-v1.png">
  <source type="image/webp" srcset="docs/media/brow-signin-v1.webp">
  <img src="docs/media/brow-signin-v1.png" width="840" alt="An expired sign-in: one click on the key opens that account's own browser profile, already signed in, and Claude Code logs in again">
</picture></p>

### One branch across every repository

Workspaces gives each feature of a multi-repo product its own folder, with a git worktree of each repository on the same branch. Claude Code starts there and sees the whole product; ten features in flight are ten folders, and no session can change another's branch.

<p align="center">
  <img alt="Workspaces: the workspaces of a multi-repo project" src="docs/screenshots/workspaces-project.png" width="420" />
  <img alt="Workspaces: sessions across accounts, each with its limits" src="docs/screenshots/workspaces-sessions.png" width="420" />
</p>

All demos and screenshots show made-up demo data.

## What it does

In the notch:

- **Every account at a glance.** For each account: the 5-hour limit, the weekly limit and any model-specific weekly limit, as percent used, with the time until each resets.
- **A reset calendar.** Weekly resets and estimated subscription renewals on a month grid, so you can see which account frees up when.
- **Limit warnings.** Off by default. Turn them on and Brow posts a macOS notification when an account passes 80 % and 95 % of a limit, once per level until it resets.
- **Copy my week.** One button copies a picture of your limits, ready to paste into a chat or a post. Accounts are numbered unless you choose to show their names, and emails never appear.
- **Copy the launch command.** One button copies the command that starts Claude Code as that account.
- **Sign in again, in that account's own browser.** Each account gets a separate browser profile — its own cookies, history and saved logins — so signing in to one never disturbs another. A second button opens that profile directly.
- **Add an account in one click.** Brow creates the account folder and opens Anthropic's own sign-in flow.
- **Tokens kept fresh.** Idle accounts are refreshed in the background, so the numbers do not go stale. An account a Claude Code session is using is left to that session, which refreshes its own token.

In Workspaces:

- **A workspace per feature.** One folder holding a git worktree of each repository you pick, all on one branch from your template. Shared files such as `CLAUDE.md` are seeded, each repository can run a post-create hook, and a workspace can fork from another one.
- **Sessions across accounts.** **Resume as…** continues a session under another account without copying, **Migrate to…** copies it in full, even into an account that is in use, and **Share** makes it visible to every linked account. Every account picker shows that account's limits.
- **Graph and statistics.** The commit graph of each repository, and lines of code across the project over time.
- **The `brow` command-line tool**, with `scan`, `workspaces`, `sessions`, `create`, `graph` and `doctor`, each with `--json`.

Separate browser profiles need Google Chrome, Chromium, Brave or Edge. Without one of them links open in your default browser, with no isolation. More on the notch is in [`docs/brow.md`](docs/brow.md), on Workspaces in [`docs/workspaces.md`](docs/workspaces.md).

<p align="center">
  <img alt="Brow settings: accounts" src="docs/screenshots/brow-settings-accounts.png" width="420" />
</p>

Collapsed, Brow shows two numbers beside the notch: how much of the 5-hour limit and of the weekly limit is used across your accounts. Hover and it opens into the panel above. The readouts can also sit in a strip below the notch:

<p align="center">
  <img alt="Readouts below the notch" src="docs/screenshots/brow-notch-collapsed-below.png" width="640" />
</p>

## What Brow does on your machine

Worth knowing before you run it. The notch:

- **Brow reads Claude Code's sign-in token from the macOS Keychain** and uses it only to call Anthropic's usage and profile endpoints. Those endpoints are not a documented public API and may change. No token is written to disk or logged, and nothing is sent anywhere else. If macOS withholds an account's token, that account shows a key; pressing it asks macOS for access.
- **Brow looks at your running Claude Code processes** when an account's token is due for a refresh or has been rejected, so that it never refreshes a token a session is using. It reads the command line of `claude`, node, bun and deno processes to tell which ones are Claude Code, takes nothing from their environment but `CLAUDE_CONFIG_DIR`, and checks when each account last saved a prompt (`history.jsonl`). The [FAQ](#does-brow-refresh-a-token-claude-code-is-using) says why.
- **The fallback token refresh is on by default.** If the normal refresh stops working Brow runs a tiny `claude -p` request, which spends a little limit and starts that account's 5-hour window. Turn it off in Settings → Accounts; the [FAQ](#does-brow-use-up-my-limits) says exactly when it runs.
- **Each account's browser profile is a separate directory** under `~/Library/Application Support/Brow/browser-profiles/`. Brow sets the profile's name and allows third-party cookies in it so that sign-in works.
- **Signing in opens Terminal** with `claude auth login`; macOS asks once for permission to control Terminal.
- **Brow marks Claude Code's first-run setup as done** in account folders other than `~/.claude` before it starts Claude Code in one: it sets `hasCompletedOnboarding` in that folder's `.claude.json` (and copies your theme if the folder has none), so the session doesn't open the onboarding wizard.

Workspaces, only once you turn it on (or Brow finds Grove's settings):

- **It edits an account's `settings.json` only if you turn on Capture the status line** for that account in Settings → Accounts (accounts Grove already captured stay captured). It points `statusLine.command` at Brow's wrapper, which records each session's model, context use and limits, then passes the same input on to the command you had, so your own status line keeps working. Turning it off puts your command back. Claude Code keeps running the wrapper while Workspaces is off, so the switch stays in Settings → Accounts until you do.
- **Sharing an account moves its session files into `~/.claude`.** Anything that would be overwritten is backed up under `<account>/grove-backup/` first.
- **The transcript safety net is off unless you turn it on** (a Grove setup keeps its setting). When it is on, Brow keeps a hard link to every transcript under `~/.claude/grove/transcripts/`. A transcript that vanishes is listed in Settings → Workspaces and comes back only when you press **Restore**. Nothing is kept longer than Claude Code keeps it: [`cleanupPeriodDays`](https://code.claude.com/docs/en/settings-reference#cleanupperioddays), the shortest that your organization's managed settings, the account's settings or the project settings of any folder its sessions ran in set — for a workspace shared between accounts, the shortest of all of theirs — and nothing within a day of that is offered back. The one period Brow cannot see is one passed to `claude` with `--settings`.
- **It runs git in your repositories**: `git worktree add` and a branch per repository when you create a workspace, and the post-create hooks you configured. It never deletes a worktree or a branch on its own.
- **It drives cmux**: through cmux's socket, with the password from `~/.config/cmux/cmux.json` when cmux asks for one, and through AppleScript, which macOS asks you to allow once.
- **`--dangerously-skip-permissions` only when you ask**, per project or per launch.

[Uninstall](#uninstall) shows how to reverse all of it.

This is an independent tool, not affiliated with or endorsed by Anthropic.

## Requirements

- macOS 26 or later; the prebuilt app is Apple silicon only. The notch layout is for MacBooks with a notch; on other displays Brow shows a pill.
- Xcode with Swift 6.4 or later, to build (Swift 6.2 cannot compile BrowKit).
- [Claude Code](https://claude.com/claude-code).
- For separate browser profiles: Chrome, Chromium, Brave or Edge.
- For Workspaces: git, and a terminal for the sessions — [cmux](https://cmux.dev), recommended, or Terminal.app ([the difference](docs/workspaces.md#cmux-or-terminalapp)). Cross-account resume and the transcript safety net need an account signed in at the default `~/.claude`.

## Install

```sh
brew install --cask efim0v/tap/brow     # the app
brew install efim0v/tap/brow-cli        # the brow command-line tool, if you want it
```

Or download **[Brow.zip](https://github.com/efim0v/brow/releases/latest/download/Brow.zip)** from the [latest release](https://github.com/efim0v/brow/releases/latest), unzip it and move `Brow.app` to `/Applications`. The release also has `brow-cli.zip`, the command-line tool (with `grove` as a second name for it), and `SHA256SUMS.txt`: with the downloads in one folder, run `shasum -a 256 -c --ignore-missing SHA256SUMS.txt`.

The build is signed ad hoc and is not notarized by Apple, so macOS blocks the first launch whichever way you installed it. Open **System Settings → Privacy & Security**, find the message about Brow and press **Open Anyway** — or clear the quarantine flag yourself:

```sh
xattr -dr com.apple.quarantine /Applications/Brow.app
```

The `brow` tool from `brow-cli.zip` carries the same flag when you download it in a browser: `xattr -d com.apple.quarantine brow`.

If macOS withholds an account's Keychain item from Brow, that account shows an orange key and Settings → Accounts lists its token as *Keychain access needed*: press the key, or **Grant Keychain access** there, and choose **Always Allow**. Because the build is signed ad hoc, the key can come back after you update to a newer build.

Brow has no Dock icon: it lives in the notch, and its settings open from the ⚙ in the panel. Turn on **Launch at login** in Settings → General to start it when you log in. To start using Workspaces, open **Settings → Workspaces**, or press the stacked-squares button in the notch panel and choose **Add project…**.

## Coming from Grove

Grove's Workspaces engine is part of Brow from 0.4.0, merged with its history; the [grove repository](https://github.com/efim0v/grove) stays up, read-only, for older builds.

- **Your setup comes along untouched.** Brow finds `~/Library/Application Support/Grove/config.json` and turns Workspaces on with your projects, accounts, captured status lines and safety-net settings. Nothing moves: the status-line wrappers stay in `Grove/bin`, where every captured account's `settings.json` points.
- **Quit Grove.app first.** While it runs, Workspaces waits and offers **Quit Grove**, so the two never write the same files. Then delete `Grove.app` (or `brew uninstall --cask grove`), and if you had added it to Login Items, remove it there and turn on **Launch at login** in Brow instead.
- **Where things went.** The tree in the menu bar is now Brow's mark, the notch with two dots. The panel's settings screen moved to **Settings → Workspaces**; adding, sharing and capturing accounts moved to **Settings → Accounts**, where adding an account is Brow's one-click **Sign in…**. Per-project settings stay in the panel.
- **The command-line tool is `brow`.** `brow-cli.zip` installs `brow` with `grove` as a second name, so your scripts keep working unchanged.
- **The transcript safety net no longer puts transcripts back by itself.** It used to restore any transcript under 90 days old on its own, including ones Claude Code's own clean-up had removed. Now it keeps nothing past Claude Code's retention, and Settings → Workspaces lists the transcripts that vanished, with **Restore**.

## FAQ

### Does Brow use up my limits?

Only through the fallback token refresh, and you can turn that off. Reading the limits is a request to Anthropic's usage endpoint, not to a model, and an idle account's token is kept fresh with `claude doctor`, which makes no model call.

The fallback is on by default. When an account's token has 30 minutes or less left and `claude doctor` did not renew it, Brow runs a one-turn `claude -p` request on Haiku in that account. That spends a sliver of the account's limit and starts its 5-hour window. Brow skips it when Anthropic has rejected the token or `claude doctor` timed out or could not start, runs it at most once every 30 minutes per account, and stops using it for an account after three attempts in a row that did not help. Settings → Accounts → **Allow `claude -p` fallback** turns it off.

### Does Brow refresh a token Claude Code is using?

No. Claude Code renews its token with a refresh token that changes on every renewal, so two renewals at about the same time can leave a session with a dead token and a request to run `/login`. Brow leaves alone any account with a running `claude` process for its folder (no `CLAUDE_CONFIG_DIR` means `~/.claude`), however long that session has sat idle, and any account with a prompt typed in the last 15 minutes. The session renews the token itself. Until it does, Settings → Accounts lists the token as *in use by Claude Code, waiting for it to refresh*. If the token has already expired, the panel shows *Token in use by Claude Code* instead of asking you to sign in, and the numbers come back once you use that session again or close it.

### Where does Brow read my token, and does anything leave my Mac?

From the Keychain item Claude Code keeps for each account: `Claude Code-credentials` for `~/.claude`, `Claude Code-credentials-<hash>` for any other account folder. Brow reads it with macOS's `security` tool and falls back to the Keychain API; with older Claude Code installs it reads `.credentials.json` in the account folder instead. It uses the access token only and leaves renewing it to Claude Code.

Brow's own network requests go to two Anthropic endpoints and nowhere else: `api.anthropic.com/api/oauth/usage` for the numbers and, about once a day per account, `api.anthropic.com/api/oauth/profile` for the renewal estimate in the calendar. Brow has no analytics and no update check. Workspaces makes no network requests of its own; the `claude` and `git` commands it runs make their usual connections, and the per-account browser profiles open claude.ai.

### Which Macs does it run on, and where does it sit?

macOS 26 or later; the prebuilt app is Apple silicon only. Brow sits at the top of the main display. If that display has a notch, the two readouts sit beside it (the default) or in a strip below it: Settings → General → **Ears**. Turn off **Show readouts next to the notch** in the same tab and nothing is drawn until the pointer reaches the notch. When the main display has no notch, an external display for instance, Brow shows a pill at the top centre instead.

### I don't see Brow's item in the menu bar.

On a MacBook with a notch, macOS hides the menu-bar items that don't fit beside it. Workspaces still opens from the stacked-squares button in the notch panel, from **Show Workspaces** in Brow's menu, and when you open Brow again from Finder or Spotlight. Settings → General → **Show Workspaces in the menu bar** turns the item off altogether.

### Why not Claude Code's built-in worktrees?

`claude --worktree` gives one session a worktree of the repository you run it in, which may be all you need for a single repository. Workspaces are for a product split across repositories: one branch across all of them under one folder, your own branch names and start points, files and hooks set up on creation, and sessions that move between accounts. [The longer answer](docs/workspaces.md#why-not-claude-codes-built-in-worktrees).

## Uninstall

1. **If you used Workspaces, give each account its status line back first** — the wrappers live in Brow's Grove folder, which step 4 deletes. In Settings → Accounts, turn off **Capture the status line** on every account that shows it; the switch is there whether Workspaces is on or off, and if Grove is still running, quit it first. Then check that no `settings.json` still points at the wrapper:

   ```sh
   find ~/.claude ~/.claude-accounts -maxdepth 2 -name settings.json -exec grep -l grove-statusline {} +
   ```

   For each file it lists, open the script that file's `statusLine.command` names: its `GROVE_ORIG` line holds the command you had before. Put that command back, or delete the `statusLine` key if `GROVE_ORIG` is empty.
2. If you turned on **Launch at login**, turn it off in Settings → General. Then quit Brow with ⌘Q while its Settings window is in front, or with **Quit Brow** in the Workspaces panel.
3. Delete the app: `brew uninstall --cask efim0v/tap/brow` and `brew uninstall efim0v/tap/brow-cli`, or move `Brow.app` and the `brow` tool to the Trash.
4. Close any browser window Brow opened for an account, then delete Brow's files: its settings, cached readings and per-account browser profiles (cookies and saved passwords included), Workspaces' folder (its config, the wrapper scripts, code statistics and the request-pacing file), and what macOS stored for Brow's network requests:

   ```sh
   rm -rf ~/Library/Application\ Support/Brow
   rm -rf ~/Library/Application\ Support/Grove
   rm -rf ~/Library/Caches/dev.artemefimov.brow ~/Library/HTTPStorages/dev.artemefimov.brow
   ```

   If you used Grove, `defaults delete dev.artemefimov.grove3` removes its preferences too.

5. If you used Workspaces, delete what it kept in your account folders: `~/.claude/grove/` (the transcript safety net and the default account's status-line captures; the transcripts in each account's `projects/` stay) and `grove/` in every other account folder. Look through any `grove-backup/` folder — what sharing set aside — before you delete it. A shared account's `file-history`, `tasks` and `session-env`, and `projects/<workspace>` for each shared workspace, are symbolic links into `~/.claude` and keep working; [`docs/workspaces.md`](docs/workspaces.md#how-accounts-share-sessions) explains them.
6. If you added Brow's `export BROWSER=…` line to `~/.zshrc`, remove it.

If you deleted the app first and Brow is still listed in System Settings → General → Login Items & Extensions, remove it there. Account folders under `~/.claude-accounts` belong to Claude Code and keep working without Brow. Workspaces are ordinary git worktrees and branches in your repositories, so they stay: remove one with `git worktree remove` on each of its worktrees, then delete its folder.

## Build

```sh
git clone https://github.com/efim0v/brow.git
cd brow

Scripts/test-in-empty-home.sh   # the whole suite, with the home folder pointed at an empty one
Scripts/build-brow.sh           # -> dist/Brow.app and dist/brow
cp -R dist/Brow.app /Applications/
```

The app is signed ad hoc by default. macOS then forgets the Keychain and Automation permissions on every rebuild; to keep them, set `BROW_SIGN_IDENTITY` to your own `Apple Development: Name (TEAMID)` identity before building.

## Layout

| Path | What it is |
|---|---|
| `Sources/GroveCore` | Accounts, credentials, usage and token refresh; git, worktrees, cmux, Claude Code sessions, the shared store, the transcript safety net, migration, code statistics |
| `Sources/GroveAppKit` | The Workspaces panel and its state |
| `Sources/BrowKit` | The notch, the limits, Settings, and Brow's side of Workspaces |
| `Sources/BrowApp` | Entry point |
| `Sources/brow-cli` | The `brow` command-line tool |
| `Resources` | The app icon, the per-account browser router, the Info.plist template |
| `Tests` | About 1,280 tests |
| `docs` | [The notch in detail](docs/brow.md), [Workspaces](docs/workspaces.md), [architecture](docs/architecture.md), [troubleshooting](docs/troubleshooting.md) |

There are no third-party dependencies. The module names `GroveCore` and `GroveAppKit` come from Grove, whose history this repository includes.

## Development

- `Scripts/test-in-empty-home.sh` and `Scripts/test-in-empty-home.sh -c release` should both stay green; `Scripts/check-warnings.sh` should find no new warnings.
- `swift run BrowApp --snapshot /tmp/brow-snap` renders the Workspaces screens to PNG without starting the app; see [`docs/snapshot-testing.md`](docs/snapshot-testing.md).
- The screenshots in this README are regenerated with
  `DEMO_SCREENSHOTS_DIR="$PWD/docs/screenshots" swift test --filter DemoScreenshotTests`.
- The notch outline's tuning constants are in `Sources/BrowKit/Panel/NotchGeometry.swift`; they are meant to be tuned by eye against the physical bezel.

## Credits

- [boring.notch](https://github.com/TheBoredTeam/boring.notch) (GPL-3.0): the notch outline's constants, and the idea of drawing in a SkyLight space of its own so the panel stays put through Spaces changes.
- [NotchNook](https://lo.cafe/notchnook): the same way of keeping a notch panel still across Spaces.
- [cmux](https://cmux.dev): the terminal Workspaces opens sessions in.
- [Grove](https://github.com/efim0v/grove): Brow's companion app until 0.4, whose Workspaces engine is now part of Brow.

## License

[GNU GPL v3](LICENSE). Brow and Grove 0.2.0 and earlier were released under the MIT License.
