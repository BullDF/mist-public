<p align="center"><img src="mist/brand/logo.png" alt="Mist" width="128"></p>

# Mist

Mist is a personal macOS browser, forked from [Phi Browser](https://github.com/phibrowser/phibrowser-mac) and tailored to how I browse and work with coding agents. It keeps Phi's Chromium engine and native AppKit and SwiftUI client, replaces Phi's AI with Drifter, a native agent chat that runs Claude Code, Codex and Gemini CLI, adds native Mail and Clipboard apps, and trims features I don't use.

## Mist apps

Drifter, Mail and Clipboard are built-in apps that open as ordinary tabs, so they pin, group and move like any page. They open from the Apps menu, the New Tab page's app tiles, Tab Search (⇧⌘A) and the address bar, which suggests an app as you type its name. Their native pages share one design kit, tinted with the Space's theme color.

### Drifter

- **Home.** ⇧⌘D opens Drifter's home page: a composer that starts a chat in a new tab, every ongoing chat with its live status (working, needs you, running in background), scheduled prompts, and a searchable history of past chats.
- **One agent, three engines.** Each chat runs Claude Code (`claude`), Codex (`codex app-server`) or Gemini CLI (`gemini --acp`), picked by the model in its composer, with an effort level and a confirmation mode. Every chat gets Mist's own MCP server, `mistbrowser`, which drives tabs, reads and writes mail, works in Slack and talks to other chats; a Mist feature is added there once and every engine and model gets it.
- **Browser work.** Tabs a chat opens go into a tab group under its chat in the sidebar and close 5 minutes after the agent last used them; a page I already have open is reused instead of opened again. Each tab the agent works or reads shows as a preview card beside the transcript, and it can record the tab it works to an MP4 with its pointer and clicks drawn in.
- **Chats that work together.** A chat can spawn child chats, up to three levels deep, which open as background tabs in its group and report back when their turns end. Any chat can list, read and message the others.
- **Chat panel.** Every tab has its own Chat panel that starts a chat with the tab already mentioned. A chat moves between its full tab and a panel (Show in Chat Panel, Mount to Tab, Unmount from Tab, or ⇧⌘F to switch), and both share one draft. An agent can mount its own chat to a tab too.
- **Composer.** `@` mentions open tabs and tab groups, `/` completes commands and skills, fenced code blocks edit in place, and images and files attach. Messages sent while the agent works queue up and stay editable, and ⌃Return sends one right away.
- **Transcript.** Native markdown with tables, code blocks and LaTeX math; grouped tool rows with readable summaries; permission, question and plan-approval cards; background tasks and context usage; named markers to jump between; find (⌘F) and text zoom (⌘= / ⌘−). Selecting text copies it on release, like a terminal. `/context`, `/model`, `/effort`, `/compact`, `/mcp` and `/clear` render as native rows.
- **Hand-offs and background work.** An agent hands me a step it can't do (a sign-in, 2FA, a CAPTCHA) with a Done card and waits. Long commands run in the background and wake the chat when they finish, on every engine.
- **Schedules and notifications.** An agent can schedule a prompt once or on a cron, to run in its own chat or start a fresh one; schedules survive relaunches, and a run missed while the Mac slept runs late. Agents can also post a macOS notification that opens their chat.
- **Memory and skills.** Chats start in Drifter's home folder (my agent-memory repo when it's there, otherwise a folder in Mist's app data), whose `memory/` and `skills/` both engines share, along with the skills of any repo a chat works in. They also load every MCP server and claude.ai connector the CLIs load, and Claude chats turn on Remote Control, so I can follow and answer them from claude.ai.
- **Chats persist.** They save as they run and resume their session when their tab comes back, across relaunches too. The sidebar lists them under Drifter, and the History menu lists recent ones.
- **Drifter in Slack.** With a Slack app's tokens in Settings ▸ Slack, chats get Slack's own MCP tools, and Drifter answers me in its DM and in channel threads where I mention it. Each thread is one chat in a background tab, with Slack's working status, buttons for permission cards and questions, and a leading model name (`sonnet`, `fable 5.1 high`) to pick the model.
- **External agents** such as Codex or Claude Code can also drive the browser over the agent CDP socket (Settings ▸ Advanced ▸ Allow agents to control Mist), each in its own agent Space.

### Mail

- **A native mail client** (⇧⌘M) for plain IMAP/SMTP accounts with passwords (a Gmail app password works): three panes, All Inboxes, All Sent, All Trash and All Junk across accounts, search, Mark All as Read, notifications for new mail, and unread counts on its pinned tab. ⌘Z and ⇧⌘Z undo and redo message actions such as delete, archive, move and mark read.
- **Rich-text compose** opens inline in a pane, not a window, with fonts, colors, attachments and a rich-text signature per account. Drafts autosave, survive a relaunch, and sync through IMAP.
- **HTML mail** renders with JavaScript off, with find and body zoom, and attachments show as file cards.
- **Accounts sync** between Macs through Mist Sync, passwords and signatures included.
- **Drifter** can search, read, draft and send mail with the account's signature, and mark, flag, archive, move or trash messages. Sending always asks with a card, and agents can never delete mail permanently.

### Clipboard

Shares one item, text, an image or a file up to 10 MB, between my Macs through Mist Sync, end-to-end encrypted. Drop, paste (⌘V) or choose a file, then send it: it replaces the item on every Mac and expires 5 minutes later. Text and images copy or drag out; files download to Downloads. Settings ▸ Sync turns sharing off per Mac.

## How it differs from Phi

- **Rebranded.** Bundle ID `com.bulldf.mist`, Mist name and logo throughout, including Chromium's own menus, New Tab page, and WebUI pages.
- **No Phi services.** Built from the open-source configuration: no Phi account, Phi AI, auto-updates, telemetry, or crash uploads, and Chromium runs sandboxed.
- **Mist Sync.** Passwords, profiles, Spaces, bookmarks, and mail accounts sync between Macs through a small Cloudflare Worker relay (`mist/sync-server/`), which also carries the shared clipboard. Records are encrypted on the Mac with a key carried in the pairing code (Settings ▸ Sync), so the relay only stores ciphertext.
- **Native New Tab page.** Normal and incognito new tabs open a native search composer with address-bar suggestions, and the Mist apps' tiles below it. Enter on an open-tab match switches to that tab; hold ⌘ to open a new one instead. Alternate New Tab (⇧⌘L) opens the omnibox instead, or the page if New Tab is set to the omnibox.
- **Address bar.** Searches always use the default engine (Google or Bing), with search suggestions fetched natively and calculator and unit-conversion answers as a copy row. Bookmarks and already-open pages come first, then past searches, suggestions, and browsing history ranked by Mist's own history search. Site search ("Tab to search") is removed.
- **Markdown reader.** Local and web `.md` files open in a native reader with find and zoom, and local files reload when they change.
- **Tab Search (⇧⌘A)** also searches browsing history and the Mist apps, and lists bookmarks before open tabs.
- **Bookmarks.** Sidebar bookmarks show as flat rows at the top of the tab list under a collapsible Bookmarks header. They always open as normal tabs, and they're mirrored into Chromium so the address bar's bookmark suggestions match.
- **Tabs.** Any tab can be renamed inline, and its name survives moves, reopening, and relaunch. Tabs opened from links always go to the end of the tab list. Clicking a tab group collapses or expands it instead of opening an overview page. Tabs, selections, and groups move to a new or another window from their context menus, and a reopened tab returns to its old place in its group. A grouped tab remembers the page it joined with and offers a one-click way back once it wanders off (⇧⌘H, with ⇧⌘S to make the current page its start page). Unpin and Close (⌥⌘W) closes a pinned tab and drops its pin. Links from other apps open in the window you make primary. The ⌃Tab switcher lists every tab, and crashed tabs are flagged in the tab list.
- **Shortcuts.** Unused default shortcuts, Chromium's ⌃⌘ tab group keys among them, are dropped, and Developer Tools moves to ⇧⌘I; every app opens from an assignable command in Settings ▸ Shortcuts.
- **Native password manager** under Settings ▸ Passwords, with save prompts, login-field autofill, saved email addresses for sign-up fields, and verification codes filled straight from Mail, since `chrome://password-manager` and the iCloud Passwords extension don't work in a self-signed build.
- **Downloads.** The downloads popover has a Clear button that removes finished downloads from the list; the files stay on disk.
- **Removed:** Phi's AI panel and settings, extension controls in the window chrome, the profile button, Kiosk windows and Open in Kiosk (external links open as normal tabs), Folio (save for later), importing from Arc, Dia, and Zen along with the migration wizard, Phi's Account, Sync and Developer settings panes, Bitwarden, Report an Issue, short highlight links, the offline-page games, Chromium's form autocomplete, and the Spanish, Dutch and Korean localizations.

## Build and install

There are no prebuilt releases: Mist is built from source. Requirements: an Apple Silicon Mac on macOS 15 or later and Xcode 27.1. Drifter needs the Claude Code CLI for Claude models and the Codex CLI for GPT models, each signed in, and Gemini CLI with a `GEMINI_API_KEY` in the `.env` of Drifter's home folder (`~/Library/Application Support/com.bulldf.mist/MistAgents/Drifter/`) for Gemini models.

```sh
./scripts/download_phi_framework.sh --version v2.18.0  # Chromium framework from Phi's releases into Frameworks/
mist/scripts/install.sh                                # build, install and launch /Applications/Mist.app
mist/scripts/install.sh --dev                          # or a separate Mist Dev.app with its own settings and data
```

Sync needs your own relay: deploy `mist/sync-server/` to a free Cloudflare account ([instructions](mist/sync-server/README.md)). Drifter in Slack needs your own Slack app's tokens.

The app builds with the `PhiBrowser-OpenSource` scheme. Fork-owned branding, scripts, and the sync relay live in `mist/`. Development notes, tests, and the upstream sync process are in [CLAUDE.md](CLAUDE.md), written for the coding agents that do most of the work here.

## Contributing

Mist is a personal tool shaped around how I work, so I'm not accepting pull requests. Sorry! Forking is very welcome, though: take it and make it yours.

## License

Apache License 2.0, see [LICENSE](LICENSE). Mist is based on the Phi Browser macOS client by Phinomenon Inc. The Chromium engine ships as `Phi Framework.framework`, Phinomenon's proprietary prebuilt binary, which this license doesn't cover. Third-party components are listed in the app's credits page and at `chrome://credits`.
