import AppKit
import ImageIO

@MainActor
final class BrowserAgentScreencast {
    let targetId: String
    private weak var tab: Tab?
    private var session: AppDevToolsPageSession?
    private var task: Task<Void, Never>?
    private var ackTask: Task<Void, Never>?
    private var pendingAcks: [Int] = []
    private var latestImage: CGImage?
    private var stopped = false
    private let onFrame: (CGImage) -> Void

    init(tab: Tab, targetId: String, onFrame: @escaping (CGImage) -> Void) {
        self.tab = tab; self.targetId = targetId; self.onFrame = onFrame
    }

    func start() {
        task = Task { [weak self] in
            guard let self, BrowserAgentTabPreview.hasLivePage(tab) else { return }
            do {
                let opened = try await AppDevToolsPageSession.open(targetId: targetId, timeout: 2)
                guard !stopped, BrowserAgentTabPreview.hasLivePage(tab),
                      tab?.webContentWrapper?.devToolsTargetId == targetId else { opened.close(); return }
                session = opened
                opened.onEvent = { [weak self] method, params in self?.event(method, params) }
                _ = try await opened.command("Page.startScreencast", params: ["format": "jpeg", "quality": 70,
                    "maxWidth": 800, "maxHeight": 1000], timeout: 2)
                task = nil
                drainAck()
            } catch { stop() }
            task = nil
        }
    }

    private func event(_ method: String, _ params: [String: Any]) {
        guard !stopped, method == "Page.screencastFrame", let id = params["sessionId"] as? Int else { return }
        if let encoded = params["data"] as? String, let data = Data(base64Encoded: encoded),
           let source = CGImageSourceCreateWithData(data as CFData, nil),
           let image = CGImageSourceCreateImageAtIndex(source, 0, nil) { latestImage = image }
        pendingAcks.append(id)
        if task == nil { drainAck() }
    }

    private func drainAck() {
        guard ackTask == nil, !stopped, let session else { return }
        ackTask = Task { [weak self] in
            guard let self else { return }
            do {
                while !stopped, !pendingAcks.isEmpty {
                    try await Task.sleep(nanoseconds: 100_000_000)
                    guard !stopped, !pendingAcks.isEmpty else { break }
                    if let image = latestImage { latestImage = nil; onFrame(image) }
                    let id = pendingAcks.removeFirst()
                    _ = try await session.command("Page.screencastFrameAck", params: ["sessionId": id], timeout: 2)
                }
            } catch { stop() }
            ackTask = nil
        }
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        task?.cancel(); ackTask?.cancel()
        let session = self.session
        self.session = nil
        Task {
            _ = try? await session?.command("Page.stopScreencast", timeout: 1)
            session?.close()
        }
    }

    nonisolated func close() { Task { @MainActor in self.stop() } }
}
