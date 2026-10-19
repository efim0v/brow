# The notch: behaviour in detail

How the notch half of Brow works. Workspaces, the menu-bar half, is in
[`workspaces.md`](workspaces.md); how the two fit together, in
[`architecture.md`](architecture.md).

- Accounts are discovered from `~/.claude` and `~/.claude-accounts/*`; dirs that
  belong to the same organisation are shown once.
- If macOS asks for access to Claude Code's Keychain item, choose "Always Allow".
  An account whose item is withheld shows a key: press it to grant access.
- Tokens are kept fresh by running `claude doctor` in the account (no model
  call) in the token's last 4½ minutes: Claude Code renews a token only in its
  last five, so an earlier `doctor` would change nothing. If that ever stops
  working, the `claude -p` fallback (Settings → Accounts, **on by default**)
  spends a little limit and starts the account's 5-hour window. It is never used
  after a 401/403 for a token that had not yet expired, after a `doctor` that
  timed out — neither is evidence the token itself can be fixed — or when `claude
  doctor` says the login is dead, and it is dropped for good after three
  ineffective rounds. A token past its expiry is not sent, so nothing refused it:
  it gets `doctor` and then `-p` like a token that is due. A `doctor` or `-p`
  that runs past its time limit gets nine seconds after SIGTERM before it is
  killed: on its way out Claude Code cleans up, runs its SessionEnd hooks and
  only then waits up to two seconds for a refresh in flight to be saved, within
  a deadline of its own of 8½ seconds. Nothing is run while the Mac is in a dark
  wake (between going to sleep and waking up, with the display asleep).
- A Claude Code session open in an account gets the first go at renewing its
  token: a session at work renews it with its next request in the token's last
  five minutes. While the token has more than two minutes left, Brow waits, and
  the account's token line in Settings reads *in use by Claude Code, waiting for
  it to refresh*. After that, after Anthropic rejects the token, and when you
  press ⟳, Brow runs `claude doctor` whoever holds the account. An idle session
  renews nothing, and Claude Code takes a lock around every refresh and re-reads
  the token under it, so a refresh by Brow no longer races the session's. That
  race was the reason 0.3.1 left such accounts alone however long the session had
  sat idle, which in the end meant their tokens were not refreshed at all. A
  session busy at that moment may see one rejected request, which Claude Code
  recovers from by itself. Brow logs each time it waits for a session or runs
  `doctor` past one. "Open" means a running `claude` process whose
  `CLAUDE_CONFIG_DIR` is that account's folder (not set means `~/.claude`), or a
  prompt typed in that account in the last 15 minutes (going by when its
  `history.jsonl` was last written). The `grep`, `find` and `rg` Claude Code
  runs from its own binary are not sessions. Brow checks only when a refresh is
  due or Anthropic has rejected the token. It reads the process list: the
  command line of each `claude`, node, bun or deno process, to tell which ones
  are Claude Code, and from a Claude Code process's environment only
  `CLAUDE_CONFIG_DIR`. A session still counts after an update has deleted the
  binary it was started from. It also reads the modification time of
  `history.jsonl`. It reads no file's contents and nothing from the Keychain for
  this, and starts no process.
