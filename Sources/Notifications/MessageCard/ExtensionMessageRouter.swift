// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

struct ExtensionMessageContext {
    let type: String
    let payload: String
    let requestId: String
    /// The sender's extension id, or a synthetic id for non-extension origins
    /// ("cdp" for the PhiAgentSpace DevTools tunnel, "debug-extension" for the
    /// debug panel). Empty when the bridge didn't attribute a sender.
    let senderId: String
    /// The authenticated identity of the connecting code agent (signing id or
    /// process name), for a direct `/phi-agent` connection. Empty for the
    /// Chromium tunnel and extension senders. Used to badge the Space with who
    /// is driving it (see `agentSpace.create`).
    let agentName: String
    /// Opaque app-issued identity for one logical external-agent session.
    /// Shared by that agent's reconnecting/sandboxed helpers, distinct from
    /// every other approved agent session. Nil for extensions and the legacy
    /// Chromium message tunnel, which therefore cannot own CDP tasks.
    let driverPrincipalId: String?

    init(type: String, payload: String, requestId: String,
         senderId: String, agentName: String = "", driverPrincipalId: String? = nil) {
        self.type = type
        self.payload = payload
        self.requestId = requestId
        self.senderId = senderId
        self.agentName = agentName
        self.driverPrincipalId = driverPrincipalId
    }
}

typealias ExtensionMessageHandler = (ExtensionMessageContext) -> String?

final class ExtensionMessageRouter {
    static let shared = ExtensionMessageRouter()

    private var handlers: [String: ExtensionMessageHandler] = [:]
    private var configured = false

    func register(type: String, handler: @escaping ExtensionMessageHandler) {
        handlers[type] = handler
    }

    func handle(type: String, payload: String, requestId: String, senderId: String = "",
                agentName: String = "", driverPrincipalId: String? = nil) -> String? {
        guard !type.hasPrefix("agentSpace.") || senderId == "cdp" else {
            return #"{"error":"forbidden"}"#
        }
        configureIfNeeded()
        let context = ExtensionMessageContext(
            type: type, payload: payload, requestId: requestId, senderId: senderId,
            agentName: agentName, driverPrincipalId: driverPrincipalId)
        if let handler = handlers[type] {
            return handler(context)
        }
        if context.type == "getWindowTheme" {
            WindowThemeMessageRouter.shared.handleGetWindowTheme(context)
        }
        return nil
    }

