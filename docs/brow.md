# Brow: behaviour in detail

- Accounts are discovered from `~/.claude` and `~/.claude-accounts/*`; dirs that
  belong to the same organisation are shown once.
- If macOS asks for access to Claude Code's Keychain item, choose "Always Allow".
  An account whose item is withheld shows a key: press it to grant access.
- Idle accounts' tokens are kept fresh by running `claude doctor` in that
  account (no model call). If that ever stops working, the `claude -p` fallback
  (Settings → Accounts, **on by default**) spends a little limit and starts the
  account's 5-hour window. It is never used after a 401/403 or a `doctor` that
  timed out — neither is evidence the token itself can be fixed — and it is
  dropped for good after three ineffective rounds.
- An account Claude Code is using is left to Claude Code: Brow runs neither
  `claude doctor` nor `claude -p` in it, whether the token is about to expire or
  Anthropic has rejected it. A running session refreshes its own token, and the
  refresh token changes on every refresh, so two refreshes at about the same
  time leave one side with a dead token and the session asks you to `/login`.
  "Using" means a running `claude` process whose `CLAUDE_CONFIG_DIR` is that
  account's folder (not set means `~/.claude`), however long it has sat idle, or
  a prompt typed in that account in the last 15 minutes (going by when its
  `history.jsonl` was last written). While Brow waits, the account's token line
  in Settings reads *in use by Claude Code, waiting for it to refresh*. If the token has already expired,
  the panel says *Token in use by Claude Code* instead of asking you to sign in,
  and the numbers come back once the session refreshes it (as soon as you use
  it) or you close it. Brow checks only when a refresh is due or Anthropic has
  rejected the token. It reads the process list: the command line of each
  `claude`, node, bun or deno process, to tell which ones are Claude Code, and
  from a Claude Code process's environment only `CLAUDE_CONFIG_DIR`. A session
  still counts after an update has deleted the binary it was started from. It
  also reads the modification time of `history.jsonl`. It reads no file's
  contents and nothing from the Keychain for this, and starts no process.
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
- The strip is drawn as the notch outline (`NotchShape`), not a rectangle. Its
  tuning knobs are constants in `Sources/BrowKit/Panel/NotchGeometry.swift` —
  `flare` (concave top corners, 6), `collapsedBottomRadius` (14),
  `expandedBottomRadius` (18), `wingWidth` (96), `belowStripHeight` (22). They are
  meant to be tuned by eye against the physical bezel; no screenshot can show it.
