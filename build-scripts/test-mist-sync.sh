#!/bin/bash
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
task_build="$(mktemp -d "${TMPDIR:-/tmp}/mist-sync.XXXXXX")"
trap 'rm -rf "$task_build"' EXIT
xcrun swiftc -swift-version 5 -D MIST_SYNC_HOSTLESS_TESTS \
  -module-cache-path "$task_build/modules" \
  "$task_root"/Sources/MistSync/*.swift \
  "$task_root/Sources/PasswordManager/MistPasswordVault.swift" \
  "$task_root/Sources/PasswordManager/MistPasswordCSV.swift" \
  "$task_root/Sources/PasswordManager/MistPasswordSyncSource.swift" \
  "$task_root/Tests/MistSync/MistPasswordSyncTests.swift" \
  "$task_root/Tests/MistSync/MistMailAccountSyncTests.swift" \
  "$task_root/Tests/MistSync/MistClipboardSyncTests.swift" \
  "$task_root/Tests/MistSync/MistClipboardPasteboardTests.swift" \
  "$task_root/Tests/MistSync/MistMemoryBrowserDataStore.swift" \
  "$task_root/Tests/MistSync/MistBrowserDataSyncTests.swift" \
  "$task_root/Tests/MistSync/MistSyncTestSupport.swift" \
  "$task_root/Tests/MistSync/MistSyncTests.swift" -o "$task_build/tests"
"$task_build/tests"
