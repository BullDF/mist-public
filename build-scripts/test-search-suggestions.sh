#!/bin/bash
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
task_build="$(mktemp -d "${TMPDIR:-/tmp}/mist-search-suggestions.XXXXXX")"
trap 'rm -rf "$task_build"' EXIT
printf '%s\n' 'import XCTest' 'import Foundation' \
  'let suite = SearchSuggestionsTests.defaultTestSuite' 'suite.run()' \
  'guard let result = suite.testRun else { fatalError("XCTest did not run") }' \
  'exit(result.executionCount == 12 && result.totalFailureCount == 0 ? 0 : 1)' > "$task_build/main.swift"
task_frameworks="$(xcode-select -p)/Platforms/MacOSX.platform/Developer/Library/Frameworks"
task_libraries="$(xcode-select -p)/Platforms/MacOSX.platform/Developer/usr/lib"
xcrun swiftc -swift-version 5 -D SEARCH_SUGGESTIONS_HOSTLESS_TESTS \
  -F "$task_frameworks" -Xlinker -rpath -Xlinker "$task_frameworks" \
  -I "$task_libraries" -L "$task_libraries" -lXCTestSwiftSupport \
  -Xlinker -rpath -Xlinker "$task_libraries" \
  -module-cache-path "$task_build/modules" \
  "$task_root/Sources/Networking/SearchSuggestions.swift" \
  "$task_root/Tests/PhiBrowserTests/SearchSuggestionsTests.swift" \
  "$task_build/main.swift" -o "$task_build/tests"
"$task_build/tests" "$@"
