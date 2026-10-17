#!/bin/zsh
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 Artem Efimov

# Runs `swift test` with the home folder pointed at a fresh, empty directory, then
# fails if the suite left any app data behind in it.
#
# Usage: Scripts/test-in-empty-home.sh [swift test arguments…]
#        Scripts/test-in-empty-home.sh -c release
#
# Why: every contributor runs the whole suite on their own Mac, next to their own
# ~/.claude, ~/.claude-accounts and ~/Library/Application Support/{Brow,Grove}. A test
# that forgets a temp dir writes into those. Foundation takes the home folder from
# CFFIXED_USER_HOME (HOME alone does not move NSHomeDirectory()), so both are set.
set -uo pipefail
cd "$(dirname "$0")/.."

EMPTY_HOME=$(mktemp -d "${TMPDIR:-/tmp}/brow-test-home.XXXXXX")
trap 'rm -rf "$EMPTY_HOME"' EXIT

HOME="$EMPTY_HOME" CFFIXED_USER_HOME="$EMPTY_HOME" swift test "$@"
test_status=$?

# What the app and the engine would write if a test reached the real folders.
leaks=()
for entry in "Library/Application Support/Grove" "Library/Application Support/Brow" \
            ".claude" ".claude.json" ".claude-accounts" "Workspaces"; do
    [[ -e "$EMPTY_HOME/$entry" ]] && leaks+=("$entry")
done
if (( ${#leaks[@]} )); then
    echo "test-in-empty-home: the suite wrote into the home folder:" >&2
    for entry in "${leaks[@]}"; do
        echo "  ~/$entry" >&2
        (cd "$EMPTY_HOME" && find "$entry" -maxdepth 3 | head -10 | sed 's/^/    /') >&2
    done
    exit 1
fi
exit $test_status
