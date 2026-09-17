#!/bin/zsh
# Builds dist/Brow.app from the BrowApp release binary.
# Usage: Scripts/build-brow.sh [--launch]
set -euo pipefail

# `${0:a:h}` is the script's own absolute directory, resolved BEFORE the cd so
# the source below still finds its sibling no matter where this was invoked from.
SCRIPT_DIR="${0:a:h}"
cd "$SCRIPT_DIR/.."
# The /usr/bin shims abort on the unaccepted Xcode license; xcode-env.sh points
# swift/git/xcrun at the toolchain directly.
source "$SCRIPT_DIR/xcode-env.sh"

swift build -c release --product BrowApp

APP="dist/Brow.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/BrowApp "$APP/Contents/MacOS/Brow"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# The browser router Claude Code is pointed at via BROWSER= (see Resources/brow-browser.sh).
# Under Resources, not MacOS: codesign treats anything in MacOS/ as a nested code
# object that needs its own signature; a resource is simply sealed with the bundle.
cp Resources/brow-browser.sh "$APP/Contents/Resources/brow-browser"
chmod +x "$APP/Contents/Resources/brow-browser"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleIdentifier</key>
	<string>dev.artemefimov.brow</string>
	<key>CFBundleName</key>
	<string>Brow</string>
	<key>CFBundleExecutable</key>
	<string>Brow</string>
	<key>CFBundleIconFile</key>
	<string>AppIcon</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<!-- Keep in sync with GroveVersion.current (Sources/GroveCore/GroveVersion.swift). -->
	<key>CFBundleShortVersionString</key>
	<string>0.2.0</string>
	<key>CFBundleVersion</key>
	<string>0.2.0</string>
	<key>LSUIElement</key>
	<true/>
	<key>LSMinimumSystemVersion</key>
	<string>26.0</string>
	<key>NSHighResolutionCapable</key>
	<true/>
	<key>NSAppleEventsUsageDescription</key>
	<string>Brow opens Terminal to run Claude Code sign-in.</string>
</dict>
</plist>
PLIST

# Sign with the stable development identity when present so the macOS
# automation (Apple Events -> Terminal) consent survives rebuilds: ad-hoc
# signatures change every build, which voids the TCC grant each time.
IDENTITY="Apple Development: Your Name (TEAMID)"
if security find-identity -v -p codesigning 2>/dev/null | grep -qF "$IDENTITY"; then
    codesign --force --sign "$IDENTITY" "$APP"
    echo "signed: $IDENTITY"
else
    codesign --force --sign - "$APP"
    echo "signed: ad-hoc (stable identity not found; automation consent will reset on rebuild)"
fi
echo "built: $APP"

if [[ "${1:-}" == "--launch" ]]; then
    open "$APP"
fi
