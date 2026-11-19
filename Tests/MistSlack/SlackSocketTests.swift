import Foundation

final class FakeSlackSocket: SlackSocketConnection {
    var frames: [Result<String, Error>] = []
    var waiter: CheckedContinuation<String, Error>?
    var sent: [String] = []
    var closed = false
    var pings = 0
    var pingError: Error?
    func receive() async throws -> String {
        if !frames.isEmpty { return try frames.removeFirst().get() }
        if closed { throw URLError(.cancelled) }
        return try await withCheckedThrowingContinuation { waiter = $0 }
    }
    func push(_ text: String) {
        if let waiter { self.waiter = nil; waiter.resume(returning: text) }
        else { frames.append(.success(text)) }
    }
    func send(_ text: String) async throws { sent.append(text) }
    func ping() async throws { pings += 1; if let pingError { throw pingError } }
    func close() {
        closed = true
        waiter?.resume(throwing: URLError(.cancelled)); waiter = nil
    }
}

enum SlackSocketTests {
    @MainActor static func until(file: StaticString = #file, line: UInt = #line, _ condition: () -> Bool) async {
        for _ in 0..<2_000 {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        preconditionFailure("Async condition did not arrive", file: file, line: line)
    }

    @MainActor static func run() async throws {
        let url = URL(string: "wss://example.invalid")!
        let first = FakeSlackSocket(), second = FakeSlackSocket()
        var opens = 0, received = 0
        let client = SlackSocketModeClient(open: { opens += 1; return url }, connect: { _ in opens == 1 ? first : second }, onEnvelope: { envelope in
            let socket = opens == 1 ? first : second
            let ack = try! JSONSerialization.jsonObject(with: Data(socket.sent.last!.utf8)) as! [String: String]
            precondition(ack["envelope_id"] == envelope["envelope_id"] as? String)
            received += 1
        })
        first.push(#"{"type":"hello","num_connections":2,"envelope_id":"hello"}"#)
        let event = #"{"type":"events_api","envelope_id":"e1","payload":{"event_id":"Ev1"}}"#
        first.push(event); first.push(event)
        first.push(#"{"type":"interactive","envelope_id":"i1","payload":{}}"#)
        first.push(#"{"type":"unknown","envelope_id":"u1"}"#)
        client.start()
        await until { first.sent.count == 5 }
        precondition(received == 2 && client.state == .connected(connections: 2))
        first.push(#"{"type":"disconnect","reason":"refresh_requested","envelope_id":"d1"}"#)
        await until { opens == 2 && first.closed }
        precondition(first.sent.count == 6)
        second.push(#"{"type":"hello","num_connections":1}"#)
        await until { client.state == .connected(connections: 1) }
        client.stop()
        precondition(second.closed && client.state == .off)

        var sleeps: [UInt64] = [], retryOpens = 0
        var retrySockets: [FakeSlackSocket] = []
        let retry = SlackSocketModeClient(open: { retryOpens += 1; return url }, connect: { _ in
            let socket = FakeSlackSocket()
            if retryOpens <= 2 { socket.frames = [.failure(URLError(.networkConnectionLost))] }
            retrySockets.append(socket)
            return socket
        }, sleep: { ns in
            if ns == 30_000_000_000 { try await Task.sleep(nanoseconds: ns) }
            else { sleeps.append(ns) }
        }, onEnvelope: { _ in })
        retry.start()
        await until { retryOpens == 3 }
        precondition(sleeps == [1_000_000_000, 2_000_000_000] && retrySockets.prefix(2).allSatisfy(\.closed))
        retrySockets[2].push(#"{"type":"hello"}"#)
        await until { retry.state == .connected(connections: 1) }
        retrySockets[2].close()
        await until { retryOpens == 4 }
        precondition(sleeps == [1_000_000_000, 2_000_000_000, 1_000_000_000])
        retrySockets[3].push(#"{"type":"disconnect","reason":"link_disabled","envelope_id":"stop"}"#)
        await until { retry.state == .failed("link_disabled") }
        precondition(retryOpens == 4 && retrySockets[3].closed)
        retry.stop()

        var pingOpens = 0, heartbeatSleeps = 0
        var pingSockets: [FakeSlackSocket] = []
        let pinging = SlackSocketModeClient(open: { pingOpens += 1; return url }, connect: { _ in
            let socket = FakeSlackSocket()
            socket.pingError = URLError(.networkConnectionLost)
            pingSockets.append(socket)
            return socket
        }, sleep: { ns in
            if ns == 30_000_000_000 {
                heartbeatSleeps += 1
                if heartbeatSleeps > 1 { try await Task.sleep(nanoseconds: ns) }
            }
        }, onEnvelope: { _ in })
        pinging.start()
        await until { pingOpens == 2 }
        precondition(pingSockets[0].pings == 1 && pingSockets[0].closed)
        pinging.stop()

        for code in ["invalid_auth", "not_authed", "token_revoked"] {
            var calls = 0
            let denied = SlackSocketModeClient(open: { calls += 1; throw SlackAPIError(code: code) }, connect: { _ in fatalError() }, sleep: { _ in fatalError("Must not retry auth") }, onEnvelope: { _ in })
            denied.start()
            await until { denied.state == .failed(code) }
            precondition(calls == 1)
            denied.stop()
        }
        // A late open completion after stop must never create a socket or change state.
        var pending: CheckedContinuation<URL, Error>?
        let stopped = SlackSocketModeClient(open: { try await withCheckedThrowingContinuation { pending = $0 } }, connect: { _ in fatalError("Connected after stop") }, onEnvelope: { _ in })
        stopped.start()
        await until { pending != nil }
        stopped.stop(); pending!.resume(returning: url)
        for _ in 0..<10 { await Task.yield() }
        precondition(stopped.state == .off)
    }
}
