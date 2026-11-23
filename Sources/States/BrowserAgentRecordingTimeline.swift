import CoreGraphics
import Foundation

enum BrowserAgentRecordingGeometry {
    static func captureSize(viewport: CGSize, scale: CGFloat) -> CGSize {
        let width = viewport.width * scale
        let height = viewport.height * scale
        let fit = min(1, 3840 / width, 2160 / height)
        return CGSize(width: max(2, (width * fit).rounded(.down)), height: max(2, (height * fit).rounded(.down)))
    }

    static func evenSize(_ size: CGSize) -> CGSize {
        CGSize(width: Int(size.width) / 2 * 2, height: Int(size.height) / 2 * 2)
    }

    static func aspectFit(_ size: CGSize, in output: CGSize) -> CGRect {
        let scale = min(output.width / size.width, output.height / size.height)
        let width = size.width * scale, height = size.height * scale
        return CGRect(x: (output.width - width) / 2, y: (output.height - height) / 2, width: width, height: height)
    }

    static func framePoint(_ point: CGPoint, frame: CGSize, device: CGSize) -> CGPoint {
        CGPoint(x: point.x * frame.width / device.width, y: point.y * frame.height / device.height)
    }
}

struct BrowserAgentRecordingTimeline {
    static let timeScale: Int32 = 60_000

    enum PointerKind: String { case move, click }

    struct Ripple {
        static let duration = 0.45
        let center: CGPoint
        let beganAt: TimeInterval

        func appearance(at time: TimeInterval) -> (radius: CGFloat, opacity: CGFloat)? {
            let elapsed = time - beganAt
            guard elapsed < Self.duration else { return nil }
            let progress = CGFloat(max(0, elapsed) / Self.duration)
            return (6 + 18 * progress, 0.9 * (1 - progress))
        }
    }

    private(set) var firstFrameTime: TimeInterval?
    private(set) var pointer: CGPoint?
    private(set) var ripples: [Ripple] = []
    private var dirty = false
    private var drewRipples = false
    private var lastPresentation: Int64?

    mutating func pageFrame(at time: TimeInterval) {
        if firstFrameTime == nil { firstFrameTime = time }
        dirty = true
    }

    mutating func pointer(_ kind: PointerKind, at point: CGPoint, time: TimeInterval) {
        if pointer != point || kind == .click { dirty = true }
        pointer = point
        if kind == .click { ripples.append(.init(center: point, beganAt: time)) }
    }

    mutating func presentation(at time: TimeInterval) -> Int64? {
        ripples.removeAll { $0.appearance(at: time) == nil }
        guard let firstFrameTime, dirty || drewRipples || !ripples.isEmpty else { return nil }
        // Frame zero has no lead-in, even when the first tick follows decoding.
        guard let lastPresentation else { return 0 }
        let ticks = Self.ticks(time - firstFrameTime)
        return ticks > lastPresentation ? ticks : nil
    }

    mutating func didAppend(at ticks: Int64) {
        lastPresentation = ticks
        dirty = false
        drewRipples = !ripples.isEmpty
    }

    func finishPresentation(at time: TimeInterval) -> Int64? {
        guard let firstFrameTime, let lastPresentation else { return nil }
        return max(lastPresentation + 1, Self.ticks(time - firstFrameTime))
    }

    private static func ticks(_ seconds: TimeInterval) -> Int64 {
        Int64(max(0, seconds) * Double(timeScale))
    }

    static func stillTimes(duration: TimeInterval, frameCount: Int) -> [TimeInterval] {
        let count = min(4, frameCount)
        guard duration > 0, count > 0 else { return [] }
        guard count > 1 else { return [0] }
        // The exact end of the track is outside the final sample.
        let last = max(0, duration - 1 / Double(timeScale))
        return (0..<count).map { index in
            index == count - 1 ? last : duration * Double(index) / Double(count - 1)
        }
    }
}
