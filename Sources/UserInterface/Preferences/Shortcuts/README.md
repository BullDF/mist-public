# macOS Shortcut Customization and Chromium Integration

## Design Goals

- Keep Chromium authoritative for ordinary `IDC_*` command dispatch.
- Intercept native Phi shortcuts before falling back to Chromium.
- Use one event-normalization path for recording and native matching.
- Keep Phi's stored shortcut identity separate from AppKit's menu representation.
- Keep settings, conflict reporting, native menus, and Chromium menu overrides in sync.
- Rebuild the main menu after an override changes without replacing existing menu actions or targets.

## Native Ownership and Key Representations

- `ShortcutsKey` in `Shortcuts.swift` is the shared shortcut identity used by
  recording, display, conflict detection, native dispatch, and the Chromium
  bridge. `eventKeys(for:)` owns `NSEvent` normalization.
- `EventKeys.canonical` is the primary identity used for new recordings and
  native lookup. For covered non-Latin letter events it is Latin; otherwise it
  remains the normalized semantic key.
- `EventKeys.legacy` preserves a different active-layout semantic character as
  a secondary native lookup candidate for previously stored non-Latin overrides.
- `ShortcutsKey.menuKeyEquivalent` projects the stored identity into the form
  AppKit and Chromium menu matching expect.
- `EventKeys.matches` and `matchingRank` share execution matching between the
  central dispatcher and Peek/Reader. Canonical candidates precede legacy
  candidates; exact stored bindings precede menu-equivalent bindings. Equal
  ranks in the dispatcher resolve by command ID, independent of dictionary order.
- `Shortcuts` owns one `ShortcutConfiguration` value. The configuration loads,
  validates, and atomically saves explicit overrides; it has no UI or Chromium
  dependencies. `Shortcuts+Custom.swift` provides effective-key lookup, change
  notification, and menu rebuild requests. It does not normalize events.
- `ShortcutInventory` is a derived snapshot of effective bindings, with command,
  native-selector, or system ownership, source, and window scope. It is not a second
  configuration store. Conflict detection and captured-key search use it.
- `ShortcutsViewModel` owns settings presentation, recording state, persistence
  errors, selection, and informational conflict details.
- `CommandDispatcher` owns pre-Chromium interception for the commands listed
  in `phiInterceptedCommands`. Other commands continue
  through Chromium.

## Settings Presentation

The search section sits above the command list and selected-command detail pane.
List selection, search text, and the mutually exclusive filter belong to `ShortcutsViewModel`; recording,
description, conflict, and restore sections are separate SwiftUI views.
List selection only navigates and keeps the native selection highlight. Recording
starts only from the detail keycaps or the shortcut button in a list row. Conflict
links clear the search text and filter and select a visible command without recording. Initial
selection and search-driven selection do not capture keys or take focus from search. Each capture session has its own responder identity so delayed
cancellation from the previous selection cannot cancel the new recording.
The recording section renders individual keycaps using the same display tokens
as other shortcut surfaces. The current combination stays visible until a modifier
is held; while modifiers are held, both assigned and unassigned commands preview
those modifiers and an ellipsis. Releasing them restores the current combination.
Modifier changes
never save or restart capture. During recording, keycaps stay flat; completing a combination
raises them and reveals their shadows. The view owns this cancellable animation,
respects Reduce Motion, and resets its presentation when the selected command changes.
Native actions and unlisted commands remain informational. The Restore button is always shown
and enabled exactly when the selected command has a stored override, regardless
of conflicts. Restoring can therefore expose an existing default-key conflict.

Enabled macOS symbolic hotkeys are read through `CopySymbolicHotKeys` when the
inventory refreshes. `SystemShortcutBindings` reuses the global-hotkey adapter's
pure keyboard-layout resolver to compare physical chords without registering or
changing any hotkeys. Settings refresh on appearance, application activation,
and input-source changes. Only enabled, matching reservations enter the inventory.
System conflicts count toward the conflict filter but have a distinct yellow
indicator and fixed informational warning, with no navigation action or editable
system row. Application conflicts remain visible alongside system warnings.
The API provides no action names and does not enumerate third-party global hotkeys.
Read failures are logged; an empty result is not proof that a shortcut is available.

## Event Normalization and Input Sources

`charactersIgnoringModifiers` removes Command, Option, and Control character
transformations, but it retains Shift-produced printable characters and the
active input source. A Cyrillic layout can therefore report a Cyrillic character
even when the same physical key represents a Latin shortcut.
Phi first reads the focused `NSTextInputContext` input-source identifier. That
API can be `nil` when focus is outside an editable responder, so Phi falls back
to the process-wide source returned by Carbon TIS, matching Chromium's source
lookup boundary.

Recording and native dispatch resolve an event in this order:

