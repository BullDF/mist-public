#!/bin/bash
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
task_build="$(mktemp -d "${TMPDIR:-/tmp}/mist-codex-tests.XXXXXX")"
trap 'rm -rf "$task_build"' EXIT
printf '%s\n' 'import XCTest' 'import Foundation' \
  'let suite = XCTestSuite(name: "Codex")' \
  'suite.addTest(CodexLaunchTests.defaultTestSuite)' \
  'suite.addTest(CodexTranscriptTests.defaultTestSuite)' \
  'suite.addTest(CodexQueueTests.defaultTestSuite)' \
  'suite.addTest(CodexServerRequestTests.defaultTestSuite)' \
  'suite.addTest(CodexModelCatalogTests.defaultTestSuite)' \
  'suite.addTest(CodexProcessTests.defaultTestSuite)' \
  'suite.run()' \
  'guard let result = suite.testRun else { fatalError("XCTest did not run") }' \
  'exit(result.executionCount >= 40 && result.totalFailureCount == 0 ? 0 : 1)' > "$task_build/main.swift"
task_frameworks="$(xcode-select -p)/Platforms/MacOSX.platform/Developer/Library/Frameworks"
task_libraries="$(xcode-select -p)/Platforms/MacOSX.platform/Developer/usr/lib"
xcrun swiftc -swift-version 5 -D MIST_CODEX_HOSTLESS_TESTS \
  -F "$task_frameworks" -Xlinker -rpath -Xlinker "$task_frameworks" \
  -I "$task_libraries" -L "$task_libraries" -lXCTestSwiftSupport \
  -Xlinker -rpath -Xlinker "$task_libraries" \
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
  "$task_root"/Tests/PhiBrowserTests/Codex*.swift \
  "$task_build/main.swift" -o "$task_build/tests"
"$task_build/tests" "$@"
