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

# Two edits to the profile, only while Chrome is not holding it (it rewrites both
# files on exit and would drop an edit made underneath it):
# - Name it after the account so Chrome's profile chip says whose browser this is.
#   The email is in the account's .claude.json; the folder's name stands in until
#   the first sign-in.
# - "Continue where you left off" (session.restore_on_startup = 1). Without it Chrome
#   deletes every SESSION cookie when the profile's instance quits, and that is what
#   icloud.com's sign-in is: X-APPLE-WEBAUTH-* carry no expiry, so each new instance
#   asked for the password again while the trusted-browser cookie sat there unused.
#   With it, session cookies survive a quit and the tabs come back too.
name=""
if [ -f "$dir/.claude.json" ] && [ -x /usr/bin/python3 ]; then
    name=$(/usr/bin/python3 -c 'import json,sys; print((json.load(open(sys.argv[1])).get("oauthAccount") or {}).get("emailAddress") or "")' "$dir/.claude.json" 2>/dev/null)
fi
[ -n "$name" ] || name=$(basename "$dir")
if [ ! -e "$profile/SingletonLock" ] && [ -x /usr/bin/python3 ]; then
    /usr/bin/python3 - "$profile" "$name" <<'PY' 2>/dev/null
import json, os, sys
profile, name = sys.argv[1], sys.argv[2]
default = os.path.join(profile, "Default")
os.makedirs(default, exist_ok=True)
def edit(path, apply):
    try:
        with open(path) as f: doc = json.load(f)
    except Exception:
        doc = {}
    if apply(doc):
        with open(path, "w") as f: json.dump(doc, f)
def prefs(doc):
    changed = False
    prof = doc.setdefault("profile", {})
    if prof.get("name") != name:
        prof["name"] = name; prof["using_default_name"] = False; changed = True
    session = doc.setdefault("session", {})
    if session.get("restore_on_startup") != 1:
        session["restore_on_startup"] = 1; changed = True
    # Third-party cookies on, explicitly: Apple's sign-in runs in an idmsa.apple.com
    # frame inside icloud.com, and a fresh profile takes whatever the build's default
    # is that week. 0 = "allow all", the setting a long-lived profile has.
    if prof.get("cookie_controls_mode") != 0:
        prof["cookie_controls_mode"] = 0; changed = True
    return changed
def state(doc):
    entry = doc.setdefault("profile", {}).setdefault("info_cache", {}).setdefault("Default", {})
    if entry.get("name") == name: return False
    entry["name"] = name; entry["is_using_default_name"] = False
    return True
edit(os.path.join(default, "Preferences"), prefs)
edit(os.path.join(profile, "Local State"), state)
PY
fi

for app in "Google Chrome" "Chromium" "Brave Browser" "Microsoft Edge"; do
    if [ -d "/Applications/$app.app" ]; then
        exec open -na "$app" --args --user-data-dir="$profile" --no-first-run --no-default-browser-check "$url"
    fi
done
# No Chromium-based browser: the default browser, shared profile (the old behaviour).
exec open "$url"
