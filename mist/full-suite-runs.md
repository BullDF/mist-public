# Full test suite runs

A full hosted run is `mist/scripts/test.sh -only-testing:PhiBrowserTests`. Append one row per full run, newest last. Targeted runs don't go here.

The 83 inherited failures tracked in BullDF/mist#3 were removed in the commit "Remove inherited hosted tests that fail in the OSS build". There is no expected-failure baseline anymore: any full-suite failure is a regression and gets its own line under Notes.

| Date | Commit | Mac | macOS / Xcode | Passed | Failed | Skipped | Time | Notes |
|---|---|---|---|---|---|---|---|---|
| 2026-10-23 | `78da0ae2` | MacBook | 27.0.1 / 27.1 | 4,756 | 83 | 1 | 7m51s | First isolated run (`com.bulldf.mist.tests`, English/US). All 83 failures also fail on upstream `e7e62b93` and became the baseline in BullDF/mist#3: 47 sync, 26 OSS AI, 8 Keychain entitlement, 2 fixtures. |
| 2026-11-01 | `2f08e048` | MacBook | 27.0.1 / 27.1 | 2,860 | 0 | 1 | 5m03s | No failures. `PhiAlertTests.testAppKitBridgePresentsConfiguredAlertAndReturnsResponse` passes in the full run but fails when its class runs alone (BullDF/mist#55). |
