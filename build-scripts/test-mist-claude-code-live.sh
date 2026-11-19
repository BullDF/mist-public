#!/bin/bash
set -euo pipefail
if [ "${MIST_LIVE_CLAUDE:-0}" != 1 ]; then
  echo 'SKIP Claude Code live smoke test (set MIST_LIVE_CLAUDE=1)'
  exit 0
fi
task_root="$(cd "$(dirname "$0")/.." && pwd)"
task_build="$(mktemp -d "${TMPDIR:-/tmp}/mist-claude-live-build.XXXXXX")"
trap 'rm -rf "$task_build"' EXIT
xcrun swiftc -swift-version 5 -parse-as-library -D MIST_CLAUDE_CODE_HOSTLESS_TESTS \
  -module-cache-path "$task_build/modules" \
  "$task_root"/Sources/MistApps/Core/*.swift \
  "$task_root"/Sources/MistAgents/Chat/*.swift \
  "$task_root/Sources/Utilities/TextFind.swift" \
  "$task_root"/Sources/MistAgents/ClaudeCode/*.swift \
  "$task_root"/Sources/MistAgents/Codex/*.swift \
  "$task_root"/Sources/MistAgents/BrowserAgent/*.swift \
  "$task_root/build-scripts/claude-code-live.swift" -o "$task_build/smoke"
cd "$task_build"
"$task_build/smoke"
