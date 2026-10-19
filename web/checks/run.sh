#!/bin/zsh
# Webappens checks: bygger facit med Swift (Sources/VinylCore) og sammenligner med JavaScript-udgaven
# i JavaScriptCore (samme motor som Safari på iPhone). Kræver macOS. Bruges også af GitHub Actions.
set -euo pipefail
ROOT=${0:A:h:h:h}
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
JSC=/System/Library/Frameworks/JavaScriptCore.framework/Versions/A/Helpers/jsc
xcrun swiftc -O -module-name VinylCore -suppress-warnings -o "$TMP/dump" "$ROOT"/Sources/VinylCore/*.swift "$ROOT/web/checks/dump/main.swift" -lsqlite3
"$TMP/dump" "$TMP/facit.json"
"$JSC" -m "$ROOT/web/checks/checks.mjs" -- "$TMP/facit.json"
