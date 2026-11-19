---
name: framework-update
description: Use this skill when Johnny invokes /framework-update, or asks whether upstream has a Chromium or Phi Framework update, or to take one into Mist. Finds upstream's newest framework release, compares it with Mist's, ports the bridge header changes without merging upstream's client, installs it, fixes the rebrand resource IDs, live-checks Dev and commits.
version: 0.3.0
---

# Framework update

`/framework-update`: find upstream's newest Phi Framework (Chromium engine) release and take it into Mist without merging upstream's client: Mist adopts the release's bridge header and ports only what it breaks. Johnny gives no version; find it. If he only asked whether there's an update, stop after step 2 and report.

Paths below are from the repo root. Download into a fresh scratchpad folder, and run Python with `-I`.

## 1. Find the release

- Mist's tag is the one in CLAUDE.md's download line; its Chromium is `plutil -extract CFBundleShortVersionString raw "Frameworks/Phi Framework.framework/Resources/Info.plist"`.
- Upstream's newest: `gh api repos/phibrowser/phibrowser-framework/releases --jq '.[:10][] | "\(.tag_name) \(.published_at)"'`. macOS releases are tagged `mac-vX.Y.Z` (before 2.17.0, `vX.Y.Z`); `win-v*` are Windows, ignore them. Take the newest macOS tag; releases are cumulative, so skip any in between. If it's Mist's version, report that Mist is up to date and stop.
- `git fetch upstream --tags`; its `nightly-latest` "would clobber" error is harmless. The client for `mac-vX.Y.Z` is branch `upstream/release/X.Y.Z`.
- The new Chromium version: download the release's `phi-browser-framework-mac.zip` (`gh api repos/phibrowser/phibrowser-framework/releases/tags/mac-vX.Y.Z --jq '.assets[].browser_download_url'`), list it with `unzip -l`, and `unzip -p` the framework's own `Phi Framework.framework/Versions/<v>/Resources/Info.plist` (helper apps have their own Info.plist).
- Report the tag, its date, Chromium old → new, and the upstream commit count `git log --oneline main..upstream/release/X.Y.Z | wc -l`.

## 2. What needs porting

The framework is built against upstream's client at `upstream/release/X.Y.Z`, and its header is the whole contract. Mist keeps that header, minus the declarations of features Mist deleted.

1. `git diff main...upstream/release/X.Y.Z -- Sources/ChromiumBridge/PhiChromiumBridgeHeader.h`. For each removed or changed line, `rg` Mist for the old selector's Swift name. Old calls into the framework would crash with an unrecognized selector; old callbacks are never called. Also note dictionary keys whose documented names changed in comments (snapshot payloads): the compiler can't see those.
2. Methods added to `PhiChromiumBridgeProtocol` are calls Mist may make; they're harmless. Methods added to protocols Chromium calls into (`PhiChromiumBridgeDelegate`, or any other that Mist's Swift code conforms to) must be guarded:
   ```sh
   python3 -I .claude/skills/framework-update/guards.py "<unzipped>/Phi Framework.framework/Versions/<v>/Phi Framework" <selector>...
   ```
   It reads the binary and prints per selector `checked` (the framework asks `respondsToSelector:` first and falls back), `UNGUARDED` (sent without asking: Mist must implement it) or `never sent`. Pass the full selector (`tabsRemovedSnapshot:windowId:`). For a `checked` selector whose fallback matters, read the check address it prints: `xcrun llvm-objdump --arch=arm64 -d --no-show-raw-insn --start-address=<addr - 0x40> --stop-address=<addr + 0x80> <binary>`.
3. `git diff main...upstream/release/X.Y.Z | grep -E '^[+-].*IDC_[A-Z_]+ *[=:] *[0-9]'` must print nothing.
4. Skim `git log --format='%h %s' main..upstream/release/X.Y.Z -- Sources/ChromiumBridge/` for commits that adapt existing callbacks to new engine behavior, and read any that do.

Report what Mist must port. If Johnny asked only to check, stop here. If a change reworks a feature Mist keeps beyond an adapter (the old client can't be mapped onto the new contract), ask him: port, merge (CLAUDE.md "Syncing with upstream") or drop the feature.

## 3. Install, port and rebrand

1. `./scripts/download_phi_framework.sh --version X.Y.Z`.
2. Bring upstream's header changes onto Mist's:
   ```sh
   git diff $(git merge-base main upstream/release/X.Y.Z) upstream/release/X.Y.Z -- Sources/ChromiumBridge/PhiChromiumBridgeHeader.h | git apply --3way
   ```
   Resolve conflicts by keeping Mist's deletions. Then `git diff upstream/release/X.Y.Z -- Sources/ChromiumBridge/PhiChromiumBridgeHeader.h` must show only declarations of features Mist deleted.
3. `mist/scripts/install.sh --dev --no-launch`. Fix every compile error and every "nearly matches" warning (a renamed callback) by mapping the new API onto Mist's model, the changed dictionary keys from step 2 too. Delete Mist workarounds the new contract makes dead. A required delegate method Mist lacks gets the behavior the header documents for clients without it.
4. Chromium renumbers pak resources between releases, so `rebrand_framework.py` usually fails on a moved ID. Then run
   ```sh
   python3 -I .claude/skills/framework-update/find_ids.py "Frameworks/Phi Framework.framework/Versions/Current/Resources"
   ```
   It matches resources by the original hashes and markers in `mist/scripts/rebrand_framework.py` and prints each constant whose ID moved (`CHANGE`). Update those constants and rebuild. A `NOT FOUND` target changed content: find it per CLAUDE.md "Mist branding".
5. `python3 mist/scripts/test_logos.py`; `test_pak.py` too, with the `brotli` shim from CLAUDE.md on `PYTHONPATH`. Compile the tests (`build-for-testing`, CLAUDE.md "Tests") and run the hosted classes covering what was ported.

## 4. Live check

Run `/live-check` with these scenarios, plus one per ported feature:

1. Dev launches and restores its windows; `chrome://version` reads "Mist <new Chromium>" with the Mist logo; the New Tab Page shows the Mist swirl.
2. Open three tabs, close two, ⌘⇧T: Mist's tab list matches Chromium's after each step, and the reopened tab returns to its old slot.
3. Quit and relaunch Dev: the same tabs restore.

Dev's profile now belongs to the new Chromium: Dev can't go back to the old framework without `install.sh --dev --seed`.

## 5. Commit

- Bump the version in the download lines of CLAUDE.md, README.md and the `sharing-mist-builds` memory's one-liner. Commit in one line, e.g. `Take Phi Framework vX.Y.Z (Chromium N), porting its bridge header without the upstream merge`.
- Install main (`mist/scripts/install.sh`) only when Johnny asks: main's profile can't go back either.
- Move the downloaded zip to `~/Downloads/Phi.Framework-vX.Y.Z.zip` for Johnny to upload to Drive's `Mist Frameworks` folder (CLAUDE.md: keep every version's zip).
