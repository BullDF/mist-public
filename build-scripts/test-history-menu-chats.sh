#!/bin/bash
set -euo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
build="$(mktemp -d "${TMPDIR:-/tmp}/mist-history-menu-chats.XXXXXX")"
trap 'rm -rf "$build"' EXIT
xcrun swiftc -swift-version 5 -module-cache-path "$build/modules" \
  "$repo/Sources/Application/MistHistoryMenuChats.swift" \
  "$repo/Tests/HistoryMenuChats/main.swift" -o "$build/tests"
"$build/tests"