1. Build the semantic key from `charactersIgnoringModifiers`. Physical Tab is
   normalized to `"\t"` and Delete to Backspace. Retain Command, Option, Shift,
   Control, and a held Function modifier. Discard the automatic Function bit
   attached to navigation/function-key characters (`U+F700` through `U+F747`).
2. For Command alone on the number row, use the physical digit except on
   Dvorak Left/Right. The raw device-independent modifier mask must be exactly
   Command, matching Chromium's exclusions for Caps Lock, keypad and Fn flags.
3. For Chromium's Command-QWERTY input sources, use the Carbon `kVK_ANSI_*`
   physical identity for every modifier combination, including Control/Option
   without Command. This covers the 26 letters, 10 digits and 11 punctuation
   keys on the main ANSI keyboard, including their Shift-produced characters.
4. Otherwise, if `charactersIgnoringModifiers` is empty or non-ASCII and `characters`
   contains one printable ASCII character, use that AppKit menu equivalent as
   the canonical character. This fallback also handles Chromium's observed
   Apple Hebrew Cmd-Q and Arabic PC/AZERTY Shift-Cmd-V exceptions; their two
   ASCII event strings require the input-source identifier to disambiguate them.
5. If no verified Latin identity is available, retain the semantic key.

Ordinary ASCII-to-ASCII differences do not trigger a physical fallback. This
preserves semantic layouts such as Dvorak instead of treating every differing
character as a QWERTY key. The explicit Command-QWERTY and Command-only number-row
rules above are the exceptions. Other punctuation remains layout-defined.
Existing semantic overrides remain native legacy candidates; their JSON has no
original layout/key-code metadata, so no speculative persistence migration runs.

The Hebrew and Arabic handling recognizes known Apple input-source families and
observed event shapes. It is not a guarantee for every third-party input method,
future input-source identifier, punctuation mapping, or macOS event behavior.

## Stored Keys and Menu Key Equivalents

Phi stores printable shortcuts as a normalized character plus explicit
modifiers. AppKit encodes Shift differently for printable menu shortcuts:

```text
Stored/display identity: p + Command + Shift
AppKit menu identity:     P + Command
```

`menuKeyEquivalent` performs this projection by uppercasing a printable
character and removing Shift from the modifier mask, except when a held Fn
or a printable numeric-keypad event requires Shift to remain in Chromium's mask. Control characters and
function keys retain Shift; for example, Shift-Tab remains `"\t" + Shift`.

Recorded Shift combinations from printable keypad hardware keys store the
optional `preservesShift: true` field. For example, Ctrl-Shift-Keypad-1 keeps
both modifiers and does not collide with Ctrl-1. Unshifted keypad digits remain
aliases of the ordinary digits. NumericPad is event metadata, not a stored
modifier; navigation keys carrying that flag do not become printable keypad
bindings. Menu and Framework inventory records already contain projected masks,
so importing an explicit printable Shift mask also preserves it. Conflict checks,
native dispatch, menu overrides, and per-alias exclusions share this identity.

Older files omit `preservesShift` and retain the legacy projection. Their keypad
origin cannot be inferred safely from characters and modifiers alone. Re-record
an affected Shift-keypad combination to opt into the corrected identity; loading
or saving unrelated shortcuts does not guess or rewrite its origin.

Shifted punctuation must store the character AppKit actually reports. For
example, the US-layout Select Previous/Next Tab defaults store `{` and `}` plus
Shift, so their menu identities remain distinct from Back/Forward's `[` and `]`.
The settings view presents those two defaults as the familiar physical-key labels
`Cmd-Shift-[` and `Cmd-Shift-]`; that presentation exception does not change the
stored or executable identity.

Fn plus an ordinary character is distinct from that character without Fn.
Native matching retains that distinction, preventing a different chord from
firing. New recordings reject held-Fn combinations because AppKit only accepts
Fn on system-provided menu items. Navigation/function keys remain supported;
their automatic Fn event flag is not a held modifier. Carbon's global-hotkey
adapter also rejects held-Fn combinations instead of registering a different
chord with Fn silently removed.

The Chromium bridge, native menu writers, conflict detection, and native
equivalent matching must all use this projected identity. Display and JSON
persistence continue to use the stored identity.

## Data Flow

### Recording

1. `KeyCaptureView` captures events only while it is the first responder of its
   owning key window. Leaving that context cancels recording. The separate
   `CommandShortcutCaptureView` observes Command-F and Escape for search focus;
   it does not record a combination into the search field.
2. `ShortcutsViewModel` interprets `ShortcutsKey.recordingAction(for:)`. Plain
   Escape cancels and plain Backspace disables. Modified keys are bindings;
   Escape requires Command or Control. Shift-only printable keys are rejected.
3. Search accepts command names, modifier names/abbreviations/symbols, and key
   characters as text (for example, `cmd ctrl S` or `⌘⌃S`). It filters cached
   inventory entries without changing bindings or reordering matching commands.
