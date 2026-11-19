import Foundation

enum SlackEventTests {
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String = #function) {
        precondition(condition(), message)
    }

    static func envelope(_ event: String, team: String = "T1") -> [String: Any] {
        decode(#"{"envelope_id":"env1","type":"events_api","accepts_response_payload":false,"retry_attempt":0,"payload":{"team_id":"\#(team)","event_id":"Ev1","event":\#(event)}}"#)
    }

    static func decode(_ json: String) -> [String: Any] {
        try! JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
    }

    @MainActor static func run() throws {
        let key = SlackThreadKey(channel: "C1", threadTs: "10.000001")
        let router = SlackEventRouter(owner: "U1", botUserID: "B1", teamID: "T1")
        let dm = #"{"type":"message","user":"U1","channel":"D1","channel_type":"im","ts":"11.000001","text":"hello"}"#
        expect(router.route(envelope(dm)) == [.message(.init(key: .init(channel: "D1", threadTs: "11.000001"), kind: .dm, ts: "11.000001", text: "hello"))])
        var dmReply = envelope(dm)
        var payload = dmReply["payload"] as! [String: Any]
        var event = payload["event"] as! [String: Any]
        event["thread_ts"] = "10.000001"
        payload["event"] = event; dmReply["payload"] = payload
        expect(router.route(dmReply) == [.message(.init(key: .init(channel: "D1", threadTs: "10.000001"), kind: .dm, ts: "11.000001", text: "hello"))])
        let mention = #"{"type":"app_mention","user":"U1","channel":"C1","ts":"10.000001","text":" <@B1> hello <@B1> "}"#
        expect(router.route(envelope(mention)) == [.message(.init(key: key, kind: .channel, ts: "10.000001", text: "hello"))])
        // In channels only mentions reach Drifter, even in a thread it already answers; a mention
        // there keys the same thread, so it continues the same chat.
        let reply = #"{"type":"message","user":"U1","channel":"C1","channel_type":"channel","ts":"11.000001","thread_ts":"10.000001","text":"reply"}"#
        expect(router.route(envelope(reply)).isEmpty)
        expect(router.route(envelope(reply.replacingOccurrences(of: #""channel_type":"channel""#, with: #""channel_type":"group""#))).isEmpty)
        expect(router.route(envelope(reply.replacingOccurrences(of: "reply", with: "<@B1> reply"))).isEmpty)
        expect(router.route(envelope(#"{"type":"message","user":"U1","channel":"C1","channel_type":"channel","ts":"11","text":"hi"}"#)).isEmpty)
        let threadMention = #"{"type":"app_mention","user":"U1","channel":"C1","ts":"11.000001","thread_ts":"10.000001","text":"<@B1> reply"}"#
        expect(router.route(envelope(threadMention)) == [.message(.init(key: key, kind: .channel, ts: "11.000001", text: "reply"))])
        expect(router.route(envelope(mention.replacingOccurrences(of: "C1", with: "D1"))).isEmpty)
        expect(router.route(envelope(dm, team: "T2")).isEmpty)
        for (field, value) in [("bot_id", "B1"), ("subtype", "message_changed"), ("user", "B1"), ("text", " <@B1> "), ("channel_type", "mpim")] {
            var changed = envelope(dm)
            var p = changed["payload"] as! [String: Any]; var e = p["event"] as! [String: Any]
            e[field] = value; p["event"] = e; changed["payload"] = p
            expect(router.route(changed).isEmpty)
        }
        for subtype in ["file_share", "thread_broadcast"] {
            expect(router.route(envelope(dm.replacingOccurrences(of: #""type":"message""#, with: #""type":"message","subtype":"\#(subtype)""#))).count == 1)
        }
        var ownerFixtures = [dm, mention, threadMention]
        for type in ["assistant_thread_started", "assistant_thread_context_changed"] {
            for context in [#"{"channel_id":"C2"}"#, "{}", #"{"channel_id":""}"#] {
                let thread = #"{"type":"\#(type)","assistant_thread":{"user_id":"U1","channel_id":"D1","thread_ts":"10.000001","context":\#(context)}}"#
                let expectedContext = context.contains("C2") ? "C2" : nil
                let threadKey = SlackThreadKey(channel: "D1", threadTs: "10.000001")
                expect(router.route(envelope(thread)) == [type == "assistant_thread_started" ? .threadStarted(threadKey, context: expectedContext) : .contextChanged(threadKey, context: expectedContext)])
                ownerFixtures.append(thread)
            }
        }
        let stopped = #"{"type":"agent_session_stopped","user":"U1","channel":"D1","thread_ts":"10.000001","streaming_message_ts":[],"event_ts":"12.000001"}"#
        expect(router.route(envelope(stopped)) == [.stopped(.init(channel: "D1", threadTs: "10.000001"))])
        expect(router.route(envelope(stopped.replacingOccurrences(of: #""thread_ts":"10.000001","#, with: ""))).isEmpty)
        expect(router.route(envelope(stopped, team: "T2")).isEmpty)
        ownerFixtures.append(stopped)
        for fixture in ownerFixtures { expect(router.route(envelope(fixture.replacingOccurrences(of: "U1", with: "U2"))).isEmpty) }
        let action = #"{"envelope_id":"act1","type":"interactive","accepts_response_payload":false,"payload":{"type":"block_actions","user":{"id":"U1"},"container":{"channel_id":"C1","message_ts":"12","thread_ts":"10"},"state":{"values":{"radio":{"r":{"selected_option":{"value":"yes"}}},"checks":{"c":{"selected_options":[{"value":"a"},{"value":"b"}]}},"empty":{"e":{"selected_option":null}}}},"actions":[{"action_id":"submit","block_id":"buttons","value":"go"},{"action_id":"select","block_id":"pick","type":"static_select","selected_option":{"value":"chosen"}}]}}"#
        let actions = router.route(decode(action))
        expect(actions == [
            .action(.init(user: "U1", channel: "C1", messageTs: "12", threadTs: "10", actionId: "submit", blockId: "buttons", value: "go", selections: ["radio": ["yes"], "checks": ["a", "b"]])),
            .action(.init(user: "U1", channel: "C1", messageTs: "12", threadTs: "10", actionId: "select", blockId: "pick", value: "chosen", selections: ["radio": ["yes"], "checks": ["a", "b"]]))])
        expect(router.route(decode(action.replacingOccurrences(of: "U1", with: "U2"))).isEmpty)
        expect(router.route(["type": "hello"]).isEmpty)

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("threads.json")
        var logs = [String]()
        let store = SlackThreadStore(url: url, log: { logs.append($0) })
        expect(logs.count == 1)
        let old = UUID(), new = UUID(), now = Date()
        store.upsert(.init(key: key, kind: .channel, chatId: old, context: nil, lastHandledTs: nil, updatedAt: now))
        let second = SlackThreadKey(channel: "D1", threadTs: "9.000001")
        store.upsert(.init(key: second, kind: .dm, chatId: old, context: nil, lastHandledTs: nil, updatedAt: now))
        store.markHandled(ts: "10.000002", for: key)
        store.markHandled(ts: "9.000001", for: key)
        expect(store.record(for: key)?.lastHandledTs == "10.000002")
        expect(store.isHandled(ts: "10.000002", for: key) && store.isHandled(ts: "9.000001", for: key))
        expect(!store.isHandled(ts: "10.000003", for: key))
        store.replaceChat(old, with: new)
        expect(store.record(for: key)?.chatId == new && store.record(for: second)?.chatId == new)
        store.setContext("C2", for: key)
        store.dmChannel = "D1"; store.lastConnectedAt = now
        let restored = SlackThreadStore(url: url, log: { _ in fatalError("Should load") })
        expect(restored.record(for: key) == store.record(for: key))
        expect(restored.record(forChat: new)?.key == key)
        expect(restored.dmChannel == "D1" && restored.lastConnectedAt == now)
        expect(restored.recentThreads(kind: .channel, since: now).count == 1)
        restored.setChat(nil, for: key); expect(restored.record(for: key)?.chatId == nil)
        for (a, b, order) in [("9.000001", "10.000000", ComparisonResult.orderedAscending), ("10.000000", "10.000000", .orderedSame), ("10.1", "10.01", .orderedDescending), ("010.10", "10.100000", .orderedSame)] {
            expect(SlackThreadStore.compare(a, b) == order)
        }
        try Data("invalid".utf8).write(to: url)
        expect(SlackThreadStore(url: url, log: { _ in }).record(for: key) == nil)
    }
}