    private func configureIfNeeded() {
        guard !configured else { return }
        configured = true

        // The bridge refuses any single message over 1 MiB, and some replies
        // are legitimately bigger (a reader article with its pictures
        // inlined). A sender splits such a payload into `bridge.chunk`
        // messages; the last one is answered with whatever the original
        // type's handler returns, so the sender sees one round trip.
        register(type: "bridge.chunk") { [weak self] context in
            self?.handleChunk(context) ?? #"{"error":"invalid"}"#
        }

        register(type: "notification") { context in
            NotificationCardManager.shared.handleRequest(context: context)
            return nil
        }

        register(type: "notification.show") { context in
            NotificationCardManager.shared.handleAgentRequest(context: context)
        }

        register(type: "imagePreview") { context in
            ImagePreviewMessageHandler.handle(context)
            return nil  // The handler replies after presentation or validation failure.
        }

        register(type: "showDialog") { context in
            ExtensionDialogManager.shared.handleRequest(context: context)
            return nil
        }

        // Both reader types ack synchronously — the extension's reports are
        // fire-and-forget, and a nil return would leave its sendMessageToApp
        // promise pending until the bridge's 30s timeout rejects it.
        register(type: "reader.offerable") { context in
            ReaderExtensionBridge.handleOfferable(context)
            return "{}"
        }
        register(type: "reader.state") { context in
            ReaderExtensionBridge.handleState(context)
            return "{}"
        }
        register(type: "reader.getStyle") { context in
            return ReaderExtensionBridge.handleGetStyle(context)
        }
        register(type: "reader.setStyle") { context in
            ReaderExtensionBridge.handleSetStyle(context)
            return "{}"
        }
        register(type: "reader.extractResult") { context in
            ReaderExtensionBridge.handleExtractResult(context)
            return "{}"
        }

        register(type: "agentSpace.create") { context in
            AgentSpaceRouter.handleCreate(context: context)
            return nil  // async reply via ExtensionMessaging
        }
        register(type: "agentSpace.list") { context in
            return AgentSpaceRouter.handleList(context: context)
        }
        register(type: "agentSpace.listProfiles") { context in
            return AgentSpaceRouter.handleListProfiles(context: context)
        }
        register(type: "agentSpace.setState") { context in
            return AgentSpaceRouter.handleSetState(context: context)
        }
        register(type: "agentSpace.cursor") { context in
            return AgentSpaceRouter.handleCursor(context: context)
        }
        register(type: "agentSpace.effect") { context in
            return AgentSpaceRouter.handleEffect(context: context)
        }
        register(type: "agentSpace.log") { context in
            return AgentSpaceRouter.handleLog(context: context)
        }
        register(type: "agentSpace.readUserMessages") { context in
            return AgentSpaceRouter.handleReadUserMessages(context: context)
        }
        register(type: "agentSpace.markError") { context in
            return AgentSpaceRouter.handleMarkError(context: context)
        }
        register(type: "agentSpace.complete") { context in
            return AgentSpaceRouter.handleComplete(context: context)
        }
        register(type: "agentSpace.getOwnership") { context in
            return AgentSpaceRouter.handleGetOwnership(context: context)
        }
        register(type: "agentSpace.panelSize") { context in
            return AgentSpaceRouter.handlePanelSize(context: context)
        }
        register(type: "agentSpace.ping") { context in
            return AgentSpaceRouter.handlePing(context: context)
        }
        register(type: "agentSpace.app.info") { context in
            return AgentSpaceRouter.handleAppInfo(context: context)
        }
        register(type: "agentSpace.handoff") { context in
            return AgentSpaceRouter.handleHandoff(context: context)
        }
        register(type: "agentSpace.takeover") { context in
            return AgentSpaceRouter.handleTakeover(context: context)
        }
        register(type: "agentSpace.openTab") { context in
            return AgentSpaceRouter.handleOpenTab(context: context)
        }
        register(type: "agentSpace.readerArticle") { context in
            AgentSpaceRouter.handleReaderArticle(context: context)
        }
        register(type: "agentSpace.readerDocument") { context in
            AgentSpaceRouter.handleReaderDocument(context: context)
        }

        register(type: "agentSpace.captureWindow") { context in
            return AgentSpaceRouter.handleCaptureWindow(context: context)
        }

        // Shadow windows (AgentSpaceRouter+Shadow.swift): invisible background
        // windows with no pip, no transcript and no takeover. Registered as
        // user-space-managed so the whole feature sits behind the same "Agent
        // control" consent as operating the user's Spaces — a user who has not
        // granted agents reach beyond their own visible Spaces must not get
        // invisible ones.
        register(type: "agentSpace.shadow.create") { context in
            AgentSpaceRouter.handleShadowCreate(context: context)
            return nil  // async reply via ExtensionMessaging
        }
        register(type: "agentSpace.shadow.list") { context in
            return AgentSpaceRouter.handleShadowList(context: context)
        }
        register(type: "agentSpace.shadow.openTab") { context in
            return AgentSpaceRouter.handleShadowOpenTab(context: context)
        }
        register(type: "agentSpace.shadow.ping") { context in
            return AgentSpaceRouter.handleShadowPing(context: context)
        }
        register(type: "agentSpace.shadow.close") { context in
            return AgentSpaceRouter.handleShadowClose(context: context)
        }

        // Management surface (AgentSpaceRouter+Management.swift): browser
        // features operated over the same tunnel — Spaces, profiles, URL
        // rules, tab groups, split view, pinned tabs, bookmarks. User-data
        // types register through the "Agent permissions" gate.
        register(type: "agentSpace.spaces.list") { context in
            return AgentSpaceRouter.handleSpacesList(context: context)
        }
        register(type: "agentSpace.spaces.create") { context in
            return AgentSpaceRouter.handleSpacesCreate(context: context)
        }
        register(type: "agentSpace.spaces.update") { context in
            return AgentSpaceRouter.handleSpacesUpdate(context: context)
        }
        register(type: "agentSpace.spaces.delete") { context in
            return AgentSpaceRouter.handleSpacesDelete(context: context)
        }
        register(type: "agentSpace.spaces.listTabs") { context in
            return AgentSpaceRouter.handleSpacesListTabs(context: context)
        }
        register(type: "agentSpace.spaces.openTab") { context in
            return AgentSpaceRouter.handleSpacesOpenTab(context: context)
        }
        register(type: "agentSpace.spaces.wakeTab") { context in
            return AgentSpaceRouter.handleSpacesWakeTab(context: context)
        }
        register(type: "agentSpace.spaces.workingTab") { context in
            AgentSpaceRouter.handleSpacesWorkingTab(context: context)
        }
        register(type: "agentSpace.spaces.readTab") { context in
            AgentSpaceRouter.handleSpacesReadTab(context: context)
        }
        register(type: "agentSpace.spaces.scrolled") { context in
            AgentSpaceRouter.handleSpacesScrolled(context: context)
        }
        register(type: "agentSpace.spaces.screenshot") { context in
            AgentSpaceRouter.handleSpacesScreenshot(context: context)
        }
        register(type: "agentSpace.spaces.exportBookmarks") { AgentSpaceRouter.handleSpacesExportBookmarks(context: $0) }
        register(type: "agentSpace.spaces.record") { AgentSpaceRouter.handleSpacesRecord(context: $0) }
        register(type: "agentSpace.spaces.recordPointer") { AgentSpaceRouter.handleSpacesRecordPointer(context: $0) }
        register(type: "agentSpace.mail.accounts") { AgentSpaceRouter.handleMailAccounts(context: $0) }
        register(type: "agentSpace.mail.list") { AgentSpaceRouter.handleMailList(context: $0) }
        register(type: "agentSpace.mail.search") { AgentSpaceRouter.handleMailSearch(context: $0) }
        register(type: "agentSpace.mail.read") { AgentSpaceRouter.handleMailRead(context: $0) }
        register(type: "agentSpace.mail.draft") { AgentSpaceRouter.handleMailDraft(context: $0) }
        register(type: "agentSpace.mail.send") { AgentSpaceRouter.handleMailSend(context: $0) }
        register(type: "agentSpace.mail.update") { AgentSpaceRouter.handleMailUpdate(context: $0) }
        register(type: "agentSpace.slack.tools") { AgentSpaceRouter.handleSlackTools(context: $0) }
        register(type: "agentSpace.slack.call") { AgentSpaceRouter.handleSlackCall(context: $0) }
        register(type: "agentSpace.tasks.start") { AgentSpaceRouter.handleTasksStart(context: $0) }
        register(type: "agentSpace.tasks.stop") { AgentSpaceRouter.handleTasksStop(context: $0) }
        register(type: "agentSpace.schedules.create") { AgentSpaceRouter.handleScheduleCreate(context: $0) }
        register(type: "agentSpace.schedules.list") { AgentSpaceRouter.handleScheduleList(context: $0) }
        register(type: "agentSpace.schedules.cancel") { AgentSpaceRouter.handleScheduleCancel(context: $0) }
        register(type: "agentSpace.notify") { AgentSpaceRouter.handleNotify(context: $0) }
        register(type: "agentSpace.agents.list") { context in
            AgentSpaceRouter.handleAgentsList(context: context)
        }
        register(type: "agentSpace.agents.mount") { AgentSpaceRouter.handleAgentsMount(context: $0) }
        register(type: "agentSpace.agents.unmount") { AgentSpaceRouter.handleAgentsUnmount(context: $0) }
        register(type: "agentSpace.agents.finish") { AgentSpaceRouter.handleAgentsFinish(context: $0) }
        register(type: "agentSpace.agents.handOff") { AgentSpaceRouter.handleAgentsHandOff(context: $0) }
        register(type: "agentSpace.agents.message") { context in
            AgentSpaceRouter.handleAgentsMessage(context: context)
        }
        register(type: "agentSpace.agents.spawn") { context in
            AgentSpaceRouter.handleAgentsSpawn(context: context)
        }
        register(type: "agentSpace.agents.read") { context in
            AgentSpaceRouter.handleAgentsRead(context: context)
        }
        register(type: "agentSpace.agents.stop") { context in
            AgentSpaceRouter.handleAgentsStop(context: context)
        }
        register(type: "agentSpace.agents.close") { context in
            AgentSpaceRouter.handleAgentsClose(context: context)
        }
        register(type: "agentSpace.spaces.activate") { context in
            return AgentSpaceRouter.handleSpacesActivate(context: context)
        }
        register(type: "agentSpace.spaces.focus") { context in
            return AgentSpaceRouter.handleSpacesFocus(context: context)
        }
        register(type: "agentSpace.profiles.create") { context in
            AgentSpaceRouter.handleProfilesCreate(context: context)
            return nil  // async reply via ExtensionMessaging
        }
        register(type: "agentSpace.profiles.rename") { context in
            AgentSpaceRouter.handleProfilesRename(context: context)
            return nil  // async reply via ExtensionMessaging
        }
        register(type: "agentSpace.urlRules.list") { context in
            return AgentSpaceRouter.handleUrlRulesList(context: context)
        }
        register(type: "agentSpace.urlRules.add") { context in
            AgentSpaceRouter.handleUrlRulesAdd(context: context)
            return nil  // async reply via ExtensionMessaging
        }
        register(type: "agentSpace.urlRules.update") { context in
            AgentSpaceRouter.handleUrlRulesUpdate(context: context)
            return nil  // async reply via ExtensionMessaging
        }
        register(type: "agentSpace.urlRules.delete") { context in
            AgentSpaceRouter.handleUrlRulesDelete(context: context)
            return nil  // async reply via ExtensionMessaging
        }
        register(type: "agentSpace.tabGroups.list") { context in
            return AgentSpaceRouter.handleTabGroupsList(context: context)
        }
        register(type: "agentSpace.tabGroups.create") { context in
            return AgentSpaceRouter.handleTabGroupsCreate(context: context)
        }
        register(type: "agentSpace.tabGroups.update") { context in
            return AgentSpaceRouter.handleTabGroupsUpdate(context: context)
        }
        register(type: "agentSpace.tabGroups.addTabs") { context in
            return AgentSpaceRouter.handleTabGroupsAddTabs(context: context)
        }
        register(type: "agentSpace.tabGroups.removeTabs") { context in
            return AgentSpaceRouter.handleTabGroupsRemoveTabs(context: context)
        }
        register(type: "agentSpace.tabGroups.ungroup") { context in
            return AgentSpaceRouter.handleTabGroupsUngroup(context: context)
        }
        register(type: "agentSpace.tabGroups.close") { context in
            return AgentSpaceRouter.handleTabGroupsClose(context: context)
        }
        register(type: "agentSpace.splitView.list") { context in
            return AgentSpaceRouter.handleSplitViewList(context: context)
        }
        register(type: "agentSpace.splitView.create") { context in
            return AgentSpaceRouter.handleSplitViewCreate(context: context)
        }
        register(type: "agentSpace.splitView.update") { context in
            return AgentSpaceRouter.handleSplitViewUpdate(context: context)
        }
        register(type: "agentSpace.splitView.swap") { context in
            return AgentSpaceRouter.handleSplitViewSwap(context: context)
        }
        register(type: "agentSpace.splitView.remove") { context in
            return AgentSpaceRouter.handleSplitViewRemove(context: context)
        }
        // Downloads are per-profile; the target window (agent task or a user
        // Space via {spaceId}) selects the profile. Gating lives inside
        // withLayoutWindow, so these register plain like the tab-layout ops.
        register(type: "agentSpace.downloads.list") { context in
            return AgentSpaceRouter.handleDownloadsList(context: context)
        }
        register(type: "agentSpace.history.search") { AgentSpaceRouter.handleHistorySearch(context: $0) }
        register(type: "agentSpace.downloads.get") { context in
            return AgentSpaceRouter.handleDownloadsGet(context: context)
        }
        register(type: "agentSpace.downloads.pause") { context in
            return AgentSpaceRouter.handleDownloadsPause(context: context)
        }
        register(type: "agentSpace.downloads.resume") { context in
            return AgentSpaceRouter.handleDownloadsResume(context: context)
        }
        register(type: "agentSpace.downloads.cancel") { context in
            return AgentSpaceRouter.handleDownloadsCancel(context: context)
        }
        register(type: "agentSpace.downloads.remove") { context in
            return AgentSpaceRouter.handleDownloadsRemove(context: context)
        }
        register(type: "agentSpace.pinnedTabs.list") { context in
            return AgentSpaceRouter.handlePinnedTabsList(context: context)
        }
        register(type: "agentSpace.pinnedTabs.add") { context in
            return AgentSpaceRouter.handlePinnedTabsAdd(context: context)
        }
        register(type: "agentSpace.pinnedTabs.update") { context in
            return AgentSpaceRouter.handlePinnedTabsUpdate(context: context)
        }
        register(type: "agentSpace.pinnedTabs.remove") { context in
            return AgentSpaceRouter.handlePinnedTabsRemove(context: context)
        }
        register(type: "agentSpace.bookmarks.list") { context in
            return AgentSpaceRouter.handleBookmarksList(context: context)
        }
        register(type: "agentSpace.bookmarks.add") { context in
            return AgentSpaceRouter.handleBookmarksAdd(context: context)
        }
        register(type: "agentSpace.bookmarks.addFolder") { context in
            return AgentSpaceRouter.handleBookmarksAddFolder(context: context)
        }
        register(type: "agentSpace.bookmarks.update") { context in
            return AgentSpaceRouter.handleBookmarksUpdate(context: context)
        }
        register(type: "agentSpace.bookmarks.move") { context in
            return AgentSpaceRouter.handleBookmarksMove(context: context)
        }
        register(type: "agentSpace.bookmarks.remove") { context in
            return AgentSpaceRouter.handleBookmarksRemove(context: context)
        }

    }