4. Recording saves only the selected command through `Shortcuts.setOverride`.
   There is no conflict confirmation or automatic removal of another command's
   keys. Conflicts, including read-only owners, appear in the detail pane after
   saving so the user can choose which commands to edit or restore.
5. After a successful changed configuration, `Shortcuts` refreshes the native
   intercepted-command map and Chromium menu. `shortcutsDidChange` also notifies
   open settings of loading or saving failures without publishing failed writes.

Unmodified keys are not recorded. A non-Latin event is stored and displayed with
a canonical Latin character only when AppKit supplies a verified ASCII equivalent
or Chromium defines an input-source-specific physical mapping. Otherwise Phi
keeps the semantic local-script character instead of saving an identity that one
of the execution paths cannot reproduce.

### Execution

- Native intercepted commands:
  `phi_command_dispatcher_delegate.mm` -> `PhiChromiumCoordinator` ->
  `CommandDispatcher.handleKeyEquivalent` -> `ShortcutsKey.eventKeys` ->
  canonical lookup -> legacy lookup -> native dispatch.
  `IDC_NEW_SPLIT_TAB` has no keyboard binding
  under Phi's product-disabled shortcut policy.
- Ordinary Chromium commands:
  `keyEquivalentOverrideForCommand:` returns the override's projected
  `menuKeyEquivalent`, after which Chromium performs its normal menu and command
  lookup.
- Native menu items:
  `AppController+Menu`, `Shortcuts.updateShortcut`, and tab context menus apply
  `menuKeyEquivalent` directly.

`ShortcutsKey.displayKey` renders symbols recorded with Shift as Shift plus a
digit in settings, recording results, aliases, and key search. Unshifted symbols
and explicit shifted keypad bindings retain their original presentation.
It never rewrites stored
keys, event normalization, or Chromium overrides. `ShortcutMenuPresentation`
uses the command's original binding for this projection while AppKit tracks a
menu; unknown menu bindings are not inferred from their symbols. A hidden alias
retains the original key equivalent during tracking, including its keypad
matches. Tracking end removes the alias and restores the exact original fields.
The inventory reads the original keys and excludes these temporary aliases.

An intercepted Phi binding owns its event once it applies to the receiving
window and feature context. A transiently unavailable action (for example,
Copy URL with no copyable selection) still consumes that event, preventing a
different hidden Chromium command from running. Unsupported window contexts,
disabled features, and absent indexed Space targets do not claim the event.
Action dispatch keeps its separate success result for non-keyboard callers.

### Tab Switcher Gestures

The initiating effective binding supplies a gesture's Command/Control/Option
hold keys. The manager freezes them until the gesture ends; the other direction's
binding and later configuration changes do not replace them. Shift changes the
binding or direction but never prolongs the gesture. Releasing any initiating
hold key commits the selection. Menu invocations and bindings without hold keys
perform one immediate step.

The delayed reveal rechecks the same hold keys and commits if their release was
missed before monitoring began. Explicit events from another window are ignored;
window or application deactivation cancels without activating a candidate.
Chromium's separate Ctrl-Tab cycling commands remain suppressed, including after
rebinding or disablement, as described below.

### Product-Disabled Shortcut Commands

The menu-only policy includes tab selection (numbered, next/previous and move),
Minimize, Hide and Hide Others, Downloads, Clear Browsing Data, Back/Forward/Home,
Stop, Search the Web, History, Bookmark All Tabs, Space navigation and creation,
New Chat, Use Selection for Find, spelling commands, Full Screen,
Reader, View Source, Inspect, Console, Share and Print Using System Dialog.
It also covers Import from Another Browser, New Tab to the Right, New Split Tab
and unsupported Chromium shell commands. Settings omits these commands and ignores
saved bindings; their actions remain available without keys.

`Shortcuts.disabledShortcutCommands` in `Shortcuts+Custom.swift` is the single
configuration point for commands whose keyboard bindings Phi does not support.
Add a `CommandWrapper` entry there to suppress its default and every saved custom
binding, omit it from settings and conflicts, and export an explicit disabled
override to Chromium's main-menu and hidden accelerator tables. The existing
Chromium Ctrl-Tab suppression uses the same policy.

The policy disables bindings by command ID, not by key combination. Released
keys can be assigned to other supported commands. Saved overrides are retained
but ignored for disabled commands; restoring defaults cannot bypass the policy.
Non-keyboard command entry points and menu item visibility are unchanged.

