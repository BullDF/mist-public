import Foundation
import XCTest
#if !MIST_CLAUDE_CODE_HOSTLESS_TESTS
@testable import Phi
#endif

final class AgentChatStoreTests: XCTestCase {
    @MainActor func testFollowUpRefusesOnlyPendingPlainPermissions() {
        let conversation = AgentConversation()
        let requests: [AgentChatItem.PermissionRequest] = [
            .init(requestId: "plain", toolName: "Bash", summary: "pwd"),
            .init(requestId: "question", toolName: "AskUserQuestion", summary: "Choose", input: .object([
                "questions": .array([.object(["question": .string("Which?")])])])),
            .init(requestId: "plan", toolName: "ExitPlanMode", summary: "Plan"),
            .init(requestId: "allowed", toolName: "Bash", summary: "pwd", status: .allowed),
            .init(requestId: "denied", toolName: "Bash", summary: "pwd", status: .denied),
            .init(requestId: "second", toolName: "mcp__mistbrowser__slack_send_message", summary: "Message")
        ]
        conversation.update(items: requests.map { .init(id: $0.requestId, kind: .permissionRequest($0)) }
            + [.init(id: "reply", kind: .assistantText(text: "Hello", isStreaming: false))], status: .awaitingPermission)
        var decisions: [(String, AgentPermissionResponse)] = []
        defer { conversation.onPermissionDecision = nil }
        conversation.onPermissionDecision = { id, response in
            decisions.append((id, response))
            // A decision republishes the transcript while the collected requests are still being refused.
            conversation.update(items: [], status: .running)
        }
        conversation.refusePendingPermissions()
        XCTAssertEqual(decisions.map(\.0), ["plain", "second"])
        XCTAssertEqual(decisions.map(\.1), [.deny(message: nil), .deny(message: nil)])
    }

