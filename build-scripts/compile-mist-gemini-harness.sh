#!/bin/bash
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
task_build="$1"
task_source="$2"
task_executable="$3"
shift 3
xcrun swiftc -swift-version 5 -D MIST_CLAUDE_CODE_HOSTLESS_TESTS -D MIST_MARKDOWN_HOSTLESS_TESTS \
  "$@" \
  -module-cache-path "$task_build/modules" \
  "$task_root"/Sources/MistApps/Core/*.swift \
  "$task_root"/Sources/MistAgents/Chat/*.swift \
  "$task_root"/Sources/MistAgents/ClaudeCode/*.swift \
  "$task_root"/Sources/MistAgents/Codex/*.swift \
  "$task_root"/Sources/MistAgents/BrowserAgent/*.swift \
  "$task_root"/Sources/MistAgents/Gemini/*.swift \
  "$task_root/Sources/MistSlack/SlackMrkdwn.swift" \
  "$task_root/Sources/Networking/APIClient.swift" \
  "$task_root/Sources/Networking/SearchSuggestions.swift" \
  "$task_root/Sources/Utilities/TextFind.swift" \
  "$task_root/Sources/UserInterface/Common/Markdown/MarkdownRenderer.swift" \
  "$task_root/Sources/UserInterface/Common/Markdown/MarkdownMath.swift" \
  "$task_root/Tests/MistGemini/HostlessLog.swift" \
  "$task_source" -o "$task_executable"
