import Foundation
import os

final class URLSessionSlackSocket: SlackSocketConnection {
    private let task: URLSessionWebSocketTask

    init(task: URLSessionWebSocketTask) {
        self.task = task
        task.resume()
    }

    func receive() async throws -> String {
        switch try await task.receive() {
        case .string(let text): return text
        case .data(let data):
            guard let text = String(data: data, encoding: .utf8) else { throw SlackAPIError(code: "invalid_response") }
            return text
        @unknown default: throw SlackAPIError(code: "invalid_response")
        }
    }

    func send(_ text: String) async throws { try await task.send(.string(text)) }
    func ping() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            // CFNetwork can call the pong handler twice when it cancels a dropped connection.
            let resumed = OSAllocatedUnfairLock(initialState: false)
            task.sendPing { error in
                guard resumed.withLock({ wasResumed in
                    defer { wasResumed = true }
                    return !wasResumed
                }) else { return }
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }
    func close() { task.cancel(with: .goingAway, reason: nil) }
}
