#!/bin/bash
set -euo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
build="$(mktemp -d "${TMPDIR:-/tmp}/mist-tab-window-move-menu.XXXXXX")"
trap 'rm -rf "$build"' EXIT
xcrun swiftc -swift-version 5 -module-cache-path "$build/modules" \
  "$repo/Sources/UserInterface/Common/Tabs/TabWindowMoveMenu.swift" \
  "$repo/Tests/TabWindowMoveMenu/main.swift" -o "$build/tests"
"$build/tests"
