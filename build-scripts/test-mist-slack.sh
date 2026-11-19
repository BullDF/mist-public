#!/bin/bash
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
task_build="$(mktemp -d "${TMPDIR:-/tmp}/mist-slack.XXXXXX")"
trap 'rm -rf "${task_build:?}"' EXIT
xcrun swiftc -swift-version 5 -module-cache-path "$task_build/modules" \
  "$task_root/Sources/MistSlack/SlackMrkdwn.swift" \
  "$task_root/Tests/MistSlack/SlackMrkdwnTests.swift" \
  "$task_root/Sources/MistSlack/SlackTokens.swift" \
  "$task_root/Sources/MistSlack/SlackEvents.swift" \
  "$task_root/Sources/MistSlack/SlackThreadStore.swift" \
  "$task_root/Sources/MistSlack/SlackSocketMode.swift" \
  "$task_root/Sources/MistSlack/SlackAgentConnection.swift" \
  "$task_root/Tests/MistSlack/SlackEventTests.swift" \
  "$task_root/Tests/MistSlack/SlackSocketTests.swift" \
  "$task_root/Tests/MistSlack/SlackConnectionTests.swift" \
  "$task_root/Tests/MistSlack/SlackDisplayNameTests.swift" \
  "$task_root/Sources/MistSlack/SlackWebAPI.swift" \
  "$task_root/Sources/MistSlack/SlackMCPClient.swift" \
  "$task_root/Sources/MistSlack/SlackDirectory.swift" \
  "$task_root/Sources/MistSlack/MistSlackService.swift" \
  "$task_root/Tests/MistSlack/SlackMCPTests.swift" \
  "$task_root/Tests/MistSlack/SlackDirectoryTests.swift" \
  "$task_root/Tests/MistSlack/MistSlackTests.swift" -o "$task_build/tests"
"$task_build/tests"
