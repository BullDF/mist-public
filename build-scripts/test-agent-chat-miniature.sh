#!/bin/bash
set -euo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
build="$(mktemp -d "${TMPDIR:-/tmp}/mist-agent-chat-miniature.XXXXXX")"
trap 'rm -rf "${build:?}"' EXIT
xcrun swiftc -swift-version 5 -module-cache-path "$build/modules" \
  "$repo/Sources/UserInterface/WebContent/AgentChat/AgentChatMiniaturePlan.swift" \
  "$repo/Tests/AgentChatMiniature/main.swift" -o "$build/tests"
"$build/tests"
