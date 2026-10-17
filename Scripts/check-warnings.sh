#!/bin/zsh
# Builds every target and test target from scratch and fails on any compiler warning
# that is not on the short list below.
#
# Usage: Scripts/check-warnings.sh
#
# From scratch because an incremental build only re-reports the files it recompiles:
# a warm .build hides every warning in code that did not change. The scratch folder
# lives under .build/ (git-ignored) and is emptied first.
set -uo pipefail
cd "$(dirname "$0")/.."

# Each entry is an extended regex matched against "<file>:<line>:<col>: warning: <text>".
# Keep it short, and say why next to each one.
allowed=(
    # The process-wide Keychain dialog switch: one function, see
    # KeychainCredentialsReader.keychainInteraction.
    "Sources/GroveCore/Services/ClaudeCredentials\.swift:[0-9]+:[0-9]+: warning: 'SecKeychain(Get|Set)UserInteractionAllowed' was deprecated"
)

SCRATCH=.build/check-warnings
rm -rf "$SCRATCH"
log=$(swift build --build-tests --scratch-path "$SCRATCH" 2>&1)
build_status=$?
if (( build_status != 0 )); then
    echo "$log" | tail -40
    echo "check-warnings: the build failed" >&2
    exit $build_status
fi

warnings=$(echo "$log" | sed 's/\x1b\[[0-9;]*m//g' | command grep -E '^/.*: warning: ' | sed "s#^$PWD/##" | sort -u)
unexpected=$warnings
for pattern in "${allowed[@]}"; do
    unexpected=$(echo "$unexpected" | command grep -vE "$pattern")
done
unexpected=$(echo "$unexpected" | sed '/^$/d')

allowed_count=$(( $(echo "$warnings" | sed '/^$/d' | wc -l) - $(echo "$unexpected" | sed '/^$/d' | wc -l) ))
if [[ -n "$unexpected" ]]; then
    echo "check-warnings: new compiler warnings:" >&2
    echo "$unexpected" | cut -c1-300 >&2
    exit 1
fi
echo "check-warnings: no new warnings ($allowed_count allowed)"
