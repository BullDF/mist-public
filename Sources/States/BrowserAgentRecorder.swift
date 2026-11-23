import AppKit
import AVFoundation
import Darwin
import ImageIO
import UniformTypeIdentifiers

enum BrowserAgentRecordingEnd: String {
    case stopped, turnEnded, tabClosed, timeLimit
}

private enum BrowserAgentRecordingError: LocalizedError {
    case alreadyRunning, noRecording, fileExists, noFrame, encoding, cancelled

    var errorDescription: String? {
        switch self {
        case .alreadyRunning: return "A recording is already running; call stop_recording first."
        case .noRecording: return "No recording is running."
        case .fileExists: return "That file exists. Pass overwrite: true or choose another path."
        case .noFrame: return "The tab didn't draw. Retry after the page finishes loading."
        case .encoding: return "The recording could not be encoded."
        case .cancelled: return "The recording was cancelled."
        }
    }
}

@MainActor
final class BrowserAgentRecordings {
    static let shared = BrowserAgentRecordings()

    private struct Finishing {
        let recorder: BrowserAgentRecorder
        let task: Task<BrowserAgentRecordingResult, Error>
        var hasReader = false
    }

    private var live: [UUID: BrowserAgentRecorder] = [:]
    private var finishing: [UUID: Finishing] = [:]
    private var finished: [UUID: Result<BrowserAgentRecordingResult, Error>] = [:]
    private var terminating = false

    func start(chat: UUID, tab: Tab, windowId: Int, path: String, overwrite: Bool) async throws {
        guard !terminating else { throw BrowserAgentRecordingError.cancelled }
        guard live[chat] == nil, finishing[chat] == nil else { throw BrowserAgentRecordingError.alreadyRunning }
        finished[chat] = nil
        guard overwrite || !FileManager.default.fileExists(atPath: path) else { throw BrowserAgentRecordingError.fileExists }
        guard let target = tab.webContentWrapper?.devToolsTargetId, !target.isEmpty else { throw BrowserAgentRecordingError.noFrame }
        let recorder = BrowserAgentRecorder(tab: tab, windowId: windowId, targetId: target,
            destination: URL(fileURLWithPath: path), overwrite: overwrite) { [weak self] reason in
            self?.finish(chat: chat, reason: reason)
        }
        live[chat] = recorder
        AgentChatStore.shared.notifyBrowserPreviewChanged(windowId: windowId)
        do {
            try await recorder.start()
        } catch {
            if live[chat] === recorder {
                live[chat] = nil
                recorder.cancel()
                AgentChatStore.shared.notifyBrowserPreviewChanged(windowId: windowId)
            }
            throw error
        }
    }

    func stop(chat: UUID) async throws -> [String: Any] {
        finish(chat: chat, reason: .stopped)
        if let pending = finishing[chat] {
            finishing[chat]?.hasReader = true
            return try await pending.task.value.message
        }
        guard let result = finished.removeValue(forKey: chat) else { throw BrowserAgentRecordingError.noRecording }
        return try result.get().message
    }

    func finish(chat: UUID, reason: BrowserAgentRecordingEnd) {
        guard let recorder = live.removeValue(forKey: chat) else { return }
        let endTime = ProcessInfo.processInfo.systemUptime
        recorder.stopCapturing()
        let task = Task {
            let result: Result<BrowserAgentRecordingResult, Error>
            do { result = .success(try await recorder.finish(reason: reason, at: endTime)) }
            catch { result = .failure(error) }
            if !terminating {
                if finishing.removeValue(forKey: chat)?.hasReader == false { finished[chat] = result }
                if case .success(let saved) = result {
                    AppLogInfo("Saved browser recording (\(reason.rawValue)) to \(saved.video.url.path)")
                } else if case .failure(let error) = result {
                    AppLogInfo("Browser recording failed: \(error.localizedDescription)")
                }
            }
            return try result.get()
        }
        finishing[chat] = Finishing(recorder: recorder, task: task)
        AgentChatStore.shared.notifyBrowserPreviewChanged(windowId: recorder.windowId)
    }

