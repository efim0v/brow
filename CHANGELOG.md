# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.5.0] - 2026-10-21

Workspaces moves into the notch panel: one window for the limits, the projects and the agents, and no menu-bar item. Projects shows what each session said last and what needs you, Agents shows who talks to whom, Glim gets two new moods, and Brow refreshes tokens again while Claude Code sessions sit open.

### Added

- **Projects and Agents in the notch panel.** While Workspaces is on, a switch at the top of the panel goes between Limits, Projects and Agents, in the same black under the notch. Show Projects in Brow's menu and opening Brow again from Finder or Spotlight open the panel pinned on Projects. Pinned, the panel takes the keyboard, on any layout.
- **What each session said last.** Projects shows each session by its state — *Needs permission* or *Asks you* in yellow when it waits on you, *Working*, *Your turn*, *Closed* — where it runs and as which account, your newest prompt and Claude's newest line. What needs you comes first. The yellow number on the Projects switch counts the sessions that need you, and an account's "N live" chip on Limits opens Projects narrowed to that account. Settings → Workspaces → **Show message previews** shows titles instead, for sharing your screen.
- **Suggested projects.** Folders where Claude Code runs that are no project yet are suggested at the top of Projects, with **Add**, or ✕ for "not now", which is remembered. **Other folders** lists the sessions outside every project, each folder with **Add as project**.
- **Agents**: who talks to whom among the Claude Code agents on this Mac, live. Sessions sit on a row, joined by arcs when they message each other, with their subagents and agent-team members in a short tree under each; a message is a small light that runs from the sender to the receiver, and RECENT lists the last ten minutes. It reads only what Claude Code already writes, only while the panel is open and for half a minute after, and keeps the first line of a message in memory for an hour at most.
- Glim has two new moods at the ends of its hunger meter. Fed far past the brim it is Stuffed: round-bellied and blissful, it pats its belly, gives a thumbs-up and still takes another bite. After hours at the Mac with nothing used it is Famished: up on its toes and leaning toward the number, its tummy rumbling, hopeful and never sad. Asleep at the 5-hour limit, it now sleeps with a small smile.

### Changed

- Workspaces' accounts are Brow's: every picker and menu lists the accounts Settings → Accounts shows, in its order, under its names, with their limits, and a session Workspaces starts runs as the account it names. Workspaces' own Accounts screen is gone.
- The panel has continuous bottom corners, a width for each of its screens and a footer that always fits, and it stops above the Dock.
- A project's worktrees that no session ran in, such as the ones scripts and agents leave behind, fold into one line, "N with no session", opened by a click.
- A session shows under one project only, the one whose folder holds it most closely. A folder inside a project, a folder that holds one, or a second project with the same name is not added.
- Sessions a program started (`claude -p`, the Agent SDK) are not listed.
- A folder that only holds projects — one right in your home folder, or one with more than 12 repositories — is not suggested as a project.
- Projects reads the start and the last 64 KB of a transcript, never all of it, so long sessions don't slow it down.
- The reset calendar keeps the same height every month.

### Removed

- Brow's menu-bar item, and Settings → General → Show Workspaces in the menu bar. The notch panel is the way in.
- Workspaces' own window, with its Liquid Glass and Settings → Workspaces → panel material: its screens are the Projects side of the notch panel.

### Fixed

