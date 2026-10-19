# Snapshot testing (agent-verifiable UI)

## How to render

    swift run BrowApp --snapshot /tmp/brow-snap     # prints "snapshot: 9 files", exits

Workspaces' screens as a window of their own draws them, without starting the app: no
notch, no menu-bar item, no engine. Nine scenes, each at its route's adaptive size @2x,
defined in `Sources/GroveAppKit/Snapshot/SnapshotMode.swift` (`SnapshotScene`):
projects, root-workspaces, workspaces-expanded, create-sheet, graph, stats,
settings (a project's settings), stats-settings, error-banner
(the RootView actionError strip over the projects route).
The state comes from `SnapshotMode.fixtureState()` — fully synthetic
(no git, no disk scanning, no real config, and every folder it could write sits in a
temp dir beside its config file); see the coverage matrix in that file.
Ages are relative to render-time `Date()`, so badge buckets stay truthful.

The notch, the Settings window and the README's pictures are rendered by the two
`DemoScreenshotTests` instead, from one set of made-up accounts (`Tests/DemoFixture`)
so the notch's and Workspaces' pictures agree:

    DEMO_SCREENSHOTS_DIR="$PWD/docs/screenshots" swift test --filter DemoScreenshotTests

The one window — the notch panel with Limits and Projects, the screens Workspaces pushes
in it, its menus, notices and corners — is rendered for review by `OneWindowRenderTests`,
through the real `NotchPanelController` at the frames it computes (`ONE_WINDOW_BEFORE_PNG`
adds a 0.4.0 render of the clipped panel to the before/after picture):

    ONE_WINDOW_RENDERS_DIR=/tmp/one-window Scripts/test-in-empty-home.sh --filter OneWindowRenderTests

Offscreen, `FadingScrollView` draws its content clipped to the room it is given, scrolled
by `renderScrollOffset` (never past the end), with its fades and indicator: ImageRenderer
draws no `ScrollView`. Views with AppKit-backed controls check `isSnapshotRender` (set with
`.snapshotRender()`) and draw lookalikes.

They draw the pet at rest. Its own renders go to a folder outside the repository:
`PetFinalRenderTests` films and stills it through Brow's real views (the strip in
every placement, the hop into the panel, the den, the moods), `PetShowreelTests`
plays the rig's reels; `PET_FINAL_ONLY` and `PET_SHOWREEL_ONLY` pick some:

    PET_FINAL_DIR=/tmp/pet-final swift test -c release --filter PetFinalRenderTests
    PET_SHOWREEL_DIR=/tmp/pet-reels swift test -c release --filter PetShowreelTests

## Regression workflow (any UI change)

1. Change view code.
2. `Scripts/test-in-empty-home.sh` (fixture invariants live in SnapshotModeTests).
3. Re-render: `rm -rf /tmp/brow-snap && swift run BrowApp --snapshot /tmp/brow-snap`.
4. READ the affected PNG(s) and check the visual assertions
   (structure + text content, never glass/blur).
5. Commit code only — PNGs are throwaway artifacts, never committed (the README's
   screenshots in `docs/screenshots` are the exception, regenerated on purpose).

## ImageRenderer caveats (empirically verified on macOS 26.4)

- `.glassEffect`-modified views render INVISIBLE offscreen (not merely flat).
  GlassCard swaps to fill+border when `\.isSnapshotRender` is true. Any new glass
  chrome must respect the same flag.
- AppKit-backed controls (e.g. `Picker(.segmented)`) render as a yellow error
  placeholder. Use pure-SwiftUI equivalents in snapshot-visible chrome, or render
  in an offscreen window as the Settings and launch-sheet demos do.
- `ScrollView`/`List` content is NOT rendered offscreen. Screens that must be
  snapshot-verifiable should render their content unscrolled (plain stacks) or
  swap the container when `\.isSnapshotRender` is true.
- The PNG background is a stand-in gradient: there is no desktop/panel material
  offscreen. Real glass is verified by running the app, not here.