    func pointer(chat: UUID, tabId: Int, kind: BrowserAgentRecordingTimeline.PointerKind, point: CGPoint) {
        guard let recorder = live[chat], recorder.tabId == tabId else { return }
        recorder.pointer(kind, at: point)
    }

    func recordedTabs(windowId: Int) -> [Tab] {
        live.values.compactMap { $0.windowId == windowId ? $0.tab : nil }
    }

    func tabClosed(_ tabId: Int) {
        for chat in live.keys.filter({ live[$0]?.tabId == tabId }) {
            finish(chat: chat, reason: .tabClosed)
        }
    }

    func cancelAll() {
        terminating = true
        for recorder in live.values { recorder.cancel() }
        for pending in finishing.values {
            pending.task.cancel()
            pending.recorder.cancel()
        }
        live.removeAll()
        finishing.removeAll()
        finished.removeAll()
    }
}

@MainActor
private final class BrowserAgentRecorder {
    private enum Command { case acknowledge(Int), restart }

    weak var tab: Tab?
    let tabId: Int
    let windowId: Int
    private let targetId: String
    private let destination: URL
    private let overwrite: Bool
    private let onEnd: (BrowserAgentRecordingEnd) -> Void
    private var session: AppDevToolsPageSession?
    private var commands: AsyncStream<Command>.Continuation?
    private var startup: CheckedContinuation<Void, Error>?
    private var startupTimeout: Task<Void, Never>?
    private var targetWatch: Task<Void, Never>?
    private var stopping = false
    private var didStart = false
    private var deviceScale: CGFloat = 1

    private lazy var pipeline = BrowserAgentRecordingPipeline(destination: destination, overwrite: overwrite,
        cursor: .arrow(), firstFrame: { [weak self] result in
            Task { @MainActor in self?.resolveStartup(result) }
        }, failed: { [weak self] in
            Task { @MainActor in self?.onEnd(.stopped) }
        })

    init(tab: Tab, windowId: Int, targetId: String, destination: URL, overwrite: Bool,
         onEnd: @escaping (BrowserAgentRecordingEnd) -> Void) {
        self.tab = tab
        self.tabId = tab.guid
        self.windowId = windowId
        self.targetId = targetId
        self.destination = destination
        self.overwrite = overwrite
        self.onEnd = onEnd
    }