Native main-menu keys are released through the same command policy and
`releasedNativeShortcutActions`: Hide, Hide Others, Minimize, Minimize All,
spelling commands, AppKit Full Screen and Option-Quit. Quit keeps Command-Q.
The main-menu hook and the existing menu-change observer clear declared keys,
preserving modifier masks so Option-alternates remain paired. Releasing only an
alternate's key while its primary keeps one unpairs them, and AppKit then shows
the alternate as an ordinary row (Close All under Close Window's Command-Shift-W). Detached inventory
copies retain explicit empty keys. Services' Command-Shift-A is still cleared.
On current macOS, AppKit synthesizes Minimize All (Option-Command-M) outside the
Window menu's items, beside its window-tiling items, so it keeps its key; the
`miniaturizeAll:` entry only covers a macOS that inserts it as a real item.
The tab-group commands (Create New Tab Group, New Tab in Group, Close Group,
Focus Previous/Next Tab Group) are product-disabled, which clears Chromium's
Control-Command-P, C, W, Z and X accelerators; their tab-group context menu
items show no key.

### Display and Conflicts

- Settings display uses the effective stored `ShortcutsKey`, or the live browser
  binding for a default owned exclusively by Chromium.
- Conflict detection compares `menuKeyEquivalent`, because representationally
  different keys can execute as the same AppKit shortcut.
- The inventory includes configurable commands without defaults, overrides,
  actual menu items, and the Framework's `shortcutBindings` snapshot. Chromium
  reads its actual hidden and delayed tables; Phi does not duplicate those keys.
  Each command's effective aliases participate in both directions of a conflict.
- Conflict scopes distinguish browser, Peek and non-browser contexts. Close Tab
  applies only in browser/Peek contexts. When Chromium's stable Close Tab row
  temporarily executes the default Close Window action in a non-browser window,
  the inventory retains Close Window as its actual owner with a non-browser-only
  scope. It stays discoverable and conflicts with app-wide bindings, without
  falsely conflicting with the browser's default Close Tab. Explicit overlapping
  custom close bindings still conflict in both directions.
  Peek expansion uses its own inventory scope even when the
  overlay is inside a browser window. Its collisions with browser-only
  commands are therefore not reported by the current scope model.
- Standard macOS editing/window services and native selectors remain in the
  conflict inventory but are omitted from settings. Their bindings are never changed by recording another command.
  Quit Phi is fixed to Command-Q and has no customization entry. Its default
  remains in conflict detection; saved custom, disabled, or excluded Quit
  bindings are ignored by native lookup and menu overrides. New Quit override
  requests are ignored without writing preferences.
  Use Selection for Find and Jump to Selection are editable exceptions in Edit.
  The main-menu hook identifies `copyToFindPboard:` and
  `centerSelectionInVisibleArea:` by action, assigns their existing configuration
  IDs, and applies effective keys on every rebuild. Their native actions and
  targets remain unchanged; disabling clears the key and restoring uses the default.
  AppKit can expose an empty `keyEquivalent` for a live menu item whose key is
  also assigned elsewhere. For empty keys, inventory collection checks a
  detached copy of the item to recover its declared binding and report the
  conflict. Explicitly cleared bindings remain empty in the copy and stay excluded.
  Entries under `NSApp.servicesMenu` that are both hidden and disabled are excluded
  from the snapshot. Independently, `AppController` reserves Command-Shift-A and
  Command-Shift-M (Terminal's man page Services' defaults) for browser use by
  clearing those keys from AppKit Services (`_processRequest:`).
  It handles menu insertion, item changes, menu tracking and main-menu replacement,
  including detached Services copies. Service actions remain available by menu;
  other service keys and the user's system-wide Services preferences are unchanged.
  Chromium menu bindings and hidden accelerators are not suppressed. This policy
  stays in effect when Tab Search or Mail is customized or disabled.
- The Apps section, after View, lists the Apps menu's commands (`PHI_OPEN_CLIPBOARD`,
  `PHI_OPEN_DRIFTER`, `PHI_OPEN_MAIL`) by app name, in `MistApps.all` order, followed
  by New Drifter Chat (`PHI_NEW_DRIFTER_CHAT`), which has no default key.
  An assigned key goes to the Apps menu item, so it works wherever
  that item is enabled.
- The Window section lists Make Primary Window (`PHI_MAKE_PRIMARY_WINDOW`),
  a browser-scoped Window menu command with no default key.
- Force Reload and Move Tab Left/Right are editable in their normal groups.
  Other recognized browser commands are discovered from the runtime inventory,
  available visible menu actions (including actions without a shortcut), and saved
  overrides, including disabled overrides. `Group.discoveredCommands`
  assigns these rows to functional sections without making absent commands visible
  or adding defaults. Tab-group actions belong to Tab; bookmark actions and the
  bookmark-bar toggle belong to Bookmarks. Unclassified commands remain in Other
  Browser Commands. Their default labels come
  from the runtime bindings when Phi has no default; no Chromium key table is
  duplicated. Unknown command IDs remain named read-only owners.
  Assigning a conflicting key preserves all other commands and their aliases.
  Explicitly disabling a command still clears all of its own bindings. Restoring
  defaults clears its override, including exclusions saved by earlier versions.
  The paired Framework must support `excludedKeyEquivalents` to honor those
  existing configurations in menu, hidden, and delayed binding matching.
