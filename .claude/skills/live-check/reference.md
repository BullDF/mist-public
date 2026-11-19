# Live check reference

Techniques and traps for driving and observing Mist Dev, by topic. Dev runs in French, so the AX labels and menu titles here are French. What belongs here: see the end of `SKILL.md`.

## Capturing

- Sessions launched from Ghostty have Screen Recording: `screencapture -x -o -l <windowID>` captures Dev's window even unfocused or on another Space. A covered window sometimes captures blank; then `open -a` Dev, capture, and return to Ghostty.
- Find the window ID with `CGWindowListCopyWindowInfo(.optionOnScreenOnly)` filtered by `pgrep -x "Mist Dev"`: the full-size window titled with the active tab. `.optionAll` also returns hidden agent windows that capture blank. Right after Ghostty takes the front, the on-screen list can miss Dev: `open -a` it first.
- For click coordinates, capture a screen rect with `screencapture -x -R<x,y,w,h>`: 2 px per point, so a point is `x + px/2, y + py/2`. A full-screen capture's y already includes the menu bar, and a `-l` capture without `-o` adds the shadow margin to every offset.
- A stuck shade on a kit control can be its hover or its selected look: sample the capture's pixel brightness (the selected fill is darker and turns the symbol to primary ink) before choosing a cause. For a bug that only sometimes shows, run the scenario on the old Dev before installing the fix, to prove it reproduces.
- To prove no native menu or popup opened (a right-click's context menu), poll `CGWindowListCopyWindowInfo(.optionOnScreenOnly)` every 100 ms for Dev's pid at layer 100 or above (popup menus are 101).
- Dark mode: `AXPress` one of Settings ▸ Général ▸ Apparence's cards ("Système", "Clair", "Sombre"), which applies at once, and set it back to Système. With Dev on System, System Events `tell appearance preferences to set dark mode to …` switches the Mac: read it first, set it back.
- Another theme: the skill's `updateSpace('default-space', {themeId: 'coral'})` applies live (`listSpaces()` shows the current `themeId`); set it back.
- Cursor: post a `mouseMoved`, wait about a second, then `screencapture -x -C -R…` (`-C` draws the cursor). For a hover cursor, also exit in small steps downward and sideways, capturing after each. The first move after a capture or an `open -a` sometimes hasn't landed or set its cursor: post a throwaway move first, and retake a frame that shows the pointer at its old spot. To read the cursor without judging pixels, a `swiftc` tool (with `NSApplication.shared` created first) compares `NSCursor.currentSystem`'s `hotSpot` and image size with `NSCursor.pointingHand`, `.iBeam` and `.arrow`, about 0.4 s after each posted move.
- The password dropdown is a child panel, missing from a `-l` capture of the browser window: capture a screen rect with `-R`. A served page whose login, email or code field (`autocomplete="one-time-code"`) has `autofocus` opens the dropdown as soon as its tab is focused, with no click; ↓ and Return via System Events pick a row. A code row needs a code mail in an Inbox from the last 10 minutes: `smtplib` one from CSLab to itself (it reaches Dev in about 5 s), with a subject no earlier test mail used.
- An overlay scroll bar shows only while its view scrolls: capture in the same shell call right after the posted wheel events, scrolling toward content. A posted hover never expands it; judge its overlap from the `AXScrollBar` frame against the rows'.

## Posting input

- Prefer accessibility: a small `swiftc` tool over `AXUIElementCreateApplication(<Dev pid>)` presses elements by label and sets a text area's `AXValue`, with no posted input. A press can report -25200 and still act, so check the tree after.
- After Dev sits in the background a while, its `AXWindows` comes back empty until an `open -a` about 1.5 s before the walk.
- System Events `entire contents … whose description is` fails with -1700: find elements with your own walker. Transcript text areas sit over 40 levels deep, so cap a walk at 120.
- For posted input, compile a CGEvent poster that refuses unless Dev is frontmost. Use `CGEventSource(stateID: .privateState)` and real modifier presses: a nil source latched ⌘, and later typing closed a tab.
- Posted CGEvent keys without a Unicode string (Return, Delete) reach neither the composer nor text fields. Send them through System Events with the frontmost check in the same call:

  ```sh
  osascript -e 'tell application "System Events"' -e 'set f to bundle identifier of first application process whose frontmost is true' -e 'if f is "com.bulldf.mist.dev" then key code 36' -e 'end tell'
  ```

- `tell (process whose bundle identifier is …)` doesn't target Dev: keys still go to the frontmost app, and an unchecked ⌘W once closed Ghostty's window.
- On the French layout, zoom in is `keystroke "=" using command down`; `"+"` posts ⌘⇧=, which is bound to nothing.
- An Edit or Write tool call can bring Ghostty forward mid-drive: `open -a "/Applications/Mist Dev.app"` before the next batch.
- A transient `NSPopover` (tab rename field, Mount to Tab picker, downloads) closes as soon as Ghostty takes the front: open it, act and capture in one shell call. Setting a search field's `AXValue` fires `controlTextDidChange`, so it filters without typing.
- Hover: post a private-source `mouseMoved` at `.cghidEventTap` and capture about 0.35 s later.
- Pressed state: post leftMouseDown, capture about 0.4 s later, then leftMouseUp. To press without firing the action, post a leftMouseDragged well outside the control before the up. An icon button's AX frame is its symbol's, so its center is the glyph's.
- Links inside chat or reader text aren't AX elements: click the center of the text area's `AXBoundsForRange` for the link text.
- Scroll with wheel events posted at `.cghidEventTap` after warping the cursor over the view, each event's `location` set to that point; warp back after. `postToPid` scrolls never land.
- Trackpad-style scrolls: pixel-unit events with `scrollWheelEventIsContinuous` 1 and `scrollWheelEventScrollPhase` 128, 1, 2…, 4, then momentum phases 1, 2…, 3. Momentum events move the view only when they also set `PointDeltaAxis1` and `FixedPtDeltaAxis1`. Negative deltas scroll down.
- A vertical `AXScrollBar`'s `AXValue` (0 top, 1 bottom) reads a scroll position, and setting it scrolls there. Wait a second after posted scrolls before reading.
- Attach files by paste: one `NSPasteboardItem` per file with a `public.file-url` string, and keep the tool alive about a second before it exits (`writeObjects([NSURL])` keeps only the first). Save and restore Johnny's clipboard, every item's types and data, around it.
- Drag (sidebar tabs, Settings list rows): private-source leftMouseDown, leftMouseDragged steps 25–30 ms apart past the threshold, a few more at the target, then leftMouseUp. Place windows with System Events `set position` / `set size`.
- Drop a file from outside Dev: a `swiftc` AppKit helper shows a small `.floating` window over the target, activates itself and starts `beginDraggingSession` with the file URL on its first `mouseDragged`. Post down, drag steps 25 ms apart to the target, hold about 0.4 s, capture from the helper's thread, then up.
- A notification banner can sit over the window's top-right and take posted clicks there. `-l` captures don't show it, so capture that rect with `-R` before clicking near it. Never answer it.

## Menus and Settings

- Open a menu bar menu with a posted click at its AX menu bar item, or System Events `click menu bar item "<x>" of menu bar 1` inside `ignoring application responses`, so `menuWillOpen:` runs. Its items then report titles, validated `enabled` state, `AXMenuItemCmdChar` and positions; a submenu's items are its menu item's first AX child. Key code 53 closes it.
- System Events `click menu item "<x>" of menu 1 of menu bar item "<y>" of menu bar 1` on Dev's process fires an item with no posted input (`of menu bar 1` is required). A click on a `commandDispatch:` item logs no `will dispatch command` line; a posted key does.
- A menu's highlighted item is its `AXMenuItem`'s `AXSelected`. The item under the pointer is highlighted too, so move the pointer off the menu first.
- Context menus vary per cell: capture the open menu and read the item's position before clicking. Or, after the posted right-click, `AXPress` items by title in the app's open `AXMenu`, reaching a submenu's items through its item's child `AXMenu` without opening it ("Ajouter à un groupe" ▸ a group).
- Every menu key: walk the menu bar's AX tree for each item's `AXMenuItemCmdChar` and `AXMenuItemCmdModifiers` (bits: 1 ⇧, 2 ⌥, 4 ⌃, 8 no ⌘; fn isn't reported). For the real `NSMenuItem`s, add a throwaway hosted test method that dumps `NSApp.mainMenu`.
- Settings opens with `click menu item "Réglages…" of menu 1 of menu bar item 2 of menu bar 1`. Its window is titled by its pane and 680 pt wide: match `item 1 of (size of w as list)`, since matching by position never works. Toolbar buttons click by name; close it with its `AXCloseButton`.
- `open -a` raises the browser window over Settings, so `AXRaise` Settings before clicking into it. AX lists Settings only while Dev is frontmost.
- In a Settings pane, switches are `AXCheckBox`es in order (`AXPress` flips one), and pickers are `AXPopUpButton`s whose menu items are the popup's descendants after an `AXPress`. A pane scrolls by its `AXScrollBar`'s `AXValue`: System Events `set value of scroll bar 1 of scroll area 1 of group 1 of window "<pane>" to 1`.
- A command with no shortcut: quit Dev, add `{"commandId":…,"key":{"modifiersRaw":…,"characters":"g"}}` to `Phi/CustomShortcuts.json` in its data folder, relaunch, and restore the file after. Recording a key in Settings ▸ Raccourcis (the row, the detail pane's "Ajouter", then the posted combination) also saves there at once.
- Raccourcis' search is a SwiftUI field: setting its `AXValue` shows text but doesn't filter, and `AXRaise` alone leaves the browser window key. Set the Settings window's `AXMain` and the field's `AXFocused`, check in the same System Events call that `AXFocusedUIElement` is a text field at the field's position (its `window` reads empty), then `keystroke`.
- Raccourcis' "conflit avec un raccourci système" comes from `CopySymbolicHotKeys`. Name the owner by walking IDs 0–400 with SkyLight's private `CGSGetSymbolicHotKeyValue(id, &char, &keyCode, &mods)` (mods in `NSEvent` flags); ⇧⌘F is default ID 157, which posted ⇧⌘F passes through to Mist.
- Over a native page, a command that misses Mist's hook runs on Chromium's hidden page. Chromium's find bar is its own small Dev window in the window list; Mist's is a view in the browser window. `will dispatch command: IDC_…` lines in `Phi/PhiLogs/` show what reached `CommandDispatcher`.
- An open sheet (Settings' account editor, Mail's discard alert) refuses a quit (-128), which stops `install.sh` with the old Dev still running: dismiss it first.

## Apps, tabs, windows and Spaces

- AppleScript (`Resources/Phi.sdef`): `list tabs scope "all"`, `activate tab window id "<w>" tab id "<t>"`, `close tab window id "<w>" tab id "<t>"` (both required, ids as text), `open tab address "<url>" space id "default-space"` (lands in the active window), `create phi window`, `add split view`. Ids change on every relaunch, installs included.
- `list tabs` escapes slashes (`https:\/\/…`): grep its raw output for a word, never a path. Loop over its ids in Python: zsh doesn't split a space-separated list, so `for t in $ids` silently misses.
- Any AppleScript to a quit Dev launches it, and LaunchServices may pick the build product (`build/DerivedData-Dev/…/Phi.app`) over `/Applications/Mist Dev.app`. Check `pgrep -f "Mist Dev.app/Contents/MacOS"` first, and after an install that the running executable is `/Applications/Mist Dev.app/Contents/MacOS/Mist Dev`.
- The slot restore snapshot (per-window maps, landing and primary marks, frames) is `slotsRestoreSnapshot` in `Phi/users/default-account-id/defaults/account_defaults.plist`: read it after a quit with `plutil -convert json -o -`. A link "from another app" is `open -a "/Applications/Mist Dev.app" <url>` run while Ghostty is front.
- AppleScript `quit` quits with no confirmation (⌘Q asks). A normal quit restores Dev's windows; after `kill -9` or a crash it relaunches into a fresh New Tab window.
- The sdef can't close a window: press its AX window's `AXCloseButton`, or ⌘⇧W. Before a key that closes things, check the name of `first window whose value of attribute "AXMain" is true`: `front window` can be a row's untitled hover card.
- Apps open with no posted input: `click menu item "<Drifter|Mail|Clipboard>" of menu 1 of menu bar item "Apps" of menu bar 1`.
- The New Tab Page's tiles are `AXButton`s in the `AXGroup` "Apps": click them by frame, since a press by name matched a zero-size button elsewhere, and the sidebar's Drifter section is an `AXCell` with the same label. A tile for an app that has a tab focuses it and closes the blank New Tab, so test from a throwaway `open tab address "chrome://newtab/"`.
- Cheap tabs: `open tab address "chrome://version/?t=N"`; `list tabs` reports them, and `chrome://newtab/`, as `phi://…`. When tabs must look different (the ⌃Tab switcher), serve numbered pages with distinct titles from `python3 -m http.server`.
- Build layouts with the skill: `openSpaceTab(space, url, {activate: false, window})`, `createTabGroup(tabIds, {title, color, space})` and `createSplitView`, in `default-space` or a throwaway `createSpace` you delete after. Pins: `addPinnedTab(url, {title})`, `removePinnedTab(guid)`.
- `listSpaceTabs(space)` rows carry `group` and `crashed` with no `enterContext`. To take a tab out of a group (an agent folder) as a drag would, `removeTabsFromGroup([tabId], {space: 'default-space'})` with no drag. Chromium's own strip order is in the `tabIndicesUpdated` lines of `Phi/PhiLogs/`; a relaunch restores windows without one, so after a relaunch compare against the order before the quit.
- Sidebar rows are `AXRow`s (`AXSelected` marks the focused tab) with no `AXShowMenu`: post a right-click at a row's `AXStaticText`. A ⌘-click (`.maskCommand`) extends the selection. Pinned items are `AXButton`s with identifier `sidebarPinnedTab`; their hover card opens about 2 s after a `mouseMoved`.
- Pin or unpin an open tab from its context menu's first item ("Épingler" / "Désépingler"); unpinning puts the tab at the end of the list, so drag it back to its old row.
- ⌘T's palette and ⌘L's dropdown are their own untitled Dev windows (capture those IDs); ⇧⌘A's panel draws inside the browser window. Type into the palette at once: an `open -a` first hands focus back, and the text lands in the active composer.
- Historique builds its rows, Recently Closed and closed windows ("N onglets") included, only after it has opened once: a System Events click on its menu bar item inside `ignoring application responses`, then key code 53. `click menu item "<title>"` then takes the first row with that title. Clicking a submenu parent blocks every AppleScript to Dev until a key code 53.
- Reopen a tab with no posted input: `click menu item "Rouvrir l'onglet fermé" of menu 1 of menu bar item "Fichier"`.
- Peek: a private-source Shift-click on a link (Shift keyDown, then down and up with `.maskShift`).
- Kill a tab's renderer through `scripts/runner.mjs`: a script that imports `helpers.mjs` itself fails as an orphaned round, and `cliLog` works only under the runner. `enterContext` the user Space, `switchTab(targetId)`, then `withPageSession` → `Page.navigate` to `chrome://kill`.
- Dev's LocalStore is `Phi/users/default-account-id/localDB/LocalStore.sqlite`: read a copy taken with its `-wal` and `-shm`.
- `install.sh --dev --seed` quits main Mist to copy its data, killing every Drifter chat running in it (`claude`/`codex` children of main's pid). When main has such children, build what the check needs in Dev instead.
- Load an unpacked extension: quit Dev, then `open -a "/Applications/Mist Dev.app" --args --load-extension=<dir>`. A plain relaunch drops it.

## Drifter

Fixtures:

- A chat is `MistAgents/Chats/<uuid>/chat.json` plus a placeholder html with `<meta name="mist-agent" content="drifter claude|codex">`; `open -a` on the html shows it.
- A fresh chat needs `title`, `background` (a hex color string like `"#ffffff"`, never a bool), `drifter` (`engine`; `model`, a Claude alias like `sonnet` or a Codex model id; `effort`; `confirmation` `ask` or `skip`; `folder` as a `file://` URL), empty `items` and `queued`, and `draft`, which can hold the prompt.
- Every item needs `mentions`, and a record that fails to decode shows "Cette conversation ne peut pas être restaurée". Ready-made items: `{"id":"a1","kind":{"assistantText":{"text":"…","isStreaming":false}},"mentions":[]}` and `{"id":"u1","kind":{"userMessage":{"text":"…","images":[]}},"mentions":[]}`; copy other kinds from a real `chat.json`.
- Top-level `memoryFolders` and `skillFolders` decide which Read and Write rows summarize as memories or skills.
- Send a fixture's draft with `AXPress` on "Envoyer": a System Events Return after `open -a` didn't send. The chat retitles itself after its first reply, so find its window by the new title.
- Dev keeps a chat it has opened in memory until it quits: reopening that uuid ignores a rewritten `chat.json`, so use a fresh uuid.
- Restored chats: make real sessions in `~/temp/` (`claude -p --session-id <uuid>`, or `codex exec --json`) and point the fixture's `sessionId` and `folder` at them. For a resumed first turn, run one turn, quit Dev, write the next prompt into `draft`, relaunch with `open -g -a`, `open -a`, then press "Envoyer".
- `open -a` on a chat's html opens it in the last-used window, and in a second tab if a tab already shows it; switch to an open chat with `activate tab`. Tab ▸ "Dupliquer l'onglet" also duplicates a chat tab.
- Spawned children and deleted empty chats: list `Chats/` and `MistApps/Drifter/` before the check and diff after. A closed tab's empty chat goes after a 2 s delay, so look again about 3.5 s later. Closing a parent's tab closes its children's tabs a few seconds later, so a `list tabs` right after can still show a child.
- Mist never deletes a chat that got a message: after closing its tab and quitting Dev, remove a test chat's `Chats/<uuid>` and `MistApps/Drifter/<uuid>.html` yourself (each `rm` alone, literal paths).
- Dev's home (`<data folder>/MistAgents/Drifter`) starts with empty `memory/` and `skills/`. Seed a fixture `memory/MEMORY.md` with headings the real Drifter lacks, copy skills from `~/Personal/drifter/skills/`, and remove them after. A never-launched chat's `/` popup offers no built-ins (`/comp` matched nothing), so a composer slash check seeds a skill; the popup rescans on the next `/`.
- New chats start on Settings ▸ Drifter's three pickers (`MistDrifter.default*` keys, absent until first changed); composer picks never save. Set a check's cheap model there, and delete the keys after while Dev is quit.

Driving:

- The composer is the `AXTextArea` described "Répondre à Drifter", "Demander à Drifter" in a chat with no message yet (transcript messages are text areas too). Setting its `AXValue` replaces the draft and any auto-inserted mention.
- To add text after a mention, set `AXSelectedTextRange` to the end, then `AXSelectedText`. `/` set that way opens the slash popup, whose rows `AXPress`.
- To watch the Drifter home while a chat starts, split the home with the chat's tab (`createSplitView` on `listSpaceTabs` target IDs) and send from the chat's composer by AX, picking it by x: the home's composer has its own "Envoyer". Switching back to the home after a send shows the change already applied, because its first refresh after appearing snaps.
- To type with System Events, set the composer's `AXFocused` first. A click focuses it only on its text line, not on the empty card below.
- After an install, restored background tabs are unloaded and titled by URL, so an `@` query on a page title matches nothing: activate them first.
- Chat panel: the header's `Chat` button (web tabs and Mail; its posted click toggles the panel closed again), or ⌘E on a web tab. The Mount to Tab picker's rows are described "<title as Chromium has it>. <url without scheme>", and a press on a missing row silently mounts nothing. It lists only web tabs and Mail (`chrome://` pages never), so mount a fixture chat to a throwaway `https://example.com/` tab.
- Preview cards: "Open X, then Y, then Z, each in its own new tab, and tell me each main heading" gives three in one cheap turn. Only the tab the agent connected to is live. Card bodies aren't AX elements; each ✕ is "Fermer l’aperçu de l’onglet", and the ✕ frames' vertical pitch is the card height plus 8 pt. For cards no tab switch captured, `activate tab` another tab right after sending.
- Whether a background working tab draws: from the skill, evaluate `Promise.race([new Promise(r => requestAnimationFrame(() => r('ran'))), new Promise(r => setTimeout(() => r('stalled'), 1500))])` on it, idle and during a turn held by `wait_for` `time`.
- A flash too short for a screenshot (a capture's cover on a visible page): loop `screencapture -x -o -l` for the turn (~10 frames/s), crop the page pane with `sips -c`, and compare md5s; diff an odd frame against its neighbor with a small `swiftc` pixel differ to find what moved. To inspect a transcript's row sequence, tile the distinct crops' top bands, labeled, into one contact sheet (a `swiftc` `NSBitmapImageRep` tiler) and Read that one image.
- What a page saw from the agent (keys, events, selection): have the fixture `fetch('/event?' + new URLSearchParams({line}))` on each event; `python3 -u -m http.server`'s request log then lists them in order, with no CDP connection.
- Per-tool durations: a Claude session JSONL's `tool_use` and `tool_result` timestamps; a Codex rollout's `custom_tool_call` and `custom_tool_call_output` pairs, one per code-mode `exec` cell (several tools can share a cell).
- Child chats: a parent prompt naming `spawn_agent` with model, effort and brief, plus how to answer (`message_agent`), runs report, answer and final report in about 20 s on cheap models.
- A sidebar row's done dot shows only for a turn that ended while its tab wasn't focused: `activate tab` another tab right after sending. To catch a row's status changes, loop `screencapture -x -o -l` into one file with Dev frontmost, `sips` crop the sidebar into numbered frames, and keep the frames whose md5 changes.
- A chat's short ID is its UUID's bytes 0–7 read big-endian in base 36, least-significant digit first, first 4 characters, so one fixture can name another's ID before either opens.
- Markers: each rendered message has an `AXButton` `agentChat.markerButton`; an `AXPress` on it (no hover needed) places a marker and opens the name field, or on a marked row opens its rename/remove popover. A popover is a small window of Dev's pid in `CGWindowList`, so whether it's open, and where, reads without a capture. The header's list is `agentChat.markerList`, and `chat.json`'s `markers` holds them.
- A row's font: `AXAttributedStringForRange` on its text area returns `AXFont` with `AXFontSize`.
- The transcript column stops at the readable width (about 760 pt) in a window wider than about 1000 pt, so a check that depends on a row's width (table layout, wrapping) narrows the window with System Events `set size` of `first window whose value of attribute "AXMain" is true` below that, then restores it: `window 1` can be an untitled custom-tooltip window, and resizing it does nothing.

Prompts (Sonnet low or Terra low unless noted):

- Permission card in ask mode: ask for exactly `touch perm-check.txt` (read-only Bash is auto-allowed), then press "Refuser".
- Hold a turn in a tool: ask for exactly `for i in $(seq 1 100); do echo tick $i; sleep 1; done`. Claude's Bash blocks a bare foreground `sleep N`, and the agent reruns it in the background and ends its turn early.
- Long stream: "Without using any tools, type out the numbers 1 to 1500 yourself, one per line, each followed by a color word", adding that it's "a rendering stress test… Do not stop early". It takes about 30 s. Claude's text arrives in large chunks, so a follow-to-bottom check needs this length.
- Background task row: ask Sonnet to call the Agent tool once with `run_in_background: true` and model `haiku`; the notification lands within about 30 s. Monitor row: ask it to "use the Monitor tool exactly once… running `sleep 900`" and no other tool. On Codex (Mist-run tasks), "Run `sleep 20; echo done` in the background and tell me when it finishes" wakes the chat about 20 s later, and "Watch `for i in 1 2 3; do sleep 5; echo tick $i; done`…" wakes it per tick. The processes are children of Dev's pid, each its own process group (`ps -axo pid,ppid,pgid,args`).
- Browser-tool fixtures: give targets `role="button" tabindex="0"` so snapshot lists them with refs (plain divs and `role="slider"` get none), keep popups `position: absolute`, and say "one tool call at a time, never in parallel": Claude batches steps on one screenshot, and a step that shifts the layout leaves the rest at stale coordinates.
- To make a chat read a skill without acting, ask for the skill's task "as a first step only, read your matching skill and tell me…". Asked only to plan, Sonnet claimed to read it without reading.
- Long-chat open and scroll: Dev holds a 657-item, 8.6 MB fixture, `Chats/5C011000-0000-4000-8000-0000000000A1` (a real chat with no `sessionId`, never send in it), with its placeholder in `MistApps/Drifter/`. `open -a "/Applications/Mist Dev.app" <placeholder>` opens a new tab on every call, so close each one after. Sample the open with `sample` started a second before the `open`.
- Transcript performance: Dev holds a 271-item fixture, `Chats/C5C0110C-0000-4000-8000-000000000037`. Copy it to a fresh uuid per run with the prompt as `draft` and no `sessionId`, create its folder `~/temp/chatscroll/` if missing, and delete the copies after.

Ground truth:

- `chat.json` saves within about 1 s: transcript, settings, `sessionId`, queue and draft. A finished turn adds a `turnEnd` item.
- What the agent received: Claude's `~/.claude/projects/<folder slug>/<sessionId>.jsonl` (every non-alphanumeric character of the folder becomes `-`), Codex's newest `~/.codex/sessions/<y>/<m>/<d>/rollout-*.jsonl`. Model and effort per turn: Claude's `message.model` and `"effort"` entries, Codex's `turn_context`.
- The images an MCP tool returned to Claude (screenshots, full-page tiles) are saved beside that JSONL as `<sessionId>/tool-results/mcp-<server>-blob-*.png`, named in the `tool_result` text: Read them to see exactly what the model saw.
- Which tools an engine had: a Claude session JSONL's `api-request-shape` lines list the tools sent (server tools like `advisor` included, which `system/init` omits) and its `deferred_tools_delta` attachments the deferred ones, `mcp__…` included. A Codex rollout's `additional_tools` line lists its native tool namespaces, and `turn_context.multi_agent_version` reads `disabled` while Codex's own `spawn_agent` is off; for MCP tools, a Codex chat can run one code-mode `exec` of `text(ALL_TOOLS.map(t => t.name)…)`, whose output shows in the rollout.
- Remote Control: Dev's log shows "Remote Control enabled" (`subsystem == "com.bulldf.mist" AND category == "ClaudeCode"`), and the session JSONL gains a `bridgeSessionId` once connected. Typing from claude.ai is a web write, so ask Johnny (`https://claude.ai/code/session_<id after cse_>`).
- A model menu reads without a capture: `AXPress` "Modèle" off the main thread (it blocks while open) and walk the `AXMenu`. To pick from "Modèle" or "Effort", run the press in the background, then in one System Events call with the frontmost check `keystroke` the item's title (type-select) and key code 36. Gate that call on the menu being open (a Dev window at layer 100 or above in `CGWindowList`): a labeled chip's AX label is "Effort | Faible", so a press by exact name missed, and the typed title and Return went into the composer and sent a message. A failed Codex catalog shows the raw model ID on the button.
- Kill only Dev's agent CLIs: walk `ps -axo pid,ppid,args` up to Dev's pid.
- To make Codex fail for Dev alone, launch the quit Dev with `--env PATH=<dir>:/usr/bin:/bin:/usr/sbin:/sbin`, where `<dir>` holds a `codex` shim that exits 1 while a flag file exists and otherwise execs `~/.local/bin/codex`. Quit Dev after.

## Mail

- Johnny's live credentials are keychain items `Mist Mail Live gmail` and `Mist Mail Live uoft-cs`. Type one without it reaching the transcript: `TXT="$(security find-generic-password -s '<item>' -w)" osascript …` with `keystroke (system attribute "TXT")` and the frontmost check.
- Both accounts stay registered in Dev (Johnny's call): never remove them. Add them only when Settings ▸ Mail lists none: preset popup "UofT CS", fields set `AXFocused` then typed, "Connexion", about 6 s for "Connecté".
- For the no-account page, rename Dev's `MistMail/` aside while it's quit, and put it back after.
- Send test mail only between Johnny's two accounts, or from a shell with `smtplib` (CSLab: `smtp.cs.toronto.edu` 587 STARTTLS, user in Drifter memory `mist-private-ids`). Afterward move every test message, sent and received, to Trash in both, and confirm with a read-only `imaplib` `SUBJECT` search. Gmail's folder names are localized (`[Gmail]/Corbeille`): take Trash from the `LIST` line flagged `\Trash`.
- A compose draft uploads to the server's Drafts 30 s after it saves, so every test draft ends sent or discarded. Discard with a posted click on the sheet's "Supprimer le brouillon": compose's toolbar trash has the same title.
- Check that actions reached the server in a copy of `MistMail/mail.sqlite` (with `-wal` and `-shm`): `pending` back to 0, `drafts` back to its count before.
- Selecting an unread message marks it read on the server, so pick read ones (`seen` in a copy of `mail.sqlite`). Before Mark All as Read, check read-only with `imaplib` that every unread message is test mail.
- Dev restores its windows at the same frame: `AXRaise` window "Mail" (with `set frontmost to true`) before clicking into it.
- Compose's fields and toolbar toggles `AXPress` by description ("À", "Objet", "Gras"), and ⌘↩ sends. Each field's row label is an `AXStaticText` with the same description, walked first: match the `AXTextField` role. Typed body text keeps landing for seconds after `keystroke` returns.
- Sidebar rows reload on every model change: click them by position with a private-source CGEvent, since System Events `click at` doesn't land.
- Pane widths autosave as `NSSplitView Subview Frames MistMailPanes2`: note it before dragging, and write it back while Dev is quit.
- Notifications post about a minute after delivery. `log show --info` on `process == "usernotificationsd"` shows the entitlement check by signing identifier and a click's `Forwarding didReceive`. Banners are another app's windows: Johnny clicks them.
- Connection states without touching a real account: a throwaway account on GreenMail in Docker at fixed loopback ports (`-p 127.0.0.1:13143:3143 -p 127.0.0.1:13025:3025`, `greenmail.users=mail:secret@example.test`), preset "Autre", both securities "Aucune (localhost uniquement)". `docker stop`/`start` of that container is a server drop; a second container on the same ports with another password for `mail` is a failed sign-in. Docker accepts the port before GreenMail answers: wait for an `imaplib` login. Remove the account and the containers after.
- Setting up that GreenMail account:
  - GreenMail has no Trash, so `imaplib` `create("Trash")` before adding the account (roles come from folder names).
  - Check Settings ▸ Synchronisation first: accounts sync, so a Dev joined to a sync group would spread the throwaway account.
  - In the add sheet, "Réglages des serveurs" opens only with a posted click (AXPress doesn't expand it), and Tab walks the text fields, skipping popups.
  - The username auto-fills from the e-mail field: ⌘A before typing it.
  - Every account row's "Supprimer" shares its label with Johnny's accounts: click the throwaway row's button by position, never AXPress by label.
  - `smtplib` to `127.0.0.1:13025` lands in Dev about 2 s later through IDLE.
- `build-scripts/test-mist-mail.sh` needs Docker: `open -a Docker`, and afterward `docker desktop stop` only if it wasn't running. Never `quit app "Docker"`: it kills the VM.

## Sync and Clipboard

- Dev has no sync set up. Run a local relay with `npx --no-install wrangler dev --local --ip 127.0.0.1 --port <p> --persist-to <scratch>` in `mist/sync-server`.
- Point Dev at it in Settings ▸ Synchronisation: post a click into the server URL field (setting its `AXValue` leaves the button disabled), type the URL, press Return. Gate the click on the front window being "Synchronisation", with no `open -a` in between.
- A second member is a hostless binary built like `test-mist-sync-e2e.sh`. It registers `MemorySyncSource(kind:)` for every kind Dev sends other than the one under test (`login`, `never-save`, `profile`, `space`, `bookmark`, `mail-account`, `clipboard`), or it stops on `unknownKind`, plus a real source for that one.
- Dev joins by setting the pairing code field's `AXValue` (the second `AXTextField`), then "Rejoindre". Joining uploads Dev's real data, encrypted: delete the relay's `--persist-to` folder afterward.
- Leave sync as found: "Désactiver la synchronisation sur ce Mac", then System Events `click button 1 of sheet 1 of window "Synchronisation"`. Turning off deletes Dev's `MistSync/` folder and keychain item, so back up the folder first and restore it while Dev is quit.
- No-echo ground truth: after a remote change, Dev's `MistSync/state.json` has an empty `outbox` and the record's version ends in the other member's device ID.
- Clipboard: a posted ⌘V pastes while the page or nothing has focus. After Settings was key, click empty page space first.
- The two "Effacer" buttons differ: the one on Envoyer's row only unstages, while the item card's clears every Mac.
- The file chooser is a sheet window "Ouvrir" (⌘⇧G, path, Return, Return). Picking a file rewrites Dev's `NSOSPLastRootDirectory` default: save it first (`defaults export com.bulldf.mist.dev - | plutil -extract NSOSPLastRootDirectory raw -`) and write it back after Dev quits.
- The sharing switch is the first `AXCheckBox` under the window "Synchronisation" (no AX title), defaults key `MistClipboardSharing` (absent = on). `BrowserAgentIdleLifetime 60` gives a one-minute item.
- The sender line's run-together name is the Mac's MDM-set computer name, not a bug.

## Slack

The Slack IDs this section names (Drifter's DM, #drifter-test, Johnny's self-DM and user ID) are in Drifter memory `mist-private-ids`.

- Slack checks are allowed in Drifter's DM and #drifter-test, plus your own sends to Johnny's self-DM below; never another channel or person.
- Dev keeps the Drifter Slack app's tokens in Settings ▸ Slack (Johnny's call), from Drifter's `local/slack.env`. To enter them, set each `AXSecureTextField`'s `AXFocused` (user, bot, app), `keystroke (system attribute "<VAR>")` with the env file sourced, then "Enregistrer".
- A check of the Slack send card itself posts nothing: in an ask-mode chat, ask for `slack_send_message` to the self-DM, then refuse the card (Refuser, or any follow-up message). Johnny's user ID makes a mention that resolves to his name.
- Send only to Johnny's self-DM, named in the prompt by its ID. Verify and delete with the user token from `python3 -I`: `conversations.history` (`latest=<ts>`, `inclusive`, `limit=1`), then `chat.delete`; the ts is the send row's `message_ts`.
- Drifter in Slack needs Johnny to type in Drifter's DM, or for channel threads in the private #drifter-test (only him and Drifter), where every trigger must @mention Drifter: his token's posts carry the app's `bot_id` and are ignored. Ask him for the exact text and any Allow or stop press. Main's own "Answer in Slack" must be off.
- Turn Dev's "Answer in Slack" on with `defaults write com.bulldf.mist.dev MistSlack.answerInSlack -bool true` while Dev is quit, and `defaults delete` it after.
- `Phi/PhiLogs/` logs every step: `slack: socket connected`, `events_api message routed […]` per envelope, `<method> ok|failed (<code>)`. Read threads with the user token's `conversations.replies`.
- An event sent while no connection is open is redelivered after catch-up has answered it.
- `agents.sessions.setStatus` with the bot token sets a thread working or `active` without an agent, and its response carries the session `title`.
- With no workspace at all, a temporary, never-committed hook in `SlackAgentBridge+App.swift`'s `start()` builds a second bridge with its own thread store and a logging `call` stub, fed `.message` events by a `DistributedNotificationCenter` observer. Revert it, reinstall Dev, and delete its store and chats.
- Clean up the test chats. Back up `MistAgents/SlackThreads.json` before turning Dev's Answer in Slack on and restore it after (delete it if the check created it): with no `lastConnectedAt` in it, Dev's connect skips catch-up, which otherwise scans Johnny's DM since Dev's last connect.

## Timing, performance and tracing

- To exercise a startup sync alone, change state through the skill and AppleScript `quit` in the same shell call: Dev exits in about 0.5 s, before a 1 s debounce (the bookmark mirror's) fires, so the relaunch has to catch up.
- Wrong-size flashes: from just before the trigger, poll `CGWindowListCopyWindowInfo(.optionAll)` for Dev's pid in a tight `swiftc` loop, printing each window's bounds, onscreen flag and alpha when they change. Only onscreen frames count.
- Running tool groups last under a second: hold one with `wait_for` `{for: time}` or a slow local server, and loop `screencapture -x -R` with no sleep.
- Record with `screencapture -x -v -V <s> -R<rect>` in the foreground, firing the trigger from a backgrounded `(sleep 1.5; …) &`: a backgrounded recorder writes its file only after the shell call returns. It won't overwrite an existing file. It records a frame per screen change: read every sample with `AVAssetReader` (BGRA) sorted by time, and time only frames whose content moved. There's no ffmpeg; Johnny's `.mov`s read the same way.
- A transcript's scroll per frame: match each frame's per-row brightness profile of the column against the previous one; a one-frame jump back is a snap.
- While a turn runs, the working row pulses every frame, so gaps between changed frames are main-thread stalls (smooth: p95 about 25 ms).
- Compare scroll smoothness only from the same start (scrolled to the bottom): one chat's p95 frame gap ranged 25–50 ms across different rows.
- Whether a transient predates a commit: Edit the change out, `install.sh --dev --no-launch`, record 10+ cycles, then Edit it back and reinstall.
- Tracing: `NSLog` doesn't reach `log show`, but temporary `AppLogInfo` lands in `Phi/PhiLogs/` within a second. A temporary `DistributedNotificationCenter` observer posted from a tiny Swift tool triggers a path without driving. Revert all of it before anything commits.
- A slow `mistbrowser` tool: the Claude CLI's `~/Library/Caches/claude-cli-nodejs/<Dev home slug>/mcp-logs-mistbrowser/*.jsonl` times each call, and the helpers' own action log goes nowhere in a user Space. To find the stalled CDP command, edit Dev's bundled `Contents/Resources/phi-browser-skill/scripts/lib/cdp.mjs` to append slow `send`s and dialog events to a scratch file. New chats load it with no reinstall; copy the repo's file back after.
- Never override `scrollWheel(with:)` to trace: it turns off responsive scrolling. Observe the clip view's bounds and `NSScrollView`'s live-scroll notifications instead.
- A bug only in installed builds that vanishes when logging is added can be the optimizer: store the failure reason, and log it after the decision.
- `install.sh` strips the dylib, so `Thread.callStackSymbols` names only AppKit and system frames (Mist's show as bogus `Kingfisher` symbols).
- Profile with `sample <pid> 8 1 -file out.txt`; a 1 ms sample slows a busy main thread, so measure pacing in a separate run. The main thread is the first thread (`CrBrowserMain`).
- Symbolicate Mist's `???` frames: `dsymutil -o <scratch>/Phi.dSYM` on `build/DerivedData-<Dev|OpenSource>/Build/Products/OpenSource/Phi.app/Contents/MacOS/Phi.debug.dylib` (its UUID must match the installed copy's, per `dwarfdump --uuid`), then `atos -o <dSYM>/Contents/Resources/DWARF/Phi.debug.dylib -l <base>`.
- Many observers under Combine's `Sink.receive` (`loadLayoutMode`, `updateHeaderVisibility`) mean a `UserDefaults` notification storm: find the writer from the `-[NSUserDefaults setObject:forKey:]` callers.
- `_CFXNotificationRemoveObservers` heavy under view or text view `dealloc` means leaked notification observers, which build up with uptime, so a fresh Dev looks fine. `NotificationCenter`'s `debugDescription` lists nothing: temporarily swizzle its two `addObserver` methods in Dev, keeping block tokens in a weak-keyed map by name (a token alive is a registration alive) and selector observers in a weak table by class, dump both on a distributed notification, and diff dumps around a workload (50 web tabs opened and closed showed the theme leak).
- Per-tab costs hide in Dev's few tabs: add about 15 `open tab address "https://github.com/<public repo>"` tabs, then close them.
- 120 Hz pacing: a temporary `displayLink` probe on the window's content view (`.common` mode) logging frames per second and frames over 1.5× the period, plus one static `CFRunLoopObserver` summing awake time per second.
- Idle CPU: `top -l 31 -s 2 -stats pid,cpu` with one `-pid` per process (Dev plus its `pgrep -P` helpers, arguments built in Python); drop the first sample.
- Typing lag: each key a field editor takes logs `scheduleUpdateCursorLocation`, so `log show --predicate 'processID == <pid> AND eventMessage CONTAINS "scheduleUpdateCursorLocation"'` timestamps processed keys. Post keys at a fixed interval and look for long gaps.
- Browser memory: take CLAUDE.md's memory-infra dump from a node script using `connectBrowser` (`lib/cdp.mjs`) with `transferMode: 'ReportEvents'`, before and after. Compare `malloc` and the growing `malloc/partitions/allocator/buckets/bucket_<slot>`.

## Network

- `python3 -m http.server --bind 127.0.0.1` serves `.md` as `text/markdown` with no charset, which Chromium decodes as windows-1252.
- `example.com` doesn't resolve through this Mac's DNS for CLI fetches: use another host.