- A token past its expiry is not sent to Anthropic: the panel says *Token expired
  12 min ago*, and adds *— Claude Code hasn't refreshed it* while a session holds
  the account. A token Anthropic rejected reads *Anthropic rejected the token*.
  The account's sign-in button turns orange only when the login is dead: `claude
  doctor` or `claude -p` said so (*Please run /login*, or, from `claude -p`,
  *Failed to authenticate*), three attempts in a row did not renew the token, or
  the account has no token.
- The usage endpoint is rate-limited server-side (measured: a small token bucket
  refilled at roughly one request per 100 s, `retry-after: 0`, and 429s that do
  not extend the window). Brow paces itself to it: background polls that arrive
  before the window re-opens are served from the last reading, the ⟳ button
  spends a small burst budget and otherwise queues itself for the moment a
  request will go through (`Updated 2 min ago · retrying in 47 s`). Claude Code's
  own usage numbers come from response headers, which is why it never "hits" this.
- In the panel, every account carries three buttons: copy the command that runs
  Claude Code as that account (`CLAUDE_CONFIG_DIR='…' claude`), sign in again, and
  open that account's browser profile. The launch command also sits in each
  account's Settings card.
- The button with stacked squares in the panel's footer opens Workspaces: the
  notch closes and stays closed until the pointer has left it, and the Workspaces
  panel opens under its menu-bar item (or at the screen's top-right corner when
  macOS hides the item behind the notch). While Workspaces is off it opens an
  introduction, from which a project can be added.
- The share button in the panel's footer copies "my week": a picture (1200 × 630,
  or 1080 × 1080 per Settings → General → Usage image) of the visible accounts'
  limits and when they reset: up to four accounts, with any more counted. A
  reading more than 3 min old is grey, as in the panel, and carries its age.
  Accounts are numbered as in limit warnings unless **Show account names** is
  on, and even then only names set in Settings are used, never an email, a
  folder or a plan.
- Add an account from Settings with one click (**Sign in…**): Brow creates
  `~/.claude-accounts/account-N` itself and opens Terminal with `claude auth login`;
  sign-in happens in Anthropic's own flow.
- Limits are checked every **30 s** by one timer that keeps running whether the
  panel is open or shut, plus on wake, on the network returning, and on hover when
  the data on screen is more than 30 s old. The footer always leads with the age
  (`Updated 3 h ago`), so a number you can see is a number you can date.
- **Settings → General → Notifications** (off by default) posts a macOS
  notification when an account passes a level (80 % and 95 % by default) of its
  5-hour, weekly or model weekly limit: once per level, account and reset period.
  Only fresh readings count (never a persisted or stale one, never a window that
  has already reset), and levels already passed when Brow starts are not
  announced. A notification names the account by the name set in Settings, or
  else as "Account 2" by its place in the panel; never by its email or folder.
  Notifications are local (`UserNotifications`); macOS is asked for permission
  when the toggle is turned on.
- **Settings → General → Ears** chooses where the two readouts sit on a built-in
  display: `Beside the notch` (default — one wing each side, the notch itself left
  clear) or `Below the notch` (one centred row in a 22 pt strip under it). It takes
  effect as you click; an external display always shows the pill.
- **The pet** (Settings → General → **Show the pet**, on by default) lives in the
  black beside the 5-hour readout, or in the strip below the notch (scale 0.80) or
  in the pill (0.82), and never covers a number. It eats what the visible accounts
  use: food is the growth of each account's 5-hour window within one reset period,
  weighted as the readout weights the accounts, so one point of the left readout is
  one point of food. The weekly and model weekly windows, a reset, an account
  appearing or shown again, its first reading and any decrease are not food. Its
  hunger runs from −50 to 100 (a new pet starts at 30): +20 an hour while you are at
  the Mac, it is awake and a reading is under 10 min old, slower when the week is
  ahead of an even pace and stopped 30 points ahead; −6 for each point it eats.
  Full at 0 or below, Content to 35, Peckish to 65, Hungry from 65, with 5 points of
  hysteresis on the way back. At an effective 5-hour aggregate of 99.5 % (the
  readout's `100%`) it falls asleep until the window resets; at 99.5 % weekly it
  hibernates in the den behind the camera until the weekly reset. A prompt written
  to an account's `history.jsonl` (watched, never read) makes it eager for 90 s.
  Moments: its intro, fed-day streaks (a day with 10 points eaten; two rest days
  allowed) at 3, 7, 14, 30, 60 and 100 days, a good week (an account's weekly limit
  closing at 70 % or more), a feast (a meal of 8 points or more), a fresh window
  and a welcome back. Nothing random reacts to you, nothing is lost, and there is
  no notification or sound. In the panel its row shows the state, the last meal and
  a hunger meter with no number; a click on the pet boops it. It draws at 30 frames
  a second at rest, 15 asleep, 10 hibernating, 60 to 120 for a meal or a hop, and
  nothing when nobody can see it or you have been away for 10 min. Its state is
  `~/Library/Application Support/Brow/pet.json`. With **Show Brow in the notch** off
  there is nowhere to see the pet, so it is off as well: no frames, no timers, no
  file watchers, and the same pet when Brow is back in the notch.
  `open Brow.app --args -petPerfLog YES`
  logs its frames and CPU once a minute to the `pet` category, and
  `-petForceState idle|asleep|hibernating` pins its state for a measurement.
- The strip is drawn as the notch outline (`NotchShape`), not a rectangle. Its
  tuning knobs are constants in `Sources/BrowKit/Panel/NotchGeometry.swift` —
  `flare` (concave top corners, 6), `collapsedBottomRadius` (14),
  `expandedBottomRadius` (18), `wingWidth` (96), `belowStripHeight` (22). They are
  meant to be tuned by eye against the physical bezel; no screenshot can show it.
