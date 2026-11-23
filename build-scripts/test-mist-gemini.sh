#!/bin/bash
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
task_build="$(mktemp -d "${TMPDIR:-/tmp}/mist-gemini-tests.XXXXXX")"
trap 'rm -rf "$task_build"' EXIT
task_frameworks="$(xcode-select -p)/Platforms/MacOSX.platform/Developer/Library/Frameworks"
task_libraries="$(xcode-select -p)/Platforms/MacOSX.platform/Developer/usr/lib"
"$task_root/build-scripts/compile-mist-gemini-harness.sh" "$task_build" "$task_root/Tests/MistGemini/GeminiTests.swift" "$task_build/tests" \
    -F "$task_frameworks" -Xlinker -rpath -Xlinker "$task_frameworks" \
    -I "$task_libraries" -L "$task_libraries" -lXCTestSwiftSupport -Xlinker -rpath -Xlinker "$task_libraries"
"$task_build/tests" "$task_root/Tests/MistGemini"