- Uppercase menu equivalents display Shift explicitly; navigation and function
  keys have readable labels. Presentation does not change execution identity.
- Select Previous/Next Tab use command-specific labels for their shifted bracket
  defaults while conflict detection continues to use `{` and `}`.

## Peek Shortcuts

Peek retains independent bindings in `Shortcuts.Group.peek`, using the shared
shortcut normalization, persistence, recording, and override mechanisms.
`PHI_PEEK_OPEN_IN_SPACE` (90025) defaults to Cmd-O.
The expansion binding invokes Peek's existing Open as Tab action while its
content owns focus in the active window and the omnibox does not eclipse it.
Bindings can be rebound, disabled, and restored independently of ordinary
window commands. Conflict reporting uses the `.peek` scope.

Peek and Reader consume the effective `IDC_CLOSE_TAB` binding only while their
visible content (including docked DevTools) owns focus in the key window. This
closes the overlay and protects its origin tab. Extra modifiers, disabled keys,
and the separate Close Window command retain their normal routing. Plain Escape
also closes the overlay, except while DevTools owns focus; modified Escape is
handled only when explicitly bound. Their navigation, Reader toggle, address-bar,
and Peek expansion checks use the same menu-equivalent matching as dispatch.

`SystemShortcutChordResolver` resolves physical Carbon chords for read-only
macOS system-shortcut conflict detection. It uses the current keyboard layout
and the shared semantic matcher, including shifted punctuation and keypad aliases.
It does not register global shortcuts.

## Chromium Shortcut and Command Dispatch Overview

- Chromium's original menu and shortcut definitions live in:
  - `chrome/browser/ui/cocoa/main_menu_builder.mm`
  - `chrome/browser/ui/cocoa/accelerators_cocoa.mm`
  - `chrome/browser/global_keyboard_shortcuts_mac.mm`
  - `chrome/app/chrome_command_ids.h`
- `Shortcuts.DefaultShortcuts` is Phi's default source for settings and native
  integration. Corresponding Chromium defaults must stay aligned unless a
  command is disabled by policy or included in `productDefaultCommands`.
- Dispatch pipeline:
  - `ChromeCommandDispatcherDelegate::prePerformKeyEquivalent` matches a menu or
    accelerator, executes non-overridable commands, or dispatches to the host.
  - `CommandForKeyEvent()` checks the main menu and then Chromium's synthetic
    hidden shortcuts.
  - A native-selector match has `from_main_menu=true` and `NO_COMMAND`. It must
    reach AppKit's original target/action, not become an IDC command merely
    because its tag is positive. This owner suppresses hidden and delayed
    fallback in post handling and renderer redispatch.
  - Phi's ownership lookup includes disabled menu matches. They return no
    executable command ID and reach AppKit validation. Ordinary enabled-only
    menu lookup and the high/normal extension priority gates remain separate.
  - `postPerformKeyEquivalent` performs additional redispatch work.
- Close-command roles across window contexts:
  - `PhiAppController::updateMenuItemKeyEquivalents` adjusts Close Tab / Close
    Window title, tag, and action before matching.
  - Menu construction assigns stable `phi.closeTab` / `phi.closeWindow`
    identifiers. Lookup never infers command identity from a configured key
    or a tag that has temporarily changed with the window context.
  - With both default close keys, a non-tabbed window still uses Cmd-W to
    close itself. With a custom or disabled close binding, Close Tab is hidden
    and Close Window retains its own configured key. Returning to a tabbed
    browser restores both original command roles without changing either key.
  - Hidden close rows have tag 0 and no action. The native main-menu hook must
    retain them so their original roles can be restored on a window change.

## Phi Integration Points

- Interception and bridging:
  - `phi_command_dispatcher_delegate.mm` calls the Phi bridge's native
    `handleKeyEquivalent` path first. Unhandled events continue through Chromium.
  - `phi_command_handler.mm` calls the native `commandDispatch` path before its
    normal command handling.
- Menu and hidden-shortcut overrides:
  - Under `BUILDFLAG(IS_MAC_PHI)`, main-menu items and Chromium's synthetic
    hidden shortcut items share `PhiApplyKeyEquivalentOverride`, which asks
    `keyEquivalentOverrideForCommand:` for each command override.
  - No override returns `nil` and preserves Chromium's default.
    The separate `IDC_CYCLE_TO_NEXT_TAB/PREV_TAB` pair is an explicit exception:
    Phi always clears it because its Tab Switcher owns Ctrl-Tab navigation.
    Rebinding or disabling the switcher must not revive another cycling engine.
    The independent `IDC_SELECT_*` commands are also disabled by product policy.
  - An explicit disable returns an empty key equivalent and zero modifiers.
  - An assigned override returns `ShortcutsKey.menuKeyEquivalent`, never the raw
    stored character/modifier pair.
  - Only `keyEquivalent` and the modifier mask are changed. Existing actions and
    targets remain Chromium-owned.
