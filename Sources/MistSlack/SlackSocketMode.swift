import Foundation

protocol SlackSocketConnection: AnyObject {
    func receive() async throws -> String
    func send(_ text: String) async throws
    func ping() async throws
    func close()
}

enum SlackSocketState: Equatable {
    case off, connecting, connected(connections: Int), failed(String)
}

@MainActor final class SlackSocketModeClient {
    private(set) var state: SlackSocketState = .off { didSet { onState(state) } }
    var onState: (SlackSocketState) -> Void = { _ in }
    var onEnvelope: ([String: Any]) -> Void
    private let open: () async throws -> URL
    private let connect: (URL) -> SlackSocketConnection
    private let sleep: (UInt64) async throws -> Void
    private var loop: Task<Void, Never>?
    private var heartbeat: Task<Void, Never>?
    private var socket: SlackSocketConnection?
    private var generation = UUID()
    private var seen = Set<String>()
    private var eventIDs: [String] = []

    init(open: @escaping () async throws -> URL,
         connect: @escaping (URL) -> SlackSocketConnection,
         sleep: @escaping (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) },
         onEnvelope: @escaping ([String: Any]) -> Void) {
        self.open = open
        self.connect = connect
        self.sleep = sleep
        self.onEnvelope = onEnvelope
    }

    func start() {
        guard loop == nil else { return }
        let id = UUID()
        generation = id
        loop = Task { [weak self] in await self?.run(id) }
    }

    func stop() {
        generation = UUID()
        loop?.cancel(); loop = nil
        heartbeat?.cancel(); heartbeat = nil
        socket?.close(); socket = nil
        state = .off
    }

    private func current(_ id: UUID) -> Bool { generation == id && !Task.isCancelled }

    private func run(_ id: UUID) async {
        var backoff: UInt64 = 1
        while current(id) {
            state = .connecting
            do {
                let url = try await open()
                guard current(id) else { return }
                let fresh = connect(url)
                // Slack requests overlapping connections when rotating a socket URL.
                let old = socket
                socket = fresh
                heartbeat?.cancel()
                old?.close()
                heartbeat = Task { [weak self] in
                    guard let self else { return }
                    do {
                        while !Task.isCancelled {
                            try await self.sleep(30_000_000_000)
                            try Task.checkCancellation()
                            try await fresh.ping()
                        }
                    } catch {
                        if !Task.isCancelled { fresh.close() }
                    }
                }
                var refresh = false
                while current(id) && !refresh {
                    let frame = try await fresh.receive()
                    guard current(id) else { return }
                    guard let envelope = (try? JSONSerialization.jsonObject(with: Data(frame.utf8))) as? [String: Any] else { continue }
                    if let envelopeID = envelope["envelope_id"] as? String {
                        let ack = try JSONSerialization.data(withJSONObject: ["envelope_id": envelopeID])
                        try await fresh.send(String(decoding: ack, as: UTF8.self))
                        guard current(id) else { return }
                    }
                    switch envelope["type"] as? String {
                    case "hello":
                        backoff = 1
                        state = .connected(connections: envelope["num_connections"] as? Int ?? 1)
                    case "disconnect":
                        if envelope["reason"] as? String == "link_disabled" {
                            finish(id, code: "link_disabled")
                            return
                        }
                        refresh = true
                        heartbeat?.cancel(); heartbeat = nil
                    case "events_api", "interactive":
                        if envelope["type"] as? String == "events_api",
                           let eventID = (envelope["payload"] as? [String: Any])?["event_id"] as? String {
                            if seen.contains(eventID) { continue }
                            seen.insert(eventID); eventIDs.append(eventID)
                            if eventIDs.count > 500 { seen.remove(eventIDs.removeFirst()) }
                        }
                        onEnvelope(envelope)
                    default: break
                    }
                }
            } catch {
                guard current(id) else { return }
                heartbeat?.cancel(); heartbeat = nil
                socket?.close(); socket = nil
                let code = (error as? SlackAPIError)?.code ?? "network"
                if ["invalid_auth", "not_authed", "token_revoked"].contains(code) {
                    finish(id, code: code)
                    return
                }
                state = .failed(code)
                do { try await sleep(backoff * 1_000_000_000) }
                catch { break }
                backoff = min(backoff * 2, 60)
            }
        }
    }

    private func finish(_ id: UUID, code: String) {
        guard generation == id else { return }
        heartbeat?.cancel(); heartbeat = nil
        socket?.close(); socket = nil
        loop = nil
        state = .failed(code)
    }
}
