#!/bin/sh
# Brow's browser router. Point Claude Code at it (`BROWSER=<this file>`) and every
# sign-in it opens lands in a Chrome profile dedicated to the account that asked:
#
#   CLAUDE_CONFIG_DIR=~/.claude-accounts/work claude auth login
#
# opens ~/Library/Application Support/Brow/browser-profiles/<key>/ where <key> is the
# same 8-hex sha256 prefix Claude Code keys the account's Keychain item on — one
# browser, one cookie jar, one claude.ai session per account, so signing one account
# in never signs another out. Brow never sees a credential: Chrome holds the
# session, Claude Code holds the token, this script only chooses the window.
#
# Claude Code calls `$BROWSER <url>`; it honours the variable (verified on 2.1.273).
set -u
url="${1:-}"
[ -n "$url" ] || { echo "brow-browser: no URL" >&2; exit 2; }

dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
case "$dir" in "~"*) dir="$HOME${dir#\~}" ;; esac
dir="${dir%/}"
if command -v shasum >/dev/null 2>&1; then
    key=$(printf '%s' "$dir" | shasum -a 256 | cut -c1-8)
else
    key=$(printf '%s' "$dir" | openssl dgst -sha256 | awk '{print substr($NF,1,8)}')
fi
profile="$HOME/Library/Application Support/Brow/browser-profiles/$key"
mkdir -p "$profile"
printf '%s\n' "$dir" > "$profile/.claude-config-dir"

for app in "Google Chrome" "Chromium" "Brave Browser" "Microsoft Edge"; do
    if [ -d "/Applications/$app.app" ]; then
        exec open -na "$app" --args --user-data-dir="$profile" --no-first-run --no-default-browser-check "$url"
    fi
done
# No Chromium-based browser: the default browser, shared profile (the old behaviour).
exec open "$url"
