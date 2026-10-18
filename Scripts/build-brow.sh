#!/bin/zsh
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 Artem Efimov

# Builds the release: dist/Brow.app (the app) and dist/brow (the command-line tool).
# Usage: Scripts/build-brow.sh [--launch]
#
# The version is BrowVersion.current (Sources/GroveCore/BrowVersion.swift), the one
# place it is written; the bundle's Info.plist is Resources/Info.plist filled in with it.
# Signed with BROW_SIGN_IDENTITY when that identity is in the keychain (GROVE_SIGN_IDENTITY
# is still read), ad hoc otherwise. Scripts/release.sh packages what this builds.
set -euo pipefail

# `${0:a:h}` is the script's own absolute directory, resolved BEFORE the cd so
# the source below still finds its sibling no matter where this was invoked from.
SCRIPT_DIR="${0:a:h}"
cd "$SCRIPT_DIR/.."
# The /usr/bin shims abort on the unaccepted Xcode license; xcode-env.sh points
# swift/git/xcrun at the toolchain directly.
source "$SCRIPT_DIR/xcode-env.sh"

VERSION=$(sed -n 's/.*static let current = "\(.*\)".*/\1/p' Sources/GroveCore/BrowVersion.swift)
if [[ ! "$VERSION" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]]; then
    echo "build-brow: no x.y.z version in Sources/GroveCore/BrowVersion.swift (found '$VERSION')" >&2
    exit 1
fi

swift build -c release --product BrowApp
swift build -c release --product brow
BIN=$(swift build -c release --show-bin-path)

APP="dist/Brow.app"
rm -rf "$APP" dist/brow
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/BrowApp" "$APP/Contents/MacOS/Brow"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# The browser router Claude Code is pointed at via BROWSER= (see Resources/brow-browser.sh).
# Under Resources, not MacOS: codesign treats anything in MacOS/ as a nested code
# object that needs its own signature; a resource is simply sealed with the bundle.
cp Resources/brow-browser.sh "$APP/Contents/Resources/brow-browser"
chmod +x "$APP/Contents/Resources/brow-browser"
# GPL-3.0: the licence travels with the binary.
cp LICENSE "$APP/Contents/Resources/LICENSE"
sed "s/@VERSION@/$VERSION/g" Resources/Info.plist > "$APP/Contents/Info.plist"
plutil -lint -s "$APP/Contents/Info.plist"

cp "$BIN/brow" dist/brow
# The linker's debug map (its N_OSO and N_SO entries) names every object file and source folder by
# its absolute path on the machine that built it. Nothing reads it at run time and no dSYM is made
# from these copies, so it goes before signing.
strip -S "$APP/Contents/MacOS/Brow" dist/brow

# Sign with the stable development identity when present so the macOS automation
# consent (Apple Events -> Terminal, cmux) survives rebuilds: ad hoc signatures change
# every build, which voids the TCC grant each time. Set BROW_SIGN_IDENTITY to your own
# "Apple Development: Name (TEAMID)" identity.
IDENTITY="${BROW_SIGN_IDENTITY:-${GROVE_SIGN_IDENTITY:-}}"
if [[ -n "$IDENTITY" ]] && security find-identity -v -p codesigning 2>/dev/null | grep -qF "$IDENTITY"; then
    SIGN=("$IDENTITY"); SIGNED_AS="$IDENTITY"
else
    SIGN=(-); SIGNED_AS="ad hoc (no stable identity found; automation consent resets on every rebuild)"
fi
codesign --force --sign "${SIGN[@]}" --identifier dev.artemefimov.brow.cli dist/brow
codesign --force --sign "${SIGN[@]}" "$APP"
codesign --verify --deep --strict "$APP"
echo "signed: $SIGNED_AS"
echo "built: $APP and dist/brow, version $VERSION"

if [[ "${1:-}" == "--launch" ]]; then
    open "$APP"
fi