    func start() async throws {
        guard !stopping else { throw BrowserAgentRecordingError.noFrame }
        try await withCheckedThrowingContinuation { continuation in
            startup = continuation
            let channel = AsyncStream<Command>.makeStream()
            commands = channel.continuation
            pipeline.start()
            Task { await runCommands(channel.stream) }
            startupTimeout = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
                self?.resolveStartup(.failure(BrowserAgentRecordingError.noFrame))
            }
            let deadline = ProcessInfo.processInfo.systemUptime + 600
            targetWatch = Task { [weak self] in
                while !Task.isCancelled {
                    guard let self, !stopping else { break }
                    guard targetIsLive else { onEnd(.tabClosed); break }
                    let remaining = deadline - ProcessInfo.processInfo.systemUptime
                    if remaining <= 0 { onEnd(.timeLimit); break }
                    do { try await Task.sleep(for: .seconds(min(1, remaining))) } catch { break }
                }
            }
        }
    }

    func pointer(_ kind: BrowserAgentRecordingTimeline.PointerKind, at point: CGPoint) {
        pipeline.pointer(kind, at: point, time: ProcessInfo.processInfo.systemUptime)
    }

    func finish(reason: BrowserAgentRecordingEnd, at endTime: TimeInterval) async throws -> BrowserAgentRecordingResult {
        let video = try await pipeline.finish(at: endTime)
        try Task.checkCancellation()
        return try await video.result(endedBy: reason)
    }

    func cancel() {
        stopCapturing()
        session?.close()
        pipeline.cancel()
    }

    private var targetIsLive: Bool {
        BrowserAgentTabPreview.hasLivePage(tab) && tab?.webContentWrapper?.devToolsTargetId == targetId
    }

    private func resolveStartup(_ result: Result<Void, Error>) {
        guard let startup else { return }
        startupTimeout?.cancel()
        startupTimeout = nil
        self.startup = nil
        if case .success = result { didStart = true }
        startup.resume(with: result)
    }

    func stopCapturing() {
        guard !stopping else { return }
        stopping = true
        resolveStartup(.failure(BrowserAgentRecordingError.noFrame))
        targetWatch?.cancel()
        session?.onClose = nil
        commands?.finish()
        commands = nil
    }

    private func runCommands(_ stream: AsyncStream<Command>) async {
        do {
            let opened = try await AppDevToolsPageSession.open(targetId: targetId, timeout: 2)
            defer { opened.close(); session = nil }
            guard !stopping, targetIsLive else { throw BrowserAgentRecordingError.noFrame }
            session = opened
            opened.onClose = { [weak self] in self?.sessionEnded() }
            AgentUserSpaceDriveRegistry.shared.appWillSendPageCommand(toTab: tabId)
            let ratio = try await opened.command("Runtime.evaluate", params: ["expression": "window.devicePixelRatio", "returnByValue": true], timeout: 2)
            let scale = (ratio["result"] as? [String: Any])?["value"] as? CGFloat ?? 1
            if scale.isFinite && scale > 0 { deviceScale = scale }
            let layout = try await opened.command("Page.getLayoutMetrics", timeout: 2)
            let viewport = layout["cssVisualViewport"] as? [String: Any] ?? [:]
            guard let width = viewport["clientWidth"] as? CGFloat, let height = viewport["clientHeight"] as? CGFloat,
                  width.isFinite, height.isFinite, width > 0, height > 0 else { throw BrowserAgentRecordingError.noFrame }
            let size = BrowserAgentRecordingGeometry.captureSize(viewport: CGSize(width: width, height: height), scale: deviceScale)
            let parameters: [String: Any] = ["format": "jpeg", "quality": 90, "everyNthFrame": 2,
                "maxWidth": Int(size.width), "maxHeight": Int(size.height)]
            _ = try await opened.command("Page.enable", timeout: 2)
            guard !stopping else { return }
            // The screencast sends a frame only when the page repaints, so a static page would send none. An
            // unclipped capture reads the displayed frame without disturbing the page and seeds the first frame.
            if let seed = try? await opened.command("Page.captureScreenshot", params: ["format": "jpeg", "quality": 90], timeout: 5),
               let jpeg = seed["data"] as? String, !stopping, targetIsLive {
                pipeline.pageFrame(jpeg, device: CGSize(width: width, height: height), scale: deviceScale,
                                   at: ProcessInfo.processInfo.systemUptime)
            }
            guard !stopping else { return }
            opened.onEvent = { [weak self] method, params in self?.event(method, params) }
            _ = try await opened.command("Page.startScreencast", params: parameters, timeout: 2)
            for await command in stream {
                if stopping { break }
                switch command {
                case .acknowledge(let id):
                    _ = try await opened.command("Page.screencastFrameAck", params: ["sessionId": id], timeout: 2)
                case .restart:
                    // Some Chromium versions reject start while a screencast is active.
                    _ = try await opened.command("Page.stopScreencast", timeout: 2)
                    if !stopping { _ = try await opened.command("Page.startScreencast", params: parameters, timeout: 2) }
                }
            }
            _ = try? await opened.command("Page.stopScreencast", timeout: 1)
        } catch {
            sessionEnded()
        }
    }

    private func sessionEnded() {
        guard !stopping else { return }
        if didStart { onEnd(.tabClosed) }
        else { resolveStartup(.failure(BrowserAgentRecordingError.noFrame)) }
    }

    private func event(_ method: String, _ params: [String: Any]) {
        guard !stopping else { return }
        switch method {
        case "Page.screencastFrame":
            guard targetIsLive else { onEnd(.tabClosed); return }
            guard let id = params["sessionId"] as? Int else { return }
            commands?.yield(.acknowledge(id))
            guard let jpeg = params["data"] as? String else { return }
            let metadata = params["metadata"] as? [String: Any]
            let device = CGSize(width: metadata?["deviceWidth"] as? CGFloat ?? 0, height: metadata?["deviceHeight"] as? CGFloat ?? 0)
            pipeline.pageFrame(jpeg, device: device, scale: deviceScale, at: ProcessInfo.processInfo.systemUptime)
        case "Page.frameNavigated":
            if let frame = params["frame"] as? [String: Any], frame["parentId"] == nil { commands?.yield(.restart) }
        default:
            break
        }
    }
}

