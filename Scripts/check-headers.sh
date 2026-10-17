#!/bin/zsh
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 Artem Efimov

# Fails when a tracked .swift, .sh or .py file does not carry the licence header in
# its first lines:
#
#   // SPDX-License-Identifier: GPL-3.0-only        (# in shell and Python)
#   // Copyright (C) 2026 Artem Efimov
#
# The header comes first, after a shebang or Package.swift's swift-tools-version line
# where a file has one. LICENSE itself stays the verbatim GPL v3 text.
#
# Usage: Scripts/check-headers.sh
set -uo pipefail
cd "$(dirname "$0")/.."

SPDX='SPDX-License-Identifier: GPL-3.0-only'
COPYRIGHT='Copyright (C) 2026 Artem Efimov'

missing=()
while IFS= read -r file; do
    first=$(head -4 "$file")
    if ! print -r -- "$first" | command grep -qE "^(//|#) $SPDX\$" \
        || ! print -r -- "$first" | command grep -qF "$COPYRIGHT"; then
        missing+=("$file")
    fi
done < <(git ls-files '*.swift' '*.sh' '*.py')

if (( ${#missing[@]} )); then
    echo "check-headers: ${#missing[@]} file(s) without the licence header:" >&2
    printf '  %s\n' "${missing[@]}" >&2
    exit 1
fi
echo "check-headers: every source file has the licence header"
