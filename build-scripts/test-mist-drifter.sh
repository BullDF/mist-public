#!/bin/bash
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
task_build="$(mktemp -d "${TMPDIR:-/tmp}/mist-browser-agent.XXXXXX")"
trap 'rm -rf "$task_build"' EXIT
printf '%s\n' 'import XCTest' 'import Foundation' \
  'let suite = BrowserAgentTests.defaultTestSuite' 'suite.run()' \
  'guard let result = suite.testRun else { fatalError("XCTest did not run") }' \
  'exit(result.executionCount >= 116 && result.totalFailureCount == 0 ? 0 : 1)' > "$task_build/main.swift"
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
  "$task_root/Sources/MistSlack/SlackMrkdwn.swift" \
  "$task_root"/Sources/MistAgents/ClaudeCode/*.swift \
  "$task_root"/Sources/MistAgents/Codex/*.swift \
  "$task_root"/Sources/MistAgents/BrowserAgent/*.swift \
  "$task_root"/Sources/MistAgents/Gemini/*.swift \
  "$task_root/Sources/Networking/APIClient.swift" \
  "$task_root/Sources/Networking/SearchSuggestions.swift" \
  "$task_root/Tests/MistGemini/HostlessLog.swift" \
  "$task_root/Sources/UserInterface/Common/Markdown/MarkdownRenderer.swift" \
  "$task_root/Sources/UserInterface/Common/Markdown/MarkdownMath.swift" \
  "$task_root/Tests/PhiBrowserTests/BrowserAgentTests.swift" \
  "$task_root/Tests/PhiBrowserTests/TestDefaults.swift" \
  "$task_build/main.swift" -o "$task_build/tests"
"$task_build/tests" "$@"
