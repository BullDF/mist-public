#!/bin/bash
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
task_build="$(mktemp -d "${TMPDIR:-/tmp}/mist-sync-e2e.XXXXXX")"
trap 'rm -rf "$task_build"' EXIT
xcrun swiftc -swift-version 5 -D MIST_SYNC_HOSTLESS_TESTS \
  -module-cache-path "$task_build/modules" \
  "$task_root"/Sources/MistSync/*.swift \
  "$task_root/Sources/PasswordManager/MistPasswordVault.swift" \
  "$task_root/Sources/PasswordManager/MistPasswordCSV.swift" \
  "$task_root/Sources/PasswordManager/MistPasswordSyncSource.swift" \
  "$task_root/Tests/MistSync/MistSyncTestSupport.swift" \
  "$task_root/Tests/MistSync/MistMemoryBrowserDataStore.swift" \
  "$task_root/Tests/MistSync/MistSyncE2ETests.swift" -o "$task_build/tests"
python3 "$task_root/build-scripts/mist-sync-e2e.py" "$task_build/tests"
