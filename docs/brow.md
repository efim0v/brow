# Brow: behaviour in detail

- Accounts are discovered from `~/.claude` and `~/.claude-accounts/*`; dirs that
  belong to the same organisation are shown once.
- On first launch macOS asks once per account for access to Claude Code's
  Keychain item — choose "Always Allow".
- Idle accounts' tokens are kept fresh by running `claude doctor` in that
  account (no model call). If that ever stops working, the `claude -p` fallback
  (Settings → Accounts, **on by default**) spends a little limit and starts the
  account's 5-hour window. It is never used after a 401/403 or a `doctor` that
  timed out — neither is evidence the token itself can be fixed — and it is
  dropped for good after three ineffective rounds.
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
- Add an account from Settings with one click (**Sign in…**): Brow creates
  `~/.claude-accounts/account-N` itself and opens Terminal with `claude auth login`;
  sign-in happens in Anthropic's own flow.
- Limits are re-fetched every **60 s** by one timer that keeps running whether the
  panel is open or shut, plus on wake, on the network returning, and on hover when
  the data on screen is more than 60 s old. The footer always leads with the age
  (`Updated 3 h ago`), so a number you can see is a number you can date.
- **Settings → General → Ears** chooses where the two readouts sit on a built-in
  display: `Beside the notch` (default — one wing each side, the notch itself left
  clear) or `Below the notch` (one centred row in a 22 pt strip under it). It takes
  effect as you click; an external display always shows the pill.
- The strip is drawn as the notch outline (`NotchShape`), not a rectangle. Its
  tuning knobs are constants in `Sources/BrowKit/Panel/NotchGeometry.swift` —
  `flare` (concave top corners, 6), `collapsedBottomRadius` (12),
  `expandedBottomRadius` (18), `wingWidth` (96), `belowStripHeight` (22). They are
  meant to be tuned by eye against the physical bezel; no screenshot can show it.
