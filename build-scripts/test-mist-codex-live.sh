#!/bin/bash
set -euo pipefail
if [ "${MIST_LIVE_CODEX:-0}" != 1 ]; then
  echo 'SKIP Codex live smoke test (set MIST_LIVE_CODEX=1)'
  exit 0
fi
task_root="$(cd "$(dirname "$0")/.." && pwd)"
task_build="$(mktemp -d "${TMPDIR:-/tmp}/mist-codex-live.XXXXXX")"
trap 'rm -rf "$task_build"' EXIT
xcrun swiftc -swift-version 5 -parse-as-library \
  -module-cache-path "$task_build/modules" \
  "$task_root"/Sources/MistApps/Core/*.swift \
  "$task_root/Sources/MistAgents/Chat/AgentChatItem.swift" \
  "$task_root/Sources/MistAgents/Chat/AgentTabMention.swift" \
  "$task_root/Sources/MistAgents/Chat/AgentConversation.swift" \
  "$task_root/Sources/MistAgents/Chat/AgentChatMarkers.swift" \
  "$task_root/Sources/MistAgents/Chat/AgentCodeBlocks.swift" \
  "$task_root/Sources/MistAgents/Chat/AgentMessageQueue.swift" \
  "$task_root/Sources/MistAgents/Chat/AgentChatSession.swift" \
  "$task_root/Sources/MistAgents/Chat/AgentAttachment.swift" \
  "$task_root/Sources/MistAgents/Chat/AgentChatStrings.swift" \
  "$task_root/Sources/MistSlack/SlackMrkdwn.swift" \
  "$task_root/Sources/MistAgents/Chat/AgentChatDisplayRow.swift" \
  "$task_root/Sources/MistAgents/Chat/AgentMemoryFiles.swift" \
  "$task_root/Sources/MistAgents/ClaudeCode/ClaudeCodeToolSummary.swift" \
  "$task_root/Sources/MistAgents/ClaudeCode/ClaudeCodeLaunchConfig.swift" \
  "$task_root/Sources/MistAgents/ClaudeCode/ClaudeCodeProtocol.swift" \
  "$task_root/Sources/MistAgents/ClaudeCode/ClaudeCodeEnvironment.swift" \
  "$task_root/Sources/MistAgents/ClaudeCode/ClaudeCodeProcess.swift" \
  "$task_root"/Sources/MistAgents/Codex/*.swift \
  "$task_root/build-scripts/codex-live.swift" -o "$task_build/smoke"
cd "$task_build"
"$task_build/smoke" "$task_root/build-scripts/codex-dummy-mcp.js"