private struct BrowserAgentRecordingCursor: Sendable {
    let image: CGImage
    let size: CGSize
    let hotSpot: CGPoint

    @MainActor
    static func arrow() -> Self? {
        let arrow = NSCursor.arrow
        guard let image = arrow.image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        return Self(image: image, size: arrow.image.size, hotSpot: arrow.hotSpot)
    }
}

/// Only the serial queue touches the decoder, compositor, timeline and writer.
private final class BrowserAgentRecordingPipeline: @unchecked Sendable {
    private struct EncodedFrame {
        let jpeg: String
        let device: CGSize
        let scale: CGFloat
        let time: TimeInterval
    }

    private let queue = DispatchQueue(label: "mist.browser-recording", qos: .userInitiated)
    private let destination: URL
    private let overwrite: Bool
    private let cursor: BrowserAgentRecordingCursor?
    private let firstFrame: @Sendable (Result<Void, Error>) -> Void
    private let failed: @Sendable () -> Void
    private var ticker: DispatchSourceTimer?
    private var timeline = BrowserAgentRecordingTimeline()
    private var pending: EncodedFrame?
    private var lastJPEG: String?
    private var frame: CGImage?
    private var device: CGSize = .zero
    private var firstSize: CGSize = .zero
    private var canvas: CGContext?
    private var writer: BrowserAgentRecordingWriter?
    private var failure: Error?

    init(destination: URL, overwrite: Bool, cursor: BrowserAgentRecordingCursor?,
         firstFrame: @escaping @Sendable (Result<Void, Error>) -> Void, failed: @escaping @Sendable () -> Void) {
        self.destination = destination
        self.overwrite = overwrite
        self.cursor = cursor
        self.firstFrame = firstFrame
        self.failed = failed
    }

