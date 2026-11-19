#!/bin/bash
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
node "$task_root/tools/phi-browser-skill/scripts/selftest-challenge.mjs"