    @MainActor func testEmptyCloseRecreatesBothURLsAndPreservesSibling() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let route = AgentChatRoute(baseDirectory: root)
        let saved = DrifterLaunchSettings(defaults: makeTestDefaults().defaults)
        saved.save(.init(engine: .codex, model: "gpt-6.1-sol", effort: "medium"))
        var reloads = 0
        let store = AgentChatStore(route: route, launchSettings: saved, tabExists: { _ in false }, reloadTab: { _, _ in reloads += 1 })
        defer { store.terminate() }
        let sibling = try store.createEmpty(tabId: 3)
        for legacy in [false, true] {
            let chat = try store.createEmpty(tabId: 1)
            let url = legacy ? route.legacyURL(for: chat.id) : route.canonicalURL(for: chat.id)
            XCTAssertTrue(store.isEmpty(chat.id))
            store.closeIfTabIsGone(1)
            XCTAssertFalse(FileManager.default.fileExists(atPath: route.chatDirectory(for: chat.id).path))
            XCTAssertTrue(route.canRecreate(chat.id))
            XCTAssertTrue(store.recreate(chat.id, tabId: 2, at: url))
            XCTAssertEqual(store.entry(for: chat.id)?.settings.config, saved.config)
            XCTAssertNil(store.entry(for: chat.id)?.settings.lockedEngine)
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
            XCTAssertFalse(store.recreate(chat.id, tabId: 2, at: url))
            store.closeIfTabIsGone(2)
        }
        XCTAssertEqual(reloads, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: route.recordURL(for: sibling.id).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: route.placeholderURL(for: sibling.id).path))
        let missing = UUID()
        try Data().write(to: route.canonicalURL(for: missing))
        XCTAssertFalse(store.recreate(missing, tabId: 4, at: route.canonicalURL(for: missing)))
    }

    @MainActor func testRestoredChatClosedUnshownIsDeletedOnlyWhenEmptyAndNoTabShowsIt() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let route = AgentChatRoute(baseDirectory: root)
        let saved = DrifterLaunchSettings(defaults: makeTestDefaults().defaults)
        let before = AgentChatStore(route: route, launchSettings: saved, tabExists: { _ in true })
        let empty = try before.createEmpty(tabId: 1), reopened = try before.createEmpty(tabId: 2)
        let sent = try before.createEmpty(tabId: 3)
        sent.update(items: [.init(id: "sent", kind: .userMessage(text: "hello", images: []))], status: .idle)
        before.saveRecord(sent.id, synchronously: true)
        before.terminate()
        // After a relaunch the tabs are back but unshown, so the new store holds no entries.
        var shown = [(chatId: reopened.id, tabId: 5)]
        let store = AgentChatStore(route: route, launchSettings: saved, closeDelay: 10_000_000, tabExists: { _ in false },
                                   chatTabs: { shown })
        defer { store.terminate() }
        for chat in [empty, reopened, sent] { store.tabDidClose(9, url: route.placeholderURL(for: chat.id).absoluteString) }
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertFalse(FileManager.default.fileExists(atPath: route.chatDirectory(for: empty.id).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: route.placeholderURL(for: empty.id).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: route.recordURL(for: reopened.id).path), "Another tab still shows it")
        XCTAssertTrue(FileManager.default.fileExists(atPath: route.recordURL(for: sent.id).path), "A chat with messages stays")
        shown = []
    }

    @MainActor func testChatMovesToAnotherTabShowingItAndEmptyGoesWithTheLast() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let route = AgentChatRoute(baseDirectory: root)
        var open: Set<Int> = [1, 2, 3, 4]
        var shown: [(chatId: UUID, tabId: Int)] = []
        let store = AgentChatStore(route: route, launchSettings: .init(defaults: makeTestDefaults().defaults),
                                   tabExists: { open.contains($0) }, chatTabs: { shown.filter { open.contains($0.tabId) } })
        defer { store.terminate() }
        func exists(_ chat: AgentConversation) -> Bool { FileManager.default.fileExists(atPath: route.recordURL(for: chat.id).path) }

        let empty = try store.createEmpty(tabId: 1)
        shown = [(empty.id, 1), (empty.id, 2)]
        open.remove(1)
        store.closeIfTabIsGone(1)
        XCTAssertTrue(store.conversation(for: empty.id) === empty, "The duplicate tab keeps the same chat")
        XCTAssertEqual(store.entry(for: empty.id)?.tabId, 2)
        XCTAssertTrue(exists(empty))
        open.remove(2)
        store.closeIfTabIsGone(2)
        XCTAssertNil(store.conversation(for: empty.id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: route.chatDirectory(for: empty.id).path), "Its last tab closed")

        let sent = try store.createEmpty(tabId: 3)
        sent.update(items: [.init(id: "sent", kind: .userMessage(text: "hello", images: []))], status: .idle)
        shown = [(sent.id, 3), (sent.id, 4)]
        open.remove(3)
        store.closeIfTabIsGone(3)
        XCTAssertTrue(store.conversation(for: sent.id) === sent)
        XCTAssertEqual(store.entry(for: sent.id)?.tabId, 4)
    }

    @MainActor func testEmptyCloseIgnoresDraftsAndKeepsQueuedReceivedSentAndQuit() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let route = AgentChatRoute(baseDirectory: root)
        let saved = DrifterLaunchSettings(defaults: makeTestDefaults().defaults)
        let store = AgentChatStore(route: route, launchSettings: saved, tabExists: { $0 == 100 })
        // The composer never keeps a chat: a draft, its host-tab mention or its attachments go with it.
        let mention = AgentTabMention(tabId: 100, title: "Host", url: "https://example.com", range: NSRange(location: 0, length: 5))
        for (kind, draft) in [AgentComposerDraft(text: " "), AgentComposerDraft(text: "@Host ", mentions: [mention]),
                              AgentComposerDraft(attachments: [.file(.init(url: root.appendingPathComponent("draft.txt")))])].enumerated() {
            let chat = try store.createEmpty(tabId: 10 + kind)
            chat.setDraft(draft)
            XCTAssertTrue(store.isEmpty(chat.id))
            store.saveRecord(chat.id, synchronously: true)
            store.closeIfTabIsGone(10 + kind)
            XCTAssertFalse(FileManager.default.fileExists(atPath: route.chatDirectory(for: chat.id).path))
        }
        for kind in 2..<5 {
            let chat = try store.createEmpty(tabId: kind)
            switch kind {
            case 2:
                var queue = AgentMessageQueue()
                queue.enqueue(.init(text: "queued"))
                chat.updateQueue(queue)
            case 3: chat.update(items: [.init(id: "peer", kind: .peerMessage(name: "peer", body: "hello"))], status: .dormant)
            default: chat.update(items: [.init(id: "sent", kind: .userMessage(text: "hello", images: []))], status: .idle)
            }
            XCTAssertFalse(store.isEmpty(chat.id))
            store.closeIfTabIsGone(kind)
            XCTAssertTrue(FileManager.default.fileExists(atPath: route.recordURL(for: chat.id).path))
        }
        let chat = try store.createEmpty(tabId: 9)
        store.terminate()
        XCTAssertTrue(FileManager.default.fileExists(atPath: route.placeholderURL(for: chat.id).path))
        let restored = AgentChatStore(route: route, launchSettings: saved, tabExists: { _ in true })
        defer { restored.terminate() }
        XCTAssertTrue(restored.restoreIfNeeded(chat.id, tabId: 9))
        XCTAssertTrue(restored.isEmpty(chat.id))
        XCTAssertNil(restored.entry(for: chat.id)?.settings.lockedEngine)
    }

    @MainActor func testEmptyChatsGoOnceNoTabOrPanelShowsThem() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let route = AgentChatRoute(baseDirectory: root)
        var open: Set<Int> = []
        var requests: [DrifterLaunchRequest] = []
        var openedTabs: [(chatId: UUID, windowId: Int)] = []
        let store = AgentChatStore(route: route, launchSettings: .init(defaults: makeTestDefaults().defaults),
            tabExists: { open.contains($0) }, windowId: { open.contains($0) ? 7 : nil },
            openChatTab: { openedTabs.append(($0, $1)) },
            browserSessionFactory: { request, _, _ in requests.append(request); return FakeSession() })
        func exists(_ chat: AgentConversation) -> Bool { FileManager.default.fileExists(atPath: route.recordURL(for: chat.id).path) }
        /// An empty chat shown in `host`'s panel whose own tab then closes.
        func detached(own: Int, host: Int) throws -> AgentConversation {
            open.formUnion([own, host])
            let chat = try store.createEmpty(tabId: own)
            store.setPanelChat(chat.id, for: host)
            open.remove(own)
            store.closeIfTabIsGone(own)
            XCTAssertNotNil(store.conversation(for: chat.id), "A panel still shows it")
            XCTAssertTrue(exists(chat))
            return chat
        }

        let moved = try detached(own: 1, host: 101)
        store.setPanelChat(nil, for: 101)
        XCTAssertNil(store.conversation(for: moved.id))
        XCTAssertFalse(exists(moved), "The panel moved to a new chat")

        let switched = try detached(own: 2, host: 102)
        let other = try store.createEmpty(tabId: 20)
        open.insert(20)
        store.setPanelChat(other.id, for: 102)
        XCTAssertFalse(exists(switched), "The panel moved to another chat")
        XCTAssertTrue(exists(other))

        let hosted = try detached(own: 3, host: 103)
        open.remove(103)
        store.tabDidClose(103)
        XCTAssertFalse(exists(hosted), "Its panel's host tab closed")

        let mounted = try store.createEmpty(tabId: 4)
        open.formUnion([4, 104])
        XCTAssertTrue(store.mount(mounted.id, to: 104))
        open.remove(4)
        store.closeIfTabIsGone(4)
        XCTAssertTrue(exists(mounted))
        store.unmount(mounted.id)
        XCTAssertFalse(exists(mounted), "Unmount from Tab")

        let ownTab = try store.createEmpty(tabId: 5)
        open.formUnion([5, 105])
        store.setPanelChat(ownTab.id, for: 105)
        store.setPanelChat(nil, for: 105)
        open.remove(105)
        store.tabDidClose(105)
        XCTAssertTrue(exists(ownTab), "Its own tab still shows it")
        open.remove(5)
        store.closeIfTabIsGone(5)
        XCTAssertFalse(exists(ownTab))

        let reopened = try detached(own: 6, host: 106)
        open.insert(60)
        XCTAssertTrue(store.restoreIfNeeded(reopened.id, tabId: 60))
        store.setPanelChat(nil, for: 106)
        XCTAssertTrue(exists(reopened), "A tab shows it again")

        let cleared = try detached(own: 7, host: 107)
        try store.clear(cleared.id)
        XCTAssertFalse(exists(cleared))
        let fresh = try XCTUnwrap(store.panelChat(for: 107))
        store.setPanelChat(nil, for: 107)
        XCTAssertNil(store.conversation(for: fresh), "/clear's fresh chat is shown only by the panel too")

        let launched = try detached(own: 8, host: 108)
        store.restart(launched.id, prompt: "Hello", attachments: [], mentions: [])
        XCTAssertEqual(requests.last?.windowId, 7, "It launches in its panel host's window")
        XCTAssertEqual(openedTabs.map(\.chatId), [launched.id], "Once it runs it gets its own tab")
        XCTAssertEqual(openedTabs.map(\.windowId), [7])
        store.setPanelChat(nil, for: 108)
        XCTAssertNotNil(store.conversation(for: launched.id), "The panel moving on doesn't close it")
        XCTAssertTrue(exists(launched))

        let panelNew = try store.createPanelChat(for: 110)
        XCTAssertFalse(exists(panelNew), "Created while its host tab doesn't exist, nothing shows it")
        open.insert(110)
        let created = try store.createPanelChat(for: 110)
        XCTAssertEqual(store.entry(for: created.id)?.tabId, -1)
        XCTAssertTrue(store.agentChats().contains(created.id))
        XCTAssertEqual(openedTabs.last?.chatId, created.id, "It opens its own tab")
        let pending = try store.createPanelChat(for: 110)
        XCTAssertFalse(exists(created), "The panel moved on before its tab arrived")
        open.insert(111)
        store.assign(pending.id, to: 111)
        let replaced = try store.createPanelChat(for: 110)
        XCTAssertFalse(exists(pending), "The next New Chat closes it with its tab while it's empty")
        XCTAssertTrue(exists(replaced))

        let quit = try detached(own: 9, host: 109)
        let kept = try store.createEmpty(tabId: 90)
        open.insert(90)
        store.terminate()
        XCTAssertFalse(exists(quit), "Panel links don't survive a relaunch")
        XCTAssertFalse(exists(replaced))
        XCTAssertTrue(exists(kept), "Session restore brings back a chat with its own tab")
        XCTAssertTrue(exists(reopened))
    }

    @MainActor func testClosingAChatsTabClosesThePanelShowingIt() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var open: Set<Int> = []
        var shown: [(chatId: UUID, tabId: Int)] = []
        var collapsed: [Int] = []
        let store = AgentChatStore(route: .init(baseDirectory: root), launchSettings: .init(defaults: makeTestDefaults().defaults),
            tabExists: { open.contains($0) }, collapsePanel: { collapsed.append($0) },
            chatTabs: { shown.filter { open.contains($0.tabId) } },
            browserSessionFactory: { _, _, _ in FakeSession() })

        let running = try store.create(request: .init(prompt: "Hello", attachments: [], config: .init(folder: root), windowId: 1), tabId: 1)
        open.formUnion([1, 101])
        store.setPanelChat(running.id, for: 101)
        open.remove(1)
        store.closeIfTabIsGone(1)
        XCTAssertNil(store.conversation(for: running.id))
        XCTAssertEqual(collapsed, [101])

        let empty = try store.createEmpty(tabId: 2)
        open.formUnion([2, 102])
        XCTAssertTrue(store.mount(empty.id, to: 102))
        open.remove(2)
        store.closeIfTabIsGone(2)
        XCTAssertNotNil(store.conversation(for: empty.id), "The closed panel still holds the empty chat")
        XCTAssertEqual(collapsed, [101, 102])

        collapsed = []
        let duplicated = try store.createEmpty(tabId: 3)
        open.formUnion([3, 30, 103])
        shown = [(duplicated.id, 30)]
        store.setPanelChat(duplicated.id, for: 103)
        open.remove(3)
        store.closeIfTabIsGone(3)
        XCTAssertEqual(store.entry(for: duplicated.id)?.tabId, 30)
        XCTAssertEqual(collapsed, [], "Another tab still shows the chat")

        let earlier = try store.createEmpty(tabId: 4)
        let later = try store.createEmpty(tabId: 40)
        open.formUnion([4, 40, 104])
        store.setPanelChat(earlier.id, for: 104)
        store.setPanelChat(later.id, for: 104)
        open.remove(4)
        store.closeIfTabIsGone(4)
        XCTAssertEqual(collapsed, [], "The panel shows another chat")

        try store.clear(later.id)
        XCTAssertEqual(collapsed, [], "/clear keeps the panel on the fresh chat")

        let mounted = try store.createEmpty(tabId: 5)
        open.formUnion([5, 105])
        XCTAssertTrue(store.mount(mounted.id, to: 105))
        store.unmount(mounted.id)
        XCTAssertEqual(collapsed, [105], "Unmount from Tab closes the panel")
        XCTAssertNotNil(store.conversation(for: mounted.id), "The chat keeps running in its own tab")

        collapsed = []
        let replaced = try store.createEmpty(tabId: 6)
        let current = try store.createEmpty(tabId: 60)
        open.formUnion([6, 60, 106])
        store.setPanelChat(replaced.id, for: 106)
        store.setPanelChat(current.id, for: 106)
        store.unmount(replaced.id)
        XCTAssertEqual(collapsed, [], "Unmounting a chat the panel no longer shows keeps the panel")
    }

    @MainActor func testDeletionRefusesUnsafeRecordsAndFolders() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let route = AgentChatRoute(baseDirectory: root)
        let manager = FileManager.default
        let records: [[String: Any]] = [["items": ["message"]], ["items": [], "queued": ["queued"]],
            ["items": [], "sessionId": "session"], ["items": "invalid"]]
        for record in records {
            let id = UUID()
            try manager.createDirectory(at: route.chatDirectory(for: id), withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: record).write(to: route.recordURL(for: id))
            XCTAssertFalse(route.deleteEmptyChat(id))
            XCTAssertTrue(manager.fileExists(atPath: route.recordURL(for: id).path))
        }
        let drafted = UUID()
        try manager.createDirectory(at: route.chatDirectory(for: drafted), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["items": [], "queued": [], "draft": "@Host unsent"]).write(to: route.recordURL(for: drafted))
        XCTAssertTrue(route.deleteEmptyChat(drafted), "A draft never keeps a chat")
        XCTAssertFalse(manager.fileExists(atPath: route.chatDirectory(for: drafted).path))
        let missing = UUID()
        try manager.createDirectory(at: route.chatDirectory(for: missing), withIntermediateDirectories: true)
        XCTAssertFalse(route.deleteEmptyChat(missing))
        let unexpected = UUID()
        try manager.createDirectory(at: route.chatDirectory(for: unexpected), withIntermediateDirectories: true)
        try Data("{\"items\":[]}".utf8).write(to: route.recordURL(for: unexpected))
        try Data().write(to: route.chatDirectory(for: unexpected).appendingPathComponent("keep"))
        XCTAssertFalse(route.deleteEmptyChat(unexpected))
        let link = UUID()
        try manager.createSymbolicLink(at: route.chatDirectory(for: link), withDestinationURL: route.chatDirectory(for: unexpected))
        XCTAssertFalse(route.deleteEmptyChat(link))
        XCTAssertTrue(manager.fileExists(atPath: route.recordURL(for: unexpected).path))
    }

    @MainActor func testEmptySettingsStyleAndLiveRewrite() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var background = "#123456"
        let saved = DrifterLaunchSettings(defaults: makeTestDefaults().defaults)
        let store = AgentChatStore(route: .init(baseDirectory: root), launchSettings: saved,
            placeholderStyle: { .init(background: background, iconPNGBase64: $0.rawValue) },
            tabExists: { $0 == 1 }, windowId: { _ in 1 }, browserSessionFactory: { _, _, _ in FakeSession() })
        defer { store.terminate() }
        let chat = try store.createEmpty(tabId: 1)
        let hidden = try store.createEmpty(tabId: 2)
        let settings = try XCTUnwrap(store.entry(for: chat.id)?.settings)
        XCTAssertTrue(settings.select(engine: .codex, model: "gpt-6.1-sol", effort: "medium"))
        XCTAssertEqual(saved.config.engine, .claude)
        let url = store.route.placeholderURL(for: chat.id)
        let html = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(html.contains("background:#123456"))
        XCTAssertTrue(html.contains("data:image/png;base64,codex"))
        XCTAssertTrue(html.contains("name=\"mist-app\" content=\"drifter\""))
        XCTAssertTrue(html.contains("content=\"drifter codex\""))
        background = "#abcdef"
        store.rewriteLivePlaceholders()
        XCTAssertTrue(try String(contentsOf: url, encoding: .utf8).contains("#abcdef"))
        XCTAssertFalse(try String(contentsOf: store.route.placeholderURL(for: hidden.id), encoding: .utf8).contains("#abcdef"))
        store.restart(chat.id, prompt: "Hello", attachments: [], mentions: [])
        XCTAssertFalse(settings.select(engine: .claude, model: "opus", effort: "xhigh"))
        settings.selectConfirmation(.ask)
        XCTAssertEqual(saved.config.confirmation, .skip)
    }

    @MainActor func testClearDeletesOnlyEmptyAndLegacyWritesStayLegacy() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AgentChatStore(route: .init(baseDirectory: root), launchSettings: .init(defaults: makeTestDefaults().defaults), tabExists: { _ in true })
        defer { store.terminate() }
        let empty = try store.createEmpty(tabId: 1)
        try store.clear(empty.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.route.recordURL(for: empty.id).path))
        let panelChat = try store.createEmpty(tabId: -1)
        store.setPanelChat(panelChat.id, for: 7)
        try store.clear(panelChat.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.route.recordURL(for: panelChat.id).path))
        XCTAssertNotNil(store.panelChat(for: 7).flatMap { store.entry(for: $0) })
        let chat = try store.createEmpty(tabId: 2)
        let route = store.route
        try FileManager.default.createDirectory(at: route.directory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: route.canonicalURL(for: UUID()).deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: route.canonicalURL(for: chat.id), to: route.legacyURL(for: chat.id))
        XCTAssertTrue(try store.updateTitle("Updated", for: chat.id))
        store.rename(chat.id, to: "Renamed", tabId: 2)
        XCTAssertEqual(route.storedTitle(for: chat.id), "Renamed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: route.canonicalURL(for: chat.id).path))
        chat.update(items: [.init(id: "sent", kind: .userMessage(text: "sent", images: []))], status: .idle)
        try store.clear(chat.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: route.recordURL(for: chat.id).path))
    }
    @MainActor func testSavedMarkersAndNamesSurviveRestore() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AgentChatStore(route: .init(baseDirectory: directory), tabExists: { _ in false },
                                   browserSessionFactory: { _, _, _ in FakeSession() })
        defer { store.terminate() }
        let chat = try store.create(request: .init(prompt: "Hi", config: .init(folder: directory), windowId: 1), tabId: 42)
        chat.update(items: [.init(id: "message", kind: .userMessage(text: "Hi", images: []))], status: .idle)
        chat.toggleMarker(itemId: "message", defaultName: "Hi")
        chat.renameMarker(itemId: "message", to: "Remember this")
        store.saveRecord(chat.id, synchronously: true)
        store.closeIfTabIsGone(42)
        XCTAssertTrue(store.restoreIfNeeded(chat.id, tabId: 43))
        XCTAssertEqual(store.conversation(for: chat.id)?.markers, [.init(id: "message", name: "Remember this")])
    }

    @MainActor func testHandOffShowsUntilDoneOrAMessageSurvivesRestoreAndSendsDoneAsJohnny() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AgentChatStore(route: .init(baseDirectory: directory), tabExists: { _ in false },
                                   browserSessionFactory: { _, _, _ in FakeSession() })
        defer { store.terminate() }
        let chat = try store.create(request: .init(prompt: "Hi", config: .init(folder: directory), windowId: 1), tabId: 42)
        XCTAssertNil(store.handOff(chat.id, message: " \n ", tab: nil))
        XCTAssertNil(chat.handOff)
        XCTAssertNotNil(store.handOff(chat.id, message: " Sign in to GitHub. ", tab: " "))
        XCTAssertEqual(chat.handOff?.message, "Sign in to GitHub.")
        XCTAssertNil(chat.handOff?.tab)
        _ = store.handOff(chat.id, message: "Approve the payment.", tab: "Checkout")
        let handOff = try XCTUnwrap(chat.handOff)
        XCTAssertEqual(handOff.tab, "Checkout")
        store.saveRecord(chat.id, synchronously: true)
        store.closeIfTabIsGone(42)
        XCTAssertTrue(store.restoreIfNeeded(chat.id, tabId: 43))
        let restored = try XCTUnwrap(store.conversation(for: chat.id))
        XCTAssertEqual(restored.handOff, handOff)

        var sent: [String] = [], queued: [String] = [], restarted: [String] = []
        restored.onSend = { text, _, _ in sent.append(text) }
        restored.onQueue = { text, _, _ in queued.append(text) }
        restored.onRestart = { restarted.append($0.text) }
        restored.finishHandOff()
        XCTAssertNil(restored.handOff)
        XCTAssertEqual(restarted, ["Done."], "A restored chat launches with his Done")
        restored.finishHandOff()
        XCTAssertEqual(restarted.count, 1, "Done sends once")
        for (status, expected) in [(AgentConversationStatus.idle, ["Done."]), (.running, ["Done."])] {
            restored.update(items: restored.items, status: status)
            restored.setHandOff(handOff)
            restored.finishHandOff()
            XCTAssertEqual(sent, expected)
        }
        XCTAssertEqual(queued, ["Done."], "A working agent gets it queued")
    }

    @MainActor private final class Family {
        final class Calls {
            var requests: [DrifterLaunchRequest] = []
            var opened: [(UUID, Int)] = []
            var closed: [Int] = []
            var liveTabs: Set<Int> = [1]
            var activeTab: Int?
            var keptTabs: Set<Int> = []
            var outsideFolder: Set<Int> = []
        }
        let calls: Calls
        let directory: URL
        let store: AgentChatStore
        let top: AgentConversation

        init(config: DrifterConfig = .init()) throws {
            let calls = Calls()
            self.calls = calls
            directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            store = AgentChatStore(route: .init(baseDirectory: directory), tabExists: { calls.liveTabs.contains($0) },
                isTabActive: { calls.activeTab == $0 },
                windowId: { calls.liveTabs.contains($0) ? 7 : nil },
                openChatTab: { calls.opened.append(($0, $1)) },
                closeChatTab: { calls.closed.append($0); calls.liveTabs.remove($0) },
                tabIsKept: { calls.keptTabs.contains($0) },
                tabIsInFolder: { id, _ in !calls.outsideFolder.contains(id) },
                browserSessionFactory: { request, conversation, _ in
                    calls.requests.append(request)
                    var transcript = ClaudeCodeTranscript()
                    transcript.userSent(text: request.prompt, attachments: [], sender: request.sender)
                    conversation.update(items: request.resume?.items ?? transcript.items, status: .starting)
                    return FakeSession()
                })
            var config = config
            config.folder = directory
            top = try store.create(request: .init(prompt: "Parent", config: config, windowId: 7), tabId: 1)
            top.update(items: top.items, status: .idle)
        }

        func spawn(from caller: AgentConversation? = nil, title: String = "Child", model: String? = nil,
                   effort: String? = nil) throws -> AgentConversation {
            let result = try store.spawnAgentChat(from: (caller ?? top).id, brief: "Do this task", title: title, model: model, effort: effort).get()
            let id = try XCTUnwrap(store.agentListing(caller: top.id).first { $0.id == result.id }?.chatId)
            return try XCTUnwrap(store.conversation(for: id))
        }
        func bind(_ chat: AgentConversation, tab: Int) {
            calls.liveTabs.insert(tab); store.assign(chat.id, to: tab)
        }
        func finish(_ chat: AgentConversation, text: String = "Final answer", stopped: Bool = false, finish: (AgentTaskFinishStatus, String)? = nil) {
            chat.update(items: chat.items + [.init(id: UUID().uuidString,
                kind: .peerMessage(name: "parent", body: "Next task"))], status: .running)
            if let finish { _ = store.finishTask(chat.id, status: finish.0, message: finish.1) }
            chat.update(items: chat.items + [
                .init(id: UUID().uuidString, kind: .assistantText(text: text, isStreaming: false)),
                .init(id: UUID().uuidString, kind: .turnEnd(durationMilliseconds: 1, finishedAt: Date(), stopped: stopped)),
            ], status: .idle)
        }
        func cleanUp() {
            store.terminate()
            try? FileManager.default.removeItem(at: directory)
        }
    }

    @MainActor private func settleReports() async throws { try await Task.sleep(nanoseconds: 30_000_000) }

    func testBackgroundCheckInMessageListsTasksAndOutput() {
        var checkIns = DrifterBackgroundCheckIns(interval: 1800)
        let id = UUID(), date = Date(timeIntervalSince1970: 1000)
        let tasks = [AgentBackgroundTask(id: "one", kind: .shell, description: "Build"),
                     AgentBackgroundTask(id: "two", kind: .task, description: "Native")]
        checkIns.tasks(tasks, id: id, now: date)
        let message = checkIns.message(tasks, id: id, now: date.addingTimeInterval(1800)) { task in
            task == "one" ? (path: "/chat/Tasks/one.log", tail: "first\nsecond") : nil
        }
        XCTAssertEqual(message.text, "- one (shell) \"Build\": started 30 min ago, output file /chat/Tasks/one.log\n  first\n  second\n- two (task) \"Native\": started 30 min ago")
        XCTAssertEqual(message.sender?.note, "Check-in from Mist, not a completion: this chat has been idle for 30 min while background work it started is still running. Make sure each task below is still making progress: read its output and look at its processes. If one is stuck (waiting on a lock, on input, or on a process that will never exit), stop it and get the work done another way. If it is making progress or is meant to keep running (a server, a watcher), leave it and end your turn. Don't message Johnny, post to Slack or call finish_task just to say it is still running. The next check-in comes after another 30 min idle.")
    }

    @MainActor func testBackgroundCheckInTimingSlackAndCompletionDots() async throws {
        let family = try Family()
        defer { family.cleanUp() }
        let store = family.store, chat = family.top
        var clock = Date().addingTimeInterval(3600)
        store.now = { clock }
        let tasks = [AgentBackgroundTask(id: "task-123", kind: .shell, description: "Build")]
        let slack = AgentChatItem(id: "slack", kind: .peerMessage(name: "Slack", body: "Hello"))
        chat.update(items: [slack], status: .running, backgroundTasks: tasks)
        chat.update(items: [slack], status: .idle, backgroundTasks: tasks)
        store.markSeen(tabId: 1)
        var received: [AgentQueuedMessage] = []
        chat.onDeliver = { message in
            received.append(message)
            if message.sender?.kind == .checkIn { chat.update(items: chat.items, status: .running, backgroundTasks: tasks) }
            return true
        }
        clock.addTimeInterval(1799); store.fireDueBackgroundCheckIns(); try await settleReports()
        XCTAssertTrue(received.isEmpty)
        clock.addTimeInterval(1); store.fireDueBackgroundCheckIns(); try await settleReports()
        XCTAssertEqual(received.count, 1)
        let message = try XCTUnwrap(received.first)
        XCTAssertEqual(message.sender?.kind, .checkIn)
        XCTAssertEqual(message.text, "- task-123 (shell) \"Build\": started 30 min ago")
        XCTAssertEqual(message.sender?.checkInTasks, ["Build"])
        XCTAssertEqual(message.sender?.postsToSlack, false)
        XCTAssertFalse(message.sender?.header.contains(AgentMessageSender.slackWakeNote) ?? true)
        XCTAssertTrue(message.sender?.header.contains("idle for 30 min") ?? false)
        chat.update(items: chat.items, status: .idle, backgroundTasks: tasks)
        XCTAssertFalse(store.unseenCompletions.contains(chat.id))
        clock.addTimeInterval(1800); store.fireDueBackgroundCheckIns(); try await settleReports()
        XCTAssertEqual(received.count, 2)
        let delivered = await store.deliverExternalMessage(.init(text: "Other", sender: .init(id: "peer", title: "Peer")), to: chat.id)
        XCTAssertTrue(delivered)
        chat.update(items: chat.items, status: .idle, backgroundTasks: tasks)
        XCTAssertTrue(store.unseenCompletions.contains(chat.id))
        store.markSeen(tabId: 1)
        clock.addTimeInterval(1800); store.fireDueBackgroundCheckIns(); try await settleReports()
        chat.update(items: chat.items, status: .failed("Stopped"), backgroundTasks: tasks)
        chat.update(items: chat.items, status: .running, backgroundTasks: tasks)
        chat.update(items: chat.items, status: .idle, backgroundTasks: tasks)
        XCTAssertTrue(store.unseenCompletions.contains(chat.id))
        clock.addTimeInterval(1800); store.fireDueBackgroundCheckIns(); try await settleReports()
        chat.update(items: chat.items, status: .idle, backgroundTasks: tasks)
        XCTAssertTrue(store.unseenCompletions.contains(chat.id))
    }

    @MainActor func testBackgroundCheckInEligibilityClockAndRetry() async throws {
        let family = try Family()
        defer { family.cleanUp() }
        let store = family.store, chat = family.top
        var clock = Date().addingTimeInterval(3600)
        store.now = { clock }
        let tasks = [AgentBackgroundTask(id: "watch", kind: .monitor, description: "Watch")]
        var count = 0
        chat.onDeliver = { _ in count += 1; return false }
        chat.update(items: [], status: .running, backgroundTasks: tasks)
        clock.addTimeInterval(1200)
        chat.update(items: [], status: .idle, backgroundTasks: tasks)
        clock.addTimeInterval(1799); store.fireDueBackgroundCheckIns(); try await settleReports()
        XCTAssertEqual(count, 0)
        clock.addTimeInterval(1)
        var queue = AgentMessageQueue(); queue.enqueue(.init(text: "Paused")); queue.pause(); chat.updateQueue(queue)
        store.fireDueBackgroundCheckIns(); try await settleReports(); XCTAssertEqual(count, 0)
        chat.updateQueue(.init())
        chat.setHandOff(.init(message: "Wait", tab: nil))
        store.fireDueBackgroundCheckIns(); try await settleReports(); XCTAssertEqual(count, 0)
        chat.setHandOff(nil)
        for status in [AgentConversationStatus.running, .awaitingPermission] {
            chat.update(items: [], status: status, backgroundTasks: tasks)
            store.fireDueBackgroundCheckIns(); try await settleReports(); XCTAssertEqual(count, 0)
        }
        chat.update(items: [], status: .idle, backgroundTasks: [])
        clock.addTimeInterval(1800); store.fireDueBackgroundCheckIns(); try await settleReports(); XCTAssertEqual(count, 0)
        chat.update(items: [], status: .idle, backgroundTasks: tasks)
        clock.addTimeInterval(1799); store.fireDueBackgroundCheckIns(); try await settleReports(); XCTAssertEqual(count, 0)
        clock.addTimeInterval(1); store.fireDueBackgroundCheckIns(); try await settleReports(); XCTAssertEqual(count, 1)
        store.fireDueBackgroundCheckIns(); try await settleReports(); XCTAssertEqual(count, 1)
        clock.addTimeInterval(1800); store.fireDueBackgroundCheckIns(); try await settleReports(); XCTAssertEqual(count, 2)
    }

    @MainActor func testBackgroundCheckInRechecksClockBeforeDelivery() async throws {
        let family = try Family()
        defer { family.cleanUp() }
        let store = family.store, chat = family.top
        var clock = Date().addingTimeInterval(3600)
        store.now = { clock }
        let tasks = [AgentBackgroundTask(id: "one", kind: .task, description: "Work")]
        var count = 0
        chat.onDeliver = { _ in count += 1; return true }
        chat.update(items: [], status: .running, backgroundTasks: tasks)
        chat.update(items: [], status: .idle, backgroundTasks: tasks)
        clock.addTimeInterval(1800)
        store.fireDueBackgroundCheckIns()
        chat.update(items: [], status: .running, backgroundTasks: tasks)
        chat.update(items: [], status: .idle, backgroundTasks: tasks)
        try await settleReports()
        XCTAssertEqual(count, 0)
        clock.addTimeInterval(1800)
        store.fireDueBackgroundCheckIns(); try await settleReports()
        XCTAssertEqual(count, 1)
    }

    @MainActor func testIdleClosingTabClosesAfterLifetimeOnceNothingHoldsIt() async throws {
        let family = try Family()
        defer { family.cleanUp() }
        let store = family.store, top = family.top, calls = family.calls
        let lifetime = BrowserAgentPreviewState.idleLifetime
        var clock = Date().addingTimeInterval(3600)
        store.now = { clock }
        func expire(after seconds: TimeInterval) {
            clock.addTimeInterval(seconds)
            store.expireBrowserPreviewCards()
        }

        expire(after: lifetime * 2)
        XCTAssertNil(store.idleTab(for: top.id), "Only registered chats close their tab")
        store.closeTabsWhenIdle([top.id])
        try await settleReports()
        XCTAssertEqual(store.idleTab(for: top.id)?.idleSince, clock)
        XCTAssertEqual(store.browserPreviewExpiryDeadline, clock.addingTimeInterval(lifetime))
        expire(after: lifetime - 1)
        XCTAssertTrue(calls.closed.isEmpty)

        top.update(items: top.items, status: .running)
        try await settleReports()
        XCTAssertNil(store.idleTab(for: top.id)?.idleSince)
        expire(after: lifetime)
        top.update(items: top.items, status: .idle)
        try await settleReports()
        XCTAssertEqual(store.idleTab(for: top.id)?.idleSince, clock, "Each turn restarts the clock")

        // A hold still there at the deadline keeps the tab, and the clock restarts once it clears.
        let holds: [(String, () -> Void, () -> Void)] = [
            ("selected", { calls.activeTab = 1 }, { calls.activeTab = nil }),
            ("draft", { top.setDraft(.init(text: "Unsent")) }, { top.setDraft(.init()) }),
            ("background task", {
                top.update(items: top.items, status: .idle, backgroundTasks: [.init(id: "t", kind: .monitor, description: "Watch")])
            }, { top.update(items: top.items, status: .idle) }),
            ("Chat panel", { calls.liveTabs.insert(2); XCTAssertTrue(store.mount(top.id, to: 2)) }, { store.unmount(top.id) }),
        ]
        for (name, hold, release) in holds {
            hold()
            expire(after: lifetime)
            XCTAssertTrue(calls.closed.isEmpty, name)
            XCTAssertNil(store.idleTab(for: top.id)?.idleSince, name)
            release()
            expire(after: 1)
            XCTAssertEqual(store.idleTab(for: top.id)?.idleSince, clock, name)
        }
        let child = try family.spawn()
        try await settleReports()
        expire(after: lifetime)
        XCTAssertTrue(calls.closed.isEmpty, "A working child holds its parent's tab")
        child.update(items: child.items, status: .idle)
        try await settleReports()
        XCTAssertEqual(store.idleTab(for: top.id)?.idleSince, clock)
        expire(after: lifetime)
        XCTAssertEqual(calls.closed, [1])
        XCTAssertNil(store.idleTab(for: top.id))
    }

    @MainActor func testIdleClosingTabTheUserKeptNeverCloses() async throws {
        let family = try Family()
        defer { family.cleanUp() }
        var clock = Date().addingTimeInterval(3600)
        family.store.now = { clock }
        family.calls.keptTabs = [1]
        family.store.closeTabsWhenIdle([family.top.id])
        try await settleReports()
        XCTAssertNil(family.store.idleTab(for: family.top.id))
        family.calls.keptTabs = []
        clock.addTimeInterval(BrowserAgentPreviewState.idleLifetime * 2)
        family.store.expireBrowserPreviewCards()
        XCTAssertTrue(family.calls.closed.isEmpty, "A pinned or grouped tab stays, even once moved back")
        XCTAssertNil(family.store.idleTab(for: family.top.id))
    }

    @MainActor func testChildPreviewBindingStatusDismissalAndDirectParent() throws {
        let family = try Family()
        defer { family.cleanUp() }
        var clock = Date(timeIntervalSince1970: 1000)
        family.store.now = { clock }
        var root = try XCTUnwrap(family.store.entry(for: family.top.id))
        root.browserPreview = .init(principalId: "root", windowId: 7)
        family.store.register(root)
        let child = try family.spawn()
        XCTAssertTrue(family.store.entry(for: family.top.id)!.browserPreview!.cards.isEmpty)
        family.bind(child, tab: 2)
        var cards = family.store.entry(for: family.top.id)!.browserPreview!.cards
        XCTAssertEqual(cards.map(\.chat), [child.id])
        XCTAssertTrue(cards[0].chatWorking)
        XCTAssertNil(family.store.browserPreviewExpiryDeadline)
        let sibling = try family.spawn(title: "Sibling")
        family.bind(sibling, tab: 3)
        clock = clock.addingTimeInterval(600)
        child.update(items: child.items, status: .running)
        child.update(items: child.items, status: .awaitingPermission)
        XCTAssertEqual(family.store.entry(for: family.top.id)!.browserPreview!.cards.map(\.tabId), [3, 2])
        child.update(items: child.items, status: .idle)
        cards = family.store.entry(for: family.top.id)!.browserPreview!.cards
        XCTAssertFalse(cards[1].chatWorking)
        XCTAssertEqual(cards[1].lastWorked, clock)
        XCTAssertNil(family.store.browserPreviewExpiryDeadline, "An idle child's card never expires")
        family.store.dismissBrowserPreview(family.top.id, tabId: 2)
        child.update(items: child.items, status: .idle)
        XCTAssertEqual(family.store.entry(for: family.top.id)!.browserPreview!.cards.map(\.tabId), [3])
        child.update(items: child.items, status: .starting)
        XCTAssertEqual(family.store.entry(for: family.top.id)!.browserPreview!.cards.map(\.tabId), [2, 3])
        family.store.dismissBrowserPreview(family.top.id, tabId: 2)
        child.update(items: child.items, status: .running)
        child.update(items: child.items, status: .awaitingPermission)
        XCTAssertEqual(family.store.entry(for: family.top.id)!.browserPreview!.cards.map(\.tabId), [3],
            "Dismissed children return only on a new turn")
        var entry = try XCTUnwrap(family.store.entry(for: child.id))
        entry.browserPreview = .init(principalId: "child", windowId: 7)
        family.store.register(entry)
        let grandchild = try family.spawn(from: child)
        family.bind(grandchild, tab: 4)
        XCTAssertEqual(family.store.entry(for: child.id)!.browserPreview!.cards.map(\.tabId), [4])
        XCTAssertEqual(family.store.entry(for: family.top.id)!.browserPreview!.cards.map(\.tabId), [3])
        family.store.tabDidClose(4)
        XCTAssertTrue(family.store.entry(for: child.id)!.browserPreview!.cards.isEmpty)
    }

    @MainActor func testChildThatFinishesBeforeBindingStillGetsAPreview() throws {
        let family = try Family()
        defer { family.cleanUp() }
        var root = try XCTUnwrap(family.store.entry(for: family.top.id))
        root.browserPreview = .init(principalId: "root", windowId: 7)
        family.store.register(root)
        let child = try family.spawn()
        child.update(items: child.items, status: .idle)
        family.bind(child, tab: 2)
        let card = try XCTUnwrap(family.store.entry(for: family.top.id)?.browserPreview?.cards.first)
        XCTAssertEqual(card.chat, child.id)
        XCTAssertFalse(card.chatWorking)
        XCTAssertNil(family.store.browserPreviewExpiryDeadline)
    }

    @MainActor func testClearingChildReplacesItsPreviewInTheSameTab() throws {
        let family = try Family()
        defer { family.cleanUp() }
        var root = try XCTUnwrap(family.store.entry(for: family.top.id))
        root.browserPreview = .init(principalId: "root", windowId: 7)
        family.store.register(root)
        let child = try family.spawn()
        family.bind(child, tab: 2)
        try family.store.clear(child.id)
        let card = try XCTUnwrap(family.store.entry(for: family.top.id)?.browserPreview?.cards.first)
        XCTAssertEqual(card.tabId, 2)
        XCTAssertNotEqual(card.chat, child.id)
        XCTAssertEqual(card.chat.flatMap { family.store.conversation(for: $0)?.status }, .dormant)
        XCTAssertFalse(card.chatWorking)
        _ = try family.store.closeAgent(AgentChatShortID.full(try XCTUnwrap(card.chat)), from: family.top.id).get()
        XCTAssertTrue(family.store.entry(for: family.top.id)!.browserPreview!.cards.isEmpty)
    }

    #if !MIST_CLAUDE_CODE_HOSTLESS_TESTS
    @MainActor func testSharedFolderEventsKeepEachTabOnOneClock() throws {
        let family = try Family()
        defer { family.cleanUp() }
        let child = try family.spawn()
        family.bind(child, tab: 2)
        var root = try XCTUnwrap(family.store.entry(for: family.top.id))
        root.browserFolder = .init(windowId: 7, token: "family")
        root.browserFolder?.join(2, now: Date())
        family.store.register(root)
        var descendant = try XCTUnwrap(family.store.entry(for: child.id))
        descendant.browserFolder = .init(windowId: 7, token: "family", borrowed: true)
        descendant.browserFolder?.join(3, now: Date())
        family.store.register(descendant)
        family.store.browserFolderGroupEvent(.init(browserId: 7,
            action: .tabJoinedGroup(tabId: 3, token: "family")))
        XCTAssertNil(family.store.browserFolder(for: family.top.id)?.members[3])
        family.store.browserFolderGroupEvent(.init(browserId: 7,
            action: .tabJoinedGroup(tabId: 4, token: "family")))
        XCTAssertNotNil(family.store.browserFolder(for: family.top.id)?.members[4])
        XCTAssertNil(family.store.browserFolder(for: child.id)?.members[4])
        family.store.browserFolderGroupEvent(.init(browserId: 7,
            action: .groupCreated(token: "family", title: "Family", color: .grey,
                isCollapsed: false, initialTabIds: [2, 3, 5])))
        XCTAssertEqual(family.store.browserFolder(for: family.top.id)?.members.keys.sorted(), [2, 4, 5])
        XCTAssertEqual(family.store.browserFolder(for: child.id)?.members.keys.sorted(), [3])
        family.store.browserFolderGroupEvent(.init(browserId: 8,
            action: .tabLeftGroup(tabId: 3, token: "family")))
        XCTAssertNotNil(family.store.browserFolder(for: child.id)?.members[3])
        family.store.browserFolderGroupEvent(.init(browserId: 7,
            action: .tabLeftGroup(tabId: 3, token: "family")))
        XCTAssertTrue(family.store.browserFolder(for: child.id)?.members.isEmpty == true)
        family.store.browserFolderGroupEvent(.init(browserId: 7, action: .groupClosed(token: "family")))
        XCTAssertNil(family.store.browserFolder(for: family.top.id))
        XCTAssertNil(family.store.browserFolder(for: child.id))
    }
    #endif

    @MainActor func testSpawnInheritsSettingsAndIsOpenBeforeTabBinds() throws {
        let family = try Family(config: .init(engine: .claude, model: "haiku", effort: "max", confirmation: .ask))
        defer { family.cleanUp() }
        family.top.setDraft(.init(text: "Keep this"))
        let child = try family.spawn(title: "  " + String(repeating: "a", count: 90) + "  ")
        XCTAssertEqual(family.store.parent[child.id], family.top.id)
        XCTAssertEqual(child.manualTitle, String(repeating: "a", count: 80))
        XCTAssertEqual(child.title, child.manualTitle)
        let entry = try XCTUnwrap(family.store.entry(for: child.id))
        XCTAssertEqual(entry.tabId, -1)
        XCTAssertEqual(entry.config.model, "haiku")
        XCTAssertEqual(entry.config.effort, "max")
        XCTAssertEqual(entry.config.confirmation, .ask)
        XCTAssertEqual(entry.config.folder, DrifterHome.current.folder)
        XCTAssertEqual(family.calls.opened.map { $0.0 }, [child.id])
        XCTAssertEqual(family.calls.opened.map { $0.1 }, [7])
        let launch = try XCTUnwrap(family.calls.requests.last)
        XCTAssertEqual(launch.prompt, "Do this task")
        XCTAssertEqual(launch.sender, .init(id: AgentChatShortID.short(family.top.id), title: "Parent", kind: .parent))
        XCTAssertEqual(launch.parent, launch.sender)
        guard case let .peerMessage(name, body) = child.items.first?.kind else { return XCTFail("Missing parent row") }
        XCTAssertEqual(name, launch.sender?.label)
        XCTAssertEqual(body, launch.prompt)
        let listing = family.store.agentListing(caller: family.top.id)
        let parentID = try XCTUnwrap(listing.first { $0.isCaller }?.id)
        let childID = try XCTUnwrap(listing.first { $0.chatId == child.id }?.id)
        XCTAssertEqual(listing.first { $0.chatId == child.id }?.parent, parentID)
        XCTAssertEqual(listing.first { $0.isCaller }?.children, [childID])
        XCTAssertEqual(family.top.draft.text, "Keep this")
        _ = try family.store.spawnAgentChat(from: family.top.id, brief: "/clear",
            title: String(repeating: "a", count: 79) + " b").get()
        XCTAssertEqual(family.calls.requests.last?.prompt, "/clear")
        let lastChild = try XCTUnwrap(family.calls.opened.last?.0)
        XCTAssertEqual(family.store.conversation(for: lastChild)?.title, String(repeating: "a", count: 79))
        XCTAssertEqual(family.store.conversation(for: lastChild)?.manualTitle, family.store.conversation(for: lastChild)?.title)
    }

    @MainActor func testSpawnResolvesModelsEffortsAndRejectsInvalidRequests() throws {
        let family = try Family(config: .init(effort: "max"))
        defer { family.cleanUp() }
        for query in ["terra", "GPT-6.1 Terra", "GpT-6.1-TeRrA"] {
            let child = try family.spawn(model: query)
            XCTAssertEqual(family.store.entry(for: child.id)?.config.engine, .codex)
            XCTAssertEqual(family.store.entry(for: child.id)?.config.model, "gpt-6.1-terra")
            XCTAssertEqual(family.store.entry(for: child.id)?.config.effort, "medium")
        }
        let codex = try family.spawn(model: "sol", effort: "high")
        family.bind(codex, tab: 2)
        let inherited = try family.spawn(from: codex)
        XCTAssertEqual(family.store.entry(for: inherited.id)?.config.model, "gpt-6.2-sol")
        XCTAssertEqual(family.store.entry(for: inherited.id)?.config.effort, "high")
        let claude = try family.spawn(model: "OPUS", effort: "max")
        XCTAssertEqual(family.store.entry(for: claude.id)?.config.engine, .claude)
        XCTAssertEqual(family.store.entry(for: claude.id)?.config.effort, "max")
        for (brief, title, model, effort, expected) in [
            ("  ", "Title", nil, nil, AgentSpawnError.emptyBrief.message),
            ("Task", "\n", nil, nil, AgentSpawnError.emptyTitle.message),
            ("Task", "Title", "missing", nil, AgentSpawnError.unknownModel.message),
            ("Task", "Title", "terra", "max", AgentSpawnError.invalidEffort(["low", "medium", "high", "xhigh"]).message),
            ("Task", "Title", "haiku", "invalid", AgentSpawnError.invalidEffort(ClaudeCodeEffort.allCases.map(\.rawValue)).message),
        ] as [(String, String, String?, String?, String)] {
            switch family.store.spawnAgentChat(from: family.top.id, brief: brief, title: title, model: model, effort: effort) {
            case .success: XCTFail("Unexpected spawn")
            case let .failure(error): XCTAssertEqual(error.message, expected)
            }
        }
        XCTAssertThrowsError(try family.spawn(from: inherited)) { error in
            XCTAssertEqual((error as? AgentSpawnError)?.message, AgentSpawnError.depth.message)
        }
        family.calls.liveTabs.removeAll()
        XCTAssertThrowsError(try family.spawn()) { error in
            XCTAssertEqual((error as? AgentSpawnError)?.message, AgentSpawnError.noWindow.message)
        }
    }

    @MainActor func testSpawnKeepsChildrenOnTheParentsConfigUnlessItRunsAnAdminModel() throws {
        func config(_ family: Family, _ chat: AgentConversation) -> DrifterConfig? { family.store.entry(for: chat.id)?.config }
        func refused(_ family: Family, from caller: AgentConversation? = nil, model: String?, effort: String?, _ expected: String,
                     line: UInt = #line) {
            switch family.store.spawnAgentChat(from: (caller ?? family.top).id, brief: "Task", title: "Child", model: model, effort: effort) {
            case .success: XCTFail("Unexpected spawn", line: line)
            case let .failure(error): XCTAssertEqual(error.message, expected, line: line)
            }
        }

        let terra = try Family(config: .init(engine: .codex, model: "gpt-6.1-terra", effort: "low"))
        defer { terra.cleanUp() }
        let terraOnly = "This chat runs GPT-6.1 Terra · low, so its children run on GPT-6.1 Terra · low; omit model and effort."
        XCTAssertEqual(AgentSpawnError.restricted(terra.store.entry(for: terra.top.id)!.config).message, terraOnly)
        for (model, effort) in [("opus", nil), ("luna", nil), (nil, "high"), ("terra", "medium")] as [(String?, String?)] {
            refused(terra, model: model, effort: effort, terraOnly)
        }
        for (model, effort) in [(nil, nil), ("terra", nil), (nil, "low"), ("GPT-6.1 Terra", "low")] as [(String?, String?)] {
            let child = try terra.spawn(model: model, effort: effort)
            XCTAssertEqual(config(terra, child)?.engine, .codex)
            XCTAssertEqual(config(terra, child)?.model, "gpt-6.1-terra")
            XCTAssertEqual(config(terra, child)?.effort, "low")
        }

        let astra = try Family(config: .init(engine: .codex, model: "gpt-6-astra", effort: "medium"))
        defer { astra.cleanUp() }
        let luna = try astra.spawn(model: "luna", effort: "high")
        XCTAssertEqual(config(astra, luna)?.model, "gpt-6-luna")
        XCTAssertEqual(config(astra, luna)?.effort, "high")
        let ownModel = try astra.spawn(effort: "xhigh")
        XCTAssertEqual(config(astra, ownModel)?.model, "gpt-6-astra")
        XCTAssertEqual(config(astra, ownModel)?.effort, "xhigh")
        refused(astra, model: "sonnet", effort: nil, "This chat runs GPT-6 Astra · medium, so its children run on GPT models only, at any effort: "
            + DrifterModel.codexPicks.joined(separator: ", ") + ".")
        refused(astra, model: "flash", effort: nil, AgentSpawnError.restricted(astra.store.entry(for: astra.top.id)!.config).message)
        refused(astra, from: luna, model: "astra", effort: nil,
                "This chat runs GPT-6 Luna · high, so its children run on GPT-6 Luna · high; omit model and effort.")

        for admin in ["opus", "fable"] {
            let family = try Family(config: .init(engine: .claude, model: admin, effort: "medium"))
            defer { family.cleanUp() }
            for (model, effort) in [("terra", "low"), ("terra", "xhigh"), ("haiku", "low"), ("haiku", "max"),
                                    ("hydrogen", "xhigh"), ("Gemini 3.8 Flash", "max")] {
                let child = try family.spawn(model: model, effort: effort)
                XCTAssertEqual(config(family, child)?.model, DrifterModel.spawnModel(model)?.model, admin)
                XCTAssertEqual(config(family, child)?.effort, effort, admin)
            }
            // A child on a model that isn't an admin is held to its own config.
            let child = try family.spawn(model: "terra", effort: "low")
            refused(family, from: child, model: "opus", effort: nil, terraOnly)
            refused(family, from: child, model: nil, effort: "medium", terraOnly)
            family.bind(child, tab: 2)
            let grandchild = try family.spawn(from: child)
            XCTAssertEqual(config(family, grandchild)?.model, "gpt-6.1-terra")
            XCTAssertEqual(config(family, grandchild)?.effort, "low")
        }

        let gemini = try Family(config: .init(engine: .gemini, model: "gemini-3.8-flash", effort: "low"))
        defer { gemini.cleanUp() }
        let restricted = AgentSpawnError.restricted(gemini.store.entry(for: gemini.top.id)!.config).message
        refused(gemini, model: "neon", effort: nil, restricted)
        refused(gemini, model: "flash", effort: "max", restricted)
        let flash = try gemini.spawn(model: "flash")
        XCTAssertEqual(config(gemini, flash)?.engine, .gemini)
        XCTAssertEqual(config(gemini, flash)?.effort, "low")
    }

    @MainActor func testSpawnFallsBackToPreviewWindowAndRestartKeepsParent() throws {
        let family = try Family()
        defer { family.cleanUp() }
        let child = try family.spawn()
        var entry = try XCTUnwrap(family.store.entry(for: child.id))
        entry.browserPreview = .init(principalId: "child", windowId: 19)
        family.store.register(entry)
        let grandchild = try family.spawn(from: child)
        XCTAssertEqual(family.calls.opened.last?.1, 19)
        XCTAssertEqual(family.store.parent[grandchild.id], child.id)
        family.bind(child, tab: 2)
        child.update(items: child.items, status: .dormant)
        family.store.restart(child.id, prompt: "Continue", attachments: [], mentions: [])
        XCTAssertEqual(family.calls.requests.last?.parent?.id, AgentChatShortID.short(family.top.id))
        XCTAssertEqual(family.calls.requests.last?.parent?.kind, .parent)
    }

    @MainActor func testDescendantControlsStopOnlyWorkingChatsAndCascadePreservesFiles() throws {
        let family = try Family()
        defer { family.cleanUp() }
        let child = try family.spawn()
        family.bind(child, tab: 2)
        let grandchild = try family.spawn(from: child)
        family.bind(grandchild, tab: 3)
        var stopped = 0, closed = 0
        grandchild.onStop = { stopped += 1 }
        child.onClose = { closed += 1 }
        grandchild.onClose = { closed += 1 }
        for target in [family.top, child] {
            XCTAssertThrowsError(try family.store.stopAgent(AgentChatShortID.full(target.id), from: grandchild.id).get())
            XCTAssertThrowsError(try family.store.closeAgent(AgentChatShortID.full(target.id), from: grandchild.id).get())
        }
        XCTAssertThrowsError(try family.store.closeAgent(AgentChatShortID.full(family.top.id), from: family.top.id).get())
        XCTAssertThrowsError(try family.store.stopAgent(AgentChatShortID.full(family.top.id), from: family.top.id).get())
        for status in [AgentConversationStatus.starting, .running, .awaitingPermission, .idle, .dormant, .failed("x"), .ended] {
            grandchild.update(items: grandchild.items, status: status)
            let result = try family.store.stopAgent(AgentChatShortID.full(grandchild.id), from: family.top.id).get()
            XCTAssertEqual(result.stopped, [.starting, .running, .awaitingPermission].contains(status))
        }
        XCTAssertEqual(stopped, 3)
        _ = try family.store.closeAgent(AgentChatShortID.full(child.id), from: family.top.id).get()
        XCTAssertEqual(Set(family.calls.closed), [2, 3])
        XCTAssertEqual(closed, 2)
        for chat in [child, grandchild] {
            XCTAssertNil(family.store.entry(for: chat.id))
            XCTAssertNil(family.store.parent[chat.id])
            XCTAssertTrue(FileManager.default.fileExists(atPath: family.store.route.recordURL(for: chat.id).path))
        }
        XCTAssertNotNil(family.store.entry(for: family.top.id))
    }

    @MainActor func testChildTakenOutOfTheFolderOutlivesItsParent() throws {
        let family = try Family()
        defer { family.cleanUp() }
        let inside = try family.spawn(title: "Inside")
        family.bind(inside, tab: 2)
        let outside = try family.spawn(title: "Outside")
        family.bind(outside, tab: 3)
        let grandchild = try family.spawn(from: outside, title: "Grandchild")
        family.bind(grandchild, tab: 4)
        family.calls.outsideFolder.insert(3)
        family.calls.liveTabs.remove(1)
        family.store.closeIfTabIsGone(1)
        XCTAssertNil(family.store.entry(for: family.top.id))
        XCTAssertNil(family.store.entry(for: inside.id))
        XCTAssertEqual(family.calls.closed, [2])
        XCTAssertNotNil(family.store.entry(for: outside.id))
        XCTAssertNotNil(family.store.entry(for: grandchild.id), "Its own children close only with it")
        XCTAssertEqual(family.store.parent[outside.id], family.top.id, "It keeps its parent link")
        XCTAssertEqual(family.store.parent[grandchild.id], outside.id)
    }

    @MainActor func testClosingTopCascadesAndClearKeepsParentWithoutPersistingTree() throws {
        let family = try Family()
        defer { family.cleanUp() }
        let child = try family.spawn()
        family.bind(child, tab: 2)
        let grandchild = try family.spawn(from: child)
        family.bind(grandchild, tab: 3)
        try family.store.clear(child.id)
        let freshID = try XCTUnwrap(family.store.agentChats().first { $0 != family.top.id })
        XCTAssertEqual(family.store.parent[freshID], family.top.id)
        XCTAssertNil(family.store.entry(for: grandchild.id))
        XCTAssertEqual(family.calls.closed, [3])
        family.calls.liveTabs.remove(1)
        family.store.closeIfTabIsGone(1)
        XCTAssertTrue(family.store.parent.isEmpty)
        XCTAssertNil(family.store.entry(for: freshID))
        XCTAssertEqual(family.calls.closed, [3, 2])
        XCTAssertFalse(family.store.canRestore(freshID), "The cleared child's fresh chat never sent a message")
        for id in [family.top.id, child.id, grandchild.id] {
            XCTAssertTrue(family.store.canRestore(id))
            let json = try String(contentsOf: family.store.route.recordURL(for: id), encoding: .utf8)
            XCTAssertFalse(json.contains("\"parent\""))
        }
    }

    @MainActor func testReportsDeliverFinishFailureAndSkipStoppedOrClosedChats() async throws {
        let family = try Family()
        defer { family.cleanUp() }
        let child = try family.spawn()
        var received: [AgentQueuedMessage] = []
        family.top.onDeliver = { received.append($0); return true }
        family.top.setDraft(.init(text: "Unsent draft"))
        family.finish(child, finish: (.done, "Final answer"))
        try await settleReports()
        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(received.last?.text, "Final answer")
        XCTAssertEqual(received.last?.sender?.kind, .report)
        XCTAssertEqual(received.last?.sender?.label, "\(AgentChatShortID.short(child.id)) (Child)")
        family.finish(child, text: "Do not forward", stopped: true, finish: (.done, "Stopped report"))
        try await settleReports()
        XCTAssertEqual(received.count, 1)
        child.update(items: child.items, status: .starting)
        child.update(items: child.items, status: .failed("Broken pipe"))
        try await settleReports()
        XCTAssertEqual(received.last?.text, "It stopped with an error: Broken pipe")
        family.finish(child, finish: (.done, "Closed before report"))
        _ = try family.store.closeAgent(AgentChatShortID.full(child.id), from: family.top.id).get()
        try await settleReports()
        XCTAssertEqual(received.count, 2)
        XCTAssertEqual(family.top.draft.text, "Unsent draft")
    }

    @MainActor func testTaskFinishesDeliverOnlyExplicitMessageAndLastCallWins() async throws {
        let family = try Family()
        defer { family.cleanUp() }
        let child = try family.spawn()
        var received: [AgentQueuedMessage] = []
        family.top.onDeliver = { received.append($0); return true }
        family.finish(child, text: "Raw reply")
        try await settleReports()
        XCTAssertTrue(received.isEmpty)
        family.finish(child, text: "Raw reply", finish: (.done, "  Task completed\n"))
        try await settleReports()
        XCTAssertEqual(received.map(\.text), ["Task completed"])
        XCTAssertEqual(received.last?.sender?.kind, .report)
        XCTAssertEqual(received.last?.sender?.taskStatus, .done)
        let label = "\(AgentChatShortID.short(child.id)) (Child)"
        XCTAssertEqual(received.last?.sender?.header, "[Report from child chat \(label): it finished its task and sent this with finish_task. No reply is needed]")
        child.update(items: child.items, status: .running)
        _ = try family.store.finishTask(child.id, status: .done, message: "Superseded").get()
        XCTAssertEqual(try family.store.finishTask(child.id, status: .blocked, message: "Which option?").get(),
                       "Mist sends this to your parent chat when this turn ends. End your turn now.")
        XCTAssertEqual(received.count, 1, "Calling the tool must wait for turn end")
        child.update(items: child.items, status: .idle)
        try await settleReports()
        XCTAssertEqual(received.map(\.text), ["Task completed", "Which option?"])
        XCTAssertEqual(received.last?.sender?.taskStatus, .blocked)
        XCTAssertEqual(received.last?.sender?.header, "[Report from child chat \(label): it is blocked and waits for your answer, sent with finish_task. Answer it with message_agent]")
        family.finish(child, text: "No new finish")
        try await settleReports()
        XCTAssertEqual(received.count, 2)
    }

    @MainActor func testStoppedFailedAndEndedTurnsDiscardFinishes() async throws {
        let family = try Family()
        defer { family.cleanUp() }
        let child = try family.spawn()
        var received: [AgentQueuedMessage] = []
        family.top.onDeliver = { received.append($0); return true }
        family.finish(child, stopped: true, finish: (.done, "Stopped"))
        try await settleReports()
        family.finish(child)
        try await settleReports()
        XCTAssertTrue(received.isEmpty)
        for status in [AgentConversationStatus.failed("Broken"), .ended] {
            child.update(items: child.items, status: .running)
            _ = try family.store.finishTask(child.id, status: .done, message: "Discard me").get()
            child.update(items: child.items, status: status)
            try await settleReports()
            family.finish(child)
            try await settleReports()
        }
        XCTAssertEqual(received.map(\.text), ["It stopped with an error: Broken"])
        XCTAssertNil(received.last?.sender?.taskStatus)
    }

    @MainActor func testFinishTaskRejectsTopLevelAndBlankMessages() throws {
        let family = try Family()
        defer { family.cleanUp() }
        let child = try family.spawn()
        XCTAssertThrowsError(try family.store.finishTask(family.top.id, status: .done, message: "Done").get()) {
            guard case AgentFinishError.notEligible = $0 else { return XCTFail("Wrong error: \($0)") }
        }
        XCTAssertThrowsError(try family.store.finishTask(child.id, status: .done, message: " \n ").get()) {
            guard case AgentFinishError.emptyMessage = $0 else { return XCTFail("Wrong error: \($0)") }
        }
    }

    @MainActor func testQuestionsReportOnceAndParentAnswersInsteadOfQueuing() async throws {
        let family = try Family()
        defer { family.cleanUp() }
        let child = try family.spawn()
        var received: [AgentQueuedMessage] = [], answered: [(String, AgentPermissionResponse)] = []
        family.top.onDeliver = { received.append($0); return true }
        let input = ClaudeCodeJSON.object(["keep": .string("original"), "questions": .array([
            .object(["header": .string("Choice"), "question": .string("Which one?"), "options": .array([
                .object(["label": .string("A"), "description": .string("First")])])]),
            .object(["header": .string("Details"), "question": .string("Why?")]),
        ])])
        let request = AgentChatItem.PermissionRequest(requestId: "question", toolName: "AskUserQuestion", summary: "Choose", input: input)
        let items = child.items + [.init(id: "question", kind: .permissionRequest(request))]
        child.update(items: items, status: .awaitingPermission)
        try await settleReports()
        child.update(items: items, status: .awaitingPermission)
        try await settleReports()
        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(received.first?.sender?.kind, .question)
        XCTAssertEqual(received.first?.text, "Choice\nWhich one?\n- A: First\n\nDetails\nWhy?")
        child.onPermissionDecision = { answered.append(($0, $1)) }
        child.onDeliver = { _ in XCTFail("Answer was queued"); return true }
        let result = try await family.store.deliverAgentMessage("Use A", to: AgentChatShortID.full(child.id), from: family.top.id).get()
        XCTAssertEqual(result.delivery, "answered")
        XCTAssertEqual(answered.first?.0, "question")
        guard case let .allowWithInput(answer) = answered.first?.1 else { return XCTFail("Missing answer") }
        XCTAssertEqual(answer["keep"], .string("original"))
        XCTAssertEqual(answer["answers"], .object(["Which one?": .string("Use A"), "Why?": .string("Use A")]))
    }

    @MainActor func testReportsWaitForStartingParentAndWakeDormantParent() async throws {
        let family = try Family()
        defer { family.cleanUp() }
        let child = try family.spawn()
        family.top.update(items: family.top.items, status: .starting)
        var received: [AgentQueuedMessage] = []
        family.top.onDeliver = { received.append($0); return true }
        family.finish(child, finish: (.done, "Final answer"))
        try await settleReports()
        XCTAssertTrue(received.isEmpty)
        family.top.update(items: family.top.items, status: .running)
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(received.count, 1)
        family.top.update(items: family.top.items, status: .dormant)
        family.finish(child, finish: (.done, "Wake parent"))
        try await settleReports()
        XCTAssertEqual(family.calls.requests.last?.prompt, "Wake parent")
        XCTAssertEqual(family.calls.requests.last?.sender?.kind, .report)
    }

    @MainActor func testReportKeepsCompletedTurnWhenNextQueuedTurnStartsImmediately() async throws {
        let family = try Family()
        defer { family.cleanUp() }
        let child = try family.spawn()
        var received: [AgentQueuedMessage] = []
        family.top.onDeliver = { received.append($0); return true }
        family.finish(child, finish: (.done, "Completed reply"))
        child.update(items: child.items + [.init(id: "next", kind: .peerMessage(name: "Parent", body: "New task"))], status: .running)
        try await settleReports()
        XCTAssertEqual(received.map(\.text), ["Completed reply"])
    }

    @MainActor func testOnlyDirectParentAnswersAndOtherMessagesStayPeers() async throws {
        let family = try Family()
        defer { family.cleanUp() }
        let child = try family.spawn()
        family.bind(child, tab: 2)
        let grandchild = try family.spawn(from: child)
        let sibling = try family.spawn(title: "Sibling")
        XCTAssertThrowsError(try family.store.stopAgent(AgentChatShortID.full(child.id), from: sibling.id).get())
        XCTAssertThrowsError(try family.store.closeAgent(AgentChatShortID.full(child.id), from: sibling.id).get())
        var messages: [AgentQueuedMessage] = []
        child.onDeliver = { messages.append($0); return true }
        child.update(items: child.items, status: .running)
        _ = try await family.store.deliverAgentMessage("Parent task", to: AgentChatShortID.full(child.id), from: family.top.id).get()
        XCTAssertEqual(messages.last?.sender?.kind, .parent)
        _ = try await family.store.deliverAgentMessage("Peer task", to: AgentChatShortID.full(child.id), from: sibling.id).get()
        XCTAssertEqual(messages.last?.sender?.kind, .peer)
        _ = try family.store.closeAgent(AgentChatShortID.full(grandchild.id), from: family.top.id).get()
        XCTAssertNil(family.store.entry(for: grandchild.id))
        XCTAssertNotNil(family.store.entry(for: child.id))
    }

    @MainActor func testTwentiethReportPausesUntilJohnnysNextMessage() async throws {
        let family = try Family()
        defer { family.cleanUp() }
        let child = try family.spawn()
        var received: [AgentQueuedMessage] = []
        family.top.onDeliver = { [weak top = family.top] message in
            guard let top else { return false }
            received.append(message)
            top.update(items: top.items + [.init(id: UUID().uuidString,
                kind: .peerMessage(name: message.sender!.label, body: message.text))], status: .idle)
            return true
        }
        for _ in 0..<21 { family.finish(child, finish: (.done, "Final answer")); try await settleReports() }
        XCTAssertEqual(received.count, 20)
        XCTAssertEqual(received.last?.sender?.reportsPaused, true)
        XCTAssertTrue(received.last?.sender?.header.contains("until Johnny sends a message here") == true)
        family.top.update(items: family.top.items + [.init(id: "johnny", kind: .userMessage(text: "Continue", images: []))], status: .idle)
        family.finish(child, finish: (.done, "Final answer"))
        try await settleReports()
        XCTAssertEqual(received.count, 21)
        XCTAssertEqual(received.last?.sender?.reportsPaused, false)
    }

    @MainActor func testReadAgentRendersTailAndAllowsSelf() throws {
        let family = try Family()
        defer { family.cleanUp() }
        family.top.update(items: [.init(id: "answer", kind: .assistantText(text: (1...70).map(String.init).joined(separator: "\n"), isStreaming: false))], status: .idle)
        let query = AgentChatShortID.full(family.top.id)
        let result = try family.store.readAgent(query, lines: 2).get()
        XCTAssertEqual(result.text, "69\n70")
        XCTAssertEqual(result.title, "Parent")
        XCTAssertEqual(result.status, "idle")
        XCTAssertEqual(try family.store.readAgent(query).get().text.components(separatedBy: "\n").count, 60)
        XCTAssertThrowsError(try family.store.readAgent(query, lines: 0).get())
        XCTAssertThrowsError(try family.store.readAgent(query, lines: 501).get())
        XCTAssertThrowsError(try family.store.readAgent("missing").get())
    }

    func testTranscriptTextAndLastTurnStopped() throws {
        var tool = AgentChatItem.ToolCall(toolUseId: "tool", name: "mcp__mistbrowser__read_agent", inputSummary: "abcd", inputJSON: "{}")
        var shell = AgentChatItem.ShellCommand(command: "false")
        shell.exitCode = 1
        var request = AgentChatItem.PermissionRequest(requestId: "q", toolName: "AskUserQuestion", summary: "Pick", input: .object([
            "questions": .array([.object(["header": .string("Choice"), "question": .string("Which?"), "options": .array([
                .object(["label": .string("A"), "description": .string("First")])])])]),
        ]))
        let items: [AgentChatItem] = [
            .init(id: "user", kind: .userMessage(text: "Start", images: [])),
            .init(id: "peer", kind: .peerMessage(name: "abcd (Parent)", body: "Task")),
            .init(id: "progress", kind: .assistantText(text: "Working", isStreaming: false)),
            .init(id: "tool", kind: .toolCall(tool)),
            .init(id: "shell", kind: .shellCommand(shell)),
            .init(id: "out", kind: .commandOutput(command: "false", text: "Output", isError: true)),
            .init(id: "q", kind: .permissionRequest(request)),
            .init(id: "task", kind: .taskNotification(summary: "Done", status: .completed)),
            .init(id: "answer1", kind: .assistantText(text: "Final one", isStreaming: false)),
            .init(id: "answer2", kind: .assistantText(text: "Final two", isStreaming: false)),
            .init(id: "notice", kind: .notice(text: "Notice", level: .info)),
            .init(id: "compact", kind: .contextUsage(.init(.object([:])))),
            .init(id: "end", kind: .turnEnd(durationMilliseconds: 1, finishedAt: Date())),
        ]
        XCTAssertEqual(AgentChatTranscriptText.render(items), "Johnny: Start\nMessage from @abcd (Parent): Task\nWorking\n• read_agent abcd (running)\n$ false (exit 1)\nOutput\nAsks: Pick\nChoice\nWhich?\n- A: First\n[task] Done\nFinal one\nFinal two\n[Notice]\n— turn ended")
        XCTAssertFalse(AgentChatTranscriptText.lastTurnStopped(items))
        let stopped = AgentChatItem(id: "stopped", kind: .turnEnd(durationMilliseconds: 1, finishedAt: Date(), stopped: true))
        XCTAssertTrue(AgentChatTranscriptText.lastTurnStopped(items + [stopped]))
        XCTAssertTrue(AgentChatTranscriptText.lastTurnStopped([stopped]))
        XCTAssertFalse(AgentChatTranscriptText.lastTurnStopped(items + [stopped,
            .init(id: "next", kind: .assistantText(text: "New turn", isStreaming: false))]))
        XCTAssertFalse(AgentChatTranscriptText.lastTurnStopped(items + [stopped,
            .init(id: "next", kind: .peerMessage(name: "Parent", body: "Next"))]))
        tool.status = .failed
        XCTAssertTrue(AgentChatTranscriptText.render([.init(id: "tool", kind: .toolCall(tool))]).hasSuffix(" (failed)"))
        request.status = .allowed
        request.resolution = .allowWithInput(.object(["answers": .object(["Which?": .string("A")])]))
        XCTAssertTrue(AgentChatTranscriptText.render([.init(id: "q", kind: .permissionRequest(request))]).hasSuffix(" (answered: A)"))
        request.status = .denied
        XCTAssertTrue(AgentChatTranscriptText.render([.init(id: "q", kind: .permissionRequest(request))]).hasSuffix(" (denied)"))
    }

    func testSenderKindsDecodeLegacyMessagesAndKeepVisiblePeerRows() throws {
        let legacy = Data("{\"id\":\"abcd\",\"title\":\"Sender\"}".utf8)
        XCTAssertEqual(try JSONDecoder().decode(AgentMessageSender.self, from: legacy).kind, .peer)
        for kind in [AgentMessageSender.Kind.peer, .parent, .report, .question] {
            let sender = AgentMessageSender(id: "abcd", title: "Sender", kind: kind)
            XCTAssertEqual(try JSONDecoder().decode(AgentMessageSender.self, from: JSONEncoder().encode(sender)), sender)
            var transcript = ClaudeCodeTranscript()
            transcript.userSent(text: "Body", attachments: [], sender: sender)
            guard case let .peerMessage(name, body) = transcript.items.first?.kind else { return XCTFail("Missing peer row") }
            XCTAssertEqual(name, "abcd (Sender)")
            XCTAssertEqual(body, "Body")
        }
    }

    @MainActor func testAgentListingRestoresOnlyOpenTabsAndIncludesPanelChats() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let route = AgentChatRoute(baseDirectory: root)
        let open = UUID(), closed = UUID()
        for id in [open, closed] {
            try route.writeRecord(.init(title: "Saved", background: "#fff", drifter: .init(), sessionId: "saved"), for: id)
        }
        var launch: DrifterLaunchRequest?
        let store = AgentChatStore(route: route, tabExists: { $0 == 1 }, windowId: { _ in 1 }, chatTabs: { [(open, 1)] },
            browserSessionFactory: { request, conversation, _ in
                launch = request
                conversation.update(items: conversation.items, status: .starting)
                return FakeSession()
            })
        defer { store.terminate() }
        let panel = AgentConversation(firstPrompt: "Panel")
        store.register(.init(conversation: panel, settings: .init(config: .init(), running: false), tabId: -1, session: nil))
        store.setPanelChat(panel.id, for: 1)
        let listing = store.agentListing(caller: panel.id)
        XCTAssertEqual(Set(listing.map(\.chatId)), [open, panel.id])
        XCTAssertEqual(listing.first { $0.chatId == open }?.status, "dormant")
        XCTAssertEqual(listing.first { $0.chatId == panel.id }?.isCaller, true)
        XCTAssertNil(store.entry(for: closed))
        XCTAssertEqual(store.entry(for: open)?.restoredSessionId, "saved")
        let delivery = try await store.deliverAgentMessage("Wake up", to: AgentChatShortID.full(open), from: panel.id).get()
        XCTAssertEqual(delivery.delivery, "started")
        XCTAssertEqual(launch?.resume?.sessionId, "saved")
        XCTAssertEqual(launch?.sender, .init(id: AgentChatShortID.short(panel.id), title: "Panel"))
    }

    @MainActor func testAgentDeliveryRoutesStatusesAndPreservesDraftAndSender() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var requests: [DrifterLaunchRequest] = []
        let store = AgentChatStore(route: .init(baseDirectory: root), tabExists: { _ in true }, windowId: { _ in 1 },
            browserSessionFactory: { request, conversation, _ in
                requests.append(request)
                conversation.update(items: conversation.items, status: .starting)
                return FakeSession()
            })
        defer { store.terminate() }
        let caller = AgentConversation(firstPrompt: "Sender"), target = AgentConversation(firstPrompt: "Recipient")
        for (index, chat) in [caller, target].enumerated() {
            store.register(.init(conversation: chat, settings: .init(config: .init(), running: false), tabId: index, session: nil))
        }
        let sender = AgentMessageSender(id: AgentChatShortID.short(caller.id), title: "Sender")
        let query = AgentChatShortID.full(target.id)
        target.setDraft(.init(text: "Keep my draft"))
        var received: [AgentQueuedMessage] = []
        var jumps = 0
        let binding = target.messageSent.sink { jumps += 1 }
        defer { binding.cancel() }
        target.onDeliver = { received.append($0); return true }
        for (status, delivery) in [(AgentConversationStatus.idle, "started"), (.running, "queued"), (.awaitingPermission, "queued")] {
            target.update(items: [], status: status)
            let result = try await store.deliverAgentMessage("Body", to: query, from: caller.id).get()
            XCTAssertEqual(result.delivery, delivery)
            XCTAssertEqual(received.last?.sender, sender)
            XCTAssertEqual(received.last?.text, "Body")
            XCTAssertEqual(target.draft.text, "Keep my draft")
        }
        target.update(items: [], status: .starting)
        let ready = Task { @MainActor in
            try await Task.sleep(nanoseconds: 150_000_000)
            caller.title = "Renamed while waiting"
            target.update(items: [], status: .idle)
        }
        let waited = try await store.deliverAgentMessage("After startup", to: query, from: caller.id).get()
        try await ready.value
        XCTAssertEqual(waited.delivery, "started")
        XCTAssertEqual(received.last?.text, "After startup")
        XCTAssertEqual(received.last?.sender, sender)
        caller.title = "Sender"
        for status in [AgentConversationStatus.dormant, .failed("Stopped")] {
            target.update(items: [], status: status)
            let result = try await store.deliverAgentMessage("Restart", to: query, from: caller.id).get()
            XCTAssertEqual(result.delivery, "started")
            XCTAssertEqual(requests.last?.sender, sender)
            XCTAssertEqual(requests.last?.prompt, "Restart")
            XCTAssertEqual(target.unsent?.sender, sender)
            store.saveRecord(target.id, synchronously: true)
            XCTAssertEqual(store.route.readRecord(for: target.id)?.queued, [sender.header + "\nRestart"])
            target.update(items: [], status: .failed("Launch failed"))
            XCTAssertTrue(target.draft.text.hasPrefix(sender.header + "\nRestart\n"))
            target.setDraft(.init(text: "Keep my draft"))
        }
        XCTAssertEqual(jumps, 0)
    }

    @MainActor func testAgentDeliveryErrorsAndUnacceptedRestart() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AgentChatStore(route: .init(baseDirectory: root), tabExists: { _ in true })
        defer { store.terminate() }
        let caller = AgentConversation(), first = AgentConversation(id: UUID(uuidString: "00000000-0000-0001-0000-000000000000")!, firstPrompt: "One")
        let second = AgentConversation(id: UUID(uuidString: "00000000-0019-a101-0000-000000000000")!, firstPrompt: "Two")
        for chat in [caller, first, second] {
            store.register(.init(conversation: chat, settings: .init(config: .init(), running: false), tabId: 1, session: nil))
        }
        func error(_ query: String, _ text: String = "Hello") async -> String {
            switch await store.deliverAgentMessage(text, to: query, from: caller.id) {
            case .success: XCTFail("Unexpected delivery"); return ""
            case let .failure(error): return error.message
            }
        }
        let empty = await error("10000", " \n")
        XCTAssertEqual(empty, AgentDeliveryError.emptyText.message)
        let own = await error(AgentChatShortID.full(caller.id))
        XCTAssertEqual(own, AgentDeliveryError.ownChat.message)
        let unknown = await error("missing")
        XCTAssertEqual(unknown, AgentDeliveryError.unknown("missing").message)
        let ambiguous = await error("1000")
        XCTAssertTrue(ambiguous.contains("10000 (One)"))
        XCTAssertTrue(ambiguous.contains("10001 (Two)"))
        first.update(items: [], status: .ended)
        let ended = await error("10000")
        XCTAssertEqual(ended, AgentDeliveryError.ended("10000").message)
        first.update(items: [], status: .idle)
        let rejected = await error("10000")
        XCTAssertEqual(rejected, AgentDeliveryError.notTaken("10000").message)
        first.update(items: [], status: .dormant)
        first.setDraft(.init(text: "Untouched"))
        let unlaunched = await error("10000")
        XCTAssertEqual(unlaunched, AgentDeliveryError.notTaken("10000").message)
        XCTAssertEqual(first.draft.text, "Untouched")
        XCTAssertNil(first.unsent)
    }

    func testPeerDraftPrefixesShiftBothMentionRanges() {
        let sender = AgentMessageSender(id: "abcd", title: "Sender")
        let mention = AgentTabMention(tabId: 1, title: "Tab", url: "https://example.com", range: NSRange(location: 0, length: 4))
        let message = AgentQueuedMessage(text: "@Tab body", mentions: [mention], sender: sender)
        let draft = AgentComposerDraft(text: "@Tab later", mentions: [mention]).prepending(message)
        XCTAssertEqual(draft.text, sender.header + "\n@Tab body\n@Tab later")
        XCTAssertEqual(draft.mentions.map { $0.range.location }, [sender.header.utf16.count + 1, message.draftText.utf16.count + 1])
    }

    @MainActor func testFileAttachmentsImportPersistAndCleanUpFailedCreation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Example.swift")
        try Data("let answer = 42".utf8).write(to: source)
        let route = AgentChatRoute(baseDirectory: root)
        var requests: [DrifterLaunchRequest] = []
        let store = AgentChatStore(route: route, tabExists: { _ in true }, browserSessionFactory: { request, _, _ in
            requests.append(request); return FakeSession()
        })
        defer { store.terminate() }
        let conversation = try store.create(request: .init(prompt: "", attachments: [.file(.init(url: source))],
            config: .init(folder: root), windowId: 1), tabId: 1)
        let folder = route.attachmentsDirectory(for: conversation.id)
        let imported = try XCTUnwrap(requests.first?.attachments.files.first)
        XCTAssertEqual(imported.url, folder.appendingPathComponent("Example.swift"))
        XCTAssertEqual(try Data(contentsOf: imported.url), try Data(contentsOf: source))
        XCTAssertEqual(conversation.title, "Example.swift")
        let duplicate = try conversation.importAttachments([.file(.init(url: source))])
        XCTAssertEqual(duplicate.files.first?.url.lastPathComponent, "Example 2.swift")
        XCTAssertEqual(try conversation.importAttachments([.file(imported)]), [.file(imported)])
        var transcript = ClaudeCodeTranscript()
        transcript.userSent(text: "Read this", attachments: [.file(imported)])
        conversation.update(items: transcript.items, status: .idle)
        store.saveRecord(conversation.id, synchronously: true)
        XCTAssertEqual(route.readRecord(for: conversation.id)?.items.first?.files, [imported])
        let before = try FileManager.default.contentsOfDirectory(atPath: route.directory.path).sorted()
        XCTAssertThrowsError(try store.create(request: .init(prompt: "", attachments: [.file(.init(url: root.appendingPathComponent("missing")))],
            config: .init(folder: root), windowId: 1), tabId: 2))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: route.directory.path).sorted(), before)
    }

    func testNewAndLegacyHTMLMarkersResolveEngine() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let route = AgentChatRoute(baseDirectory: root), id = UUID()
        try FileManager.default.createDirectory(at: route.directory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: route.canonicalURL(for: UUID()).deletingLastPathComponent(), withIntermediateDirectories: true)
        for (marker, engine) in [("claudeCode", DrifterEngine.claude), ("browserAgent", .claude), ("browserAgent codex", .codex),
                                 ("drifter claude", .claude), ("drifter codex", .codex)] {
            try "<meta name=\"mist-agent\" content=\"\(marker)\">".write(to: route.placeholderURL(for: id), atomically: true, encoding: .utf8)
            XCTAssertEqual(route.storedAgent(for: id), engine)
        }
        XCTAssertTrue(AgentChatRoute.html(title: "Title", background: "#fff", engine: .codex).contains("content=\"drifter codex\""))
    }

    @MainActor func testPendingClaudeTitlePersistsThroughDormantRestore() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let route = AgentChatRoute(baseDirectory: root), id = UUID()
        try route.writeRecord(.init(title: "Automatic", background: "#fff", drifter: .init(folder: root), sessionId: "saved"), for: id)
        let store = AgentChatStore(route: route, tabExists: { _ in false })
        store.rename(id, to: "Manual", tabId: 42)
        XCTAssertEqual(store.conversation(for: id)?.pendingSessionTitle, "Manual")
        store.terminate()
        let reopened = AgentChatStore(route: route, tabExists: { _ in true })
        defer { reopened.terminate() }
        XCTAssertTrue(reopened.restoreIfNeeded(id, tabId: 43))
        XCTAssertEqual(reopened.conversation(for: id)?.pendingSessionTitle, "Manual")
        XCTAssertEqual(reopened.entry(for: id)?.restoredSessionId, "saved")
        XCTAssertNil(reopened.entry(for: id)?.session)
    }

    func testLegacyRecordsMigrateWithoutLosingConversationData() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let route = AgentChatRoute(baseDirectory: root)
        let folder = root.appendingPathComponent("OriginalProject")
        let config = DrifterConfig(engine: .codex, model: "saved-model", effort: "high", confirmation: .ask, folder: folder)
        var shell = AgentChatItem.ShellCommand(command: "pwd")
        shell.stdout.append("/old/project\n"); shell.status = .succeeded
        let record = AgentChatRecord(title: "Saved title", background: "#fff", drifter: config, sessionId: "session",
            items: [.init(id: "shell", kind: .shellCommand(shell))], queued: ["Next"], draft: "Draft",
            memoryFolders: ["/old/memory"], skillFolders: ["/old/skills"], manualTitle: "Manual", pendingSessionTitle: "Pending")
        let data = try JSONEncoder().encode(record)
        let base = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        for mode in ["manual", "plan", "acceptEdits", "auto", "bypassPermissions"] {
            let id = UUID()
            var legacy = base
            legacy.removeValue(forKey: "drifter")
            legacy["agent"] = "claudeCode"
            legacy["claudeCode"] = ["folder": folder.absoluteString, "permissionMode": mode, "model": "sonnet", "effort": "low"]
            try FileManager.default.createDirectory(at: route.chatDirectory(for: id), withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: legacy).write(to: route.recordURL(for: id))
            let migrated = try XCTUnwrap(route.readRecord(for: id))
            XCTAssertEqual(migrated.drifter, .init(engine: .claude, model: "sonnet", effort: "low",
                confirmation: ["manual", "plan"].contains(mode) ? .ask : .skip, folder: folder))
            XCTAssertEqual(migrated.items, record.items)
            XCTAssertEqual(migrated.sessionId, record.sessionId)
            XCTAssertEqual(migrated.queued, record.queued)
            XCTAssertEqual(migrated.draft, record.draft)
            XCTAssertEqual(migrated.skillFolders, record.skillFolders)
            XCTAssertEqual(migrated.memoryFolders, record.memoryFolders)
            XCTAssertEqual(migrated.manualTitle, "Manual")
            XCTAssertEqual(migrated.pendingSessionTitle, "Pending")
        }
        for engine in DrifterEngine.allCases {
            let id = UUID()
            var legacy = base
            legacy.removeValue(forKey: "drifter")
            legacy["agent"] = "browserAgent"
            legacy["browserAgent"] = ["engine": engine.rawValue, "model": "saved-model", "effort": "high", "confirmation": "ask"]
            try FileManager.default.createDirectory(at: route.chatDirectory(for: id), withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: legacy).write(to: route.recordURL(for: id))
            let migrated = try XCTUnwrap(route.readRecord(for: id))
            XCTAssertEqual(migrated.drifter, .init(engine: engine, model: "saved-model", effort: "high", confirmation: .ask,
                folder: route.legacyBrowserAgentDirectory))
            let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(migrated)) as? [String: Any])
            XCTAssertNotNil(encoded["drifter"])
            XCTAssertNil(encoded["agent"])
            XCTAssertNil(encoded["browserAgent"])
            XCTAssertNil(encoded["claudeCode"])
        }
    }

    @MainActor func testClearCodexKeepsSettingsFolderAndPanelWithoutLaunching() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var launches: [DrifterLaunchRequest] = [], navigated: URL?
        let store = AgentChatStore(route: .init(baseDirectory: root), tabExists: { _ in true }, windowId: { _ in 1 },
            navigateTab: { _, url in navigated = url }, browserSessionFactory: { request, _, _ in launches.append(request); return FakeSession() })
        defer { store.terminate() }
        let config = DrifterConfig(engine: .codex, model: "gpt", effort: "high", confirmation: .ask, folder: root)
        let old = try store.create(request: .init(prompt: "Hello", config: config, windowId: 1), tabId: 42)
        store.setPanelChat(old.id, for: 9)
        try store.clear(old.id)
        let id = try XCTUnwrap(store.panelChat(for: 9)), fresh = try XCTUnwrap(store.entry(for: id))
        XCTAssertNotEqual(id, old.id)
        XCTAssertEqual(fresh.config, config)
        XCTAssertEqual(fresh.conversation.status, .dormant)
        XCTAssertTrue(fresh.conversation.items.isEmpty)
        XCTAssertEqual(launches.count, 1)
        XCTAssertEqual(navigated, store.route.placeholderURL(for: id))
        store.restart(id, prompt: "Next", attachments: [], mentions: [])
        XCTAssertEqual(launches.count, 2)
        XCTAssertEqual(launches.last?.config, config)
        XCTAssertNil(launches.last?.resume?.sessionId)
        XCTAssertTrue(store.canRestore(old.id))
    }




    private func savedItems(image: AgentImageAttachment) -> [AgentChatItem] {
        [.init(id: "user", kind: .userMessage(text: "@News", images: [image]),
               mentions: [.init(tabId: 9, title: "News", url: "https://news.test", range: NSRange(location: 0, length: 5))]),
         .init(id: "assistant", kind: .assistantText(text: "Working", isStreaming: true)),
         .init(id: "tool", kind: .toolCall(.init(toolUseId: "tool", name: "Bash", inputSummary: "pwd", inputJSON: "{}", background: .running))),
         .init(id: "permission", kind: .permissionRequest(.init(requestId: "permission", toolName: "Bash", summary: "Allow?"))),
         .init(id: "allowed", kind: .permissionRequest(.init(requestId: "allowed", toolName: "AskUserQuestion", summary: "Question",
               status: .allowed, resolution: .allowWithInput(.object(["answers": .string("yes")]))))),
         .init(id: "peer", kind: .peerMessage(name: "Peer", body: "Update")),
         .init(id: "info", kind: .notice(text: "Notice", level: .info)),
         .init(id: "end", kind: .turnEnd(durationMilliseconds: 1200, finishedAt: Date(timeIntervalSince1970: 100))),
         .init(id: "shell", kind: .shellCommand(.init(command: "pwd")))]
    }

    func testSettledShellStopsAndKeepsOutput() throws {
        var command = AgentChatItem.ShellCommand(command: "pwd")
        command.stdout.append("/folder\n")
        let item = AgentChatItem(id: "shell", kind: .shellCommand(command))
        command.status = .stopped
        XCTAssertEqual(item.settled.kind, .shellCommand(command))

    }

    func testLinkMatchesTabIgnoringFragmentAndTrailingSlashOnly() {
        let key = AgentChatLink.matchKey
        XCTAssertEqual(key("https://github.com/o/r/pull/1512"), key("https://github.com/o/r/pull/1512/#discussion"))
        XCTAssertEqual(key("https://GitHub.com/o/r/pull/1512"), key("https://github.com/o/r/pull/1512"))
        XCTAssertEqual(key("https://example.com"), key("https://example.com/"))
        XCTAssertEqual(key("https://example.com/a?q=1#x"), key("https://example.com/a/?q=1"))
        XCTAssertNotEqual(key("https://github.com/o/r/pull/1512/files"), key("https://github.com/o/r/pull/1512"))
        XCTAssertNotEqual(key("https://example.com/a?q=1"), key("https://example.com/a?q=2"))
        XCTAssertNotEqual(key("https://example.com/a"), key("http://example.com/a"))
        XCTAssertNil(key("not a url"))
    }

    func testRecordRoundTripUsesImageFilesAndToleratesMissingImage() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let route = AgentChatRoute(baseDirectory: directory), id = UUID()
        let image = AgentImageAttachment(data: Data("image bytes kept out of JSON".utf8), mediaType: "image/jpeg")
        let record = AgentChatRecord(title: "Saved", background: "#123456",
            drifter: .init(engine: .codex, model: "gpt", effort: "high", confirmation: .ask), sessionId: "session",
            items: savedItems(image: image), queued: ["Queued"], draft: "Draft", memoryFolders: ["/memory", "/team"], skillFolders: ["/skills"])
        try route.writeRecord(record, for: id)
        let loaded = try XCTUnwrap(route.readRecord(for: id))
        XCTAssertEqual(loaded.title, record.title)
        XCTAssertEqual(loaded.background, record.background)
        XCTAssertEqual(loaded.drifter, record.drifter)
        XCTAssertEqual(loaded.drifter, record.drifter)
        XCTAssertEqual(loaded.sessionId, record.sessionId)
        XCTAssertEqual(loaded.items, record.items)
        XCTAssertEqual(loaded.queued, record.queued)
        XCTAssertEqual(loaded.draft, record.draft)
        XCTAssertEqual(loaded.memoryFolders, record.memoryFolders)
        XCTAssertEqual(loaded.skillFolders, record.skillFolders)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: route.recordURL(for: id))) as? [String: Any])
        legacy.removeValue(forKey: "memoryFolders")
        legacy.removeValue(forKey: "skillFolders")
        let imageURL = try route.imageURL(image, for: id)
        let decoder = JSONDecoder()
        decoder.userInfo[.legacyBrowserAgentDirectory] = route.legacyBrowserAgentDirectory
        decoder.userInfo[.agentChatImages] = imageURL.deletingLastPathComponent()
        let decodedLegacy = try decoder.decode(AgentChatRecord.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertNil(decodedLegacy.memoryFolders)
        XCTAssertNil(decodedLegacy.skillFolders)
        let json = try String(contentsOf: route.recordURL(for: id), encoding: .utf8)
        XCTAssertTrue(json.contains(imageURL.lastPathComponent))
        XCTAssertFalse(json.contains(image.data.base64EncodedString()))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: imageURL.deletingLastPathComponent().path).count, 1)
        try FileManager.default.removeItem(at: imageURL)
        let missing = try XCTUnwrap(route.readRecord(for: id))
        guard case let .userMessage(_, images) = missing.items[0].kind else { return XCTFail() }
        XCTAssertEqual(images.first?.data, Data())
        XCTAssertEqual(missing.items.count, record.items.count)
        try Data("invalid".utf8).write(to: route.recordURL(for: id))
        XCTAssertNil(route.readRecord(for: id))
    }

    @MainActor func testClosedChatRestoresSettledTranscriptSettingsSessionAndDraft() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var requests: [DrifterLaunchRequest] = []
        let store = AgentChatStore(route: .init(baseDirectory: directory), tabExists: { _ in false }, browserSessionFactory: { request, conversation, _ in
            requests.append(request)
            let session = FakeSession()
            session.resumeId = request.resume?.sessionId ?? "saved-session"
            conversation.onClose = { session.close() }
            return session
        })
        defer { store.terminate() }
        let config = DrifterConfig(model: "sonnet", effort: "low", folder: directory)
        let conversation = try store.create(request: .init(prompt: "Hello", attachments: [], config: config, windowId: 1), tabId: 42)
        let items = savedItems(image: .init(data: Data([1, 2, 3]), mediaType: "image/png"))
        conversation.update(items: items, status: .running)
        conversation.title = "Saved title"
        conversation.autoTitle = conversation.title
        conversation.setDraft(.init(text: "Draft"))
        conversation.contextTokens = 50_000
        conversation.memoryFolders = [directory.appendingPathComponent("memory", isDirectory: true)]
        conversation.skillFolders = [directory.appendingPathComponent("skills", isDirectory: true)]
        conversation.contextWindowSize = 200_000
        var queue = AgentMessageQueue()
        queue.enqueue(.init(text: "Queued first", attachments: [], mentions: []))
        queue.enqueue(.init(text: "Queued second", attachments: [], mentions: []))
        conversation.updateQueue(queue)
        store.closeIfTabIsGone(42)
        XCTAssertTrue(store.canRestore(conversation.id))
        let html = try Data(contentsOf: store.route.placeholderURL(for: conversation.id))
        XCTAssertTrue(store.restoreIfNeeded(conversation.id, tabId: 43))
        let restored = try XCTUnwrap(store.conversation(for: conversation.id))
        XCTAssertFalse(restored === conversation)
        XCTAssertEqual(restored.status, .dormant)
        XCTAssertEqual(restored.title, "Saved title")
        XCTAssertEqual(restored.draft.text, "Queued first\nQueued second\nDraft")
        XCTAssertEqual(restored.contextTokens, 50_000)
        XCTAssertEqual(restored.memoryFolders, conversation.memoryFolders)
        XCTAssertEqual(restored.skillFolders, conversation.skillFolders)
        XCTAssertEqual(restored.contextWindowSize, 200_000)
        XCTAssertTrue(restored.queue.isEmpty)
        XCTAssertEqual(restored.items, items.map(\.settled))
        XCTAssertEqual(restored.items[1].kind, .assistantText(text: "Working", isStreaming: false))
        guard case let .toolCall(tool) = restored.items[2].kind,
              case let .permissionRequest(permission) = restored.items[3].kind else { return XCTFail() }
        XCTAssertEqual(tool.status, .failed)
        XCTAssertEqual(tool.background, .finished)
        XCTAssertEqual(permission.status, .denied)
        XCTAssertEqual(store.entry(for: conversation.id)?.tabId, 43)
        XCTAssertEqual(store.entry(for: conversation.id)?.config, config)
        XCTAssertEqual(requests.count, 1)
        XCTAssertNil(store.entry(for: conversation.id)?.session)
        XCTAssertEqual(store.entry(for: conversation.id)?.restoredSessionId, "saved-session")
        XCTAssertEqual(try Data(contentsOf: store.route.placeholderURL(for: conversation.id)), html)
    }

    @MainActor func testReopeningBeforeCloseDelayReassignsLiveConversation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var launches = 0
        let store = AgentChatStore(route: .init(baseDirectory: directory), closeDelay: 10_000_000, tabExists: { $0 == 43 }, browserSessionFactory: { _, _, _ in
            launches += 1
            return FakeSession()
        })
        defer { store.terminate() }
        let conversation = try store.create(request: .init(prompt: "Hello", attachments: [], config: .init(folder: directory), windowId: 1), tabId: 42)
        store.tabDidClose(42)
        XCTAssertTrue(store.restoreIfNeeded(conversation.id, tabId: 43))
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(store.conversation(for: conversation.id) === conversation)
        XCTAssertEqual(store.entry(for: conversation.id)?.tabId, 43)
        XCTAssertTrue(store.restoreIfNeeded(conversation.id, tabId: 44))
        XCTAssertEqual(store.entry(for: conversation.id)?.tabId, 43, "A second tab must not steal a still-live entry")
        XCTAssertEqual(launches, 1)
    }

    @MainActor func testWindowCloseSweepsGoneTabsAndSkipsPendingPanelLaunch() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var closes = 0
        let store = AgentChatStore(route: .init(baseDirectory: directory), closeDelay: 10_000_000, tabExists: { $0 == 43 }, browserSessionFactory: { _, conversation, _ in
            conversation.onClose = { closes += 1 }
            return FakeSession()
        })
        defer { store.terminate() }
        var chats: [Int: UUID] = [:]
        for tabId in [-1, 42, 43] {
            chats[tabId] = try store.create(request: .init(prompt: "Chat", attachments: [], config: .init(folder: directory), windowId: 1), tabId: tabId).id
        }
        store.windowWillClose()
        store.windowWillClose()
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(closes, 1)
        XCTAssertNil(store.conversation(for: chats[42]!))
        XCTAssertNotNil(store.conversation(for: chats[43]!))
        XCTAssertNotNil(store.conversation(for: chats[-1]!))
        XCTAssertTrue(store.canRestore(chats[42]!))
    }


    @MainActor func testRestoredBrowserChatLaunchesWithItsFirstMessageOnSavedEngineAndSettings() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var requests: [DrifterLaunchRequest] = []
        let store = AgentChatStore(route: .init(baseDirectory: directory), tabExists: { _ in false }, windowId: { $0 == 42 ? 222 : nil },
            browserSessionFactory: { request, _, folder in
                XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path))
                requests.append(request)
                return FakeSession()
            })
        defer { store.terminate() }
        for engine in DrifterEngine.allCases {
            let id = UUID(), config = DrifterConfig(engine: engine, model: "saved-model", effort: "low", confirmation: .ask)
            let items = [AgentChatItem(id: "user", kind: .userMessage(text: "Earlier", images: []))]
            let record = AgentChatRecord(title: "Saved browser", background: "#fff", drifter: config,
                sessionId: "saved", items: items, queued: [], draft: "Next", contextTokens: 1_000, contextWindowSize: 10_000)
            try store.route.writeRecord(record, for: id)
            XCTAssertTrue(store.restoreIfNeeded(id, tabId: 42))
            XCTAssertTrue(requests.isEmpty, "Showing a restored chat launches nothing")
            let conversation = try XCTUnwrap(store.conversation(for: id))
            XCTAssertEqual(conversation.status, .dormant)
            XCTAssertEqual(conversation.contextTokens, 1_000)
            XCTAssertEqual(conversation.contextWindowSize, 10_000)
            let settings = try XCTUnwrap(store.entry(for: id)?.settings)
            XCTAssertEqual(settings.config, config)
            XCTAssertTrue(settings.isEnabled)
            settings.selectConfirmation(.skip)
            store.saveRecord(id, synchronously: true)
            XCTAssertEqual(store.route.readRecord(for: id)?.sessionId, "saved")
            XCTAssertEqual(store.route.readRecord(for: id)?.drifter.confirmation, .skip)
            conversation.restart(text: "Next", attachments: [], mentions: [])
            XCTAssertEqual(requests.count, 1)
            let request = try XCTUnwrap(requests.last)
            XCTAssertEqual(request.prompt, "Next")
            XCTAssertEqual(request.windowId, 222)
            XCTAssertEqual(request.config, DrifterConfig(engine: engine, model: "saved-model", effort: "low", confirmation: .skip))
            XCTAssertEqual(request.resume, .init(sessionId: "saved", items: items.map(\.settled)))
            XCTAssertTrue(store.conversation(for: id) === conversation)
            XCTAssertTrue(store.entry(for: id)?.settings === settings)
            requests.removeAll()
        }
    }

    @MainActor func testFailedBrowserChatRestartsThroughRestoreKeepingConversationAndSettings() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var requests: [DrifterLaunchRequest] = []
        let store = AgentChatStore(route: .init(baseDirectory: directory), tabExists: { _ in true }, windowId: { $0 == 42 ? 333 : nil },
            browserSessionFactory: { request, _, _ in
                requests.append(request)
                let session = FakeSession()
                session.resumeId = request.resume?.sessionId ?? "thread"
                return session
            })
        defer { store.terminate() }
        let config = DrifterConfig(engine: .codex, model: "saved-model", effort: "low", confirmation: .ask)
        let conversation = try store.create(request: .init(prompt: "Hello", config: config, windowId: 7), tabId: 42)
        let settings = try XCTUnwrap(store.entry(for: conversation.id)?.settings)
        let items = [AgentChatItem(id: "user", kind: .userMessage(text: "Hello", images: [])),
                     AgentChatItem(id: "tool", kind: .toolCall(.init(toolUseId: "tool", name: "Bash", inputSummary: "pwd", inputJSON: "{}")))]
        conversation.update(items: items, status: .idle)
        conversation.onRestart?(.init(text: "Ignored"))
        XCTAssertEqual(requests.count, 1)
        conversation.update(items: items, status: .failed("Codex stopped unexpectedly."))
        let image = AgentImageAttachment(data: Data([1]), mediaType: "image/png")
        conversation.onRestart?(.init(text: "Again", attachments: [.image(image)]))
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests.last?.prompt, "Again")
        XCTAssertEqual(requests.last?.attachments, [.image(image)])
        XCTAssertEqual(requests.last?.windowId, 333)
        XCTAssertEqual(requests.last?.config, config)
        XCTAssertEqual(requests.last?.resume, .init(sessionId: "thread", items: items.map(\.settled)))
        XCTAssertTrue(store.conversation(for: conversation.id) === conversation)
        XCTAssertTrue(store.entry(for: conversation.id)?.settings === settings)
        XCTAssertEqual(store.entry(for: conversation.id)?.tabId, 42)
    }

    @MainActor func testHiddenPreviewCardsStayHiddenUntilShownOrTheChatHasNone() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AgentChatStore(route: .init(baseDirectory: directory), tabExists: { _ in true },
            windowId: { _ in 1 }, browserSessionFactory: { _, _, _ in FakeSession() })
        defer { store.terminate() }
        let conversation = AgentConversation()
        store.register(.init(conversation: conversation,
            settings: DrifterSettings(config: .init(), running: false), tabId: 42,
            session: FakeSession(), browserPreview: .init(principalId: "p", windowId: 1)))
        conversation.update(items: [], status: .running)
        store.setBrowserPreviewHidden(conversation.id, true)
        XCTAssertFalse(store.isBrowserPreviewHidden(conversation.id), "A chat with no cards has nothing to hide")
        store.reportWorkingTab(principalId: "p", tabId: 7, live: true)
        let posted = expectation(forNotification: .browserAgentPreviewDidChange, object: store)
        store.setBrowserPreviewHidden(conversation.id, true)
        wait(for: [posted], timeout: 1)
        XCTAssertTrue(store.isBrowserPreviewHidden(conversation.id))
        store.reportWorkingTab(principalId: "p", tabId: 8, live: true)
        XCTAssertTrue(store.isBrowserPreviewHidden(conversation.id), "A new card joins the hidden ones")
        store.setBrowserPreviewHidden(conversation.id, false)
        XCTAssertFalse(store.isBrowserPreviewHidden(conversation.id))
        store.setBrowserPreviewHidden(conversation.id, true)
        store.dismissBrowserPreview(conversation.id, tabId: 7)
        store.dismissBrowserPreview(conversation.id, tabId: 8)
        store.reportWorkingTab(principalId: "p", tabId: 9, live: true)
        XCTAssertEqual(store.entry(for: conversation.id)?.browserPreview?.cards.map(\.tabId), [9])
        XCTAssertFalse(store.isBrowserPreviewHidden(conversation.id), "Cards after the chat had none show again")
    }

    @MainActor func testBrowserFolderSurvivesRestartAndTracksTurnsWithoutPreviewCards() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AgentChatStore(route: .init(baseDirectory: directory), tabExists: { _ in true },
            windowId: { _ in 1 }, browserSessionFactory: { _, _, _ in FakeSession() })
        defer { store.terminate() }
        var clock = Date().addingTimeInterval(3600)
        store.now = { clock }
        let conversation = AgentConversation()
        var folder = BrowserAgentFolderState(windowId: 1, token: "folder")
        folder.join(7, now: clock)
        store.register(.init(conversation: conversation,
            settings: DrifterSettings(config: .init(), running: false), tabId: 42,
            session: FakeSession(), browserPreview: .init(principalId: "p", windowId: 1),
            browserFolder: folder))
        conversation.update(items: [], status: .running)
        store.reportWorkingTab(principalId: "p", tabId: 7, live: true)
        store.dismissBrowserPreview(conversation.id, tabId: 7)
        XCTAssertNil(store.browserPreviewExpiryDeadline)
        clock.addTimeInterval(60)
        conversation.update(items: [], status: .failed("Failed"))
        let deadline = clock.addingTimeInterval(BrowserAgentPreviewState.idleLifetime)
        XCTAssertEqual(store.entry(for: conversation.id)?.browserFolder?.nextExpiry, deadline)
        store.restart(conversation.id, prompt: "Again", attachments: [], mentions: [])
        XCTAssertEqual(store.entry(for: conversation.id)?.browserFolder?.token, "folder")
        XCTAssertEqual(store.entry(for: conversation.id)?.browserFolder?.members.keys.sorted(), [7])
        XCTAssertEqual(store.entry(for: conversation.id)?.browserFolder?.nextExpiry, deadline)
        store.tabDidClose(7)
        XCTAssertTrue(store.entry(for: conversation.id)?.browserFolder?.members.isEmpty == true)
    }



    @MainActor func testRestartMessageReturnsUnlessTheAgentTakesIt() {
        let conversation = AgentConversation()
        conversation.update(items: [], status: .failed("Stopped"))
        conversation.setDraft(.init(text: "Later"))
        let image = AgentImageAttachment(data: Data([1]), mediaType: "image/png")
        conversation.restart(text: "First", attachments: [.image(image)], mentions: [])
        XCTAssertEqual(conversation.draft.text, "First\nLater")
        XCTAssertEqual(conversation.draft.attachments, [.image(image)])
        conversation.onRestart = { _ in conversation.update(items: [], status: .starting) }
        conversation.setDraft(.init(text: ""))
        conversation.restart(text: "Second", attachments: [], mentions: [])
        XCTAssertEqual(conversation.draft.text, "")
        conversation.update(items: [], status: .failed("Stopped again"))
        XCTAssertEqual(conversation.draft.text, "Second")
        XCTAssertTrue(conversation.draft.attachments.isEmpty)
        conversation.restart(text: "Third", attachments: [], mentions: [])
        conversation.update(items: [], status: .idle)
        conversation.update(items: [], status: .running)
        conversation.update(items: [], status: .failed("Stopped after taking it"))
        XCTAssertEqual(conversation.draft.text, "Second")
        XCTAssertNil(conversation.unsent)
    }

    @MainActor func testContinuousChangesAreThrottledAndDraftDoesNotPublishConversation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AgentChatStore(route: .init(baseDirectory: directory), tabExists: { _ in true }, browserSessionFactory: { _, _, _ in FakeSession() })
        defer { store.terminate() }
        let conversation = try store.create(request: .init(prompt: "Hello", attachments: [], config: .init(folder: directory), windowId: 1), tabId: 42)
        var publications = 0
        let subscription = conversation.objectWillChange.sink { publications += 1 }
        conversation.setDraft(.init(text: "Typed draft"))
        XCTAssertEqual(publications, 0)
        for index in 0..<15 {
            conversation.update(items: [.init(id: "stream", kind: .assistantText(text: String(index), isStreaming: true))], status: .running)
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        let record = try XCTUnwrap(store.route.readRecord(for: conversation.id))
        XCTAssertEqual(record.draft, "Typed draft")
        XCTAssertFalse(record.items.isEmpty, "Saving must fire while streaming continues")
        withExtendedLifetime(subscription) {}
    }

    @MainActor func testPanelHistorySurvivesNewChatAndFallsBackAfterAChatCloses() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AgentChatStore(route: .init(baseDirectory: directory), tabExists: { _ in false }, browserSessionFactory: { _, _, _ in FakeSession() })
        defer { store.terminate() }
        let first = try store.create(request: .init(prompt: "First", attachments: [], config: .init(folder: directory), windowId: 1), tabId: 41)
        let second = try store.create(request: .init(prompt: "Second", attachments: [], config: .init(folder: directory), windowId: 1), tabId: 42)
        store.setPanelChat(first.id, for: 7)
        store.setPanelChat(nil, for: 7)
        XCTAssertNil(store.panelChat(for: 7))
        XCTAssertEqual(store.panelChatHistory(for: 7).map(\.id), [first.id])
        store.setPanelChat(second.id, for: 7)
        store.setPanelChat(first.id, for: 7)
        XCTAssertEqual(store.panelChatHistory(for: 7).map(\.id), [second.id, first.id])
        XCTAssertTrue(store.panelChatHistory(for: 8).isEmpty)
        store.closeIfTabIsGone(41)
        XCTAssertEqual(store.panelChat(for: 7), second.id)
        XCTAssertEqual(store.panelChatHistory(for: 7).map(\.id), [second.id])
        store.closeIfTabIsGone(42)
        XCTAssertNil(store.panelChat(for: 7))
        XCTAssertTrue(store.panelChatHistory(for: 7).isEmpty)
        store.tabDidClose(7)
        XCTAssertTrue(store.panelChatHistory(for: 7).isEmpty)
    }

    @MainActor
    func testPanelMappingFollowsHostAndChatLifetimes() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AgentChatStore(route: .init(baseDirectory: directory), tabExists: { _ in false },
                                   browserSessionFactory: { _, _, _ in FakeSession() })
        defer { store.terminate() }
        let conversation = try store.create(request: .init(prompt: "Panel", attachments: [], config: .init(folder: directory), windowId: 1),
                                            tabId: 42)
        store.setPanelChat(conversation.id, for: 7)
        XCTAssertEqual(store.panelChat(for: 7), conversation.id)
        store.tabDidClose(7)
        XCTAssertNil(store.panelChat(for: 7))
        XCTAssertNotNil(store.conversation(for: conversation.id), "Closing the host does not close its separate chat")
        store.setPanelChat(conversation.id, for: 8)
        store.closeIfTabIsGone(42)
        XCTAssertNil(store.panelChat(for: 8))
        XCTAssertNil(store.conversation(for: conversation.id))
        store.setPanelChat(UUID(), for: 9)
        store.terminate()
        XCTAssertNil(store.panelChat(for: 9))
    }

    @MainActor
    func testPanelHostIsTheOpenTabWhosePanelStartedTheChat() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var open: Set<Int> = [7, 8, 42, 43]
        let store = AgentChatStore(route: .init(baseDirectory: directory), closeDelay: 10_000_000, tabExists: { open.contains($0) },
                                   browserSessionFactory: { _, _, _ in FakeSession() })
        defer { store.terminate() }
        let first = try store.create(request: .init(prompt: "First", attachments: [], config: .init(folder: directory), windowId: 1), tabId: 42)
        let second = try store.create(request: .init(prompt: "Second", attachments: [], config: .init(folder: directory), windowId: 1), tabId: 43)
        XCTAssertNil(store.panelHost(of: first.id), "A chat not started from a panel has no host")
        store.setPanelChat(first.id, for: 7)
        store.setPanelChat(nil, for: 7)
        store.setPanelChat(second.id, for: 8)
        store.setPanelChat(nil, for: 8)
        XCTAssertEqual(store.panelHost(of: first.id), 7, "Starting a new chat in the panel keeps the earlier chat's host")
        XCTAssertEqual(store.panelHost(of: second.id), 8)
        open.remove(7)
        XCTAssertNil(store.panelHost(of: first.id), "A closed host is no host")

        var changes = 0
        let subscription = store.objectWillChange.sink { changes += 1 }
        defer { subscription.cancel() }
        store.tabDidClose(8)
        XCTAssertEqual(changes, 1, "Closing a host whose panel shows no chat still updates pages")
        XCTAssertNil(store.panelHost(of: second.id))
        changes = 0
        store.windowWillClose()
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(changes, 1, "A closed window's host tabs are forgotten")
        XCTAssertTrue(store.panelChatHistory(for: 7).isEmpty)
        XCTAssertNotNil(store.conversation(for: first.id))
    }

    @MainActor
    func testMountLinksAnUnlinkedChatOnlyToAnOpenTabWithAnEmptyPanel() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var open: Set<Int> = [7, 8, 9, 42, 43, 44]
        let store = AgentChatStore(route: .init(baseDirectory: directory), tabExists: { open.contains($0) },
                                   browserSessionFactory: { _, _, _ in FakeSession() })
        defer { store.terminate() }
        func create(_ tab: Int) throws -> UUID {
            try store.create(request: .init(prompt: "Test", attachments: [], config: .init(folder: directory), windowId: 1), tabId: tab).id
        }
        let first = try create(42), second = try create(43), panelStarted = try create(44)
        store.setPanelChat(panelStarted, for: 9)
        var changes = 0
        let subscription = store.objectWillChange.sink { changes += 1 }
        defer { subscription.cancel() }
        XCTAssertTrue(store.mount(first, to: 7))
        XCTAssertEqual(store.panelHost(of: first), 7)
        XCTAssertEqual(store.panelChat(for: 7), first)
        XCTAssertGreaterThan(changes, 0)
        XCTAssertFalse(store.mount(first, to: 8))
        XCTAssertFalse(store.mount(second, to: 7))
        XCTAssertFalse(store.mount(second, to: 99))
        XCTAssertFalse(store.mount(panelStarted, to: 8))
        XCTAssertFalse(store.mount(UUID(), to: 8))
        store.setPanelChat(nil, for: 9)
        XCTAssertTrue(store.mount(second, to: 9))
        open.remove(7)
        store.tabDidClose(7)
        XCTAssertNil(store.panelHost(of: first))
        XCTAssertTrue(store.mount(first, to: 8))
    }

    @MainActor
    func testUnmountEmptiesTheHostPanelAndKeepsTheChatRunning() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AgentChatStore(route: .init(baseDirectory: directory), tabExists: { [7, 8, 42, 43].contains($0) },
                                   browserSessionFactory: { _, _, _ in FakeSession() })
        defer { store.terminate() }
        let earlier = try store.create(request: .init(prompt: "Test", attachments: [], config: .init(folder: directory), windowId: 1), tabId: 42).id
        let mounted = try store.create(request: .init(prompt: "Test", attachments: [], config: .init(folder: directory), windowId: 1), tabId: 43).id
        store.setPanelChat(earlier, for: 7)
        XCTAssertTrue(store.mount(mounted, to: 8))
        store.setPanelChat(mounted, for: 7)
        var changes = 0
        let subscription = store.objectWillChange.sink { changes += 1 }
        defer { subscription.cancel() }
        store.unmount(mounted)
        XCTAssertNil(store.panelHost(of: mounted))
        XCTAssertNil(store.panelChat(for: 7), "The panel showing the chat goes back to empty")
        XCTAssertNil(store.panelChat(for: 8))
        XCTAssertEqual(store.panelChatHistory(for: 8).map(\.id), [])
        XCTAssertEqual(store.panelChatHistory(for: 7).map(\.id), [earlier])
        XCTAssertNotNil(store.entry(for: mounted), "The chat keeps running in its own tab")
        XCTAssertEqual(changes, 1)
        store.unmount(mounted)
        XCTAssertEqual(changes, 1, "Unmounting an unlinked chat changes nothing")
        XCTAssertTrue(store.mount(mounted, to: 8))
        XCTAssertEqual(store.panelHost(of: mounted), 8)
    }

    @MainActor
    func testUnmountClearsANewChatsDraftThatIsOnlyTheHostMention() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AgentChatStore(route: .init(baseDirectory: directory), tabExists: { [8, 9, 43].contains($0) },
                                   browserSessionFactory: { _, _, _ in FakeSession() })
        defer { store.terminate() }
        let conversation = try store.create(request: .init(prompt: "Test", attachments: [], config: .init(folder: directory), windowId: 1), tabId: 43)
        conversation.update(items: [], status: .dormant)
        func mention(_ tabId: Int) -> AgentTabMention {
            AgentTabMention(tabId: tabId, title: "Host", url: "https://example.com", range: NSRange(location: 0, length: 5))
        }
        let kept: [AgentComposerDraft] = [
            .init(text: "@Host summarize this", mentions: [mention(8)]),
            .init(text: "@Host ", mentions: [mention(9)]),
            .init(text: "@Host ", mentions: [mention(8)], attachments: [.file(.init(url: directory))]),
        ]
        for draft in kept {
            XCTAssertTrue(store.mount(conversation.id, to: 8))
            conversation.setDraft(draft)
            store.unmount(conversation.id)
            XCTAssertEqual(conversation.draft, draft)
        }
        let hostOnly = AgentComposerDraft(text: "@Host ", mentions: [mention(8)])
        conversation.update(items: [.init(id: "user", kind: .userMessage(text: "Test", images: []))], status: .idle)
        XCTAssertTrue(store.mount(conversation.id, to: 8))
        conversation.setDraft(hostOnly)
        store.unmount(conversation.id)
        XCTAssertEqual(conversation.draft, hostOnly, "The panel never inserts into a started chat, so the user typed it")
        conversation.update(items: [], status: .dormant)
        XCTAssertTrue(store.mount(conversation.id, to: 8))
        conversation.setDraft(hostOnly)
        store.unmount(conversation.id)
        XCTAssertEqual(conversation.draft, AgentComposerDraft())
    }

    @MainActor
    func testVisiblePanelsMarkSeenAndSuppressUnseenCompletions() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AgentChatStore(route: .init(baseDirectory: directory), tabExists: { _ in false },
                                   browserSessionFactory: { _, _, _ in FakeSession() })
        defer { store.terminate() }
        let conversation = try store.create(request: .init(prompt: "Panel", attachments: [], config: .init(folder: directory), windowId: 1),
                                            tabId: 42)
        func finish() {
            conversation.update(items: [], status: .running)
            conversation.update(items: [], status: .idle)
        }
        finish()
        XCTAssertTrue(store.unseenCompletions.contains(conversation.id))
        let first = UUID(), second = UUID()
        store.setPanelVisible(conversation.id, panelId: first)
        XCTAssertTrue(store.unseenCompletions.isEmpty)
        finish()
        XCTAssertTrue(store.unseenCompletions.isEmpty)
        store.setPanelVisible(conversation.id, panelId: second)
        store.setPanelVisible(nil, panelId: first)
        finish()
        XCTAssertTrue(store.unseenCompletions.isEmpty, "Another visible panel still counts")
        store.setPanelVisible(nil, panelId: second)
        finish()
        XCTAssertEqual(store.unseenCompletions, [conversation.id])
    }

    /// Store observers (the Chat panel, sidebar and address bar) refresh on every store change, so a
    /// streamed update, which republishes the chat's status, must not publish the store.
    @MainActor
    func testStreamedUpdatesDoNotPublishTheStore() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AgentChatStore(route: .init(baseDirectory: directory), tabExists: { _ in false },
                                   browserSessionFactory: { _, _, _ in FakeSession() })
        defer { store.terminate() }
        let conversation = try store.create(request: .init(prompt: "Stream", attachments: [], config: .init(folder: directory), windowId: 1),
                                            tabId: 42)
        conversation.update(items: [], status: .running)
        var changes = 0
        let subscription = store.objectWillChange.sink { changes += 1 }
        defer { subscription.cancel() }
        var text = ""
        for chunk in 0..<20 {
            text += "line \(chunk)\n"
            conversation.update(items: [.init(id: "reply", kind: .assistantText(text: text, isStreaming: true))], status: .running, outputTokens: chunk)
        }
        XCTAssertEqual(changes, 0)
    }

    @MainActor
    func testBrowserTurnPublishesOnlyActiveFlagChangesAndOrdersWorkingTabs() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AgentChatStore(route: .init(baseDirectory: directory), tabExists: { _ in true })
        defer { store.terminate() }
        let conversation = AgentConversation()
        store.register(.init(conversation: conversation, settings: DrifterSettings(config: .init()), tabId: 42,
            session: FakeSession(), browserPreview: .init(principalId: "first", windowId: 1)))
        var notifications = 0
        let observer = NotificationCenter.default.addObserver(forName: .browserAgentPreviewDidChange,
            object: store, queue: .main) { _ in notifications += 1 }
        defer { NotificationCenter.default.removeObserver(observer) }
        for status in [AgentConversationStatus.running, .running, .awaitingPermission, .starting, .dormant] {
            conversation.update(items: [], status: status)
            XCTAssertTrue(store.entry(for: conversation.id)?.browserPreview?.turnActive == true)
            XCTAssertEqual(notifications, 1)
        }
        for status in [AgentConversationStatus.idle, .idle, .ended, .failed("Failed"), .starting, .dormant] {
            conversation.update(items: [], status: status)
            XCTAssertFalse(store.entry(for: conversation.id)?.browserPreview?.turnActive == true)
            XCTAssertEqual(notifications, 2)
        }
        for status in [AgentConversationStatus.ended, .failed("Failed")] {
            let before = notifications
            conversation.update(items: [], status: .running)
            XCTAssertEqual(notifications, before + 1)
            conversation.update(items: [], status: status)
            XCTAssertFalse(store.entry(for: conversation.id)?.browserPreview?.turnActive == true)
            XCTAssertEqual(notifications, before + 2)
        }
        let second = AgentConversation()
        store.register(.init(conversation: second, settings: DrifterSettings(config: .init()), tabId: 43,
            session: FakeSession(), browserPreview: .init(principalId: "second", windowId: 1)))
        conversation.update(items: [], status: .running)
        second.update(items: [], status: .awaitingPermission)
        store.reportWorkingTab(principalId: "first", tabId: 7, live: true)
        store.reportWorkingTab(principalId: "second", tabId: 7, live: true)
        XCTAssertEqual(store.activeBrowserPreviews(windowId: 1).map(\.principalId), ["first", "second"])
        store.reportWorkingTab(principalId: "first", tabId: 7, live: true)
        XCTAssertEqual(store.activeBrowserPreviews(windowId: 1).map(\.principalId), ["second", "first"])
        XCTAssertTrue(store.activeBrowserPreviews(windowId: 2).isEmpty)
        store.tabDidClose(7)
        XCTAssertTrue(store.activeBrowserPreviews(windowId: 1).isEmpty)
        conversation.update(items: [], status: .idle)
        second.update(items: [], status: .idle)
    }

    @MainActor
    func testNewTurnHoldsOnlyTabsReportedInThatTurn() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AgentChatStore(route: .init(baseDirectory: directory), tabExists: { _ in true })
        defer { store.terminate() }
        let conversation = AgentConversation()
        store.register(.init(conversation: conversation, settings: DrifterSettings(config: .init()), tabId: 42,
            session: FakeSession(), browserPreview: .init(principalId: "p", windowId: 1)))
        conversation.update(items: [], status: .running)
        store.reportWorkingTab(principalId: "p", tabId: 7, live: true)
        XCTAssertEqual(store.activeBrowserPreviews(windowId: 1).map(\.tabId), [7])
        conversation.update(items: [], status: .idle)
        conversation.update(items: [], status: .running)
        XCTAssertTrue(store.activeBrowserPreviews(windowId: 1).isEmpty,
                      "A new turn leaves the last turn's tab alone until the agent reports it")
        store.reportWorkingTab(principalId: "p", tabId: 7, live: true)
        XCTAssertEqual(store.activeBrowserPreviews(windowId: 1).map(\.tabId), [7])
        conversation.update(items: [], status: .idle)
    }

    @MainActor
    func testReadReportsNotifyMountsAndRefreshFolderClock() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AgentChatStore(route: .init(baseDirectory: directory), tabExists: { _ in true })
        defer { store.terminate() }
        let start = Date().addingTimeInterval(3600)
        var clock = start
        store.now = { clock }
        var folder = BrowserAgentFolderState(windowId: 1, token: "folder")
        folder.join(7, now: start)
        let first = AgentConversation()
        let second = AgentConversation()
        store.register(.init(conversation: first, settings: DrifterSettings(config: .init()), tabId: 42,
            session: FakeSession(), browserPreview: .init(principalId: "first", windowId: 1), browserFolder: folder))
        store.register(.init(conversation: second, settings: DrifterSettings(config: .init()), tabId: 43,
            session: FakeSession(), browserPreview: .init(principalId: "second", windowId: 1)))
        first.update(items: [], status: .running)
        var notifications = 0
        let observer = NotificationCenter.default.addObserver(forName: .browserAgentPreviewDidChange,
            object: store, queue: .main) { note in
                XCTAssertEqual(note.userInfo?["windowId"] as? Int, 1)
                notifications += 1
            }
        defer { NotificationCenter.default.removeObserver(observer) }

        clock = start.addingTimeInterval(10)
        XCTAssertTrue(store.reportReadTab(principalId: "first", tabId: 7, reading: true))
        XCTAssertEqual(notifications, 1)
        XCTAssertEqual(store.activeBrowserReadTabs(windowId: 1), [7])
        XCTAssertTrue(store.activeBrowserReadTabs(windowId: 2).isEmpty)
        XCTAssertTrue(store.activeBrowserPreviews(windowId: 1).isEmpty)
        XCTAssertEqual(store.entry(for: first.id)?.browserFolder?.members[7], clock)
        let initialOrder = store.entry(for: first.id)?.browserPreview?.reportOrder

        store.reportReadTab(principalId: "second", tabId: 8, reading: true)
        XCTAssertEqual(store.activeBrowserReadTabs(windowId: 1), [7])
        second.update(items: [], status: .running)
        XCTAssertEqual(store.activeBrowserReadTabs(windowId: 1), [7, 8])
        clock = start.addingTimeInterval(20)
        let beforeEnd = notifications
        XCTAssertTrue(store.reportReadTab(principalId: "first", tabId: 7, reading: false))
        XCTAssertEqual(notifications, beforeEnd + 1)
        XCTAssertEqual(store.entry(for: first.id)?.browserPreview?.reportOrder, initialOrder)
        XCTAssertEqual(store.entry(for: first.id)?.browserFolder?.members[7], clock)
        XCTAssertEqual(store.activeBrowserReadTabs(windowId: 1), [8])
        second.update(items: [], status: .idle)
        XCTAssertTrue(store.activeBrowserReadTabs(windowId: 1).isEmpty)
    }

    @MainActor
    func testBrowserPreviewExpiryUsesEarliestDeadlineAndNotifiesOncePerWindow() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AgentChatStore(route: .init(baseDirectory: directory), tabExists: { _ in true })
        defer { store.terminate() }
        let start = Date().addingTimeInterval(3600)
        var clock = start
        store.now = { clock }
        let conversation = AgentConversation()
        store.register(.init(conversation: conversation, settings: DrifterSettings(config: .init()), tabId: 42,
            session: FakeSession(), browserPreview: .init(principalId: "p", windowId: 1)))
        conversation.update(items: [], status: .running)
        store.reportWorkingTab(principalId: "p", tabId: 1, live: true)
        XCTAssertNil(store.browserPreviewExpiryDeadline)
        clock = start.addingTimeInterval(60)
        store.reportWorkingTab(principalId: "p", tabId: 2, live: true)
        XCTAssertEqual(store.browserPreviewExpiryDeadline, start.addingTimeInterval(360))
        clock = start.addingTimeInterval(120)
        conversation.update(items: [], status: .idle)
        store.dismissBrowserPreview(conversation.id, tabId: 1)
        XCTAssertEqual(store.browserPreviewExpiryDeadline, start.addingTimeInterval(420))
        clock = start.addingTimeInterval(180)
        store.reportWorkingTab(principalId: "p", tabId: 2, live: true)
        XCTAssertEqual(store.browserPreviewExpiryDeadline, start.addingTimeInterval(480))
        store.reportWorkingTab(principalId: "p", tabId: 3, live: true)
        var notifications = 0
        let observer = NotificationCenter.default.addObserver(forName: .browserAgentPreviewDidChange,
            object: store, queue: .main) { note in
                XCTAssertEqual(note.userInfo?["windowId"] as? Int, 1)
                notifications += 1
            }
        defer { NotificationCenter.default.removeObserver(observer) }
        clock = start.addingTimeInterval(480)
        store.expireBrowserPreviewCards()
        XCTAssertEqual(notifications, 1)
        XCTAssertTrue(store.browserPreviewCardTabs(windowId: 1).isEmpty)
        XCTAssertNil(store.browserPreviewExpiryDeadline)
        store.expireBrowserPreviewCards()
        XCTAssertEqual(notifications, 1)
    }

    @MainActor
    func testOrdinaryChatUpdatesDoNotPublishBrowserPreviewChanges() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AgentChatStore(route: .init(baseDirectory: directory), tabExists: { _ in true },
                                   browserSessionFactory: { _, _, _ in FakeSession() })
        defer { store.terminate() }
        var previews = 0
        var changes = 0
        let observer = NotificationCenter.default.addObserver(forName: .browserAgentPreviewDidChange,
            object: store, queue: .main) { _ in previews += 1 }
        defer { NotificationCenter.default.removeObserver(observer) }
        let subscription = store.objectWillChange.sink { changes += 1 }
        defer { subscription.cancel() }
        let conversation = try store.create(request: .init(prompt: "Ordinary chat", attachments: [],
            config: .init(folder: directory), windowId: 1), tabId: 42)
        conversation.update(items: [], status: .running)
        conversation.update(items: [], status: .idle)
        store.markSeen(tabId: 42)
        XCTAssertFalse(store.reportWorkingTab(principalId: "external", tabId: 7, live: true))
        store.dismissBrowserPreview(conversation.id, tabId: 7)
        XCTAssertGreaterThan(changes, 0)
        XCTAssertEqual(previews, 0, "General chat updates must not schedule browser-preview work in any window")
    }

    @MainActor
    func testTitleUpdateRewritesEscapedHTMLAndReloadsCurrentTab() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var reloaded: [Int] = []
        var titles: [String] = []
        let store = AgentChatStore(route: .init(baseDirectory: directory), tabExists: { _ in true }, reloadTab: { reloaded.append($0); titles.append($1) }, browserSessionFactory: { _, _, _ in FakeSession() })
        defer { store.terminate() }
        let conversation = try store.create(request: .init(prompt: "Original", attachments: [], config: .init(folder: directory), windowId: 1), tabId: 1)
        conversation.update(items: [.init(id: "u", kind: .userMessage(text: "Original", images: []))], status: .running)
        store.assign(conversation.id, to: 42)
        conversation.onTitleGenerated?(" New <title> & name ")
        XCTAssertEqual(conversation.title, "New <title> & name")
        XCTAssertEqual(try String(contentsOf: store.route.placeholderURL(for: conversation.id), encoding: .utf8),
                       AgentChatRoute.html(title: conversation.title, background: "#FFFFFF", engine: .claude))
        XCTAssertEqual(reloaded, [42])
        XCTAssertEqual(titles, ["New <title> & name"])
        XCTAssertFalse(try store.updateTitle(" \n", for: conversation.id))
        XCTAssertFalse(try store.updateTitle(conversation.title, for: conversation.id))
        XCTAssertEqual(reloaded, [42])
        XCTAssertEqual(conversation.status, .running)
        XCTAssertEqual(conversation.items.count, 1)
        XCTAssertEqual(store.route.storedTitle(for: conversation.id), "New <title> & name")
        XCTAssertNil(store.route.storedTitle(for: UUID()))
    }

    @MainActor
    func testRenamePersistsManualAndAutomaticTitlesAndEscapedHTML() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var reloaded: [Int] = []
        let store = AgentChatStore(route: .init(baseDirectory: directory), tabExists: { _ in true },
            reloadTab: { id, _ in reloaded.append(id) }, browserSessionFactory: { _, _, _ in FakeSession() })
        defer { store.terminate() }
        let conversation = try store.create(request: .init(prompt: "First prompt", attachments: [], config: .init(folder: directory), windowId: 1),
                                            tabId: 42)
        conversation.onTitleGenerated?("Automatic title")
        store.rename(conversation.id, to: "  Manual <name> & title\n", tabId: 42)
        XCTAssertEqual(conversation.title, "Manual <name> & title")
        XCTAssertEqual(conversation.manualTitle, conversation.title)
        XCTAssertEqual(conversation.autoTitle, "Automatic title")
        XCTAssertEqual(store.route.storedTitle(for: conversation.id), conversation.title)
        XCTAssertTrue(try String(contentsOf: store.route.placeholderURL(for: conversation.id), encoding: .utf8).contains("<title>Manual &lt;name&gt; &amp; title</title>"))
        let record = try XCTUnwrap(store.route.readRecord(for: conversation.id))
        XCTAssertEqual(record.title, conversation.title)
        XCTAssertEqual(record.manualTitle, conversation.title)
        XCTAssertEqual(record.autoTitle, "Automatic title")
        XCTAssertEqual(record.pendingSessionTitle, conversation.title)
        XCTAssertEqual(reloaded, [42, 42])
    }


    @MainActor
    func testGeneratedTitleCannotReplaceManualName() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AgentChatStore(route: .init(baseDirectory: directory), tabExists: { _ in true }, browserSessionFactory: { _, _, _ in FakeSession() })
        defer { store.terminate() }
        let conversation = try store.create(request: .init(prompt: "First prompt", attachments: [], config: .init(folder: directory), windowId: 1),
                                            tabId: 42)
        // Even accepting the current automatic title makes it a manual name.
        store.rename(conversation.id, to: conversation.title, tabId: 42)
        let html = try Data(contentsOf: store.route.placeholderURL(for: conversation.id))
        conversation.onTitleGenerated?("Manual echo from Claude")
        XCTAssertEqual(conversation.title, "First prompt")
        XCTAssertEqual(conversation.autoTitle, "First prompt")
        XCTAssertEqual(conversation.manualTitle, "First prompt")
        XCTAssertEqual(try Data(contentsOf: store.route.placeholderURL(for: conversation.id)), html)
        store.saveRecord(conversation.id, synchronously: true)
        XCTAssertEqual(store.route.readRecord(for: conversation.id)?.autoTitle, "First prompt")
    }

    @MainActor
    func testClearingManualNameRestoresAutomaticTitleAcrossRestore() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AgentChatStore(route: .init(baseDirectory: directory), tabExists: { _ in false }, browserSessionFactory: { _, _, _ in FakeSession() })
        defer { store.terminate() }
        let conversation = try store.create(request: .init(prompt: "First prompt", attachments: [], config: .init(folder: directory), windowId: 1),
                                            tabId: 42)
        conversation.onTitleGenerated?("Automatic title")
        store.rename(conversation.id, to: "Manual title", tabId: 42)
        store.closeIfTabIsGone(42)
        XCTAssertTrue(store.restoreIfNeeded(conversation.id, tabId: 43))
        let restored = try XCTUnwrap(store.conversation(for: conversation.id))
        XCTAssertEqual(restored.manualTitle, "Manual title")
        XCTAssertEqual(restored.autoTitle, "Automatic title")
        store.rename(conversation.id, to: " \n ", tabId: 43)
        XCTAssertNil(restored.manualTitle)
        XCTAssertEqual(restored.title, "Automatic title")
        XCTAssertEqual(store.route.storedTitle(for: conversation.id), "Automatic title")
        let record = try XCTUnwrap(store.route.readRecord(for: conversation.id))
        XCTAssertNil(record.manualTitle)
        XCTAssertEqual(record.autoTitle, "Automatic title")
        XCTAssertEqual(record.pendingSessionTitle, "Automatic title")
        restored.onTitleGenerated?("New automatic title")
        XCTAssertEqual(restored.title, "New automatic title")
    }

    @MainActor
    func testLegacyRecordWithoutTitleFieldsDecodesAndRestores() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let route = AgentChatRoute(baseDirectory: directory), id = UUID()
        let record = AgentChatRecord(title: "Legacy title", background: "#fff",
            drifter: .init(folder: directory), items: [], queued: [], draft: "")
        try route.writeRecord(record, for: id)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: route.recordURL(for: id))) as? [String: Any])
        XCTAssertNil(json["autoTitle"])
        XCTAssertNil(json["manualTitle"])
        XCTAssertNil(json["pendingSessionTitle"])
        let store = AgentChatStore(route: route, tabExists: { _ in true }, browserSessionFactory: { _, _, _ in FakeSession() })
        defer { store.terminate() }
        XCTAssertTrue(store.restoreIfNeeded(id, tabId: 42))
        XCTAssertEqual(store.conversation(for: id)?.autoTitle, "Legacy title")
        XCTAssertEqual(store.conversation(for: id)?.title, "Legacy title")
        XCTAssertNil(store.conversation(for: id)?.manualTitle)
    }


    @MainActor
    func testUnrestorableChatRenameOnlyRewritesTitleAndReloads() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let route = AgentChatRoute(baseDirectory: directory), id = UUID()
        try FileManager.default.createDirectory(at: route.directory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: route.canonicalURL(for: UUID()).deletingLastPathComponent(), withIntermediateDirectories: true)
        let html = AgentChatRoute.html(title: "Old", background: "#123456", engine: .codex)
        try html.write(to: route.placeholderURL(for: id), atomically: true, encoding: .utf8)
        var reloaded: [Int] = []
        let store = AgentChatStore(route: route, tabExists: { _ in true }, reloadTab: { id, _ in reloaded.append(id) })
        defer { store.terminate() }
        store.rename(id, to: " New & name ", tabId: 42)
        XCTAssertEqual(try String(contentsOf: route.placeholderURL(for: id), encoding: .utf8), AgentChatRoute.html(title: "New & name", background: "#FFFFFF", engine: .codex))
        XCTAssertEqual(reloaded, [42])
        XCTAssertNil(store.entry(for: id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: route.recordURL(for: id).path))
    }

    @MainActor
    func testCodexChatRenameDoesNotQueueClaudeControl() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let route = AgentChatRoute(baseDirectory: directory), id = UUID()
        try route.writeRecord(.init(title: "Automatic", background: "#fff",
            drifter: .init(engine: .codex), items: [], queued: [], draft: ""), for: id)
        let store = AgentChatStore(route: route, tabExists: { _ in true })
        defer { store.terminate() }
        store.rename(id, to: "Manual", tabId: 42)
        XCTAssertEqual(store.conversation(for: id)?.title, "Manual")
        XCTAssertNil(store.conversation(for: id)?.pendingSessionTitle)
        XCTAssertNil(route.readRecord(for: id)?.pendingSessionTitle)
    }

    func testRouteMatchesOnlyOwnedUUIDFiles() {
        let route = AgentChatRoute(baseDirectory: URL(fileURLWithPath: "/tmp/Mist Dev", isDirectory: true))
        let id = UUID()
        XCTAssertEqual(route.conversationId(for: route.placeholderURL(for: id).absoluteString), id)
        for url in [nil, "https://example.com/\(id).html", "file:///tmp/\(id).html",
                    route.directory.appendingPathComponent("other.html").absoluteString,
                    route.directory.appendingPathComponent("\(id).HTML").absoluteString,
                    route.directory.appendingPathComponent("child/\(id).html").absoluteString,
                    route.placeholderURL(for: id).absoluteString + "?x=1",
                    route.placeholderURL(for: id).absoluteString + "#fragment",
                    "file://remote" + route.placeholderURL(for: id).path] {
            XCTAssertNil(route.conversationId(for: url), url ?? "nil")
        }
        let other = AgentChatRoute(baseDirectory: URL(fileURLWithPath: "/tmp/Mist Tests"))
        XCTAssertNil(other.conversationId(for: route.placeholderURL(for: id).absoluteString))
    }

    func testHTMLEscapingAndTitle() {
        XCTAssertEqual(MistAppPlaceholder.escape("<&>\"'"), "&lt;&amp;&gt;&quot;&#39;")
        XCTAssertEqual(AgentChatRoute.html(title: "<script>&", background: "#123456", engine: .claude),
                       "<!doctype html><html><head><meta charset=\"utf-8\"><meta name=\"mist-app\" content=\"drifter\"><meta name=\"mist-agent\" content=\"drifter claude\"><title>&lt;script&gt;&amp;</title><style>html{background:#123456}</style></head><body></body></html>")
        XCTAssertEqual(AgentChatRoute.title(for: "\n  \n hello \nworld"), "hello")
        XCTAssertEqual(AgentChatRoute.title(for: "  \n"), AgentChatStrings.image)
        XCTAssertEqual(AgentChatRoute.title(for: String(repeating: "x", count: 61)), String(repeating: "x", count: 59) + "…")
        XCTAssertEqual(AgentChatRoute.title(for: String(repeating: "x", count: 60)).count, 60)
    }

    @MainActor
    func testEndedChatKeepsTheAgentItsFileRecords() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let route = AgentChatRoute(baseDirectory: directory)
        try FileManager.default.createDirectory(at: route.directory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: route.canonicalURL(for: UUID()).deletingLastPathComponent(), withIntermediateDirectories: true)
        let codex = UUID(), legacy = UUID()
        try AgentChatRoute.html(title: "t", background: "#000000", engine: .codex)
            .write(to: route.placeholderURL(for: codex), atomically: true, encoding: .utf8)
        try "<!doctype html><html><head><title>t</title></head></html>"
            .write(to: route.placeholderURL(for: legacy), atomically: true, encoding: .utf8)
        let store = AgentChatStore(route: route, tabExists: { _ in true }, reloadTab: { _, _ in }, browserSessionFactory: { _, _, _ in FakeSession() })
        defer { store.terminate() }
        XCTAssertEqual(store.agent(for: codex), .codex)
        XCTAssertEqual(store.agent(for: codex), .codex)
        XCTAssertEqual(store.agent(for: legacy), .claude)
        XCTAssertEqual(store.agent(for: legacy), .claude)
    }

    @MainActor
    func testMovedTabSurvivesThenClosedTabEndsSessionAndKeepsFiles() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var exists = true
        let fake = FakeSession()
        let store = AgentChatStore(route: AgentChatRoute(baseDirectory: directory), closeDelay: 10_000_000,
                                   tabExists: { $0 == 42 && exists }, browserSessionFactory: { _, conversation, _ in
            conversation.onClose = { fake.closes += 1 }
            return fake
        })
        let conversation = try store.create(request: .init(prompt: "Hello", attachments: [], config: .init(folder: directory), windowId: 1), tabId: 42)
        let file = store.route.placeholderURL(for: conversation.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        let image = AgentImageAttachment(data: Data([1, 2, 3]), mediaType: "image/jpeg")
        let imageURL = try store.route.imageURL(image, for: conversation.id)
        XCTAssertEqual(imageURL, try store.route.imageURL(image, for: conversation.id))
        XCTAssertEqual(imageURL.pathExtension, "jpg")
        XCTAssertEqual(try Data(contentsOf: imageURL), image.data)
        store.tabDidClose(42)
        XCTAssertEqual(fake.closes, 0)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(store.conversation(for: conversation.id) === conversation)
        XCTAssertEqual(fake.closes, 0)
        exists = false
        store.tabDidClose(42)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(fake.closes, 1)
        XCTAssertNil(store.conversation(for: conversation.id))
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: imageURL.path))
        XCTAssertNotNil(store.route.readRecord(for: conversation.id))
        store.closeIfTabIsGone(42)
        XCTAssertEqual(fake.closes, 1)
    }

    @MainActor
    func testTerminateClosesSessionsButRetainsRestorableFiles() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fake = FakeSession()
        let store = AgentChatStore(route: .init(baseDirectory: directory), tabExists: { _ in true }, browserSessionFactory: { _, conversation, _ in
            conversation.onClose = { fake.closes += 1 }
            return fake
        })
        let conversation = try store.create(request: .init(prompt: "", attachments: [], config: .init(folder: directory), windowId: 1), tabId: 1)
        store.tabDidClose(1)
        conversation.setDraft(.init(text: "Saved at termination"))
        store.terminate()
        XCTAssertEqual(fake.closes, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.route.placeholderURL(for: conversation.id).path))
        XCTAssertNil(store.conversation(for: conversation.id))
        XCTAssertEqual(store.route.readRecord(for: conversation.id)?.draft, "Saved at termination")
        XCTAssertFalse(store.restoreIfNeeded(conversation.id, tabId: 2))
        store.terminate()
        XCTAssertEqual(fake.closes, 1)
    }

    @MainActor
    func testMissingFolderLaunchFallsBackToDrifterHome() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        var launches = 0
        let store = AgentChatStore(route: .init(baseDirectory: directory), tabExists: { _ in false }, browserSessionFactory: { _, _, _ in
            launches += 1
            return FakeSession()
        })
        defer { store.terminate(); try? FileManager.default.removeItem(at: directory) }
        let chat = try store.create(request: .init(prompt: "hello", attachments: [], config: .init(folder: directory.appendingPathComponent("missing")), windowId: 1), tabId: 1)
        XCTAssertEqual(launches, 1)
        XCTAssertEqual(store.entry(for: chat.id)?.config.folder, DrifterHome.current.folder)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.route.placeholderURL(for: chat.id).path))
    }

    @MainActor private final class FakeSession: AgentChatSession {
        var onToolPaths: (([String]) -> Void)?
        var agentTextTransform: ((String) -> String)?
        var closes = 0
        var resumeId: String?
        var automaticallyAllows: ((String, Bool) -> Bool)?
        var onStarted: ((Int32) -> Void)?
        var onEnded: (() -> Void)?
        func approvePendingBrowserTools() {}
        func close() { closes += 1 }
        func terminateNow() { close() }
    }

    @MainActor
    func testUnseenCompletionLifecycle() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var activeTabId: Int?
        let store = AgentChatStore(route: .init(baseDirectory: directory), tabExists: { _ in false },
                                   isTabActive: { $0 == activeTabId }, browserSessionFactory: { _, _, _ in FakeSession() })
        let conversation = try store.create(request: .init(prompt: "Hello", attachments: [], config: .init(folder: directory), windowId: 1), tabId: 42)
        func finishTurn() {
            conversation.update(items: [], status: .running)
            conversation.update(items: [], status: .idle)
        }
        finishTurn()
        XCTAssertEqual(store.unseenCompletions, [conversation.id])
        // Repeated idle updates must retain the unread completion.
        conversation.update(items: [], status: .idle)
        XCTAssertEqual(store.unseenCompletions, [conversation.id])
        store.markSeen(tabId: 99)
        XCTAssertEqual(store.unseenCompletions, [conversation.id])
        store.markSeen(tabId: 42)
        XCTAssertTrue(store.unseenCompletions.isEmpty)
        activeTabId = 42
        finishTurn()
        XCTAssertTrue(store.unseenCompletions.isEmpty)
        activeTabId = nil
        finishTurn()
        conversation.update(items: [], status: .running)
        XCTAssertTrue(store.unseenCompletions.isEmpty)
        conversation.update(items: [], status: .idle)
        XCTAssertEqual(store.unseenCompletions, [conversation.id])
        store.closeIfTabIsGone(42)
        XCTAssertTrue(store.unseenCompletions.isEmpty)
        XCTAssertNil(store.conversation(for: conversation.id))
        finishTurn()
        XCTAssertTrue(store.unseenCompletions.isEmpty)
    }
}