    // MARK: - Chunked messages

    /// One `bridge.chunk`: piece `seq` of `total` for message `id`, carrying
    /// a base64 slice of the original payload's UTF-8 bytes.
    private struct ChunkPayload: Decodable {
        let id: String
        let seq: Int
        let total: Int
        let type: String
        let data: String
    }

    private struct PendingChunks {
        var type: String
        var parts: [Data?]
        var touched: Date
    }

    /// Bounds on a reassembly: 64 pieces of at most 1 MiB is far above any
    /// article, and a sender that never finishes is swept after a minute.
    private static let maxChunks = 64
    private static let maxChunkBytes = 1024 * 1024
    private static let chunkIdleTimeout: TimeInterval = 60

    private var pendingChunks: [String: PendingChunks] = [:]

    private func handleChunk(_ context: ExtensionMessageContext) -> String? {
        guard let data = context.payload.data(using: .utf8),
              let chunk = try? JSONDecoder().decode(ChunkPayload.self, from: data),
              chunk.total >= 1, chunk.total <= Self.maxChunks,
              chunk.seq >= 0, chunk.seq < chunk.total,
              chunk.data.utf8.count <= Self.maxChunkBytes,
              let bytes = Data(base64Encoded: chunk.data) else {
            return #"{"error":"invalid"}"#
        }
        let now = Date()
        pendingChunks = pendingChunks.filter {
            now.timeIntervalSince($0.value.touched) < Self.chunkIdleTimeout
        }
        var pending = pendingChunks[chunk.id]
            ?? PendingChunks(type: chunk.type,
                             parts: Array(repeating: nil, count: chunk.total),
                             touched: now)
        guard pending.type == chunk.type, pending.parts.count == chunk.total else {
            pendingChunks.removeValue(forKey: chunk.id)
            return #"{"error":"invalid"}"#
        }
        pending.parts[chunk.seq] = bytes
        pending.touched = now
        if pending.parts.contains(where: { $0 == nil }) {
            pendingChunks[chunk.id] = pending
            return #"{"ok":true}"#
        }
        pendingChunks.removeValue(forKey: chunk.id)
        var joined = Data()
        for part in pending.parts { joined.append(part ?? Data()) }
        guard let payload = String(data: joined, encoding: .utf8) else {
            return #"{"error":"invalid"}"#
        }
        // Dispatched under the last chunk's request id, so the handler's
        // reply — sync here, or async through ExtensionMessaging — answers
        // the sender's final send.
        return handle(type: chunk.type, payload: payload,
                      requestId: context.requestId, senderId: context.senderId,
                      agentName: context.agentName,
                      driverPrincipalId: context.driverPrincipalId)
    }
}