    func start() {
        queue.async { [self] in
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now(), repeating: .nanoseconds(33_333_333), leeway: .milliseconds(2))
            timer.setEventHandler { [weak self] in self?.tick() }
            self.ticker = timer
            timer.resume()
        }
    }

    func pageFrame(_ jpeg: String, device: CGSize, scale: CGFloat, at time: TimeInterval) {
        queue.async {
            let frame = EncodedFrame(jpeg: jpeg, device: device, scale: scale, time: time)
            self.pending = frame
            if self.timeline.firstFrameTime == nil { self.tick() }
        }
    }

    func pointer(_ kind: BrowserAgentRecordingTimeline.PointerKind, at point: CGPoint, time: TimeInterval) {
        queue.async { self.timeline.pointer(kind, at: point, time: time) }
    }

    private func tick() {
        guard failure == nil else { return }
        do {
            if let pending {
                self.pending = nil
                try decode(pending)
            }
            let now = ProcessInfo.processInfo.systemUptime
            guard let writer, let canvas, let frame, let ticks = timeline.presentation(at: now), writer.isReady else { return }
            draw(frame, into: canvas, at: now)
            guard let image = canvas.makeImage() else { throw BrowserAgentRecordingError.encoding }
            let first = writer.frameCount == 0
            if try writer.append(image, at: CMTime(value: ticks, timescale: BrowserAgentRecordingTimeline.timeScale)) {
                timeline.didAppend(at: ticks)
                if first { firstFrame(.success(())) }
            }
        } catch {
            failure = error
            ticker?.cancel()
            writer?.cancel()
            if timeline.firstFrameTime == nil || writer?.frameCount == 0 { firstFrame(.failure(error)) }
            else { failed() }
        }
    }

    private func decode(_ pending: EncodedFrame) throws {
        guard pending.jpeg != lastJPEG || (pending.device != .zero && pending.device != device) else { return }
        guard let data = Data(base64Encoded: pending.jpeg), let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { return }
        let size = CGSize(width: image.width, height: image.height)
        if writer == nil {
            let output = BrowserAgentRecordingGeometry.evenSize(size)
            guard output.width > 0, output.height > 0,
                  let canvas = CGContext(data: nil, width: Int(output.width), height: Int(output.height), bitsPerComponent: 8,
                    bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
                throw BrowserAgentRecordingError.encoding
            }
            canvas.interpolationQuality = .high
            self.canvas = canvas
            firstSize = size
            writer = try BrowserAgentRecordingWriter(destination: destination, overwrite: overwrite, size: output, queue: queue)
        }
        lastJPEG = pending.jpeg
        frame = image
        device = pending.device.width > 0 && pending.device.height > 0 ? pending.device
            : CGSize(width: size.width / pending.scale, height: size.height / pending.scale)
        timeline.pageFrame(at: pending.time)
    }

    private func draw(_ image: CGImage, into context: CGContext, at time: TimeInterval) {
        let output = CGSize(width: context.width, height: context.height)
        let size = CGSize(width: image.width, height: image.height)
        let rect = size == firstSize ? CGRect(x: 0, y: output.height - size.height, width: size.width, height: size.height)
            : BrowserAgentRecordingGeometry.aspectFit(size, in: output)
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(origin: .zero, size: output))
        context.draw(image, in: rect)
        let scale = BrowserAgentRecordingGeometry.framePoint(CGPoint(x: 1, y: 1), frame: rect.size, device: device)
        func position(_ point: CGPoint) -> CGPoint {
            let pixel = BrowserAgentRecordingGeometry.framePoint(point, frame: rect.size, device: device)
            return CGPoint(x: rect.minX + pixel.x, y: rect.maxY - pixel.y)
        }

        context.saveGState()
        context.clip(to: rect)
        for ripple in timeline.ripples {
            guard let style = ripple.appearance(at: time) else { continue }
            let center = position(ripple.center)
            let radiusX = style.radius * scale.x, radiusY = style.radius * scale.y
            let ring = CGRect(x: center.x - radiusX, y: center.y - radiusY, width: 2 * radiusX, height: 2 * radiusY)
            let lineScale = min(scale.x, scale.y)
            context.saveGState()
            context.setShadow(offset: .zero, blur: 2 * lineScale, color: CGColor(gray: 0, alpha: style.opacity * 0.65))
            context.setStrokeColor(CGColor(gray: 0, alpha: style.opacity * 0.5))
            context.setLineWidth(4 * lineScale)
            context.strokeEllipse(in: ring)
            context.restoreGState()
            context.setStrokeColor(CGColor(gray: 1, alpha: style.opacity))
            context.setLineWidth(2 * lineScale)
            context.strokeEllipse(in: ring)
        }
        if let cursor, let pointer = timeline.pointer {
            let origin = position(pointer)
            context.draw(cursor.image, in: CGRect(x: origin.x - cursor.hotSpot.x * scale.x,
                y: origin.y - (cursor.size.height - cursor.hotSpot.y) * scale.y,
                width: cursor.size.width * scale.x, height: cursor.size.height * scale.y))
        }
        context.restoreGState()
    }

    func finish(at time: TimeInterval) async throws -> BrowserAgentRecordingVideo {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                self.ticker?.cancel()
                self.pending = nil
                if let failure = self.failure { continuation.resume(throwing: failure); return }
                guard let writer = self.writer, let ticks = self.timeline.finishPresentation(at: time) else {
                    self.writer?.cancel()
                    continuation.resume(throwing: BrowserAgentRecordingError.noFrame)
                    return
                }
                writer.finish(at: CMTime(value: ticks, timescale: BrowserAgentRecordingTimeline.timeScale)) {
                    continuation.resume(with: $0)
                }
            }
        }
    }

    func cancel() {
        queue.sync {
            ticker?.cancel()
            failure = BrowserAgentRecordingError.cancelled
            pending = nil
            writer?.cancel()
        }
    }
}

