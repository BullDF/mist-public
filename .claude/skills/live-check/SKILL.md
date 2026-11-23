---
name: live-check
description: Use this skill when Johnny invokes /live-check [what] (an issue number, a commit range or a description), or asks to verify, check or test a Mist change live in the running app, and whenever an orchestrated worker verifies its task. Installs Mist Dev, briefly checks that the change works through the least intrusive driving route, restores Dev and reports pass or fail per scenario.
version: 0.3.0
---

# Live check

`/live-check [what]`: prove a Mist change works in the real app, Mist Dev. `what` is an issue number, a commit range or a description; with none, check this session's change, and ask if there isn't one.

**Keep it brief.** A live check only confirms that the feature or fix just made works, and takes minutes, not half an hour. Check the main path the way Johnny uses it. Skip regression sweeps, edge cases, sibling modes, alternate input methods and extra screenshots unless the change is about them or the brief names them.

The how-to lives in CLAUDE.md's "Driving the running app" section and in `reference.md` next to this file (capturing, posting input, menus, tabs and Spaces, agent chats, timing). Read the reference's section before using one of its techniques.

## Hard rules

1. **Mist Dev only** (`/Applications/Mist Dev.app`, `com.bulldf.mist.dev`). Never launch, quit, script or screenshot-drive main Mist (`com.bulldf.mist`) or official Phi, and never connect a CDP or skill client to either. Never run `install.sh` without `--dev`. Leave main Mist running untouched.
2. **Harmless.**
   - Drifter chats in Dev start in Dev's own home (`<data folder>/MistAgents/Drifter`); a restored-chat fixture's `folder` and raw `claude -p` or Codex probes use only `~/temp/` (or a subfolder).
   - The web is read-only: browse, search and read, but never fill or submit forms, sign in, send email or messages, post, buy or change an account. Slack is the exception: a check may run in Drifter's DM and #drifter-test, per `reference.md`'s Slack section.
   - Any Drifter task you give in Dev is read-only too, outside Dev's home.
3. **Cheap agents.** Drifter chats you run in Dev use Sonnet with low effort on Claude, Terra with low effort on Codex and Gemini 3.8 Flash with low effort on Gemini, unless the check is about a specific model's behavior or capabilities. Set the model and effort in the composer or in `chat.json` before the first message, and restore the defaults you changed.
4. **Never type into another app.** Every posted key or click checks that Dev is frontmost in the same call.
5. **Refocus Ghostty** after every round of driving or screenshots, so Johnny sees progress: `osascript -e 'tell application id "com.mitchellh.ghostty" to activate'`.
6. **Leave Dev as you found it:** theme, language, layout, windows, test tabs, Spaces, chats, defaults, custom shortcuts and Johnny's clipboard.

## Steps

1. **Scenarios.** Before touching Dev, write one to three scenarios as exact steps plus the expected result, done the way Johnny uses the feature: one per behavior the change adds or fixes. Pure logic belongs in tests, and how a native view looks in an offscreen render; check here only what the running app shows.
2. **Pre-flight.**
   - A live check is a real one. When Johnny asks for it, the screen is yours until you report: he won't touch the keyboard or mouse. Bring Dev forward and post input whenever the check needs it, without checking whether he's at the keyboard or asking him to step away.
   - Captures need Screen Recording, which sessions launched from Ghostty have. If your `ps -o ppid=` chain reaches `/Applications/Mist.app` (a session in main Mist's chat), you can't capture: say so and stop.
3. **Install.** Confirm what you're testing with `git log -1` and `git status`, then run `mist/scripts/install.sh --dev`. A normal quit restores Dev's windows. Never add `--seed` unless the task asks: it overwrites Dev's settings and data with main's.
4. **Note what you'll change**, to restore it later: tabs (`osascript -e 'tell application id "com.bulldf.mist.dev" to list tabs scope "all"'`), each defaults key you'll write, `CustomShortcuts.json`, and the clipboard before you paste.
5. **Drive**, preferring routes that need no focus:
   1. AppleScript (`Resources/Phi.sdef`): open, activate, reload and close tabs; create windows.
   2. The phi-browser skill's helpers and raw CDP (`tools/phi-browser-skill/`, `PHI_BUNDLE_ID=com.bulldf.mist.dev`): page content, bookmarks, pinned tabs, Spaces, URL rules.
   3. Files and defaults: `chat.json` chats, `defaults write` (most keys only while Dev is quit), `CustomShortcuts.json`.
   4. Posted input, last: a private-source CGEvent poster or System Events addressed by bundle ID, with the frontmost check.
6. **Evidence.** Capture Dev's window with `screencapture -x -o -l <windowID>` and Read every PNG: passing assertions and log lines have hidden visible breakage before. Check behavior against ground truth too: `chat.json`, the engine's session log, `Phi/PhiLogs/`. Record anything too fast for a screenshot.
7. **Failures.** If your task lets you fix (an orchestrated worker, a "make it work" handover, or Johnny asked), fix, commit, reinstall Dev and rerun every scenario, not only the failed one, until a clean run. Revert temporary tracing and test hooks before any commit. Otherwise report the failure and stop.
8. **Restore** Dev (rule 6), confirm with `list tabs`, refocus Ghostty.
9. **Report** one line per scenario: pass or fail, and what showed it (a screenshot's full absolute path, a log line). For a failure, expected versus observed.

Before you finish, add to `reference.md` only what will save a later check real time or prevent harm: a reusable technique, a trap that cost you a retry, a safety or cleanup rule. Leave out recipes for this one check, AX labels a tree walk shows, and behavior the code or CLAUDE.md already states. One short bullet under its topic; rewrite or delete a stale line rather than add one beside it.

## Orchestrated workers

Johnny is away: where this skill says to ask him, write the question to `$ORCH/<task-id>.question` per `worker-rules.md`. Put screenshots meant for him under `$ORCH/screens/`.
