#!/bin/bash
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
task_build="$(mktemp -d "${TMPDIR:-/tmp}/mist-claude-code.XXXXXX")"
trap 'rm -rf "$task_build"' EXIT
printf '%s\n' 'import XCTest' 'import Foundation' \
  'let suite = XCTestSuite(name: "Claude Code")' \
  'suite.addTest(ClaudeCodeLaunchTests.defaultTestSuite)' \
  'suite.addTest(ClaudeCodeRemoteControlArchiveTests.defaultTestSuite)' \
  'suite.addTest(ClaudeCodeModelCatalogTests.defaultTestSuite)' \
  'suite.addTest(ClaudeCodeSlashCommandTests.defaultTestSuite)' \
  'suite.addTest(ClaudeCodeEngineTests.defaultTestSuite)' \
  'suite.addTest(AgentMessageQueueTests.defaultTestSuite)' \
  'suite.addTest(ClaudeCodeQueueTests.defaultTestSuite)' \
  'suite.addTest(ClaudeCodeToolSummaryTests.defaultTestSuite)' \
  'suite.addTest(ClaudeCodeSessionSettingsTests.defaultTestSuite)' \
  'suite.addTest(AgentChatStoreTests.defaultTestSuite)' \
  'suite.addTest(AgentChatMarkersTests.defaultTestSuite)' \
  'suite.addTest(SlackAgentBridgeTests.defaultTestSuite)' \
  'suite.addTest(SlackModelPrefixTests.defaultTestSuite)' \
  'suite.addTest(AgentChatHistoryTests.defaultTestSuite)' \
  'suite.addTest(DrifterHomeListTests.defaultTestSuite)' \
  'suite.addTest(AgentSidebarStatusTests.defaultTestSuite)' \
  'suite.addTest(AgentChatDisplayRowTests.defaultTestSuite)' \
  'suite.addTest(AgentCodeBlocksTests.defaultTestSuite)' \
  'suite.addTest(MarkdownRendererTests.defaultTestSuite)' 'suite.run()' \
  'guard let result = suite.testRun else { fatalError("XCTest did not run") }' \
  'exit(result.executionCount >= 200 && result.totalFailureCount == 0 ? 0 : 1)' > "$task_build/main.swift"
task_frameworks="$(xcode-select -p)/Platforms/MacOSX.platform/Developer/Library/Frameworks"
task_libraries="$(xcode-select -p)/Platforms/MacOSX.platform/Developer/usr/lib"
xcrun swiftc -swift-version 5 -D MIST_CLAUDE_CODE_HOSTLESS_TESTS -D MIST_MARKDOWN_HOSTLESS_TESTS \
  -framework AppKit \
  -F "$task_frameworks" -Xlinker -rpath -Xlinker "$task_frameworks" \
  -I "$task_libraries" -L "$task_libraries" -lXCTestSwiftSupport \
  -Xlinker -rpath -Xlinker "$task_libraries" \
  -module-cache-path "$task_build/modules" \
  "$task_root"/Sources/MistApps/Core/*.swift \
  "$task_root"/Sources/MistAgents/Chat/*.swift \
  "$task_root/Sources/Utilities/TextFind.swift" \
  "$task_root"/Sources/MistAgents/ClaudeCode/*.swift \
  "$task_root"/Sources/MistAgents/Codex/*.swift \
  "$task_root"/Sources/MistAgents/BrowserAgent/*.swift \
  "$task_root"/Sources/MistAgents/Gemini/*.swift \
  "$task_root/Sources/Networking/APIClient.swift" \
  "$task_root/Sources/Networking/SearchSuggestions.swift" \
  "$task_root/Tests/MistGemini/HostlessLog.swift" \
  "$task_root/Sources/UserInterface/Common/Markdown/MarkdownRenderer.swift" \
  "$task_root/Sources/UserInterface/Common/Markdown/MarkdownMath.swift" \
  "$task_root/Tests/PhiBrowserTests/MarkdownRendererTests.swift" \
  "$task_root/Tests/PhiBrowserTests/ClaudeCodeLaunchTests.swift" \
  "$task_root/Tests/PhiBrowserTests/ClaudeCodeRemoteControlArchiveTests.swift" \
  "$task_root/Tests/PhiBrowserTests/ClaudeCodeModelCatalogTests.swift" \
  "$task_root/Tests/PhiBrowserTests/ClaudeCodeSlashCommandTests.swift" \
  "$task_root/Tests/PhiBrowserTests/ClaudeCodeEngineTests.swift" \
  "$task_root/Tests/PhiBrowserTests/AgentMessageQueueTests.swift" \
  "$task_root/Tests/PhiBrowserTests/ClaudeCodeQueueTests.swift" \
  "$task_root/Tests/PhiBrowserTests/ClaudeCodeToolSummaryTests.swift" \
  "$task_root/Tests/PhiBrowserTests/ClaudeCodeSessionSettingsTests.swift" \
  "$task_root/Tests/PhiBrowserTests/AgentChatStoreTests.swift" \
  "$task_root/Tests/PhiBrowserTests/AgentChatMarkersTests.swift" \
  "$task_root/Tests/PhiBrowserTests/SlackAgentBridgeTests.swift" \
  "$task_root/Tests/PhiBrowserTests/SlackModelPrefixTests.swift" \
  "$task_root/Sources/MistSlack/SlackModelPrefix.swift" \
  "$task_root/Sources/MistSlack/SlackEvents.swift" \
  "$task_root/Sources/MistSlack/SlackThreadStore.swift" \
  "$task_root/Sources/MistSlack/SlackMrkdwn.swift" \
  "$task_root/Sources/MistSlack/SlackAgentStrings.swift" \
  "$task_root/Sources/MistSlack/SlackAgentBridge.swift" \
  "$task_root/Sources/MistSlack/SlackAgentCards.swift" \
  "$task_root/Sources/MistSlack/SlackWebAPI.swift" \
  "$task_root/Tests/PhiBrowserTests/AgentChatHistoryTests.swift" \
  "$task_root/Tests/PhiBrowserTests/DrifterHomeListTests.swift" \
  "$task_root/Tests/PhiBrowserTests/AgentSidebarStatusTests.swift" \
  "$task_root/Tests/PhiBrowserTests/AgentChatDisplayRowTests.swift" \
  "$task_root/Tests/PhiBrowserTests/AgentCodeBlocksTests.swift" \
  "$task_root/Tests/PhiBrowserTests/TestDefaults.swift" \
  "$task_build/main.swift" -o "$task_build/tests"
"$task_build/tests" "$@"
