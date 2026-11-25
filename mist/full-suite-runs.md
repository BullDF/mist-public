# Full test suite runs

A full hosted run is `mist/scripts/test.sh -only-testing:PhiBrowserTests`. Append one row per full run, newest last. Targeted runs don't go here.

The 83 inherited failures tracked in BullDF/mist#3 were removed in the commit "Remove inherited hosted tests that fail in the OSS build". There is no expected-failure baseline anymore: any full-suite failure is a regression and gets its own line under Notes.

| Date | Commit | Mac | macOS / Xcode | Passed | Failed | Skipped | Time | Notes |
|---|---|---|---|---|---|---|---|---|
| 2026-10-23 | `78da0ae2` | MacBook | 27.0.1 / 27.1 | 4,756 | 83 | 1 | 7m51s | First isolated run (`com.bulldf.mist.tests`, English/US). All 83 failures also fail on upstream `e7e62b93` and became the baseline in BullDF/mist#3: 47 sync, 26 OSS AI, 8 Keychain entitlement, 2 fixtures. |
| 2026-11-01 | `2f08e048` | MacBook | 27.0.1 / 27.1 | 2,860 | 0 | 1 | 5m03s | No failures. `PhiAlertTests.testAppKitBridgePresentsConfiguredAlertAndReturnsResponse` passes in the full run but fails when its class runs alone (BullDF/mist#55). |
| 2026-11-24 | `12c3e7c0` | MacBook | 27.2.1 / 27.1 | 3,208 | 3 | 1 | 5m39s | `ContentSurfaceHostingTests.testPreviewStackKeepsEveryCardTheSameSize` also failed alone: it still asserted the 400 pt card width that `74d8939a` narrowed to 381 pt; fixed in the commit after this run. `BrowserStateBookmarkLayoutTests.testChangingSplitBookmarkLayoutUpdatesRuntimeAndStore` (bookmark missing after the layout change) and `ShortcutMenuRebuildIntegrationTests.testShortcutChangesRebindDynamicMenusAndKeepReceivingTabUpdates` (Tab menu never got `ShortcutMenuFirst`) fail only in the full run and pass when their classes run alone. |
| 2026-11-24 | `7c3df2aa` | MacBook | 27.2.1 / 27.1 | 3,210 | 1 | 1 | 6m02s | Bookmark failure fixed by `7c3df2aa` (LocalStore publishers subscribed to saves after their first fetch). Run with temporary diagnostics in the shortcut test: it failed again, and its `data:` tab never got a title even after 36 s. |
| 2026-11-24 | `7c3df2aa` | MacBook | 27.2.1 / 27.1 | 3,211 | 0 | 1 | 5m45s | No failures (same diagnostics). The shortcut failure is intermittent: 2 of 3 full runs today. |
| 2026-11-24 | `db39c670` | MacBook | 27.2.1 / 27.1 | 3,211 | 0 | 1 | 5m20s | 20 consecutive runs with temporary diagnostics in the shortcut test, all without failures. The intermittent shortcut failure (BullDF/mist#89, the agent browser's `data:` page never loading) did not recur and the issue is closed. |
