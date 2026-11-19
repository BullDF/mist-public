#!/bin/bash
set -euo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
build="$(mktemp -d "${TMPDIR:-/tmp}/mist-apps.XXXXXX")"
trap 'rm -rf "${build:?}"' EXIT
xcrun swiftc -swift-version 5 -module-cache-path "$build/modules" \
  "$repo"/Sources/MistApps/Core/*.swift "$repo/Tests/MistApps/main.swift" -o "$build/tests"
"$build/tests" "$repo"
