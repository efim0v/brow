# Contributing to Brow

Thanks for helping. Brow is a small app with one maintainer, so this guide is short: where to ask, what fits, how to build and test, and how to send a change.

- **Questions and setup help:** [Discussions → Q&A](https://github.com/efim0v/brow/discussions/categories/q-a).
- **Bugs:** [open an issue](https://github.com/efim0v/brow/issues/new/choose) with the bug report form. It asks for the versions, the Mac and the log needed to track a problem down.
- **Ideas:** the feature request form, or [Discussions → Ideas](https://github.com/efim0v/brow/discussions/categories/ideas) to talk one through first.
- **Security problems:** never in public. See [SECURITY.md](SECURITY.md).

Everyone taking part follows the [code of conduct](CODE_OF_CONDUCT.md).

## What fits in Brow

Brow has one job: show the 5-hour and weekly limits of every Claude Code account on the Mac, in the notch, and sign each account in with one click ([What it does](README.md#what-it-does)). Fixes and improvements to that job are welcome, and so are fixes for a Mac or display that Brow draws wrongly on.

Some things live elsewhere:

- **Workspaces, worktrees and moving sessions between accounts** are [Grove](https://github.com/efim0v/grove)'s job.
- **Account discovery, credentials, usage readings and token refresh** come from `GroveCore`, a library in the grove repository ([how the two fit together](docs/grove-and-brow.md)). A change there lands in grove first and gets a release; Brow then raises the version it depends on.
- **Problems with Claude Code itself** belong in [anthropics/claude-code](https://github.com/anthropics/claude-code/issues).

The promises in [What Brow does on your machine](README.md#what-brow-does-on-your-machine) have to stay true: a change must not write a token to disk, log it, or make Brow send anything anywhere but Anthropic's usage and profile endpoints.

For anything bigger than a small fix, open an issue first, so the approach is agreed before you spend time on code.

## Build, run and test

You need macOS 26 or later and Xcode with Swift 6.2 or newer. The only dependency, `GroveCore`, is fetched from the grove repository on the first build.

```sh
git clone https://github.com/efim0v/brow.git
cd brow

swift build                                # debug build
swift test                                 # the whole suite
swift test --filter LimitsAggregateTests   # one test class
Scripts/build-brow.sh                      # release build -> dist/Brow.app
open dist/Brow.app                         # Scripts/build-brow.sh --launch does both
```

- The tests need no network, no Keychain access and no Claude account. One test is skipped on purpose: it renders the README screenshots and runs only when `DEMO_SCREENSHOTS_DIR` is set.
- `Scripts/build-brow.sh` signs the app ad hoc unless `GROVE_SIGN_IDENTITY` names a code-signing identity of yours, such as `Apple Development: Name (TEAMID)`. With an ad hoc signature macOS forgets Brow's Keychain and Automation permissions on every rebuild. The script expects Xcode at `/Applications/Xcode.app` (see [`Scripts/xcode-env.sh`](Scripts/xcode-env.sh)).
- Brow does not check for a second copy of itself, so quit the installed one before you open your build: open its Settings from the ⚙ in the panel and press ⌘Q while that window is in front.
- To watch the logs while you work:

  ```sh
  log stream --level info --predicate 'subsystem == "dev.artemefimov.brow"'
  ```

  Brow's own categories are `limits`, `tokens` and `panel`; GroveCore's `TokenKeeper`, `ProcessRunner` and `keychain` log under the same subsystem.
- The README screenshots are rendered from made-up accounts:

  ```sh
  DEMO_SCREENSHOTS_DIR="$PWD/docs/screenshots" swift test --filter DemoScreenshotTests
  ```

  The panel shots carry the current date and time, so they can change between runs. Commit them only with a change that alters what they show.

[Layout](README.md#layout) in the README says where the code lives. [`docs/brow.md`](docs/brow.md) describes the behaviour in detail, and [`docs/grove-and-brow.md`](docs/grove-and-brow.md) lists the contracts Brow and Grove share on disk.

## Pull requests

- One change per pull request, branched from `main`. Small is easier to review.
- `swift build` and `swift test` pass. New behaviour comes with a test in `Tests/BrowKitTests`; a fixed bug comes with a test that fails without the fix.
- For a visible change, attach a screenshot or a short recording and name the Mac you checked it on. Notch geometry is tuned by eye against the physical bezel (the constants are in [`NotchGeometry.swift`](Sources/BrowKit/Panel/NotchGeometry.swift)), so the model and screen size matter.
- Update the README or `docs/` when behaviour changes.
- Keep the [runtime contracts](docs/grove-and-brow.md#runtime-contracts) with Grove intact. `accountKey` in particular exists twice, in GroveCore and in `Resources/brow-browser.sh`, and both must compute the same value.
- The maintainer reviews pull requests as time allows and may ask for changes.

Brow is licensed under the [GNU GPL v3](LICENSE); what you contribute is licensed under the same terms.

## Style

- Match the code around your change: four-space indentation, and names and structure like the neighbouring code. The repository has no formatter or linter configuration.
- Comments say why. Many lines carry a note about the bug they fixed; keep yours in that spirit, and keep a comment until what it explains is gone.
- Log through `BrowLog` ([`Sources/BrowKit/BrowLog.swift`](Sources/BrowKit/BrowLog.swift)). Never log a token or anything read from a Keychain item.
- Keep the build free of compiler warnings.
- Commit subjects follow the history: a type, an optional scope, and a lower-case summary of what changes for the user, such as `fix(brow): reset times in the bars carry the date, not the weekday` or `docs: say what Brow is in the first line`.
