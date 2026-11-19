# Space window close behavior

Defines what happens when a Space's NSWindow closes, depending on how the close was triggered. Owner: `SpaceWindowSlot.unregisterWindow(for:)` in `SpaceManager.swift`. Every Chromium-side `[NSWindow close]` and AppKit-side `performClose:` funnels into `windowWillClose` → `unregisterWindow`, so this is the single decision point. In hosted-window mode (below) the window whose close is observed is the session's `lifecycleWindow` — its hidden Chromium window — never the shared shell.

## The shell window

Every Space session is hosted: a slot owns one visible `ShellWindow` (`ShellWindowController.swift`) and Chromium never shows a browser window. The shell owns the window's one split (`ShellSplitViewController.swift`: the sidebar column with its vibrancy backdrop, width and collapsed state | the page area), so the sidebar reads as one sidebar across Space switches; each Space's `SpaceSessionController` keeps its sidebar content (`SidebarViewController.view`, painting no backdrop) *resident* in the column — added once it has a shell, hidden unless presented, sized with the column — and keeps its page tree (`MainSplitViewController.view`, which builds no split of its own when hosted) resident and hidden in the page area. A switch reuses these attachments: the vertical-layout switch shows the entering session's resident content with only its band visible and slides that band in while the leaving band slides out (`HostedBandSlide`), the entering page cross-fades on the same animation clock, and the Chromium round trips (`setPresented:`, the Browser spawn of a dormant Space) run one turn after the first frame. The session's Chromium NSWindow only carries the Browser's lifecycle and mirrors the shell's frame; the shell takes the presented session's title from it (its active tab's), since the Dock menu, the Window menu and Mission Control list the shell, and shows the Space name instead while the session has no Browser yet or is on the placeholder page (`SpaceWindowSlot.retitleShell`). The close model maps onto the legacy one as follows; `unregisterWindow` still classifies, then hands off to `unregisterHostedSession`.

- **Window-driven close of the shell** (red ✕, ⇧⌘W on the shell): `ShellWindowController.windowShouldClose` → `slot.shellRequestedClose()`, which starts the same cascade a window-driven close does — `IDC_CLOSE_WINDOW` for every session through Chromium — and refuses the AppKit close. The shell is closed by `removeSlot` → `closeShellIfPresent` once the last session has unregistered, or kept (with the survivor re-presented by the cascade-veto recovery) when a `beforeunload` prompt vetoes.
- **A session's Chromium window closing** (tab-row ✕ on the last home page, `window.close()`, an Incognito Space reap, a Space deleted): `windowWillClose` on the hidden window → `unregisterWindow` → `unregisterHostedSession`. Presented + tab-driven with a sibling that has tabs → `activate(sibling)`. Presented otherwise → cascade the rest, as above. A background session → dropped from the map with no side effects (it was never on screen). When the map empties, `removeSlot` closes the shell.
- **The shell closing with no live session left** (a vetoed cascade whose survivor then closed on its own, a presented dormant session whose spawn never landed): `shellDidClose` removes the slot itself, so a windowless slot never lingers in the registry.
- **Dormant sessions** (`dormantSessionsBySpaceId`, built ahead of their Browser under a reserved window id) have no Chromium window and never reach `unregisterWindow`; `discardDormant` retires them when their Space leaves the slot or the slot closes.

Retiring a Space's window from code must go through `SpaceSessionController.closeChromiumWindow()`, never `window?.close()`: in hosted mode `window` is the shell, and closing it would tear the whole slot down.

## What leaves the shell with a Space

A Space's page tree and sidebar content stay resident in the shell, hidden,
between its turns. Three things belong to a Space but do not live in its
tree, and each is handled at the moment the Space withdraws
(`SpaceSessionController.removeSessionViewFromShell`):

