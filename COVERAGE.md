# Test coverage policy

Run `Scripts/coverage.sh` to measure coverage and enforce the gate.

## The gate: logic layer ≥ 95%

Brow is a SwiftUI app with two surfaces. Per standard practice for UI apps, the
unit-coverage **gate** is the **pure / mockable logic layer** of the engine it took
over from Grove — it must stay at **≥ 95%** line coverage:

- `GroveCore` services (git, claude, statusline capture reader, workspace, shared
  store, the transcript safety net and Claude Code's retention, statusline, config
  store, process runner — and the rate-limit model, OAuth clients, token keeper and
  account directory the notch builds on),
- `GroveCore` models (config, errors, paths, folders),
- `GroveAppKit/Presentation/*` (all the pure view-models),
- `GroveAppKit/State/*` (`AppState`, routing, account limits).

These are tested directly with fixtures, temp dirs, and injected runners/fetchers
(no real network, git, cmux, or `~/.claude` access).

`BrowKit` is reported on a line of its own, not gated. It measures `Model/*`,
`State/*` and all of `Pet/*`: the store, settings, activation and limit-warning logic
and the pet's brain, rig and words, unit-tested the same way, and also the pet's views
(`PetCanvas`, `PetLayerView`), its senses (`PetSenses`) and its perf log (`PetPerfLog`),
which render tests and `PetSensesTests` cover only in part. BrowKit's other views, its
panel and its app delegate are left out, as in the table below.

## Excluded from the gate (validated by other means)

These are **not** unit-testable in isolation; covering them to 95% would require
real external infrastructure or UI automation, which would be brittle and pull in
dependencies the app deliberately avoids (it has none):

| Excluded | Why | How it's validated instead |
|----------|-----|----------------------------|
| `GroveAppKit/Views/*`, `DesignSystem`, `GroveLog` | SwiftUI rendering + interactive `@State`/button closures | **Snapshot/render tests** (`SnapshotModeTests`, `DashboardRenderTests`, `ViewStatesRenderTests`) render every scene — both snapshot and live branches — and assert non-empty output, catching layout/render crashes. |
| `WorkspacesMenuBarController` | `NSStatusItem`/`NSPanel` bootstrap | Its anchor logic is unit-tested (`PanelAnchorTests`); the rest by running the app. |
| `BrowKit/Views/*`, `BrowKit/Panel/*`, `BrowKit/App/*` | The notch window, SwiftUI views, the app delegate | Render and pixel tests (`PanelRefreshGateTests`, `EarsViewFillTests`, `PanelViewShapeTests`, `BrowMarkTests`), the host's own tests (`WorkspacesHostTests`), and the app. |
| `Services/CmuxService`, `Services/CmuxAppleScript` | Drive the real cmux CLI / control socket / `osascript` + a live shell handshake | Their pure/parse logic IS unit-tested with a scripted runner (`CmuxServiceTests`, `CmuxAppleScriptBackendTests`); the real-socket/osascript paths are validated manually and via `Brow --cmux-probe`. |
| `Diagnostics/CmuxProbe.swift` | A manual diagnostic that benchmarks the real cmux socket | Run by hand: `open -nW /Applications/Brow.app --args --cmux-probe <out>`. |
| `Snapshot/SnapshotMode.swift` | Is itself the test/render harness | n/a |
| `BrowApp`, `brow-cli` | Entry points | `brow`'s name handling and help text are in `GroveCore` and unit-tested (`ToolNameTests`). |

The overall (all-files) number is also printed for transparency; it is lower
because it includes the excluded view/integration code above.

## Where it stands

At 0.4.0 the gate measures about 93 %, under the policy, and `coverage.sh` exits 1.
Nearly all of the gap came in with Grove's code: `TerminalFocus` has no tests, and
`GitStatsService`, `ClaudeService`, `ClaudeCredentials`, `ProcessRunner` and
`SessionMigration` hold most of the other untested lines. CI does not run
`coverage.sh`, so no build fails on it; bringing the gate back to 95 % is open work.
