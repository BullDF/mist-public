#!/bin/bash
set -euo pipefail
if [[ "${MIST_LIVE_GEMINI:-}" != 1 ]]; then
  printf '%s\n' 'Set MIST_LIVE_GEMINI=1 to run the live Gemini ACP check.'
  exit 0
fi
if [[ -z "${GEMINI_API_KEY:-}" ]]; then
  printf '%s\n' 'Export GEMINI_API_KEY before running the live Gemini ACP check.'
  exit 1
fi
task_root="$(cd "$(dirname "$0")/.." && pwd)"
task_build="$(mktemp -d "${TMPDIR:-/tmp}/mist-gemini-live.XXXXXX")"
trap 'rm -rf "$task_build"' EXIT
mkdir "$task_build/workspace"
"$task_root/build-scripts/compile-mist-gemini-harness.sh" "$task_build" "$task_root/Tests/MistGemini/live.swift" "$task_build/live"
"$task_build/live" "$task_build/workspace" "$task_root/Tests/MistGemini" "$task_root/Resources/gemini-preload.mjs"
