#!/bin/bash
set -euo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
build="$(mktemp -d "${TMPDIR:-/tmp}/mist-agent-chat-link.XXXXXX")"
trap 'rm -rf "${build:?}"' EXIT
xcrun swiftc -swift-version 5 -module-cache-path "$build/modules" \
  "$repo/Sources/MistAgents/Chat/AgentChatLink.swift" \
  "$repo/Tests/AgentChatLink/main.swift" -o "$build/tests"
"$build/tests"