- A page in HTML fullscreen sits under the shell's content view, above
  every Space. The withdrawing session puts it back under its tree first
  (`WebContentContainerViewController.collapseContentFullscreenForConcealment`),
  and Chromium's `UnpresentHostedBrowser` leaves tab fullscreen with the
  Space, as a tab switch does in a real window. The leaving Space is a
  background session for `sessionRequestedShellFullscreen` from the moment
  `concealFromShell` runs, whether or not the slot has moved
  `visibleController` on yet, and the shell keeps its fullscreen state for
  the Space replacing it, with one exception: when the leaving Space's
  request put the shell into fullscreen (`shellFullscreenOwner`), Chromium
  asks for the window to leave fullscreen with the tab, and the shell does,
  as a real window does. Fullscreen the user entered through AppKit — the
  green button, or View › Enter Full Screen and its ⌃⌘F, which send
  AppKit's `toggleFullScreen:` rather than Chromium's fullscreen command and
  reach the slot as `shellFullScreenWillChange`, not as a request — has no
  owner and stays. A browser fullscreen Chromium requests for a Space (an
  extension or agent changing the window's state, through
  `windowRequestedFullscreen:`) belongs to that Space, but no tab brought
  it, so it stays too when the Space leaves.
  The slot's restore record leaves out a fullscreen whose owner's page is
  still in it (`snapshotIsFullScreen`), so quitting from a video in
  fullscreen reopens windowed.
- A crash page reloads and opens help through its own session
  (`BrowserState.windowController`), never through the shell's window
  controller, which is whichever Space is presented.
- Anything that needs the window the user sees — the Dock's reopen, an
  agent's whole-window capture — maps a hosted Browser to the shell
  presenting it (`GetBrowserWindows` in the app controller) or composes the
  Space's resident trees in the shell's layout
  (`AgentSpaceRouter.renderWindow`), because the Browser's own NSWindow is
  never shown and a hidden tree draws nothing into a bitmap.

## Sidebar geometry ownership

`ShellSplitViewController` owns the sidebar's width and collapsed state through
its `NSSplitViewItem`. Space sessions have no stored copy of either value.
`BrowserState.sidebarCollapsed` and `sidebarWidth` are read-only projections of
the owning split; their publishers observe that split even while the session is
dormant or concealed. Sidebar commands mutate the owning split directly.
Creating, attaching, presenting, or switching sessions never applies sidebar
geometry. Spawn contexts carry frame placement only. Standalone Incognito
windows use their own `MainSplitViewController` split.

Every Space's strip in the window reads its sliding viewport from the slot
(`SpaceWindowSlot.stripViewportStart`), every strip computes it at the row
width last measured on screen (`SpaceWindowSlot.stripViewportWidth`) so a
hidden strip's own layout width can't move it, and only the strip on screen — the
leaving Space's, during the band slide — animates a switch; the others snap
(`SpacesStripPresence`), so the entering strip is at rest when the landing
reveals it. The band's Core Animation clock starts one run-loop turn after the
entering side is prepared, once the strip's pending SwiftUI update has
committed, so both move on the same frames. A Space never shown in the window
(no tabs yet) slides in without waiting for its first tab; its rows fill in
when Chromium reports that tab.

The shell also owns one `FloatingSidebarHostViewController`: its hover trigger,
panel container, width and dismissal timers survive Space switches. While the
panel is hidden, a switch only makes the presented Space's resident tree the
panel's content; its activation, layout and row realization wait for the
collapse-time activation or the first hover. The panel
opens at the shell split's last expanded column width (seeded from the
account's saved width), so docked and floating widths share one source; the
presented Space's floating tree stays mounted and is realized off screen when
the column collapses, before the hover trigger enables. Each hosted session keeps its floating content mounted, hidden
while another Space is presented, just like its docked content. Content is
evicted only when the session leaves the shell. The same `HostedBandSlide` animates the
pinned/tab band in the docked and floating surfaces (when both Spaces show one shared
pinned collection — the same pinned rows, per the Pinned Tab Scope — only the tab list
slides: the leaving pinned strip stays put and the entering one takes over at landing); it retains outgoing floating
content until landing and holds pointer-driven dismissal during the transition.
Both modes retain their band backing layers between switches. Live targets
reconcile pending native row changes before motion. A dormant target forms the
available native rows (pinned tabs, bookmarks, New Tab) before motion starts;
its normal tabs appear when its Browser reports them, after the slide. Initial floating layout runs during session hosting; return visits do not
remount or reactivate it. Both backgrounds use the band's Core Animation clock; the
incoming floating surface removes its theme-fill binding while transparent so
later theme updates cannot paint over the outgoing rows.
Standalone windows mount a separate host in their own content controller.

## Native startup preparation