- Brow refreshes your tokens again while Claude Code sessions sit open in your accounts. 0.3.1 stopped refreshing the token of any account with a running `claude` process for its folder, however long that session had been idle, so that two refreshes at once could not leave the session with a dead token. That reasoning does not hold. Claude Code now takes a lock around each refresh and re-reads the token under it, so a refresh by Brow and one by a session no longer collide. And a session renews its token only when it sends a request in the token's last five minutes, so an idle session renews nothing. With sessions left open for days, nothing refreshed any token: eight hours after the last refresh each account read *Token in use by Claude Code*, then *Rate limited*, its bars went grey, and signing in again only started the eight hours over. Now a session gets the first go only while the token has more than two minutes left. After that, after Anthropic rejects the token, and when you press ⟳, Brow runs `claude doctor` whether or not a session holds the account. A session busy at that moment may see one rejected request, which Claude Code recovers from by itself. Brow notes each time in its log.
- Brow runs `claude doctor` in a token's last 4½ minutes, when it can work. Claude Code renews a token only in its last five minutes, so the `claude doctor` Brow ran half an hour early did nothing, was counted as a failure, and was followed by `claude -p`, which spends a little limit and starts the account's 5-hour window.
- Brow no longer takes the `grep`, `find` and `rg` that Claude Code runs from its own binary for sessions. One left behind in an old `tail -F | grep` kept its account "in use" for days.
- Brow no longer sends a token past its expiry to Anthropic. The panel says *Token expired 12 min ago*, adding *— Claude Code hasn't refreshed it* while a session holds the account, instead of *Rate limited*.
- The sign-in button turns orange only when the login is really dead: when `claude doctor` or `claude -p` says so (*Please run /login*, or *Failed to authenticate* from `claude -p`), when three attempts in a row did not renew the token, or when the account has no token. A token Anthropic rejected reads *Anthropic rejected the token* while Brow tries to refresh it.
- When `claude doctor` or `claude -p` runs past its time limit, it gets nine seconds to exit before Brow kills it, not half a second. On its way out Claude Code cleans up, runs its SessionEnd hooks and only then waits up to two seconds for a token refresh in flight to be saved, and a kill in that wait could lose the renewed token.
- No `claude` runs while the Mac is in a dark wake (Power Nap and the like): nobody is there, and the Mac can go back to sleep in the middle of a refresh.

## [0.4.0] - 2026-10-18

Grove is now part of Brow. Its Workspaces engine — workspaces of git worktrees across several repositories, the Claude Code sessions in them and moving sessions between accounts — runs inside Brow, merged into this repository with its history. Grove's own changelog is in [`docs/history/grove-changelog.md`](docs/history/grove-changelog.md). The notch also gets a pet that eats what your accounts use.

### Added

