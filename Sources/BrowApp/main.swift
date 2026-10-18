// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Artem Efimov

import BrowKit
import GroveAppKit
import GroveCore

// main.swift (not @main) so the two hidden modes can run and exit BEFORE any
// NSApplication machinery starts:
//   --snapshot <dir>     renders the Workspaces screens offscreen and exits
//                        (SnapshotMode, docs/snapshot-testing.md);
//   --cmux-probe <file>  writes a cmux diagnostic report (CmuxProbe,
//                        docs/troubleshooting.md); it parks the main thread in
//                        dispatchMain() and never returns when the flag is present.
// Top-level code runs on the main thread; assumeIsolated bridges into the @MainActor
// entry points.
let handledSnapshot = MainActor.assumeIsolated { SnapshotMode.runIfRequested() }
if !handledSnapshot && !CmuxProbe.runIfRequested() {
    MainActor.assumeIsolated { BrowApp.run() }
}