- Main-menu rebuild:
  - `requestRebuildMainMenu` reruns `BuildMainMenu` and reapplies custom shortcuts.
  - The same rebuild refreshes cached hidden key equivalents from their defaults
    before applying current overrides, so rebinding, disabling, and restoring a
    shortcut take effect without restarting the browser.
  - `PhiAppController::mainMenuRebuilt` restores the File menu delegate and
    updates the close-menu roles. Before replacement, `mainMenuWillRebuild`
    clears History's old item map and detaches History/Tab delegates and
    observers while their old menus are still installed.
  - After replacement, the existing History/Tab bridge types are recreated
    for the loaded profile/browser when browser access is allowed. Tab
    restoration prefers the controller's current browser, including a hosted
    presentation, over a separate collection's last-active window.
  - Bookmarks remain owned by the native main-menu observer, which reattaches
    its delegate and rebuilds its contents when the main menu changes.
- Native-menu synchronization:
  - `Shortcuts.updateShortcut(for:)` projects both an effective override and the
    corresponding Phi default, and clears commands disabled by product policy.
    Other menu items outside `DefaultShortcuts` are left unchanged.
  - The native Bookmarks builder applies effective bindings to Bookmark This
    Tab, Bookmark All Tabs, and Manage Bookmarks whenever it repopulates the menu.
    Customization and disablement preserve each item's native action and target.
- Hidden-shortcut boundary:
  - For retained commands, a custom binding replaces every hidden alias, including
    keypad bindings. An explicit disable clears every alias; removing the override
    restores the product default. An exclusion record removes only matching aliases.
  - Tab selection, tab movement and Back/Forward are disabled by product policy.
    Their hidden and delayed WebContents-only aliases stay suppressed, including
    with saved overrides and after restoring defaults.
  - A native Phi command that conflicts with a hidden Chromium accelerator must
    still match in the pre-dispatch interceptor unless that Chromium command's
    binding was changed or disabled. An unhandled event continues to the hidden
    Chromium lookup.

Restore All requires a confirmation alert explaining that custom shortcuts will
be removed and the action cannot be undone. Cancelling leaves the configuration
unchanged; confirming uses the existing atomic reset and recovery path.

## Persistence and Compatibility

`CustomShortcuts.json` represents four states:

- No command entry: use the default shortcut.
- Entry with a null key and no exclusions: explicitly disabled.
- Entry with a key: custom override.
- Entry with `excludedKeys` and a null key: inherit defaults except those keys.

In memory these are absence, `ShortcutOverride.disabled`, `.custom(key)`, and
`.excluding(keys)`. Existing custom/disabled records keep their original format.
Older clients interpret an exclusion record as a full disable, so using this
configuration with an older client does not retain the partial-default behavior.
The store writes a candidate before replacing its in-memory value; a failed
write leaves the previous runtime bindings and file intact. Unknown command IDs
survive unrelated edits. Legacy records with an omitted key also mean disabled.

Missing files use defaults. Read errors, malformed JSON, and duplicate command
records block edits instead of silently becoming an empty configuration.
Same-account loading failures retain the last valid in-memory state; switching
accounts first clears the previous account's overrides. Explicit recovery copies
the original file to a unique recovery path before saving defaults. Failed
backup or reset writes preserve the original contents.

The file is decoded exactly as stored. Phi does not migrate a legacy character
during load because persisted data contains neither the original physical key
code nor the input-source identity needed for a reliable conversion.

New recordings use the current canonical form. Legacy lookup can preserve native
execution for an existing non-Latin intercepted-command override when the
canonical key is unassigned, but it does not guarantee Latin display,
cross-layout execution, or compatibility for ordinary Chromium commands.
Legacy records also cannot be assigned a reliable Latin alias during static
conflict reporting: the JSON has no original key code or input-source metadata.
Re-recording the shortcut persists the current canonical identity and restores
normal conflict comparison without guessing at old data.

## Key Files

- Native identity, recording, persistence, and conflict reporting:
  - `Sources/UserInterface/Preferences/Shortcuts/Shortcuts.swift`
  - `Sources/UserInterface/Preferences/Shortcuts/Shortcuts+Custom.swift`
  - `Sources/UserInterface/Preferences/Shortcuts/ShortcutConfiguration.swift`
  - `Sources/UserInterface/Preferences/Shortcuts/ShortcutInventory.swift`
  - `Sources/UserInterface/Preferences/Shortcuts/ShortcutsSettingsView.swift`
  - `Sources/UserInterface/Preferences/Shortcuts/ShortcutsViewModel.swift`
  - `Sources/CommandDispatcher/CommandDispatcher.swift`
  - `Sources/ChromiumBridge/PhiChromiumCoordinator.swift`