/// Use one serial background queue for appends, finalization and cancellation.
final class BrowserAgentRecordingWriter: @unchecked Sendable {
    let destination: URL
    let temporary: URL
    private let overwrite: Bool
    private let size: CGSize
    private let queue: DispatchQueue
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private var lastBuffer: CVPixelBuffer?
    private var cancelled = false
    private(set) var frameCount = 0

    init(destination: URL, overwrite: Bool, size: CGSize, queue: DispatchQueue) throws {
        self.destination = destination
        self.overwrite = overwrite
        self.size = size
        self.queue = queue
        let name = destination.deletingPathExtension().lastPathComponent
        let stem = String(decoding: name.utf8.prefix(160), as: UTF8.self)
        temporary = destination.deletingLastPathComponent().appendingPathComponent(".\(stem).\(UUID().uuidString).recording.mp4")
        let width = Int(size.width), height = Int(size.height)
        let bitRate = max(128_000, Int(8_000_000 * size.width * size.height / (2880 * 1800)))
        writer = try AVAssetWriter(outputURL: temporary, fileType: .mp4)
        writer.movieTimeScale = BrowserAgentRecordingTimeline.timeScale
        input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width, AVVideoHeightKey: height, AVVideoCompressionPropertiesKey: [
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel, AVVideoAverageBitRateKey: bitRate,
                AVVideoAllowFrameReorderingKey: false
            ]])
        input.expectsMediaDataInRealTime = true
        input.mediaTimeScale = BrowserAgentRecordingTimeline.timeScale
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
        ])
        do {
            guard writer.canAdd(input) else { throw BrowserAgentRecordingError.encoding }
            writer.add(input)
            guard writer.startWriting() else { throw writer.error ?? BrowserAgentRecordingError.encoding }
            writer.startSession(atSourceTime: .zero)
        } catch {
            cancel()
            throw error
        }
    }

    var isReady: Bool { writer.status != .writing || input.isReadyForMoreMediaData }

    @discardableResult
    func append(_ image: CGImage, at time: CMTime) throws -> Bool {
        guard writer.status == .writing else { throw writer.error ?? BrowserAgentRecordingError.encoding }
        guard input.isReadyForMoreMediaData else { return false }
        var buffer: CVPixelBuffer?
        guard let pool = adaptor.pixelBufferPool,
              CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess, let buffer else {
            throw BrowserAgentRecordingError.encoding
        }
        try copy(image, into: buffer)
        guard adaptor.append(buffer, withPresentationTime: time) else { throw writer.error ?? BrowserAgentRecordingError.encoding }
        lastBuffer = buffer
        frameCount += 1
        return true
    }

    private func copy(_ image: CGImage, into buffer: CVPixelBuffer) throws {
        guard CVPixelBufferLockBaseAddress(buffer, []) == kCVReturnSuccess else { throw BrowserAgentRecordingError.encoding }
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let info = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue
        guard let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: Int(size.width), height: Int(size.height),
            bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info) else {
            throw BrowserAgentRecordingError.encoding
        }
        context.draw(image, in: CGRect(origin: .zero, size: size))
    }

    func finish(at time: CMTime, completion: @escaping @Sendable (Result<BrowserAgentRecordingVideo, Error>) -> Void) {
        appendTail(at: time, deadline: .now() + .seconds(5), completion: completion)
    }

    private func appendTail(at time: CMTime, deadline: DispatchTime,
                            completion: @escaping @Sendable (Result<BrowserAgentRecordingVideo, Error>) -> Void) {
        do {
            guard !cancelled else { throw BrowserAgentRecordingError.cancelled }
            guard let lastBuffer, writer.status == .writing else { throw writer.error ?? BrowserAgentRecordingError.encoding }
            guard input.isReadyForMoreMediaData else {
                guard DispatchTime.now() < deadline else { throw BrowserAgentRecordingError.encoding }
                queue.asyncAfter(deadline: .now() + .milliseconds(10)) { self.appendTail(at: time, deadline: deadline, completion: completion) }
                return
            }
            guard adaptor.append(lastBuffer, withPresentationTime: time) else { throw writer.error ?? BrowserAgentRecordingError.encoding }
            writer.endSession(atSourceTime: time)
            input.markAsFinished()
            writer.finishWriting {
                self.queue.async { completion(Result { try self.publish() }) }
            }
        } catch {
            cancel()
            completion(.failure(error))
        }
    }

    private func publish() throws -> BrowserAgentRecordingVideo {
        do {
            guard !cancelled else { throw BrowserAgentRecordingError.cancelled }
            guard writer.status == .completed else { throw writer.error ?? BrowserAgentRecordingError.encoding }
            let bytes = try temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            // Both paths are siblings, so rename is atomic. RENAME_EXCL also checks for an intervening file.
            let moved = renamex_np(temporary.path, destination.path, overwrite ? 0 : UInt32(RENAME_EXCL))
            if moved != 0 {
                let code = errno
                if !overwrite && code == EEXIST { throw BrowserAgentRecordingError.fileExists }
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
            }
            return BrowserAgentRecordingVideo(url: destination, size: size, bytes: bytes, frameCount: frameCount)
        } catch {
            cancel()
            throw error
        }
    }

    func cancel() {
        cancelled = true
        if writer.status == .writing { writer.cancelWriting() }
        try? FileManager.default.removeItem(at: temporary)
    }
}

