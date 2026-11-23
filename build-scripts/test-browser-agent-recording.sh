#!/bin/bash
set -euo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
build="$(mktemp -d "${TMPDIR:-/tmp}/mist-browser-agent-recording.XXXXXX")"
trap 'rm -rf "${build:?}"' EXIT
xcrun swiftc -swift-version 5 -module-cache-path "$build/modules" \
    "$repo/Sources/States/BrowserAgentRecordingTimeline.swift" \
    "$repo/Tests/BrowserAgentRecording/main.swift" -o "$build/tests"
"$build/tests"
