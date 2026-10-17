#!/bin/zsh
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 Artem Efimov

# Packages a release from what Scripts/build-brow.sh built, and checks it the way a
# user will get it. Uploads nothing: the tag (bare semver, `0.4.0`) and the GitHub
# release are made by hand.
#
# Usage: Scripts/release.sh [--build]
#
#   dist/Brow.zip        Brow.app
#   dist/brow-cli.zip    brow, grove (a symlink to brow), LICENSE
#   dist/SHA256SUMS.txt  for both
set -euo pipefail
cd "$(dirname "$0")/.."

[[ "${1:-}" == "--build" ]] && Scripts/build-brow.sh
if [[ ! -d dist/Brow.app || ! -x dist/brow ]]; then
    echo "release: no dist/Brow.app or dist/brow — run Scripts/build-brow.sh first" >&2
    exit 1
fi
VERSION=$(sed -n 's/.*static let current = "\(.*\)".*/\1/p' Sources/GroveCore/BrowVersion.swift)
PLIST_VERSION=$(plutil -extract CFBundleShortVersionString raw dist/Brow.app/Contents/Info.plist)
if [[ "$VERSION" != "$PLIST_VERSION" ]]; then
    echo "release: dist/Brow.app is $PLIST_VERSION but BrowVersion is $VERSION — rebuild" >&2
    exit 1
fi
codesign --verify --deep --strict dist/Brow.app

rm -f dist/Brow.zip dist/brow-cli.zip dist/SHA256SUMS.txt
# --norsrc --noextattr --noqtn --noacl: no resource forks, extended attributes, quarantine
# or ACLs in the archive. With them, an unzip other than ditto writes AppleDouble ._ files
# into the bundle and its signature no longer verifies.
ZIP=(ditto -c -k --norsrc --noextattr --noqtn --noacl)
"${ZIP[@]}" --keepParent dist/Brow.app dist/Brow.zip

STAGE=$(mktemp -d "${TMPDIR:-/tmp}/brow-release.XXXXXX")
CHECK=$(mktemp -d "${TMPDIR:-/tmp}/brow-release-check.XXXXXX")
trap 'rm -rf "$STAGE" "$CHECK"' EXIT
cp dist/brow "$STAGE/brow"
# The tool's second name, for scripts written for Grove's: one binary, a symlink.
ln -s brow "$STAGE/grove"
cp LICENSE "$STAGE/LICENSE"
"${ZIP[@]}" "$STAGE" dist/brow-cli.zip

(cd dist && shasum -a 256 Brow.zip brow-cli.zip > SHA256SUMS.txt)

# What a user gets: unzipped by /usr/bin/unzip, not ditto.
/usr/bin/unzip -q dist/Brow.zip -d "$CHECK/app"
codesign --verify --deep --strict --verbose=1 "$CHECK/app/Brow.app"
if [[ -n "$(find "$CHECK/app" -name '._*' -print -quit)" ]]; then
    echo "release: Brow.zip carries AppleDouble files" >&2
    exit 1
fi
/usr/bin/unzip -q dist/brow-cli.zip -d "$CHECK/cli"
if [[ ! -L "$CHECK/cli/grove" || "$(readlink "$CHECK/cli/grove")" != brow ]]; then
    echo "release: brow-cli.zip has no grove -> brow symlink" >&2
    exit 1
fi
codesign --verify --strict "$CHECK/cli/brow"
[[ "$("$CHECK/cli/brow" --version)" == "$VERSION" ]] || { echo "release: brow --version is not $VERSION" >&2; exit 1; }
[[ "$("$CHECK/cli/grove" --help | head -1)" == "grove — "* ]] || { echo "release: grove does not answer as grove" >&2; exit 1; }
(cd dist && shasum -a 256 -c SHA256SUMS.txt)

echo "release $VERSION:"
ls -l dist/Brow.zip dist/brow-cli.zip dist/SHA256SUMS.txt
echo "Nothing was uploaded. To publish, by hand: git tag $VERSION && git push origin $VERSION,"
echo "then gh release create $VERSION --verify-tag dist/Brow.zip dist/brow-cli.zip dist/SHA256SUMS.txt"
