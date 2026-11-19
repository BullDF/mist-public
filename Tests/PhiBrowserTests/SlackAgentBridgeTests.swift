import Foundation
import XCTest
#if !MIST_CLAUDE_CODE_HOSTLESS_TESTS
@testable import Phi
#endif

final class SlackAgentBridgeTests: XCTestCase {
    @MainActor private final class Fixture {
        final class Session {}
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        var requests: [DrifterLaunchRequest] = []
        var calls: [(String, [String: String])] = []
        var callResult: ((String, [String: String]) throws -> [String: Any])?
        var asyncCallResult: ((String, [String: String]) async throws -> [String: Any])?
        var decisions: [(String, AgentPermissionResponse)] = []
        var knownChannel: String? = "#general"
        var queued: [AgentQueuedMessage] = []
        var delivered: [AgentQueuedMessage] = []
        var workspace: String? = "https://example.slack.com/"
        var reopen = true
        var restoreOnReopen = false
        var closedTabs: [Int] = []
        var starts = 0
        var startError: Error?
        var tabsExist = true
        var fastRefresh = false
        var sleeps: [UInt64] = []
        var key = SlackThreadKey(channel: "D1", threadTs: "1.0")
        lazy var threads = SlackThreadStore(url: directory.appendingPathComponent("threads.json"), log: { _ in })
        lazy var store = AgentChatStore(route: .init(baseDirectory: directory), tabExists: { [weak self] _ in self?.tabsExist == true }, windowId: { _ in 7 },
            closeChatTab: { [weak self] in self?.closedTabs.append($0) },
            browserSessionFactory: { [unowned self] request, chat, _ in
                self.requests.append(request)
                var transcript = ClaudeCodeTranscript()
                transcript.userSent(text: request.prompt, attachments: [], sender: request.sender)
                chat.update(items: (request.resume?.items ?? []) + transcript.items, status: .starting)
                chat.onDeliver = { [weak self, weak chat] message in
                    guard let self, let chat else { return false }
                    self.delivered.append(message)
                    if chat.status == .running || chat.status == .awaitingPermission { self.queued.append(message) }
                    else { self.begin(chat, message: message) }
                    return true
                }
                return Session()
            })
        lazy var bridge = SlackAgentBridge(store: store, threads: threads, call: { [weak self] method, parameters in
            guard let self else { return [:] }
            self.calls.append((method, parameters))
            if let asyncCallResult = self.asyncCallResult { return try await asyncCallResult(method, parameters) }
            if let callResult = self.callResult { return try callResult(method, parameters) }
            return ["ts": "card.\(self.calls.count)"]
        }, startChat: { [weak self] text, sender, config in
            guard let self else { throw SlackAgentBridge.StartError.noWindow }
            if let error = self.startError { throw error }
            self.starts += 1
            var config = config; config.folder = self.directory
            return try self.store.create(request: .init(prompt: text, config: config, windowId: 7, sender: sender, slackThread: sender.kind == .slack), tabId: self.starts).id
        }, models: { SlackModelCatalogFixture.models }, launchConfig: { DrifterConfig() }, reopenChat: { [weak self] id in
            guard let self, self.reopen else { return false }
            if self.restoreOnReopen, self.store.conversation(for: id) == nil { return self.store.restoreIfNeeded(id, tabId: 9) }
            return self.store.conversation(for: id) != nil
        }, channelName: { [weak self] _ in self?.knownChannel },
        owner: { "U1" }, botUserID: { "B1" }, workspaceURL: { [weak self] in self?.workspace },
        sleep: { [weak self] duration in
            self?.sleeps.append(duration)
            try await Task.sleep(nanoseconds: self?.fastRefresh == true && duration == 60_000_000_000 ? 20_000_000 : duration)
        })

