#!/bin/zsh
# Builds and runs the development binary of Brow under an identifier of its own.
# Usage: Scripts/dev-run.sh [--release] [-- <args passed to Brow>]
#
# Why its own identifier: macOS keys per-app state on how a binary is signed and
# named. The menu-bar item's slot is one of them, and on macOS 26.4 rebuild churn
# under the shipping id corrupted that slot (Grove had to move to a new bundle id).
# A dev build signed as dev.artemefimov.brow.dev cannot do that to dev.artemefimov.brow,
# and consents (Automation for Terminal and cmux) given to it stay with it:
#
#   ad hoc (what SwiftPM produces)  -> keyed by cdhash  -> DIES on every rebuild
#   stable identity                 -> keyed by identifier + leaf certificate
#
# Set BROW_SIGN_IDENTITY to your own "Apple Development: Name (TEAMID)" identity to
# keep consents across rebuilds. The dev binary reads and writes the same settings
# folders as the app (~/Library/Application Support/Brow and …/Grove).
set -euo pipefail

cd "$(dirname "$0")/.."
source Scripts/xcode-env.sh

CONFIGURATION="debug"
if [[ "${1:-}" == "--release" ]]; then
    CONFIGURATION="release"
    shift
fi
[[ "${1:-}" == "--" ]] && shift

IDENTITY="${BROW_SIGN_IDENTITY:-${GROVE_SIGN_IDENTITY:-}}"
IDENTIFIER="dev.artemefimov.brow.dev"

swift build -c "$CONFIGURATION" --product BrowApp
BINARY="$(swift build -c "$CONFIGURATION" --show-bin-path)/BrowApp"

if [[ -n "$IDENTITY" ]] && security find-identity -v -p codesigning 2>/dev/null | grep -qF "$IDENTITY"; then
    codesign --force --sign "$IDENTITY" --identifier "$IDENTIFIER" "$BINARY"
    echo "signed: $IDENTITY ($IDENTIFIER)"
else
    codesign --force --sign - --identifier "$IDENTIFIER" "$BINARY"
    echo "signed: ad hoc ($IDENTIFIER); consents reset on every rebuild" >&2
fi

exec "$BINARY" "$@"
