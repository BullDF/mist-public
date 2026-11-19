import AppKit
import Foundation
import Network

/// Dedicated transport for the encrypted relay; its bearer token comes from the group key.
@MainActor
final class MistSyncClient {
    var onOpen: (() async throws -> Void)?
    var onFrame: ((String) async throws -> Void)?
    var onDisconnect: ((Error) -> Void)?
    var onConnecting: (() -> Void)?
    private let session: URLSession
    private let monitorNetwork: Bool
    private var monitor: NWPathMonitor?
    private var wakeObserver: NSObjectProtocol?
    private var connection: Task<Void, Never>?
    private var heartbeat: Task<Void, Never>?
    private var socket: URLSessionWebSocketTask?
    private var credentials: MistSyncCredentials?
    private var token = ""
    private var awaitingPong = false
    private var heartbeatError: Error?
    private var backoff: UInt64 = 1
    private var generation = UUID()

    init(session: URLSession, monitorNetwork: Bool = true) {
        self.session = session
        self.monitorNetwork = monitorNetwork
    }

    func start(credentials: MistSyncCredentials, token: String) {
        stop()
        self.credentials = credentials
        self.token = token
        if monitorNetwork {
            wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
            ) { [weak self] _ in Task { @MainActor in self?.reconnect() } }
            let pathMonitor = NWPathMonitor()
            pathMonitor.pathUpdateHandler = { [weak self] path in
                if path.status == .satisfied { Task { @MainActor in self?.reconnect() } }
            }
            pathMonitor.start(queue: DispatchQueue(label: "mist.sync.network"))
            monitor = pathMonitor
        }
        reconnect()
    }

    func stop() {
        generation = UUID()
        connection?.cancel(); connection = nil
        heartbeat?.cancel(); heartbeat = nil
        socket?.cancel(with: .goingAway, reason: nil); socket = nil
        monitor?.cancel(); monitor = nil
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = nil
        credentials = nil
    }

    func reconnect() {
        guard let credentials else { return }
        generation = UUID()
        let attempt = generation
        connection?.cancel()
        heartbeat?.cancel()
        socket?.cancel(with: .goingAway, reason: nil)
        backoff = 1
        connection = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled, generation == attempt {
                onConnecting?()
                var request = URLRequest(url: credentials.webSocketURL)
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                let task = session.webSocketTask(with: request)
                task.maximumMessageSize = 40 * 1024 * 1024
                socket = task
                awaitingPong = false
                heartbeatError = nil
                task.resume()
                do {
                    try await onOpen?()
                    guard generation == attempt, !Task.isCancelled else { return }
                    heartbeat = Task { [weak self] in
                        while !Task.isCancelled {
                            do {
                                try await Task.sleep(nanoseconds: 30_000_000_000)
                                guard let self, self.generation == attempt else { return }
                                if self.awaitingPong { throw MistSyncError.missedPong }
                                self.awaitingPong = true
                                try await task.send(.string("ping"))
                            } catch {
                                if !Task.isCancelled, let self, self.generation == attempt {
                                    self.heartbeatError = error
                                    task.cancel(with: .goingAway, reason: nil)
                                }
                                return
                            }
                        }
                    }
                    while !Task.isCancelled, generation == attempt {
                        let message = try await task.receive()
                        guard generation == attempt, !Task.isCancelled else { return }
                        guard case .string(let text) = message else { throw MistSyncError.invalidFrame }
                        if text == "pong" { awaitingPong = false; continue }
                        try await onFrame?(text)
                    }
                } catch {
                    guard generation == attempt, !Task.isCancelled else { return }
                    onDisconnect?(heartbeatError ?? error)
                }
                heartbeat?.cancel()
                task.cancel(with: .goingAway, reason: nil)
                socket = nil
                do { try await Task.sleep(nanoseconds: backoff * 1_000_000_000) } catch { return }
                backoff = min(backoff * 2, 60)
            }
        }
    }

    func caughtUp() { backoff = 1 }

    func send(_ frame: MistSyncFrame) async throws {
        guard let socket else { throw URLError(.notConnectedToInternet) }
        let bytes = try JSONEncoder().encode(frame)
        try await socket.send(.string(String(decoding: bytes, as: UTF8.self)))
    }

    /// A failed send must break receive too, so the connection loop retries the persisted outbox.
    func failConnection() { socket?.cancel(with: .goingAway, reason: nil) }
}
