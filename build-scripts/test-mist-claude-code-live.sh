#!/bin/bash
set -euo pipefail
if [ "${MIST_LIVE_CLAUDE:-0}" != 1 ]; then
  echo 'SKIP Claude Code live smoke test (set MIST_LIVE_CLAUDE=1)'
  exit 0
fi
task_root="$(cd "$(dirname "$0")/.." && pwd)"
task_build="$(mktemp -d "${TMPDIR:-/tmp}/mist-claude-live-build.XXXXXX")"
trap 'rm -rf "$task_build"' EXIT
"$task_root/build-scripts/compile-mist-gemini-harness.sh" "$task_build" "$task_root/build-scripts/claude-code-live.swift" "$task_build/smoke"
cd "$task_build"
"$task_build/smoke"