- **Workspaces**, in the menu bar: Grove's panel — projects, workspaces, sessions, Resume as…, Migrate to…, Share, the commit graph and the code statistics — on Liquid Glass, behind Brow's mark, the notch with two dots. It is off until you use it: for someone who never used Grove nothing of it runs, and nothing is read or written for it. It turns on by itself for someone who did, with their projects, accounts and settings ([what changes](README.md#coming-from-grove)).
- While Grove.app is running, Workspaces waits and offers Quit Grove, so the two never write the same files. It also runs in one copy of Brow at a time: a second install or a development build waits while another copy runs it.
- The notch panel gets a Workspaces button, which also opens Workspaces when macOS hides the menu-bar item behind the notch. Opening Brow again from Finder or Spotlight shows Workspaces while it is on, and Settings otherwise. Brow's menu gets Show Workspaces.
- Every account picker in Workspaces — the launch sheet, Resume as…, Migrate to…, the Accounts screen — shows that account's 5-hour and weekly use as the notch reads it. Workspaces names each account as the notch does, by the name given in Settings → Accounts, and writes its plan the same way (Max 20x).
- One Settings window with four tabs. General gains Show Workspaces in the menu bar. Each card in Accounts gains a Workspaces section: Share sessions, Capture the status line, and the account's default model and effort; a Workspaces account with no card of its own, such as a second folder of the same login, gets a section after the cards, and one whose folder is gone can be removed from Workspaces there. Workspaces holds the projects, the workspace folder, the transcript safety net and the panel material. About has the version, the licence and the credits.
- The command-line tool is `brow`, with `grove` as a second name, so scripts written for Grove's tool keep working unchanged. `brow --version` prints Brow's version. It ships as `brow-cli.zip`.
- The model pickers offer Claude Code's aliases (`opus`, `sonnet`, `haiku`), pinned versions, and Other… for any model id.
- Settings → General → Show Brow in the notch. Off, Brow draws nothing at the top of the screen and no panel opens there, for someone who uses Brow for Workspaces only. Limit warnings still arrive, and opening Brow again shows Workspaces or Settings.
- **Glim, a pet that eats your limits.** A small creature lives in the black beside the notch, below it, or in the pill, and eats what your accounts use: when the 5-hour number goes up, it takes a bite, drawn as a bead of light that leaves the number untouched. Hours at the Mac without Claude Code make it hungry; it never gets hungry while you are away, and its light is its hunger meter. When the 5-hour limit is used up it falls asleep full until the window resets; when the weekly limit is used up it hibernates in its den behind the camera until the weekly reset. It perks up when a prompt is written to an account's `history.jsonl`, which Brow asks macOS to watch and never reads. Hover the notch and it hops into a new first row of the panel, with its state, its last meal and a hunger meter; a click on it boops it. It draws only while someone can see it, follows Reduce Motion, Reduce Transparency and Increase Contrast, and keeps its state in `~/Library/Application Support/Brow/pet.json`. On by default; Settings → General → **Show the pet** turns it off, and with Show Brow in the notch off there is no pet at all.

### Changed

- Capturing an account's status line is a choice per account. Grove installed its wrapper into every account's `settings.json` at launch; Brow installs it only where you turn capture on, and keeps it where Grove already had it. Claude Code keeps running the wrapper while Workspaces is off, so Settings → Accounts keeps the switch that gives the status line back, whether Workspaces is on or off.
- The transcript safety net is off for a setup Brow creates; a Grove setup keeps its setting.
- The transcript safety net no longer puts a transcript back by itself. The transcripts that vanish are listed in Settings → Workspaces, newest first, with Restore: a period passed to `claude --settings` cannot be read from outside, so only you can tell a transcript deleted by accident from one cleaned up on purpose.
- Sessions Workspaces starts use Brow's own browser router and Settings → General → Path to claude.
- Brow's settings decode field by field: a value that cannot be read costs that one setting instead of all of them, and the file as it was is kept as `config.json.bak` ([#7](https://github.com/efim0v/brow/issues/7)).
- One log subsystem, `dev.artemefimov.brow`, for the whole app.

### Fixed

- The transcript safety net no longer brings back, or keeps, transcripts Claude Code's own retention deleted. It restored every mirrored transcript under 90 days old; it now reads `cleanupPeriodDays` from your organization's managed settings, server-managed settings, the account's settings and the project settings of every folder the account's sessions ran in, takes the shortest — for a workspace shared between accounts, the shortest of all of theirs — and keeps nothing past it. Migrate to… follows the same rule when it falls back on the safety net's copy ([efim0v/grove#6](https://github.com/efim0v/grove/issues/6)).
- Opening Accounts no longer shows a red "unknown session store" banner for the folders Claude Code itself writes ([efim0v/grove#7](https://github.com/efim0v/grove/issues/7)).
- Launch no longer re-creates an account folder you deleted ([efim0v/grove#12](https://github.com/efim0v/grove/issues/12)).
- Reading a token through the `security` tool gives up after ten seconds, as it was meant to ([efim0v/grove#9](https://github.com/efim0v/grove/issues/9)).
- The model pickers no longer miss new models ([efim0v/grove#10](https://github.com/efim0v/grove/issues/10)).
- The launch-at-login toggle can no longer show on while it is off, and says when macOS is waiting for your approval ([#8](https://github.com/efim0v/brow/issues/8)).
- The build has no compiler warnings again ([efim0v/grove#11](https://github.com/efim0v/grove/issues/11)).
- With Show readouts next to the notch off, a display without a notch no longer shows an empty black pill: nothing is drawn until the pointer reaches the top centre, as the setting says.

## [0.3.1] - 2026-10-15

### Fixed

- Brow no longer refreshes the token of an account Claude Code is using. It ran `claude doctor`, and if that did not help `claude -p`, in an account whose token was about to expire or had been rejected, even while a Claude Code session was running in that account. The session refreshes its own token, and two refreshes at about the same time could leave it with a dead token and a request to run `/login`. Now an account with a running `claude` process for its folder, or with a prompt typed in it in the last 15 minutes, is left to Claude Code. Its token line in Settings reads *in use by Claude Code, waiting for it to refresh*, and a rejected token shows *Token in use by Claude Code* in the panel instead of asking you to sign in. To tell, Brow reads the command line of running `claude`, node, bun and deno processes, takes only `CLAUDE_CONFIG_DIR` from their environment, and reads the modification time of the account's `history.jsonl`. It does this only when a refresh is due or the token was rejected. Idle accounts are refreshed as before.

## [0.3.0] - 2026-10-15

### Added

- Limit warnings, off by default. Turn them on in Settings → General → Notifications and Brow posts a macOS notification when an account passes 80 % and 95 % of its 5-hour, weekly or model-specific weekly limit: once per level, per account and per reset period, with the time the limit resets. The levels can be changed to 70 % and 90 %, or 90 % only. An optional second notice says when a limit Brow warned about has reset. Each notification names the account by the name you gave it in Settings, or else as "Account 1", "Account 2" in panel order, never by its email. Brow asks macOS for permission only when you turn warnings on; the notifications are made on your Mac and nothing is sent anywhere.
- Copy my week: a button in the panel's footer copies a picture of your current usage, ready to paste into a chat or a post: the 5-hour, weekly and model-specific weekly limits of each account the panel shows (up to four), with when each resets. Accounts appear as "Account 1", "Account 2", numbered as in limit warnings; turn on Show account names in Settings → General → Usage image to use the names you gave them. Emails, folder names and plans are never in the picture. The same section offers a wide (1200 × 630) or a square (1080 × 1080) picture, shows a preview and saves it as a PNG.

## [0.2.3] - 2026-10-14

### Fixed

- Brow has its own app icon: the grey tile with the notch and the two dots from the website. Earlier builds shipped Grove's tree icon by mistake, so Finder, Launchpad, Spotlight, Login Items and the first-launch dialogs showed Grove's icon for Brow.

## [0.2.2] - 2026-10-14

### Fixed

- After a sign-in, Brow marks Claude Code's first-run setup as done in the account's `.claude.json`. It no longer rewrites a `.claude.json` that doesn't parse, such as one caught half-written by Claude Code, which would have left only two keys and dropped the account's sign-in, MCP servers and project trust. The write now goes through Claude Code's lock file and keeps a symlinked `.claude.json` a symlink. The fix is in `GroveCore` 0.2.2 ([efim0v/grove#4](https://github.com/efim0v/grove/issues/4), [#5](https://github.com/efim0v/grove/issues/5)), which Brow now requires.

## [0.2.1] - 2026-10-13

Update if you run 0.2.0: it kept Claude Code access tokens in a cache file.

### Security

- Usage and profile requests no longer go through the shared URL cache. Brow 0.2.0 stored each request, with the Claude Code access token in its `Authorization` header, and each response, with the account's email and plan, in `~/Library/Caches/dev.artemefimov.brow/Cache.db`. Any process running as your user could read that file without a Keychain prompt. The tokens there are access tokens, which expire after about eight hours; refresh tokens were never stored. The first request after launching 0.2.1 empties that cache. The fix is in `GroveCore` 0.2.1, which Brow now requires.

### Added

- An Install section in the README for the prebuilt `Brow.zip`. It covers the first launch, which macOS blocks because the build is not notarized, and points to `SHA256SUMS.txt` for checking the download. A download link sits at the top of the README.
- Three animated demos at the top of the README: which account still has room, when each limit resets, and signing in again in one click.
- Homebrew: `brew install --cask efim0v/tap/brow` installs Brow from the [efim0v/homebrew-tap](https://github.com/efim0v/homebrew-tap) tap. As with the zip, macOS blocks the first launch.
- A FAQ in the README: what can use up an account's limits and exactly when the `claude -p` fallback runs, where Brow reads each account's token and where its requests go, and which Macs and displays it runs on.
- An Uninstall section in the README: turning off Launch at login, removing the app, and deleting the files Brow keeps, its per-account browser profiles included.
- The README in Russian (`README.ru.md`) and Simplified Chinese (`README.zh-CN.md`), with a language switcher at the top of all three READMEs.
- A landing page at [efim0v.github.io/brow](https://efim0v.github.io/brow/), published from `site/` with GitHub Pages.
- A contributing guide (`CONTRIBUTING.md`), a code of conduct (the Contributor Covenant 2.1), a security policy (`SECURITY.md`) that explains how to report a vulnerability privately, issue forms for bug reports and feature requests, and a pull request template.
- Continuous integration: GitHub Actions builds Brow and runs its tests on macOS 26 for every pull request and every push to `main`.

### Changed

- Brow is now licensed under the [GNU GPL v3](LICENSE). Version 0.2.0 and earlier were released under the MIT License.

### Fixed

- An account Brow has no reading for yet no longer counts as 0 % used in the two readouts beside the notch and in the panel's Overall line. With a Pro account at 90 % of both limits and a Max 20x account with no reading, both readouts showed 4 %; they now show 90 %.
- `docs/brow.md` said the limits are re-fetched every 60 s. Brow checks them every 30 s, and the doc and the code comments now say so.
- The README and `docs/brow.md` no longer say that macOS asks once per account for Keychain access on first launch. Brow does not bring up the Keychain dialog by itself: an account whose Keychain item macOS withholds shows an orange key, and pressing the key asks for access.

## [0.2.0] - 2026-10-05

First public release: the usage and rate limits of every Claude Code account, in the MacBook notch.

### Added

- Two readouts beside the notch: how much of the 5-hour limit and of the weekly limit is used across your accounts. They can sit in a strip below the notch instead. On displays without a notch Brow shows a pill.
- A panel that opens on hover, with every account's 5-hour limit, weekly limit and any model-specific weekly limit, as percent used, and when each resets.
- A reset calendar: weekly resets and estimated subscription renewals on a month grid.
- Buttons on each account: copy the command that starts Claude Code as that account, sign in again, and open that account's browser profile.
- A separate browser profile for each account, with its own cookies, history and saved logins, so signing in to one account never disturbs another. It needs Google Chrome, Chromium, Brave or Edge; without one, links open in the default browser with no isolation.
- Adding an account in one click: Brow creates the account folder and opens Anthropic's own sign-in flow.
- Background token refresh for idle accounts. If it stops working, Brow falls back to a tiny `claude -p` request, which spends a little limit and starts that account's 5-hour window. The fallback is on by default; turn it off in Settings → Accounts.
- A prebuilt `Brow.zip` for macOS 26 or later on Apple silicon, signed ad hoc and not notarized, with `SHA256SUMS.txt` to verify it.

[Unreleased]: https://github.com/efim0v/brow/compare/0.5.0...HEAD
[0.5.0]: https://github.com/efim0v/brow/compare/0.4.0...0.5.0
[0.4.0]: https://github.com/efim0v/brow/compare/0.3.1...0.4.0
[0.3.1]: https://github.com/efim0v/brow/compare/0.3.0...0.3.1
[0.3.0]: https://github.com/efim0v/brow/compare/0.2.3...0.3.0
[0.2.3]: https://github.com/efim0v/brow/compare/0.2.2...0.2.3
[0.2.2]: https://github.com/efim0v/brow/compare/0.2.1...0.2.2
[0.2.1]: https://github.com/efim0v/brow/compare/0.2.0...0.2.1
[0.2.0]: https://github.com/efim0v/brow/releases/tag/0.2.0