- Chromium bridge and interception:
  - `chrome/browser/phinomenon/phi_app_bridge/PhiChromiumBridge.h|.mm`
  - `chrome/browser/phinomenon/phi_app_bridge/phi_command_dispatcher_delegate.mm`
  - `chrome/browser/phinomenon/phi_app_bridge/phi_command_handler.mm`
- Chromium menu and matching:
  - `chrome/browser/ui/cocoa/main_menu_builder.mm`
  - `ui/base/cocoa/nsmenuitem_additions.mm`
  - `chrome/browser/global_keyboard_shortcuts_mac.mm`
  - `chrome/app/chrome_command_ids.h`
- Cmd-W / close-window dispatch:
  - `chrome/browser/phinomenon/phi_app_bridge/phi_app_controller_mac.mm`
- Related Chromium documentation:
  - `docs/mac/about_hotkeys_and_keycodes.md` in the Chromium source tree.
- Representative tests:
  - `Tests/PhiBrowserTests/PhiBrowserTests.swift`
  - `Tests/PhiBrowserTests/ShortcutConfigurationTests.swift`
  - `Tests/PhiBrowserTests/ShortcutInventoryTests.swift`
  - `Tests/PhiBrowserTests/ShortcutInventoryIntegrationTests.swift`
  - `Tests/PhiBrowserTests/ShortcutSettingsPersistenceTests.swift`
  - `Tests/PhiBrowserTests/ShortcutNativeMenuIntegrationTests.swift`
  - `Tests/PhiBrowserUITests/ShortcutSettingsUITests.swift`
  - `Tests/PhiBrowserUITests/ShortcutMenuOwnershipUITests.swift`
  - `Tests/PhiBrowserUITests/ShortcutUITestEnvironment.swift`

## Native Chat Commands

`PHI_NEW_CONVERSATION` (raw value `90004`, no keyboard binding) starts a new
native chat in the focused page's Chat panel. The View-menu action
`newConversation(_:)` calls that page controller's `newPanelChat()`.

`PHI_SWITCH_CHAT_PANEL_AND_TAB` (⇧⌘F) switches from the focused chat tab to its
mounted Chat panel, or from the focused tab's open Chat panel to the chat's tab;
it is disabled otherwise, regardless of keyboard focus.

`PHI_CLOSE_PANEL_CHAT` (⇧⌘E, View ▸ Close Chat) runs the Chat panel header's
Close Chat on the focused tab's open panel while it shows a chat; otherwise the
key stays with the page.

## Start Page Commands

`PHI_SET_START_PAGE` (⇧⌘S) and `PHI_RETURN_TO_START_PAGE` (⇧⌘H) are Tab menu
items acting on the focused tab's in-memory group start page, the same as the
tab context menu's Set Current Page as Start Page and the sidebar icon's return
arrow. They apply only in sidebar layouts and only when the action can run;
otherwise the key stays with the page.

## Unpin and Close

`PHI_UNPIN_AND_CLOSE_TAB` (⌥⌘W) is a Tab menu item, in every layout, acting on
the focused tab: a pinned tab closes and loses its pin, like the pinned tab
context menu's Unpin and Close, where ⌘W keeps the pin; any other tab just
closes.

## Product Defaults and User Overrides

Mist supplies these defaults before user overrides are applied. The Framework
omits conflicting aliases for Mist's native commands; the override bridge
exports the differing defaults for Chromium commands:

| Phi action | Product key | Replaced Chromium default |
| --- | --- | --- |
| Copy URL | Command-Shift-C | Inspect alias; Inspect's other key is disabled |
| Toggle Sidebar | Command-S | Save Page |
| Toggle Chat Panel | Command-E | Use Selection for Find (disabled) |
| Switch Between Chat Panel and Tab | Command-Shift-F | Always Show Toolbar in Full Screen (disabled) |
| Close Chat (Chat panel) | Command-Shift-E | None |
| Set Current Page as Start Page | Command-Shift-S | None |
| Return to Start Page | Command-Shift-H | Home (disabled) |
| Unpin and Close | Command-Option-W | None |
| Choose Model (focused Drifter composer) | Command-M | Minimize (disabled) |
| Choose Effort (focused Drifter composer) | Command-period | Stop (disabled) |
| Open DevTools | Command-Shift-I | Option-Command-I |
| Alternate New Tab | Command-Shift-L | None |
| Zoom In | Command-equals | Command-plus |
| Duplicate Tab | Command-Y | No Chromium default; History is disabled |
| Drifter (Apps menu) | Command-Shift-D | Bookmark All Tabs (disabled) |
| Mail (Apps menu) | Command-Shift-M | Profile menu (disabled) |

