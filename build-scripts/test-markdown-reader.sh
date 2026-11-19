#!/bin/bash
set -euo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
build="$(mktemp -d "${TMPDIR:-/tmp}/mist-markdown-reader.XXXXXX")"
trap 'rm -rf "${build:?}"' EXIT
xcrun swiftc -swift-version 5 -module-cache-path "$build/modules" \
  "$repo/Sources/MarkdownReader/MarkdownDocumentRoute.swift" \
  "$repo/Sources/MarkdownReader/MarkdownFileWatcher.swift" \
  "$repo/Sources/MarkdownReader/MarkdownReaderZoom.swift" \
  "$repo/Sources/Utilities/TextFind.swift" \
  "$repo/Tests/MarkdownReader/main.swift" -o "$build/tests"
"$build/tests"