struct BrowserAgentRecordingVideo: Sendable {
    let url: URL
    let size: CGSize
    let bytes: Int
    let frameCount: Int

    func result(endedBy: BrowserAgentRecordingEnd) async throws -> BrowserAgentRecordingResult {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        generator.maximumSize = BrowserAgentScreenshotGeometry.modelSize(for: size)
        var stills: [BrowserAgentRecordingResult.Still] = []
        for seconds in BrowserAgentRecordingTimeline.stillTimes(duration: duration, frameCount: frameCount) {
            try Task.checkCancellation()
            let time = CMTime(seconds: seconds, preferredTimescale: BrowserAgentRecordingTimeline.timeScale)
            guard let frame = try? await generator.image(at: time) else { continue }
            let data = NSMutableData()
            guard let jpeg = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { continue }
            CGImageDestinationAddImage(jpeg, frame.image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
            if CGImageDestinationFinalize(jpeg) { stills.append(.init(at: seconds, data: data as Data)) }
        }
        return BrowserAgentRecordingResult(video: self, duration: duration, endedBy: endedBy, stills: stills)
    }
}

struct BrowserAgentRecordingResult: Sendable {
    struct Still: Sendable {
        let at: TimeInterval
        let data: Data
    }

    let video: BrowserAgentRecordingVideo
    let duration: TimeInterval
    let endedBy: BrowserAgentRecordingEnd
    let stills: [Still]

    var message: [String: Any] {
        ["ok": true, "path": video.url.path, "durationSeconds": duration, "width": Int(video.size.width),
         "height": Int(video.size.height), "bytes": video.bytes, "endedBy": endedBy.rawValue,
         "stills": stills.map { ["at": $0.at, "image": $0.data.base64EncodedString(), "mimeType": "image/jpeg"] }]
    }
}
