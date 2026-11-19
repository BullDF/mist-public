#!/bin/bash
set -euo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
build="$(mktemp -d "${TMPDIR:-/tmp}/mist-mail-body.XXXXXX")"
trap 'rm -rf "${build:?}"' EXIT
xcrun swiftc -swift-version 5 -module-cache-path "$build/modules" \
  "$repo"/Sources/MistApps/Core/*.swift \
  "$repo/Sources/UserInterface/WebContent/Mail/MailBodyPreparation.swift" \
  "$repo/Tests/MailBody/main.swift" -o "$build/tests"
"$build/tests"