        var chat: AgentConversation { store.conversation(for: threads.record(for: key)!.chatId!)! }
        func send(_ ts: String = "1.1", kind: SlackThreadKind = .dm, text: String = "Hello") async throws {
            bridge.receive(.message(.init(key: key, kind: kind, ts: ts, text: text)))
            try await settle()
        }
        func begin(_ chat: AgentConversation, message: AgentQueuedMessage) {
            var transcript = ClaudeCodeTranscript()
            transcript.userSent(text: message.text, attachments: [], sender: message.sender)
            chat.update(items: chat.items + transcript.items, status: .running)
        }
        func finish(_ text: String = "**Reply**", stopped: Bool = false, report: Bool = true) {
            if report, AgentChatTranscriptText.isSlackTurn(chat.items) {
                _ = store.finishTask(chat.id, status: .done, message: text)
            }
            chat.update(items: chat.items + [
                .init(id: UUID().uuidString, kind: .assistantText(text: text, isStreaming: false)),
                .init(id: UUID().uuidString, kind: .turnEnd(durationMilliseconds: 1, finishedAt: Date(), stopped: stopped))
            ], status: .idle)
        }
        var posts: [String] { calls.filter { $0.0 == "chat.postMessage" }.compactMap { $0.1["text"] } }
        var cardPosts: [(String, [String: String])] { calls.filter { $0.0 == "chat.postMessage" && $0.1["blocks"] != nil && $0.1["unfurl_links"] == nil } }
        var updates: [(String, [String: String])] { calls.filter { $0.0 == "chat.update" } }
        var renames: [[String: String]] { calls.filter { $0.0 == "agents.sessions.rename" }.map(\.1) }
        /// Waits for a debounced call (a thread's title waits 1 s) without a fixed margin over its delay.
        func until(_ condition: () -> Bool) async throws {
            var polls = 0
            while !condition(), polls < 150 { try await Task.sleep(nanoseconds: 20_000_000); polls += 1 }
        }
        func blocks(_ call: (String, [String: String])) throws -> [[String: Any]] {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try XCTUnwrap(call.1["blocks"]).utf8)) as? [[String: Any]])
        }
        func permission(_ request: AgentChatItem.PermissionRequest) {
            chat.onPermissionDecision = { [weak self] id, response in
                guard let self else { return }
                self.decisions.append((id, response))
                let items = self.chat.items.map { item -> AgentChatItem in
                    guard case var .permissionRequest(request) = item.kind, request.requestId == id else { return item }
                    request.status = response.allows ? .allowed : .denied
                    request.resolution = response
                    return .init(id: item.id, kind: .permissionRequest(request))
                }
                self.chat.update(items: items, status: .running)
            }
            chat.update(items: chat.items + [.init(id: request.requestId, kind: .permissionRequest(request))], status: .awaitingPermission)
        }
        func press(_ id: String, request: String = "p", q: Int? = nil, o: Int? = nil, selections: [String: [String]] = [:]) throws {
            let value = String(decoding: try JSONEncoder().encode(SlackAgentCards.Value(chat: chat.id, request: request, q: q, o: o)), as: UTF8.self)
            bridge.receive(.action(.init(user: "U1", channel: key.channel, messageTs: "card", threadTs: key.threadTs,
                actionId: id, blockId: "drifter.permission", value: value, selections: selections)))
        }
        func settle() async throws { try await Task.sleep(nanoseconds: 40_000_000) }
        func clean() { store.terminate(); try? FileManager.default.removeItem(at: directory) }
    }

    @MainActor func testStartsLinksDeduplicatesAndContinuesDormantChat() async throws {
        let f = Fixture(); defer { f.clean() }
        try await f.send()
        XCTAssertEqual(f.starts, 1)
        XCTAssertEqual(f.requests[0].sender?.kind, .slack)
        XCTAssertTrue(AgentChatTranscriptText.isSlackTurn(f.chat.items))
        XCTAssertEqual(f.requests[0].sender?.label, "Slack")
        try await f.send()
        XCTAssertEqual(f.starts, 1)
        f.chat.update(items: f.chat.items, status: .running); f.finish()
        try await f.send("1.2")
        XCTAssertEqual(f.requests.count, 1)
        f.chat.update(items: f.chat.items, status: .dormant)
        try await f.send("1.3")
        XCTAssertEqual(f.requests.count, 2)
        XCTAssertEqual(f.starts, 1)
        XCTAssertEqual(f.requests.last?.sender?.kind, .slack)
    }

    @MainActor func testMissingChatRelinksAndConcurrentMessagesStartOnlyOnce() async throws {
        let f = Fixture(); defer { f.clean() }
        f.threads.upsert(.init(key: f.key, kind: .dm, chatId: UUID(), updatedAt: Date()))
        f.bridge.receive(.message(.init(key: f.key, kind: .dm, ts: "1.1", text: "One")))
        f.bridge.receive(.message(.init(key: f.key, kind: .dm, ts: "1.2", text: "Two")))
        try await f.settle()
        XCTAssertEqual(f.starts, 1)
        f.chat.update(items: f.chat.items, status: .running)
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(f.queued.count, 1)
        XCTAssertEqual(f.starts, 1)
    }

    @MainActor func testSlackFinishesRequireCallAndPostMessageWithContext() async throws {
        let f = Fixture(); defer { f.clean() }
        try await f.send()
        XCTAssertEqual(f.store.isSlackThreadChat?(f.chat.id), true)
        XCTAssertEqual(f.store.isSlackThreadChat?(UUID()), false)
        XCTAssertTrue(f.requests[0].slackThread)
        f.chat.update(items: f.chat.items, status: .running)
        f.finish("Raw reply", report: false)
        try await f.settle()
        XCTAssertTrue(f.posts.isEmpty)
        for status in [AgentTaskFinishStatus.done, .blocked] {
            f.chat.update(items: f.chat.items, status: .running)
            XCTAssertEqual(try f.store.finishTask(f.chat.id, status: status, message: "Explicit message").get(),
                           "Mist posts this to the Slack thread when this turn ends. End your turn now.")
            f.finish("Raw reply", report: false)
            try await f.settle()
        }
        XCTAssertEqual(f.posts, ["Explicit message", "Explicit message"])
        let last = try XCTUnwrap(f.calls.last { $0.0 == "chat.postMessage" })
        let blocks = try f.blocks(last)
        XCTAssertEqual(blocks.last?["type"] as? String, "context")
        let elements = try XCTUnwrap(blocks.last?["elements"] as? [[String: String]])
        XCTAssertEqual(elements.first?["text"], "GPT-6.1 Sol · medium")
        f.begin(f.chat, message: .init(text: "Mist message"))
        XCTAssertThrowsError(try f.store.finishTask(f.chat.id, status: .done, message: "No Slack post").get()) {
            guard case AgentFinishError.notSlackTurn = $0 else { return XCTFail("Wrong error: \($0)") }
            XCTAssertEqual(($0 as? AgentFinishError)?.message,
                           "This turn answers Johnny in Mist, not in Slack, so nothing would post: reply here instead.")
        }
        f.finish("Mist reply", report: false)
        try await f.settle()
        XCTAssertEqual(f.posts.count, 2)
    }

    @MainActor func testSlackFinishKeepsCompletedTurnWhenMistTurnStartsImmediately() async throws {
        let f = Fixture(); defer { f.clean() }
        try await f.send()
        f.chat.update(items: f.chat.items, status: .running)
        _ = try f.store.finishTask(f.chat.id, status: .done, message: "Slack finish").get()
        f.finish("Raw reply", report: false)
        f.begin(f.chat, message: .init(text: "Next Mist turn"))
        try await f.settle()
        XCTAssertEqual(f.posts, ["Slack finish"])
        f.finish("Mist reply", report: false)
        try await f.settle()
        XCTAssertEqual(f.posts, ["Slack finish"])
    }

    @MainActor func testStatusReplyChunksStopAndFailure() async throws {
        let f = Fixture(); defer { f.clean() }
        try await f.send()
        XCTAssertTrue(f.calls.contains { $0.0 == "agents.sessions.setStatus" && $0.1["status"] == "processing" })
        f.chat.update(items: f.chat.items, status: .running)
        let reply = "**Reply**\n\n" + String(repeating: "x", count: 8000)
        f.finish(reply); try await f.settle()
        XCTAssertEqual(f.posts, SlackMrkdwn.chunks(reply, limit: 3000))
        let last = try XCTUnwrap(f.calls.last { $0.0 == "chat.postMessage" })
        XCTAssertEqual((try f.blocks(last).first?["text"] as? [String: String])?["text"], SlackMrkdwn.chunks(reply, limit: 3000).last)
        XCTAssertEqual(f.calls.last(where: { $0.0 == "agents.sessions.setStatus" })?.1["status"], "active")
        try await f.send("1.2"); f.finish(stopped: true); try await f.settle()
        XCTAssertEqual(f.posts.count, SlackMrkdwn.chunks(reply, limit: 3000).count)
        try await f.send("1.3")
        f.chat.update(items: f.chat.items, status: .failed("failure")); try await f.settle()
        XCTAssertEqual(f.posts.last, String(format: SlackAgentStrings.failed, "failure"))
        XCTAssertTrue(f.calls.filter { $0.0 == "chat.postMessage" }.allSatisfy { $0.1["unfurl_links"] == "false" && $0.1["thread_ts"] == f.key.threadTs })
    }

    @MainActor func testSlackStopStopsTurnWaitsForStartAndClearsIdleSession() async throws {
        let f = Fixture(); defer { f.clean() }
        try await f.send()
        var stops = 0
        f.chat.onStop = { stops += 1 }
        f.bridge.receive(.stopped(f.key))
        XCTAssertEqual(stops, 0)
        f.chat.update(items: f.chat.items, status: .running); try await f.settle()
        XCTAssertEqual(stops, 1)
        f.bridge.receive(.stopped(f.key))
        XCTAssertEqual(stops, 2)
        f.finish(stopped: true); try await f.settle()
        XCTAssertTrue(f.posts.isEmpty)
        XCTAssertEqual(f.calls.last(where: { $0.0 == "agents.sessions.setStatus" })?.1["status"], "active")
        f.permission(.init(requestId: "p", toolName: "Bash", summary: "ls"))
        f.bridge.receive(.stopped(f.key))
        XCTAssertEqual(stops, 3)
        f.finish(stopped: true); try await f.settle()
        f.calls.removeAll()
        f.bridge.receive(.stopped(f.key)); try await f.settle()
        XCTAssertEqual(stops, 3)
        XCTAssertEqual(f.calls.map(\.0), ["agents.sessions.setStatus"])
        XCTAssertEqual(f.calls.last?.1["status"], "active")
        let other = SlackThreadKey(channel: "D2", threadTs: "2.0")
        f.bridge.receive(.stopped(other)); try await f.settle()
        XCTAssertEqual(f.calls.last?.1, ["channel_id": "D2", "thread_ts": "2.0", "status": "active"])
        XCTAssertTrue(f.posts.isEmpty)
    }

    @MainActor func testMistTurnAndSlackQueuedBehindIt() async throws {
        let f = Fixture(); defer { f.clean() }
        try await f.send(); f.chat.update(items: f.chat.items, status: .running); f.finish(); try await f.settle()
        f.calls.removeAll()
        f.begin(f.chat, message: .init(text: "Mist message"))
        try await f.send("1.2")
        XCTAssertEqual(f.queued.count, 1)
        f.finish("Mist reply"); try await f.settle()
        XCTAssertTrue(f.posts.isEmpty)
        XCTAssertFalse(f.calls.contains { $0.0 == "agents.sessions.setStatus" })
        f.begin(f.chat, message: f.queued.removeFirst()); f.finish("Slack reply"); try await f.settle()
        XCTAssertEqual(f.posts, ["Slack reply"])
    }

    @MainActor func testTitlesContextAndClear() async throws {
        let f = Fixture(); defer { f.clean() }
        f.bridge.receive(.threadStarted(f.key, context: "C1"))
        try await f.send()
        XCTAssertTrue(f.requests[0].sender!.header.contains("<#C1> (#general)"))
        XCTAssertTrue(f.requests[0].sender!.header.contains("This is his private DM with Drifter; still keep your message concise."))
        XCTAssertFalse(f.requests[0].sender!.header.contains("public"))
        f.chat.title = MistAppID.drifter.name
        try await Task.sleep(nanoseconds: 1_050_000_000)
        XCTAssertFalse(f.calls.contains { $0.0 == "agents.sessions.rename" })
        f.chat.title = "Title"
        try await f.until { f.renames.count == 1 }
        f.chat.title = "Title"
        try await Task.sleep(nanoseconds: 1_050_000_000)
        XCTAssertEqual(f.renames, [["channel_id": f.key.channel, "thread_ts": f.key.threadTs, "title": "Title"]])
        f.chat.title = String(repeating: "t", count: 250)
        try await f.until { f.renames.count == 2 }
        XCTAssertEqual(f.renames.map { $0["title"] }, ["Title", String(repeating: "t", count: 200)])
        let old = f.chat.id
        f.store.onChatReplaced = { [weak f] in f?.bridge.chatReplaced($0, with: $1) }
        try f.store.clear(old)
        XCTAssertNotEqual(f.chat.id, old)
        try await f.send("1.2")
        XCTAssertEqual(f.starts, 1)
        XCTAssertEqual(f.requests.last?.sender?.kind, .slack)
        XCTAssertTrue(AgentChatTranscriptText.isSlackTurn(f.chat.items))
    }

    @MainActor func testMistMessageMidSlackTurnClearsThinking() async throws {
        let f = Fixture(); defer { f.clean() }
        try await f.send()
        f.chat.update(items: f.chat.items, status: .running)
        f.begin(f.chat, message: .init(text: "Mist message"))
        f.finish("Mist reply"); try await f.settle()
        XCTAssertEqual(f.calls.last(where: { $0.0 == "agents.sessions.setStatus" })?.1["status"], "active")
        XCTAssertTrue(f.posts.isEmpty)
    }

    @MainActor func testWakeTurnsPostOnlyAfterJohnnysSlackMessage() async throws {
        let f = Fixture(); defer { f.clean() }
        try await f.send(); f.chat.update(items: f.chat.items, status: .running); f.finish("First"); try await f.settle()
        XCTAssertEqual(f.posts, ["First"])
        let report = AgentMessageSender(id: "abcd", title: "Child", kind: .report)
        var delivered = await f.store.deliverExternalMessage(.init(text: "Child result", sender: report), to: f.chat.id)
        XCTAssertTrue(delivered)
        XCTAssertEqual(f.delivered.last?.sender?.postsToSlack, true)
        XCTAssertEqual(f.delivered.last?.sender?.header,
                       "[Report from child chat abcd (Child). \(AgentMessageSender.slackWakeNote)]")
        try await f.settle()
        XCTAssertEqual(f.calls.last(where: { $0.0 == "agents.sessions.setStatus" })?.1["status"], "processing")
        f.finish("Wake reply"); try await f.settle()
        XCTAssertEqual(f.posts, ["First", "Wake reply"])

        // A wake turn without finish_task posts nothing, even with text between tools.
        delivered = await f.store.deliverExternalMessage(.init(text: "Peer", sender: .init(id: "efgh", title: "")), to: f.chat.id)
        XCTAssertTrue(delivered)
        XCTAssertEqual(f.delivered.last?.sender?.postsToSlack, true)
        let tool = AgentChatItem.ToolCall(toolUseId: "tool", name: "Bash", inputSummary: "ls", inputJSON: "{}")
        f.chat.update(items: f.chat.items + [
            .init(id: "between", kind: .assistantText(text: "Between tools", isStreaming: false)),
            .init(id: "tool", kind: .toolCall(tool)),
            .init(id: "end", kind: .turnEnd(durationMilliseconds: 1, finishedAt: Date(), stopped: false))
        ], status: .idle)
        try await f.settle()
        XCTAssertEqual(f.posts, ["First", "Wake reply"])

        // A turn the engine starts on its own (a Monitor) posts only its own reply.
        f.chat.update(items: f.chat.items, status: .running); f.finish("Monitor reply"); try await f.settle()
        XCTAssertEqual(f.posts, ["First", "Wake reply", "Monitor reply"])

        // Once Johnny types in Mist, wake turns stay in Mist.
        f.begin(f.chat, message: .init(text: "Mist message")); f.finish("Mist reply"); try await f.settle()
        delivered = await f.store.deliverExternalMessage(.init(text: "Late result", sender: report), to: f.chat.id)
        XCTAssertTrue(delivered)
        XCTAssertEqual(f.delivered.last?.sender?.postsToSlack, false)
        XCTAssertEqual(f.delivered.last?.sender?.header, "[Report from child chat abcd (Child)]")
        f.finish("Late reply"); try await f.settle()
        XCTAssertEqual(f.posts, ["First", "Wake reply", "Monitor reply"])
    }

    func testWakePostsToSlackCountsQueuedMessages() {
        let slack = AgentChatItem(id: "slack", kind: .peerMessage(name: AgentChatTranscriptText.slackSender, body: "Hi"))
        let mist = AgentChatItem(id: "mist", kind: .userMessage(text: "Hi", images: []))
        let report = AgentChatItem(id: "report", kind: .peerMessage(name: "abcd (Child)", body: "Done"))
        let slackSender = AgentMessageSender(id: AgentChatTranscriptText.slackSender, title: "", kind: .slack)
        let peer = AgentQueuedMessage(text: "Peer", sender: .init(id: "efgh", title: ""))
        XCTAssertTrue(AgentChatTranscriptText.wakePostsToSlack([mist, slack, report], queued: [peer]))
        XCTAssertFalse(AgentChatTranscriptText.wakePostsToSlack([slack, mist, report], queued: []))
        XCTAssertFalse(AgentChatTranscriptText.wakePostsToSlack([slack], queued: [.init(text: "Typed"), peer]))
        XCTAssertTrue(AgentChatTranscriptText.wakePostsToSlack([mist], queued: [.init(text: "Typed"), .init(text: "Slack", sender: slackSender), peer]))
        XCTAssertFalse(AgentChatTranscriptText.wakePostsToSlack([report], queued: []))
    }

    @MainActor func testChannelNoteNamesTheThreadAndAMentionContinuesItsChat() async throws {
        let f = Fixture(); defer { f.clean() }
        f.key = .init(channel: "C01ABCDEF23", threadTs: "1794004997.379269")
        try await f.send("1794004997.379269", kind: .channel)
        let header = try XCTUnwrap(f.requests.first?.sender?.header)
        for part in ["in a thread in <#C01ABCDEF23> (#general): https://example.slack.com/archives/C01ABCDEF23/p1794004997379269, "
                        + "channel ID C01ABCDEF23, thread ts 1794004997.379269", "public: his colleagues read it", "concise",
                     "Answer him by calling finish_task", "a turn without finish_task posts nothing", "stand on its own",
                     "under Drifter's name", "slack_send_message, which posts as Johnny", "its report wakes you"] {
            XCTAssertTrue(header.contains(part), part)
        }
        f.chat.update(items: f.chat.items, status: .running); f.finish(); try await f.settle()
        f.workspace = nil
        try await f.send("1794004998.000001", kind: .channel, text: "Again")
        XCTAssertEqual(f.starts, 1)
        XCTAssertEqual(f.delivered.last?.text, "Again")
        let later = try XCTUnwrap(f.delivered.last?.sender?.header)
        XCTAssertTrue(later.contains("in a thread in <#C01ABCDEF23> (#general): channel ID C01ABCDEF23, thread ts 1794004997.379269"))
        XCTAssertEqual(SlackAgentBridge.permalink(f.key, workspace: "https://example.slack.com"),
                       "https://example.slack.com/archives/C01ABCDEF23/p1794004997379269")
        XCTAssertNil(SlackAgentBridge.permalink(f.key, workspace: "http://example.slack.com/"))
    }

    @MainActor func testChannelTitleAndErrorsAreReplied() async throws {
        let f = Fixture(); defer { f.clean() }
        f.key = .init(channel: "C1", threadTs: "1")
        try await f.send(kind: .channel)
        XCTAssertTrue(f.requests[0].sender!.header.contains("in a thread in <#C1>"))
        f.chat.title = "Channel title"
        try await f.until { !f.renames.isEmpty }
        XCTAssertEqual(f.renames, [["channel_id": "C1", "thread_ts": "1", "title": "Channel title"]])
        f.reopen = false; f.startError = SlackAgentBridge.StartError.noWindow
        try await f.send("1.2", kind: .channel)
        XCTAssertEqual(f.posts.last, SlackAgentStrings.noWindow)
        f.startError = NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "test failure"])
        try await f.send("1.3", kind: .channel)
        XCTAssertEqual(f.posts.last, SlackAgentStrings.notTaken + " test failure")
    }

    @MainActor func testRefreshPermissionCloseAndReopen() async throws {
        let f = Fixture(); defer { f.clean() }
        f.fastRefresh = true
        try await f.send()
        f.chat.update(items: f.chat.items, status: .running)
        try await f.settle()
        XCTAssertTrue(f.sleeps.contains(60_000_000_000))
        XCTAssertGreaterThan(f.calls.filter { $0.0 == "agents.sessions.setStatus" && $0.1["status"] == "processing" }.count, 2)
        f.chat.update(items: f.chat.items, status: .awaitingPermission)
        try await f.settle()
        XCTAssertEqual(f.calls.last(where: { $0.0 == "agents.sessions.setStatus" })?.1["status"], "active")
        let count = f.calls.count
        try await f.settle()
        XCTAssertEqual(f.calls.count, count)
        f.chat.update(items: f.chat.items, status: .running)
        let old = f.chat, id = old.id
        f.tabsExist = false
        f.store.closeIfTabIsGone(1)
        try await f.settle()
        XCTAssertNil(f.store.conversation(for: id))
        XCTAssertEqual(f.calls.last(where: { $0.0 == "agents.sessions.setStatus" })?.1["status"], "active")
        f.tabsExist = true
        XCTAssertTrue(f.store.restoreIfNeeded(id, tabId: 1))
        try await f.settle()
        XCTAssertFalse(old === f.chat)
        try await f.send("1.2")
        f.chat.update(items: f.chat.items, status: .running); f.finish("Restored reply")
        try await f.settle()
        XCTAssertEqual(f.posts.last, "Restored reply")
    }

    @MainActor func testIdleThreadChatTabClosesAndALaterReplyRestoresTheSameChat() async throws {
        let f = Fixture(); defer { f.clean() }
        f.restoreOnReopen = true
        var clock = Date().addingTimeInterval(3600)
        f.store.now = { clock }
        try await f.send()
        let id = f.chat.id
        XCTAssertNotNil(f.store.idleTab(for: id))
        XCTAssertNil(f.store.idleTab(for: id)?.idleSince, "A starting chat holds its tab")
        f.chat.update(items: f.chat.items, status: .running); f.finish("First reply")
        try await f.settle()
        XCTAssertEqual(f.store.idleTab(for: id)?.idleSince, clock)
        clock.addTimeInterval(BrowserAgentPreviewState.idleLifetime)
        f.store.expireBrowserPreviewCards()
        XCTAssertEqual(f.closedTabs, [1])
        f.tabsExist = false
        f.store.closeIfTabIsGone(1)
        try await f.settle()
        XCTAssertNil(f.store.conversation(for: id))
        XCTAssertNotNil(f.store.route.readRecord(for: id), "Closing the tab keeps the chat")
        f.tabsExist = true
        try await f.send("1.2", text: "Again")
        XCTAssertEqual(f.chat.id, id)
        XCTAssertEqual(f.starts, 1)
        XCTAssertEqual(f.store.entry(for: id)?.tabId, 9)
        XCTAssertNotNil(f.store.idleTab(for: id), "The restored chat's tab closes once idle again")
        f.chat.update(items: f.chat.items, status: .running); f.finish("Restored reply")
        try await f.settle()
        XCTAssertEqual(f.posts.last, "Restored reply")
    }

    @MainActor func testFailedDeliveryAndSenderCodingCompatibility() async throws {
        let f = Fixture(); defer { f.clean() }
        try await f.send(); f.chat.update(items: f.chat.items, status: .running); f.finish()
        try await f.settle()
        f.chat.onDeliver = { _ in false }
        try await f.send("1.2")
        XCTAssertEqual(f.posts.last, SlackAgentStrings.notTaken)
        let old = try JSONDecoder().decode(AgentMessageSender.self, from: Data(#"{"id":"peer","title":""}"#.utf8))
        XCTAssertNil(old.note)
        XCTAssertEqual(old.kind, .peer)
        let source = AgentMessageSender(id: "Slack", title: "", kind: .slack, note: "context")
        XCTAssertEqual(try JSONDecoder().decode(AgentMessageSender.self, from: JSONEncoder().encode(source)), source)
        XCTAssertEqual(source.header, "[context]")
        var woken = AgentMessageSender(id: "abcd", title: "", kind: .question)
        woken.postsToSlack = true
        XCTAssertEqual(try JSONDecoder().decode(AgentMessageSender.self, from: JSONEncoder().encode(woken)), woken)
        XCTAssertFalse(old.postsToSlack)
    }

    private func question(_ count: Int = 1, multi: Bool = false) -> AgentChatItem.PermissionRequest {
        .init(requestId: "p", toolName: "AskUserQuestion", summary: "", input: .object(["questions": .array((0..<count).map { index in
            .object(["header": .string("H<&>"), "question": .string("Question \(index)"), "multiSelect": .bool(multi && index == 0),
                     "options": .array([.object(["label": .string("Yes"), "description": .string("Details")]), .object(["label": .string("No"), "description": .string("")])])])
        })]))
    }

    @MainActor func testPermissionBlocksAndAllowDenyOutcomes() async throws {
        for allow in [true, false] {
            let f = Fixture(); defer { f.clean() }
            try await f.send()
            f.permission(.init(requestId: "p", toolName: "Bash", summary: "a<&>"))
            try await f.settle()
            let blocks = try f.blocks(XCTUnwrap(f.cardPosts.first))
            XCTAssertEqual(blocks.count, 2)
            XCTAssertTrue((blocks[0]["text"] as? [String: String])?["text"]?.contains("a&lt;&amp;&gt;") == true)
            let buttons = try XCTUnwrap(blocks[1]["elements"] as? [[String: Any]])
            XCTAssertEqual(buttons.map { $0["action_id"] as? String }, ["drifter.allow", "drifter.deny"])
            let value = try JSONDecoder().decode(SlackAgentCards.Value.self, from: Data(try XCTUnwrap(buttons[0]["value"] as? String).utf8))
            XCTAssertEqual(value.chat, f.chat.id); XCTAssertEqual(value.request, "p")
            try f.press(allow ? "drifter.allow" : "drifter.deny"); try await f.settle()
            XCTAssertEqual(f.decisions.first?.1, allow ? .allow : .deny(message: nil))
            XCTAssertEqual(f.updates.count, 1)
            XCTAssertFalse(try f.blocks(f.updates[0]).contains { $0["type"] as? String == "actions" })
            f.chat.update(items: f.chat.items, status: .running); try await f.settle()
            XCTAssertEqual(f.updates.count, 1)
        }
        let f = Fixture(); defer { f.clean() }
        try await f.send()
        let request = AgentChatItem.PermissionRequest(requestId: "p", toolName: "mcp__mistbrowser__navigate", summary: "", input: .object(["url": .string("https://example.com/?a=<b>&x=1")]))
        f.permission(request); try await f.settle()
        XCTAssertEqual(f.cardPosts.first?.1["text"], SlackAgentCards.title(request))
        XCTAssertEqual(try f.blocks(XCTUnwrap(f.cardPosts.first))[1]["block_id"] as? String, "drifter.permission")
    }

    @MainActor func testSlackMessagePermissionPreviews() throws {
        AgentChatStrings.slackUserName = { $0 == "U123" ? "Manju Rao" : nil }
        AgentChatStrings.slackChannelName = { $0 == "C1" ? ("#general", false) : nil }
        defer { AgentChatStrings.slackUserName = nil; AgentChatStrings.slackChannelName = nil }
        let message = "**Hi <@U123>** <!here> <!channel> in <#C1> & <tag>\n[Read](https://example.com)"
        for tool in ["slack_send_message", "slack_schedule_message"] {
            let request = AgentChatItem.PermissionRequest(requestId: "p", toolName: "mcp__mistbrowser__" + tool, summary: "", input: .object([
                "channel_id": .string("C1"), "message": .string(message), "post_at": .string("later")]))
            let blocks = SlackAgentCards.blocks(request, chat: UUID())
            let text = try XCTUnwrap((blocks[0]["text"] as? [String: String])?["text"])
            let title = tool == "slack_send_message" ? "Drifter wants to send a Slack message to #general" : "Drifter wants to schedule a Slack message to #general"
            XCTAssertEqual(text, "*" + title + "*\n*Hi @Manju Rao* @here @channel in #general &amp; &lt;tag&gt;\n<https://example.com|Read>" + (tool == "slack_schedule_message" ? "\nScheduled for later" : ""))
            XCTAssertEqual(request.input["message"].string, message)
        }
        let long = AgentChatItem.PermissionRequest(requestId: "p", toolName: "mcp__mistbrowser__slack_send_message", summary: "", input: .object([
            "message": .string(String(repeating: "<&", count: 1000))]))
        let text = try XCTUnwrap((SlackAgentCards.blocks(long, chat: UUID())[0]["text"] as? [String: String])?["text"])
        XCTAssertEqual(text.count, 3000)
        XCTAssertTrue(text.hasSuffix("…"))
    }

    @MainActor func testQuestionButtonsAndSubmit() async throws {
        let f = Fixture(); defer { f.clean() }
        try await f.send(); f.permission(question()); try await f.settle()
        let blocks = try f.blocks(XCTUnwrap(f.cardPosts.first))
        XCTAssertEqual(blocks.count, 3)
        XCTAssertEqual((blocks[0]["text"] as? [String: String])?["text"], "*H&lt;&amp;&gt;*\nQuestion 0")
        let buttons = try XCTUnwrap(blocks[1]["elements"] as? [[String: Any]])
        XCTAssertEqual(buttons.map { $0["action_id"] as? String }, ["drifter.option.0", "drifter.option.1"])
        let value = try JSONDecoder().decode(SlackAgentCards.Value.self, from: Data(try XCTUnwrap(buttons[1]["value"] as? String).utf8))
        XCTAssertEqual(value.q, 0); XCTAssertEqual(value.o, 1)
        try f.press("drifter.option.1", q: 0, o: 1); try await f.settle()
        XCTAssertEqual(f.decisions.first?.1, question().answerResponse([0: .init(options: [1])]))
        XCTAssertEqual(f.updates.first?.1["text"], AgentChatStrings.answered + ": No")

        var request = question(2, multi: true); request = .init(requestId: "p2", toolName: request.toolName, summary: "", input: request.input)
        f.permission(request); try await f.settle()
        let multi = try f.blocks(XCTUnwrap(f.cardPosts.last))
        XCTAssertEqual((multi[1]["elements"] as? [[String: Any]])?.first?["type"] as? String, "checkboxes")
        XCTAssertEqual((multi[3]["elements"] as? [[String: Any]])?.first?["type"] as? String, "radio_buttons")
        try f.press("drifter.select", request: "p2"); try await f.settle()
        XCTAssertEqual(f.decisions.count, 1)
        try f.press("drifter.submit", request: "p2", selections: ["q0": ["0"]]); try await f.settle()
        XCTAssertEqual(f.decisions.count, 1)
        XCTAssertEqual(f.calls.last?.0, "chat.postEphemeral")
        XCTAssertEqual(f.calls.last?.1["user"], "U1")
        try f.press("drifter.submit", request: "p2", selections: ["q0": ["0", "1"], "q1": ["1"]]); try await f.settle()
        XCTAssertEqual(f.decisions.last?.1, request.answerResponse([0: .init(options: [0, 1]), 1: .init(options: [1])]))
    }

    @MainActor func testRepeatedPermissionPublishMistAnswerAndFreeText() async throws {
        let f = Fixture(); defer { f.clean() }
        try await f.send(); f.permission(question()); try await f.settle()
        f.permission(.init(requestId: "other", toolName: "Bash", summary: "test")); try await f.settle()
        XCTAssertEqual(f.cardPosts.count, 2)
        f.chat.onPermissionDecision?("other", .deny(message: nil)); try await f.settle()
        XCTAssertEqual(f.updates.count, 1)
        f.chat.update(items: f.chat.items, status: .awaitingPermission)
        try await f.send("1.2")
        XCTAssertEqual(f.decisions.last?.0, "p")
        XCTAssertTrue(f.queued.isEmpty)
        if case let .allowWithInput(input) = f.decisions.last?.1 { XCTAssertEqual(input["answers"]["Question 0"].string, "Hello") }
        else { XCTFail("Missing free text answer") }
        XCTAssertEqual(f.updates.count, 2)
        f.permission(.init(requestId: "plain", toolName: "Bash", summary: "test")); try await f.settle()
        try await f.send("1.3")
        XCTAssertEqual(f.queued.count, 1)
    }

    @MainActor func testThreadReplyQueuesBeforeRefusingPendingPlainPermission() async throws {
        let f = Fixture(); defer { f.clean() }
        try await f.send()
        f.permission(.init(requestId: "plain", toolName: "Bash", summary: "pwd"))
        try await f.settle()
        let decide = f.chat.onPermissionDecision
        f.chat.onPermissionDecision = { [weak f] id, response in
            guard let f else { return }
            XCTAssertEqual(f.queued.map(\.text), ["Do something else"])
            decide?(id, response)
        }
        try await f.send("1.2", text: "Do something else")
        XCTAssertEqual(f.decisions.map(\.0), ["plain"])
        XCTAssertEqual(f.decisions.map(\.1), [.deny(message: nil)])
        XCTAssertEqual(f.updates.last?.1["text"], AgentChatStrings.denied)
    }

    @MainActor func testMistCardsNotPostedAndStalePress() async throws {
        let f = Fixture(); defer { f.clean() }
        try await f.send(); f.chat.update(items: f.chat.items, status: .running); f.finish(); try await f.settle()
        f.begin(f.chat, message: .init(text: "Mist"))
        f.permission(question()); try await f.settle()
        XCTAssertTrue(f.cardPosts.isEmpty)
        f.chat.onPermissionDecision?("p", .allow); try await f.settle()
        try f.press("drifter.allow"); try await f.settle()
        XCTAssertEqual(f.updates.last?.1["text"], SlackAgentStrings.noLongerWaiting)
        let value = String(decoding: try JSONEncoder().encode(SlackAgentCards.Value(chat: UUID(), request: "missing")), as: UTF8.self)
        f.bridge.receive(.action(.init(user: "U1", channel: "D1", messageTs: "gone", threadTs: "1.0", actionId: "drifter.allow", blockId: "x", value: value, selections: [:])))
        try await f.settle()
        XCTAssertEqual(f.updates.last?.1["ts"], "gone")
    }

    @MainActor func testHandOffCardDoneArrivesAsSlackMessageAndAReplyClosesIt() async throws {
        let f = Fixture(); defer { f.clean() }
        try await f.send()
        XCTAssertNotNil(f.store.handOff(f.chat.id, message: "Sign in <here>", tab: "GitHub"))
        try await f.settle()
        let post = try XCTUnwrap(f.cardPosts.first)
        XCTAssertEqual(post.1["text"], "Sign in <here>")
        let blocks = try f.blocks(post)
        let text = try XCTUnwrap((blocks[0]["text"] as? [String: String])?["text"])
        XCTAssertTrue(text.contains("Sign in &lt;here&gt;") && text.contains("GitHub"), text)
        let button = try XCTUnwrap((blocks[1]["elements"] as? [[String: Any]])?.first)
        XCTAssertEqual(button["action_id"] as? String, "drifter.handOffDone")
        f.finish(report: false); try await f.settle()
        let id = try XCTUnwrap(f.chat.handOff?.id)
        try f.press("drifter.handOffDone", request: id); try await f.settle()
        XCTAssertNil(f.chat.handOff)
        XCTAssertEqual(f.delivered.last?.text, "Done.")
        XCTAssertEqual(f.delivered.last?.sender?.kind, .slack)
        let update = try XCTUnwrap(f.updates.first)
        XCTAssertEqual(update.1["ts"], post.1["ts"] ?? update.1["ts"])
        XCTAssertFalse(try f.blocks(update).contains { $0["type"] as? String == "actions" })
        let delivered = f.delivered.count
        try f.press("drifter.handOffDone", request: id); try await f.settle()
        XCTAssertEqual(f.delivered.count, delivered, "A second press sends nothing")

        XCTAssertNotNil(f.store.handOff(f.chat.id, message: "Pass the CAPTCHA", tab: nil))
        try await f.settle()
        XCTAssertEqual(f.cardPosts.count, 2)
        try await f.send("1.2", text: "Skip that page")
        XCTAssertNil(f.chat.handOff)
        XCTAssertTrue(f.updates.contains { $0.1["text"] == "Pass the CAPTCHA" })
    }

    @MainActor func testClosingChatExpiresCards() async throws {
        let f = Fixture(); defer { f.clean() }
        try await f.send(); f.permission(question()); try await f.settle()
        f.tabsExist = false; f.store.closeIfTabIsGone(1); try await f.settle()
        XCTAssertEqual(f.updates.count, 1)
        XCTAssertEqual(f.updates[0].1["text"], SlackAgentStrings.noLongerWaiting)
    }

    @MainActor func testStalePressAfterCloseKeepsResolvedCard() async throws {
        let f = Fixture(); defer { f.clean() }
        try await f.send(); f.permission(question()); try await f.settle()
        let blocks = try f.blocks(XCTUnwrap(f.cardPosts.first))
        let button = try XCTUnwrap((blocks[1]["elements"] as? [[String: Any]])?.first)
        let value = try XCTUnwrap(button["value"] as? String)
        f.chat.onPermissionDecision?("p", question().answerResponse([0: .init(options: [0])])!)
        try await f.settle()
        let ts = try XCTUnwrap(f.updates.first?.1["ts"])
        let outcome = f.updates.first?.1["text"]
        f.tabsExist = false; f.store.closeIfTabIsGone(1); try await f.settle()
        f.bridge.receive(.action(.init(user: "U1", channel: f.key.channel, messageTs: ts, threadTs: f.key.threadTs,
            actionId: "drifter.option.0", blockId: "q0", value: value, selections: [:])))
        try await f.settle()
        XCTAssertEqual(f.updates.count, 1)
        XCTAssertEqual(f.updates.first?.1["text"], outcome)
    }

    @MainActor func testSuggestedPrompts() async throws {
        let f = Fixture(); defer { f.clean() }
        for (context, name) in [("C1" as String?, "#general" as String?), ("C2", nil), (nil, nil)] {
            f.knownChannel = name
            f.bridge.receive(.threadStarted(f.key, context: context)); try await f.settle()
            let call = try XCTUnwrap(f.calls.last(where: { $0.0 == "assistant.threads.setSuggestedPrompts" }))
            let prompts = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try XCTUnwrap(call.1["prompts"]).utf8)) as? [[String: String]])
            XCTAssertEqual(prompts.count, 3)
            if name != nil {
                XCTAssertEqual(prompts[0]["title"], String(format: SlackAgentStrings.catchUpChannel, "#general"))
                XCTAssertEqual(prompts[0]["message"], String(format: SlackAgentStrings.catchUpChannelMessage, "<#C1>"))
                XCTAssertEqual(prompts[1]["message"], String(format: SlackAgentStrings.summarizeChannelMessage, "<#C1>"))
                XCTAssertEqual(prompts[2]["title"], SlackAgentStrings.catchUpSlack)
            } else {
                XCTAssertEqual(prompts.map { $0["title"] }, [SlackAgentStrings.catchUpSlack, SlackAgentStrings.checkInbox, SlackAgentStrings.planDay])
            }
        }
        f.knownChannel = "@Alice"
        f.bridge.receive(.contextChanged(f.key, context: "D2")); try await f.settle()
        XCTAssertTrue(f.calls.last?.1["prompts"]?.contains("@Alice") == true)
        XCTAssertEqual(f.threads.record(for: f.key)?.context, "D2")
    }

    func testCatchUpSelection() {
        let key = SlackThreadKey(channel: "D1", threadTs: "1")
        let messages: [[String: Any]] = [
            ["ts": "9", "user": "U1", "text": "before since"],
            ["ts": "11", "user": "U1", "text": "already replied"],
            ["ts": "12", "bot_id": "bot", "text": "reply"],
            ["ts": "13", "user": "U1", "text": "handled"],
            ["ts": "14", "user": "another", "text": "other"],
            ["ts": "15", "user": "U1", "subtype": "message_changed", "text": "edit"],
            ["ts": "16", "user": "U1", "text": "<@B1>  One "],
            ["ts": "17", "user": "U1", "subtype": "file_share", "text": "Two"],
            ["ts": "18", "user": "U1", "text": "<@B1> "],
        ]
        let selected = SlackCatchUp.message(Array(messages.reversed()), key: key, since: "10", owner: "U1", botUserID: "B1", isHandled: { $0 == "13" })
        XCTAssertEqual(selected, .init(key: key, kind: .dm, ts: "17", text: "One\n\nTwo"))
        XCTAssertNil(SlackCatchUp.message(messages + [["ts": "19", "user": "B1", "text": "reply"]], key: key, since: "10", owner: "U1", botUserID: "B1", isHandled: { _ in false }))
        XCTAssertNil(SlackCatchUp.message([["ts": "10", "user": "U1", "text": "at since"]], key: key, since: "10", owner: "U1", botUserID: "B1", isHandled: { _ in false }))
    }

    @MainActor func testCatchUpCreatesAndContinuesDMWithPagination() async throws {
        let f = Fixture(); defer { f.clean() }
        await f.bridge.catchUp(since: nil)
        XCTAssertTrue(f.calls.isEmpty)
        // Keep the known chat idle so catch-up can deliver immediately.
        try await f.send(); f.chat.update(items: f.chat.items, status: .running); f.finish(); try await f.settle()
        let known = f.chat.id
        f.calls.removeAll()
        f.callResult = { method, parameters in
            switch method {
            case "conversations.open": return ["channel": ["id": "D1"]]
            case "conversations.history":
                XCTAssertEqual(parameters["oldest"], "80.000000")
                if parameters["cursor"] == nil {
                    return ["messages": [["ts": "100", "user": "U1", "text": "New"]], "response_metadata": ["next_cursor": "next"]]
                }
                return ["messages": [["ts": "1.0", "latest_reply": "103"]]]
            case "conversations.replies":
                if parameters["ts"] == "1.0" {
                    return ["messages": [["ts": "101", "user": "B1", "text": "old reply"], ["ts": "103", "user": "U1", "text": "Continue"]]]
                }
                return ["messages": [["ts": "100", "user": "U1", "text": "New"], ["ts": "102", "user": "U1", "text": "More"]]]
            default: return [:]
            }
        }
        await f.bridge.catchUp(since: Date(timeIntervalSince1970: 200))
        XCTAssertEqual(f.threads.dmChannel, "D1")
        XCTAssertEqual(f.starts, 2)
        XCTAssertEqual(f.requests.last?.prompt, "New\n\nMore")
        XCTAssertEqual(f.threads.record(for: f.key)?.chatId, known)
        XCTAssertEqual(f.threads.record(for: f.key)?.lastHandledTs, "103")
        XCTAssertTrue(f.threads.isHandled(ts: "100", for: .init(channel: "D1", threadTs: "100")))
        let starts = f.starts
        f.bridge.receive(.message(.init(key: .init(channel: "D1", threadTs: "100"), kind: .dm, ts: "102", text: "More")))
        try await f.settle()
        XCTAssertEqual(f.starts, starts)
        f.chat.update(items: f.chat.items, status: .running)
        await f.bridge.catchUp(since: Date(timeIntervalSince1970: 200))
        XCTAssertEqual(f.calls.filter { $0.0 == "conversations.open" }.count, 1)
        XCTAssertEqual(f.starts, starts)
    }

    @MainActor func testCatchUpFailureStopsAndConcurrentRunIsIgnored() async throws {
        let f = Fixture(); defer { f.clean() }
        f.threads.dmChannel = "D1"
        // The fake response throws before any replies or chat can be created.
        f.callResult = { method, _ in
            if method == "conversations.history" { throw NSError(domain: "test", code: 1) }
            return [:]
        }
        await f.bridge.catchUp(since: Date())
        XCTAssertEqual(f.calls.map(\.0), ["conversations.history"])
        XCTAssertEqual(f.starts, 0)
        f.calls.removeAll()
        var continuation: CheckedContinuation<Void, Never>?
        f.asyncCallResult = { _, _ in
            await withCheckedContinuation { continuation = $0 }
            return ["messages": []]
        }
        let first = Task { await f.bridge.catchUp(since: Date()) }
        try await f.settle()
        await f.bridge.catchUp(since: Date())
        XCTAssertEqual(f.calls.count, 1)
        try XCTUnwrap(continuation).resume()
        await first.value
    }

    @MainActor private func context(_ f: Fixture) throws -> [String] {
        try f.calls.filter { $0.0 == "chat.postMessage" && $0.1["blocks"] != nil && $0.1["unfurl_links"] != nil }.compactMap { call in
            try f.blocks(call).last.flatMap { ($0["elements"] as? [[String: Any]])?.first?["text"] as? String }
        }
    }

    @MainActor func testModelPrefixStartsChatAndNamesItUnderEveryReply() async throws {
        let f = Fixture(); defer { f.clean() }
        try await f.send(text: "sonnet low reply with one word: ok")
        let config = try XCTUnwrap(f.requests.first?.config)
        XCTAssertEqual([config.engine.rawValue, config.model, config.effort], ["claude", "sonnet", "low"])
        XCTAssertEqual(f.requests[0].prompt, "reply with one word: ok")
        f.chat.update(items: f.chat.items, status: .running); f.finish("ok"); try await f.settle()
        XCTAssertEqual(f.posts, ["ok"])
        XCTAssertEqual(try context(f), ["Sonnet 5.5 · low"])
        try await f.send("1.2"); f.finish("again"); try await f.settle()
        XCTAssertEqual(f.posts, ["ok", "again"])
        XCTAssertEqual(try context(f), ["Sonnet 5.5 · low", "Sonnet 5.5 · low"])
    }

    @MainActor func testNoPrefixRunsSolAtMediumAndBareModelAtMedium() async throws {
        let f = Fixture(); defer { f.clean() }
        try await f.send(text: "reply with one word: ok")
        XCTAssertEqual([f.requests[0].config.engine.rawValue, f.requests[0].config.model, f.requests[0].config.effort], ["codex", "gpt-6.1-sol", "medium"])
        XCTAssertEqual(f.requests[0].prompt, "reply with one word: ok")
        f.chat.update(items: f.chat.items, status: .running); f.finish("ok"); try await f.settle()
        XCTAssertEqual(try context(f), ["GPT-6.1 Sol · medium"])
        f.key = .init(channel: "D1", threadTs: "2.0")
        try await f.send("2.0", text: "fable reply with one word: ok")
        XCTAssertEqual([f.requests[1].config.model, f.requests[1].config.effort], ["fable", "medium"])
    }

    @MainActor func testPrefixOnlyThreadSetsModelForItsFirstChat() async throws {
        let f = Fixture(); defer { f.clean() }
        try await f.send(text: "Haiku high")
        XCTAssertEqual(f.starts, 0)
        XCTAssertEqual(f.posts, [String(format: SlackAgentStrings.modelSet, "Haiku 5.5 · high")])
        try await f.send("1.2", text: "hi")
        XCTAssertEqual([f.requests[0].config.model, f.requests[0].config.effort], ["haiku", "high"])
        XCTAssertNil(f.threads.record(for: f.key)?.model)
    }

    @MainActor func testPrefixSwitchesModelWithinEngineAndRefusesOtherEngine() async throws {
        let f = Fixture(); defer { f.clean() }
        try await f.send(text: "sonnet low hi")
        f.chat.update(items: f.chat.items, status: .running); f.finish("ok"); try await f.settle()
        try await f.send("1.2", text: "haiku low reply with one word: ok")
        let config = try XCTUnwrap(f.store.drifterConfig(for: f.chat.id))
        XCTAssertEqual([config.model, config.effort], ["haiku", "low"])
        XCTAssertEqual(f.chat.items.compactMap { item -> String? in
            guard case let .peerMessage(_, body) = item.kind else { return nil }
            return body
        }.last, "reply with one word: ok")
        f.finish("ok"); try await f.settle()
        XCTAssertEqual(try context(f), ["Sonnet 5.5 · low", "Haiku 5.5 · low"])
        let rows = f.chat.items.count
        try await f.send("1.3", text: "terra low reply with one word: ok")
        XCTAssertEqual(f.posts.last, String(format: SlackAgentStrings.otherEngine, "GPT-6.1 Terra"))
        XCTAssertEqual(f.chat.items.count, rows)
        XCTAssertEqual(f.store.drifterConfig(for: f.chat.id)?.model, "haiku")
        try await f.send("1.4", text: "opus")
        XCTAssertEqual(f.posts.last, String(format: SlackAgentStrings.modelSet, "Opus 5.5 · medium"))
        XCTAssertEqual(f.chat.items.count, rows)
        XCTAssertEqual(f.store.drifterConfig(for: f.chat.id)?.model, "opus")
    }

    func testCardTextLimitsAndEscaping() throws {
        let long = String(repeating: "x", count: 100)
        let request = AgentChatItem.PermissionRequest(requestId: "p", toolName: "AskUserQuestion", summary: "", input: .object([
            "questions": .array([.object(["header": .string("<&>"), "question": .string(String(repeating: "a", count: 4000)),
                "multiSelect": .bool(true), "options": .array([.object(["label": .string(long), "description": .string(long)])])])])]))
        let blocks = SlackAgentCards.blocks(request, chat: UUID())
        let section = try XCTUnwrap((blocks[0]["text"] as? [String: String])?["text"])
        XCTAssertTrue(section.hasPrefix("*&lt;&amp;&gt;*")); XCTAssertEqual(section.count, 3000)
        let element = try XCTUnwrap((blocks[1]["elements"] as? [[String: Any]])?.first)
        let option = try XCTUnwrap((element["options"] as? [[String: Any]])?.first)
        for field in ["text", "description"] {
            let label = try XCTUnwrap((option[field] as? [String: String])?["text"])
            XCTAssertEqual(label.count, 75); XCTAssertTrue(label.hasSuffix("…"))
        }
        var single = request
        single.input = .object(["questions": .array([.object(["header": .string("h"), "question": .string("q"),
            "options": .array([.object(["label": .string(long)])])])])])
        let buttonBlocks = SlackAgentCards.blocks(single, chat: UUID())
        let button = try XCTUnwrap((buttonBlocks[1]["elements"] as? [[String: Any]])?.first)
        XCTAssertEqual((button["text"] as? [String: String])?["text"]?.count, 75)
    }
}
