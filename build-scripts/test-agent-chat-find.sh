#!/bin/bash
set -euo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
build="$(mktemp -d "${TMPDIR:-/tmp}/mist-agent-chat-find.XXXXXX")"
trap 'rm -rf "${build:?}"' EXIT
xcrun swiftc -swift-version 5 -module-cache-path "$build/modules" \
  "$repo/Sources/Utilities/TextFind.swift" \
  "$repo/Sources/MistAgents/Chat/AgentChatFindMatches.swift" \
  "$repo/Tests/AgentChatFind/main.swift" -o "$build/tests"
"$build/tests"