After launch restores settle, `SpaceManager` prepares one incognito tree and
one agent tree, without an NSWindow, Chromium Browser, task registration or
published Space. Both spares remain outside window/Space registries and
persistence. The agent spare has no profile: its bookmark store binding is
also deferred. An accepted agent request claims the spare's runtime id, then
publishes the Space and records the task through the normal ownership checks.
Adoption binds the requested profile once and installs the same native tree
in the requested shell. Agent Browser creation passes the reserved window id
so the existing dormant-session attachment path reuses that tree while keeping
the window hidden. Adoption accepts both ephemeral and persistent agent
Spaces (either agent signature). Failed creation discards the claimed native
session.

Incognito creation similarly claims and adopts its spare before the existing
Browser spawn. One replacement of each consumed kind is prepared outside the
request's animation. Profile permissions are checked when claiming/adopting
an agent spare; store transitions and quit discard all unused content.
Persistent agent reattachment keeps its existing Space identity and follows
the existing reuse/spawn path. Chromium creation still happens only on demand.

## Space switch timing

Resident switches reuse the pinned collection snapshot when its identifiers
and backing content are unchanged. Pending state changes still reconcile
synchronously before presentation. The floating host lays out its outer panel
only when its geometry changes or a hide must be reversed; showing resident
content lays out that content alone. Snapshot capture stays on the UI thread,
while PNG encoding and atomic persistence run on the cache's utility queue so
they do not hold up subsequent input. Dormant prefetch decodes disk images
into pixels; the slide uses a layer-hosted image with the cached point size and
top-left clipping rather than asking NSImageView to draw it again.

Page trees also remain resident while concealed. Hiding their ancestor invokes
Chromium's `WebContentsViewCocoa.viewDidHide`, which reports `kHidden` just as
removing the page from its window does. Switching back only unhides and sorts
the tree; closing, rebinding and dropping a session still evict it. Hidden page
trees follow shell resizing, avoiding stale geometry on the next switch.

`SpaceSwitchTiming` keeps a monotonic step timeline for tests to check stage
coverage and ordering. Recording defaults to off; tests opt in with
`recordsSteps: true`. Each step contains its name and milliseconds since the
request began. An input event, when available, precedes the request and has a
negative timestamp.

The timeline covers state publication/persistence, incognito spare claim and
binding, outgoing concealment, native presentation, pinned/floating mounting,
row refresh/layout/realization/display, page installation, animation setup and
submission, deferred Chromium visibility, profile loading, Browser creation or
ghost reconstruction, native window attachment, initial-tab seeding, and
animation completion/cleanup. A forced settle or failure has its own marker.
`presentationFinished` tracks completion independently of step recording.

## Why two paths exist

A `SpaceWindowSlot` is the user-perceived window. It hosts one `SpaceSessionController` per Space ever surfaced from this slot; exactly one is visible at a time. Two close triggers map to different user intent:

- **Tab-driven close** — the user closed the last normal home page in the active Space through the tab UI. Swift tags the close and dispatches `IDC_CLOSE_WINDOW` for that Space, allowing a sibling Space with tabs to take over.
- **Window-driven close** — the user explicitly closed the window itself (red ✕, ⇧⌘W via the Close Window menu item's `performClose:` action, ⌘W on the last tab, Chromium's internal `BrowserWindowCocoa::Close`). The user is saying "I'm done with this whole window."

In a normal, non-agent Space, closing the active tab when no normal tabs would remain first creates one home page if any closing normal tab is a real page. The home page is created before the specific old wrappers close, so the strip never empties. Pinned tabs do not count. Closing the last home page with ⌘W is deliberately window-driven: `performClose(nil)` on the shell tears the whole slot down like ⇧⌘W / the red ✕. Multi-select close uses the same policy for the complete selection and also closes the shell when all closing normal tabs are home pages. Inactive closes, Incognito Spaces, and agent Spaces retain their existing behavior.

`BrowserState.applyLastTabClosePolicy(to:intent:)` evaluates the whole closing batch once. Sidebar group header and group context-menu closes (`BrowserState.closeTabGroup(token:intent:)`) and split-cell context-menu Close use tab-driven intent. The customizable `IDC_CLOSE_TAB_GROUP` command uses window-driven intent, like ⌘W and multi-select close. A group replacement home page is ungrouped; when the policy proceeds, group closes use Chromium's group-close operation and split closes keep their inactive-pane-first ordering. Agent API group closes bypass this policy, and agent-owned Spaces remain ineligible.

By the time `windowWillClose` fires, tab strip state is identical in both cases (Chromium has torn the tabs down already), so the slot needs an out-of-band signal to tell them apart.

## How tab-driven close is tagged

These entry points apply the policy with tab-driven intent:

