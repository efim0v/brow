#!/bin/zsh
# Measures test coverage and enforces the project's coverage policy (see COVERAGE.md).
#
# The GATE is the pure/mockable LOGIC layer of the Workspaces engine and the code the
# notch shares with it (GroveCore services and models, GroveAppKit presentation and
# state) and must be >= 95%. SwiftUI views are validated by the snapshot/render tests;
# real cmux/osascript/socket adapters and the NSApplication entry points are validated
# by manual/integration testing — both are excluded from the gate. BrowKit's own logic
# (models and state) is reported on a line of its own.
set -euo pipefail
cd "$(dirname "$0")/.."

# With the home folder pointed at an empty one, like Scripts/test-in-empty-home.sh.
EMPTY_HOME=$(mktemp -d "${TMPDIR:-/tmp}/brow-coverage-home.XXXXXX")
trap 'rm -rf "$EMPTY_HOME"' EXIT
HOME="$EMPTY_HOME" CFFIXED_USER_HOME="$EMPTY_HOME" swift test --enable-code-coverage
# With either SwiftPM build system .build/debug links to the debug products. The classic
# one makes a single test bundle (plus a .dSYM folder next to its binary, hence plain
# files only); the newer one, the default in Swift 6.4, makes one bundle per test target.
# llvm-cov reads them all and counts code linked into several bundles once.
PROF=.build/debug/codecov/default.profdata
OBJECTS=()
for bin in .build/debug/*.xctest/Contents/MacOS/*(.N); do
    OBJECTS+=(-object "$bin")
done
if [[ ! -f "$PROF" || ${#OBJECTS[@]} -eq 0 ]]; then
    echo "no coverage profile or test bundle under .build/debug" >&2
    exit 1
fi

# Excluded from the logic gate (validated by other means, not unit coverage).
GATE_IGNORE='Tests|\.build|GroveAppKit/Views/|GroveMenuBarApp|WorkspacesMenuBarController|DesignSystem|GroveLog|Snapshot/SnapshotMode|Services/Cmux|Diagnostics/CmuxProbe|BrowKit/|BrowApp/|brow-cli/'
# BrowKit's logic: its models and state, without the views, the notch window and the
# app delegate (render tests and the app cover those).
BROWKIT_IGNORE='Tests|\.build|GroveCore/|GroveAppKit/|BrowKit/Views/|BrowKit/Panel/|BrowKit/App/|BrowKit/BrowLog|BrowApp/|brow-cli/'

cover() {
    xcrun llvm-cov report "${OBJECTS[@]}" -instr-profile="$PROF" \
        -ignore-filename-regex="$1" --show-region-summary=false 2>/dev/null \
        | grep TOTAL | awk '{n=NF; v=$(n-3); gsub("%","",v); print v}'
}

ALL=$(cover 'Tests|\.build')
GATE=$(cover "$GATE_IGNORE")
BROWKIT=$(cover "$BROWKIT_IGNORE")
echo "Overall line coverage:    ${ALL}%"
echo "Logic-gate coverage:      ${GATE}%   (policy: >= 95%)"
echo "BrowKit logic coverage:   ${BROWKIT}%   (reported, not gated)"

awk -v g="$GATE" 'BEGIN { exit (g+0 >= 95) ? 0 : 1 }' \
    && echo "GATE PASS" || { echo "GATE FAIL"; exit 1; }
