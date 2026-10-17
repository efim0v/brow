# Contributing to Brow

Thanks for helping. Brow has one maintainer, so this guide stays short: where to ask, what fits, how to build and test, and how to send a change.

- **Questions and setup help:** [Discussions → Q&A](https://github.com/efim0v/brow/discussions/categories/q-a).
- **Bugs:** [open an issue](https://github.com/efim0v/brow/issues/new/choose) with the bug report form. It asks which part of Brow the bug is in, and for the versions, the Mac and the log needed to track it down.
- **Ideas:** the feature request form, or [Discussions → Ideas](https://github.com/efim0v/brow/discussions/categories/ideas) to talk one through first.
- **Security problems:** never in public. See [SECURITY.md](SECURITY.md).

Everyone taking part follows the [code of conduct](CODE_OF_CONDUCT.md).

## What fits in Brow

Brow has two surfaces ([What it does](README.md#what-it-does)):

- **the notch**: the 5-hour and weekly limits of every Claude Code account on the Mac, and one-click sign-in for each;
- **Workspaces**, in the menu bar: workspaces of git worktrees across several repositories, the Claude Code sessions in them, and moving sessions between accounts — with the commit graph, the code statistics and the `brow` command-line tool.

Fixes and improvements to either are welcome, and so are fixes for a Mac or display that Brow draws wrongly on. Problems with Claude Code itself belong in [anthropics/claude-code](https://github.com/anthropics/claude-code/issues), and problems with cmux in [manaflow-ai/cmux](https://github.com/manaflow-ai/cmux/issues). If Brow reports cmux as unavailable while cmux is running, read [`docs/troubleshooting.md`](docs/troubleshooting.md) first.

Three things to keep in mind:

- **[What Brow does on your machine](README.md#what-brow-does-on-your-machine) has to stay true.** A change must not write a token to disk, log it, or send anything anywhere but Anthropic's usage and profile endpoints. A change to what Brow writes into Claude Code's own files — each account's `settings.json` and `.claude.json`, its session folders — updates that section in the same pull request.
- **Claude Code's JSON files are written through `HotJSONFile` only**, which takes Claude Code's own lock, writes nothing when nothing changes and never overwrites a file that does not parse. And nothing of Workspaces runs, or writes, until the user has turned it on (`WorkspacesActivation`).
- **No third-party dependencies.** The package has none, on purpose (see [COVERAGE.md](COVERAGE.md)).

For anything bigger than a small fix, open an issue first, so the approach is agreed before you spend time on code.

## Build, run and test

You need macOS 26 or later, Xcode with Swift 6.4 or newer, and git.

```sh
git clone https://github.com/efim0v/brow.git
cd brow

swift build                                   # debug build: libraries, app and CLI
Scripts/test-in-empty-home.sh                 # the whole suite, about three minutes
Scripts/test-in-empty-home.sh -c release      # the same suite, optimized
swift test --filter LimitsAggregateTests      # one test class
Scripts/check-warnings.sh                     # a clean build that fails on new warnings
Scripts/build-brow.sh                         # release build -> dist/Brow.app and dist/brow
```

- `Scripts/test-in-empty-home.sh` runs `swift test` with the home folder pointed at an empty one and fails if the suite leaves Brow's or Grove's data, or Claude Code's folders, in it. Plain `swift test` works too, but only the script proves a test kept out of your own `~/.claude`.
- Both the debug and the release run should pass before a pull request. The optimized run is not a formality: release builds have miscompiled the engine before (see `WorktreeScanResult` in `Sources/GroveCore/Services/WorkspaceService.swift`).
- The suite runs offline and needs no Claude account and no Keychain access. A few tests are skipped unless you ask for them: `CmuxLiveTests` talks to a running cmux (`GROVE_LIVE_CMUX=1`), the two `DemoScreenshotTests` render the README screenshots (`DEMO_SCREENSHOTS_DIR`), and the review renders write to `BROW_REVIEW_DIR`.
- Some tests are timed. `ISODateParsingTests` gives 100,000 date parses one second, so it can fail on a heavily loaded Mac; run it again on its own before you dig in.
- New tests follow the existing pattern: fixtures, temporary directories and injected runners rather than the real `~/.claude`, the network or a running cmux. An `AppState` built on a temporary config file keeps every folder it writes beside that file (`WorkspacesFolders`). [COVERAGE.md](COVERAGE.md) describes how each layer is tested.

To run what you built:

- **A build you run is Brow for real.** It reads and writes the same `~/Library/Application Support/Brow` and, with Workspaces on, `~/Library/Application Support/Grove` as an installed copy. Workspaces runs in one copy at a time (the second waits for the first, see [troubleshooting](docs/troubleshooting.md#workspaces-says-it-is-open-in-another-brow)), but the notch runs in both, so quit the installed one first (⌘Q with its Settings window in front, or **Quit Brow** in the Workspaces panel).
- `Scripts/dev-run.sh` builds and runs the debug binary under its own identifier, `dev.artemefimov.brow.dev`, so rebuilds cannot disturb the installed app's menu-bar slot or permissions.
- Both build scripts sign ad hoc unless `BROW_SIGN_IDENTITY` names a code-signing identity of yours, such as `Apple Development: Name (TEAMID)`. With an ad hoc signature macOS forgets Brow's Keychain and Automation permissions on every rebuild.
- `swift run BrowApp --snapshot /tmp/brow-snap` renders the Workspaces screens to PNG from made-up data and exits without starting the app; see [`docs/snapshot-testing.md`](docs/snapshot-testing.md). `swift run brow --help` and `swift run brow doctor` run the command-line tool.
- To watch the logs while you work:

  ```sh
  log stream --level info --predicate 'subsystem == "dev.artemefimov.brow"'
  ```

  The notch logs under the categories `limits`, `tokens`, `panel` and `notify`, Workspaces under `workspaces` and `perf`; `TokenKeeper`, `ProcessRunner`, `ClaudeService` and `keychain` log under the same subsystem.
- The README screenshots are rendered from made-up accounts and projects, one set of accounts (`Tests/DemoFixture`) for the notch, Settings and Workspaces, so the pictures agree where they meet:

  ```sh
  DEMO_SCREENSHOTS_DIR="$PWD/docs/screenshots" swift test --filter DemoScreenshotTests
  ```

  The notch's shots are drawn at 09:41 today, and Workspaces' ages count back from the moment of the render, so the pictures change from one day to the next. Commit them only with a change that alters what they show.

[Layout](README.md#layout) in the README says where the code lives. [`docs/brow.md`](docs/brow.md) and [`docs/workspaces.md`](docs/workspaces.md) describe the behaviour in detail, and [`docs/architecture.md`](docs/architecture.md) lists the modules and the contracts between them.

## Style

- Match the code around your change: four-space indentation, and names and structure like the neighbouring code. There is no formatter or linter to run.
- Every target builds in the Swift 5 language mode (`Package.swift`). `Scripts/check-warnings.sh` must find no new warnings.
- Every `.swift`, `.sh` and `.py` file starts with the licence header (`Scripts/check-headers.sh` checks it).
- Comments say why. Many lines carry a note about the bug they fixed; keep yours in that spirit, and keep a comment until what it explains is gone.
- Log through `BrowLog` or `GroveLog`. Never log a token or anything read from a Keychain item.
- `GroveAppKit` never imports `BrowKit`: what the Workspaces panel needs from the app comes in through closures and protocols such as `AccountLimitsProviding`.
- UI changes: re-render the affected screens and look at them. If a change alters a screen the README shows, regenerate its screenshots.
- Commit subjects follow the history: a type, an optional scope, and a lower-case summary of what changes for the user, such as `fix(brow): reset times in the bars carry the date, not the weekday` or `fix(core): the transcript mirror keeps only what Claude Code keeps`.

## Pull requests

1. Fork the repository and branch off `main`.
2. Keep one change per pull request; a small one is easier to review.
3. Run both test scripts. New behaviour comes with a test; a fixed bug comes with a test that fails without the fix.
4. Open the pull request and fill in the template: what changed and why, how you tested it, screenshots for UI changes (name the Mac you checked a notch change on — the outline is tuned by eye, see [`NotchGeometry.swift`](Sources/BrowKit/Panel/NotchGeometry.swift)), and whether the change touches Claude Code's files.
5. Keep the [contracts](docs/architecture.md#contracts) intact. `accountKey` in particular exists twice, in `GroveCore` and in `Resources/brow-browser.sh`; `BrowserRouterContractTests` holds the two together.

With one maintainer, a review can take a few days.

## License

Brow is licensed under the [GNU GPL v3](LICENSE). By sending a pull request you agree that your contribution is released under the same licence.