- `Tab.close()` (`Sources/UserInterface/Common/Tabs/Tab.swift`) — reached from the tab-row ✕ button and every other UI path that closes a tab through the `Tab` object: the tab context menu's Close, the split-pane close, the sidebar tab list, the tab-search palette, AppleScript.
- Sidebar group header and group context-menu closes — routed through `BrowserState.closeTabGroup(token:intent:)` for the whole group.
- Split-cell context-menu Close (`SpaceSessionController+Actions.closeTab(_:)`) — evaluated for both live panes before either pane closes.

When the policy returns `closeWindow`, it calls `slot.markTabDrivenClose(for: spaceId)` before dispatching `IDC_CLOSE_WINDOW` for the Space's Chromium window. The existing `tabs.count <= 1` marker remains on the fallback close path for ineligible windows. The marker is a spaceId → expiration-deadline entry in `pendingTabDrivenCloseDeadlines` on the slot. Any close path that does NOT tag the slot is treated as window-driven by default.

**The tag is cancelled when the window survives a fallback last-tab close — on any of three signals.** `PhiChromiumCoordinator.windowDidEnterPlaceholderMode` cancels before fallible work when Chromium enters its tabless placeholder. `BrowserState.handleNewTabFromChromium` and `adoptPeekTabIntoStrip` cancel when the list goes from empty back to non-empty, including Chromium's automatic refill; that judgment happens when the queued event mutates the native list. Finally, `resolvePeekCandidate` and `finishPeekCandidate` cancel in their prologs before any outcome branch, and every peek adoption cancels unconditionally. These signals prove the window survived, so leaving a marker armed would misclassify the user's next window close as a tab-driven hand-off.

The explicit last-home-page `IDC_CLOSE_WINDOW` reaches `unregisterWindow` with its live marker and makes the sibling hand-off reachable. The survival cancellation signals above remain for fallback closes and non-user ways the strip can empty; placeholder mode and Chromium's refill behavior are unchanged.

Keyboard ⌘W (`CommandDispatcher.dispatchCommand(.IDC_CLOSE_TAB, …)`) deliberately does **not** tag. After the last real page has been replaced, closing its home page calls the shell's `performClose(nil)` → `ShellWindowController.windowShouldClose` → `slot.shellRequestedClose()`, which cascades the slot through Chromium. (⌘W is still swallowed by `handleCloseTab()` when the omnibox is open, which returns `true` without dispatching anything — no tag is involved either way.)

**Incognito Spaces bypass the tag entirely on a last-tab close.** Both `Tab.close()` and the ⌘W dispatch intercept it up front and route into `SpaceManager.requestCloseIncognitoSpace(spaceId:)`: a confirmation ("This will also close this Incognito Space, are you sure?", suppressible via "Do not ask again") followed by `closeIncognitoSpace(spaceId:)`, which closes the Space's windows in every slot retreat-first (evict-then-close, like `deleteSpace`) and removes the runtime Space itself. Close paths that never reach the interception — a window-driven slot cascade, a scripted `window.close()` — are mopped up by `reapIncognitoSpaceIfWindowless(_:)`, called one turn deferred from `unregisterWindow`, which retires an Incognito Space once no slot holds a window for it.

One robustness rule applies to the tag:

- **Markers have a TTL (`tabDrivenCloseTTL`, currently 2s).** When a tagged close is vetoed — typically an `onbeforeunload` prompt the user cancels — the tab stays put: the window enters no placeholder, no insertion re-fills an emptied strip, and no `unregisterWindow` fires, so nothing cancels or drains the marker. The TTL caps the stale window so a later window-driven close on the same Space is still correctly classified; inside that window it is still misclassified.

`unregisterWindow` reads `Date() < deadline` to decide `isTabDriven`. Expired markers are drained but not honored.

## Decision matrix

`unregisterWindow(for: spaceId)` decides between three outcomes from `wasVisible` (`visibleController === controller`) and `isTabDriven`:

| `wasVisible` | `isTabDriven` | sibling Space with tabs? | result |
|---|---|---|---|
| true | true | yes | `activate(spaceId: sibling)` — slot stays alive on the sibling after the closing session withdraws from the shell. |
| true | true | no | cascade — `cascadeCloseRemainingWindows` closes every remaining sibling through Chromium. |
| true | false | (ignored) | cascade. |
| false | false | (ignored) | cascade. |
| false | true | (ignored) | drop only — the controller leaves the map with no side effects. |

