# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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

[Unreleased]: https://github.com/efim0v/brow/compare/0.2.0...HEAD
[0.2.0]: https://github.com/efim0v/brow/releases/tag/0.2.0
