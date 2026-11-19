#!/bin/bash
set -euo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
build="$(mktemp -d "${TMPDIR:-/tmp}/mist-removed-menu-items.XXXXXX")"
trap 'rm -rf "$build"' EXIT
xcrun swiftc -swift-version 5 -module-cache-path "$build/modules" \
  "$repo/Sources/Application/MistRemovedMenuItems.swift" \
  "$repo/Tests/RemovedMenuItems/main.swift" -o "$build/tests"
"$build/tests"