The `wasVisible == false && isTabDriven == false` row is why the cascade is **not** gated on `wasVisible` alone: in the slot's native tab group `visibleController` can lag AppKit's actually-selected tab, so a real window-driven close can arrive on a controller that isn't the tracked visible one. Gating the cascade on `wasVisible` only let that close slip through and strand the slot's other Spaces with live tabs. Background closes that must NOT cascade (`deleteSpace` / `changeProfile` / `respawnWindow`) evict the controller first, so they early-return on the identity guard and never reach this branch.

After the body, if `windowsBySpaceId.isEmpty` the slot removes itself from `SpaceManager.slots`. Emptying the last slot does **not** quit the app: it stays alive with no windows on screen, so the Dock icon can reopen the group. `removeSlot` shrinks the restore snapshot on its way out, and that write is a no-op when this was the last slot — `persistSlotsSnapshot` never overwrites a saved snapshot with an empty one, which is exactly what freezes the final layout for the reopen to restore from.

Because that final write is a no-op, the snapshot a reopen restores from is whichever one landed *before* the close — which is why `unregisterWindow` opens with `flushPendingSlotsSnapshotPersist()`, before it touches the window map. Window moves and resizes persist on a debounce (they fire far too often to write per event), and this is the last moment such a pending write can still describe a whole, live slot. It is a no-op unless a frame change is actually outstanding, and mid-cascade it writes nothing at all — `persistSlotsSnapshot` refuses while any slot is tearing down, and likewise while quitting or while a windowless reopen is still replaying its session (`mayPersistSlotsSnapshot` holds all three). A refused flush leaves the frame change on record for the next write rather than dropping it, so the only case that really loses one is closing a window inside the debounce *during* a reopen replay — where keeping the last complete snapshot is the deliberate trade.

## How the cascade closes windows (`cascadeCloseRemainingWindows`)

The cascade closes each remaining window **through Chromium**, via
`bridge.executeCommand(IDC_CLOSE_WINDOW, windowId:)` →
`chrome::FindBrowserWithID` → `chrome::ExecuteCommand` →
`BrowserWindow::Close`. This is the same path the user's own window close
takes, and it is the fix for the flaky teardown:

- **Why not `NSWindow.close()`.** An earlier version poked each sibling's
  `NSWindow.close()` directly. The slot's windows live in one native tab
  group, and closing several of them — even serialized one per runloop turn —
  raced AppKit's tab-bar selection promotion, dropping some programmatic
  closes and stranding background Spaces with live tabs (with 7 Spaces, ~2
  routinely survived). Driving the close through Chromium tears each `Browser`
  down deterministically and independently of the AppKit tab group.
- **Re-entrancy.** The `isCascadingSlotClose` flag makes each window's later
  `unregisterWindow` (fired when Chromium finishes its teardown) just drop
  from the map instead of re-running a hand-off/cascade; the last drop clears
  the flag and removes the slot.
- **Trade-off: `beforeunload` is honored.** Unlike `NSWindow.close()`,
  `IDC_CLOSE_WINDOW` runs `beforeunload`, so a background Space with unsaved
  changes *and* prior user interaction can surface a dialog — the same
  behavior the visible window already has. (Chrome suppresses the dialog for
  pages with no user gesture, so untouched background Spaces close silently.)
- **Siblings on the placeholder page depend on a Chromium-side whitelist.** A
  window parked on the placeholder page has an empty tab strip, and
  `BrowserCommandController::ExecuteCommandWithDisposition` drops every command
  that is not on the placeholder whitelist it keeps for that state.
  `IDC_CLOSE_WINDOW` sits on that list for this cascade's sake; take it off and
  placeholder siblings silently survive the cascade, which the slot then reads
  as a vetoed close and puts back on screen seconds later.

## Sequence (matching log tags)

Window-driven close of a slot with N Spaces:

```
[SpaceWindowSlot] window-driven close of <visibleSpaceId>; cascading N-1 sibling(s) via Chromium
  → cascadeCloseRemainingWindows issues IDC_CLOSE_WINDOW for each remaining sibling;
    each closing sibling drains via the isCascadingSlotClose guard (no further log line),
    and the last drop removes the slot.
```

Tab-driven last-home-page close with a viable sibling:

```
[SpaceWindowSlot] tab-driven close of <visibleSpaceId>; switching to sibling <siblingSpaceId>
```

(Slot stays alive; no further log line.)