Commands disabled by product policy keep their menu actions without keyboard bindings. This is a product
baseline, not a user disable stored in `CustomShortcuts.json`, and it does not
change when the corresponding Phi action is rebound or disabled. Restoring
defaults therefore never revives an inherited Chromium action on these keys.
Peek-only keys such as Command-O keep their separate contextual behavior.
Save Page remains available as a menu action. Phi's native File-menu hook clears
its keyboard equivalent even if a legacy configuration contains an override;
it has no ordinary settings row without a discovered binding or saved override.

Mist always exports `productDefaultCommands` (Zoom In, Duplicate Tab and Open DevTools) to
Chromium, even without a saved override. These defaults replace every built-in
alias. A custom or disabled user override wins. An exclusion that excludes the
product default exports a disable; any other exclusion inherits Mist's default,
so it exports the product default rather than Chromium's built-in key.
Restoring defaults exports Command-equals, Command-Y and Command-Shift-I again.

The existing override bridge still applies explicit user bindings to retained
menu and hidden entries. User-created collisions continue through normal
conflict reporting without automatic reassignment. Do not suppress every Phi-versus-Chromium
conflict or filter these entries only in the settings UI: matching, exported
inventory, menu labels and conflict detection must use the same effective keys.
A matching Framework build is required; an older Framework still exports its
older defaults and settings truthfully reports those collisions.

## Verification Boundaries

Model tests use synthetic `NSEvent` values to cover representative Cyrillic,
Hebrew, Arabic, ASCII-layout, Command-QWERTY, shifted-printable, and Tab cases.
Paired integration tests also select real OS input sources, restore the previous
source, and compare fixture events with the loaded Framework's menu matcher.
This establishes matcher agreement for those fixtures, not physical typing or
IME composition behavior for every input source.

Shift-keypad regression tests cover digits and printable operators, distinct
shifted/unshifted dispatch, configuration reload, menu/bridge round trips, alias
exclusions, Carbon registration, and system-conflict reporting. Paired fixtures
compare the corrected Phi identity with the loaded Framework's existing matcher;
they do not substitute for physical full-keyboard acceptance testing.
The Command-QWERTY fixtures exclude the existing character-projection gaps for
Shift-Keypad-Equals, JIS Keypad-Comma, and Keypad-Enter: Chromium maps the first
through OEM_PLUS, has no JIS keypad-comma mapping, and maps Enter to Return.
Preserving Shift does not resolve those separate layout-specific differences.

Native integration tests exercise the companion dispatcher, close-menu roles,
menu bridge replacement, overlay handlers, and window-scoped Phi actions.
Settings and ownership UI tests isolate file storage with `--user-data-dir`,
but still share Canary's UserDefaults and Keychain. Run these
suites only in a dedicated signed-out test session; never use a personal
signed-in Canary session. They require the explicit
`TEST_RUNNER_PHI_SHORTCUT_GUEST_TESTS=1` environment variable when invoking
`xcodebuild` and otherwise skip before creating or launching the application.
This opt-in acknowledges the environment requirement; it does not add account
isolation. Their input-source preflight requires a directly selected keyboard
layout, such as ABC or U.S., before XCTest synthesizes keys. It reads the active source without changing
system settings. An input method causes an explicit skip, which is not a
shortcut pass; this avoids the test host's input-method restoration interrupting
keyboard tests with System Settings. IME composition needs separate acceptance.

Reader UI cases additionally require the installed Reader extension and a
loopback HTTP server rooted at `Tests/Shortcuts/fixtures`. Pass
`TEST_RUNNER_PHI_SHORTCUT_READER_FIXTURE_URL=http://127.0.0.1:8767/reader-article.html`
to `xcodebuild` to opt in. Without that environment variable they skip before
launching Phi. A file URL does not exercise Reader's HTTP(S) content script.

Chromium C++ test sources are separate from these native tests; compiling the
Framework does not execute that C++ test suite.

## Notes

- Never write a raw stored `ShortcutsKey` directly to an `NSMenuItem`; use
  `menuKeyEquivalent`.
- Do not overwrite original menu actions or targets when applying an override.
- After rebuilding the main menu, retain the stable close-command identifiers
  and hidden rows used by `updateMenuItemKeyEquivalents`.
- To let Cmd-W on non-browser windows fall back to system `performClose:`, return
  unhandled for those windows or remove the Close Tab binding.

### Bookmark bar command ownership

`IDC_SHOW_BOOKMARK_BAR` retains its Chromium command identity and participates in
Bookmarks shortcut settings. Phi replaces the View menu entry with its native action,
using the command's effective binding (default Cmd-Shift-B, custom, or disabled).
Direct browser command dispatch also uses Phi's bookmark bar visibility setting;
The native menu's
existing traditional-layout visibility rule is unchanged.
