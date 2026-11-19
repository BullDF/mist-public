import AppKit
import SwiftUI

/// A ring that empties as a deadline nears, with the time left as `m:ss` in its middle.
///
/// It costs next to nothing while it runs. The sweep is one Core Animation `strokeEnd` animation, which the render
/// server runs, so the app does no per-frame work. The label changes once a second, on a timer that runs only while
/// the ring is in a visible window and not hidden, and stops for good at the deadline. Coming back on screen restarts
/// both from the clock.
final class MistCountdownRingView: NSView {
    static let side: CGFloat = 42
    private static let lineWidth: CGFloat = 3.5
    private static let animationKey = "countdown"
    private let track = CAShapeLayer()
    private let progress = CAShapeLayer()
    private let label = NSTextField(labelWithString: "")
    private var deadline: Date?
    private var duration: TimeInterval = 1
    private var timer: Timer?
    private var occlusionObserver: NSObjectProtocol?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        for shape in [track, progress] {
            shape.fillColor = nil
            shape.lineWidth = Self.lineWidth
            shape.lineCap = .round
            layer?.addSublayer(shape)
        }
        track.phi(source: self)[\.strokeColor] = ThemedColor.mistChipFill.cgColorMapperOptional
        progress.phi(source: self)[\.strokeColor] = ThemedColor.themeColor.cgColorMapperOptional
        progress.strokeEnd = 0
        label.font = .monospacedDigitSystemFont(ofSize: 10.5, weight: .bold)
        label.alignment = .center
        label.phi.setTextColor(.textPrimary)
        addSubview(label)
        label.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([label.centerXAnchor.constraint(equalTo: centerXAnchor),
                                     label.centerYAnchor.constraint(equalTo: centerYAnchor)])
    }
    convenience init() { self.init(frame: NSRect(x: 0, y: 0, width: Self.side, height: Self.side)) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit {
        timer?.invalidate()
        if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
    }

    override var intrinsicContentSize: NSSize { NSSize(width: Self.side, height: Self.side) }

    /// Counts down to `deadline`; the ring is full `duration` before it. Setting the same values again does nothing.
    func set(deadline: Date, duration: TimeInterval) {
        guard deadline != self.deadline || duration != self.duration else { return }
        self.deadline = deadline
        self.duration = max(duration, 1)
        restart()
    }

    override func layout() {
        super.layout()
        // From 12 o'clock, clockwise: the end retreats toward the top as time runs out.
        let radius = (min(bounds.width, bounds.height) - Self.lineWidth) / 2
        let path = CGMutablePath()
        path.addArc(center: CGPoint(x: bounds.midX, y: bounds.midY), radius: radius,
                    startAngle: .pi / 2, endAngle: .pi / 2 - 2 * .pi, clockwise: true)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for shape in [track, progress] {
            shape.frame = bounds
            shape.path = path
        }
        CATransaction.commit()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
        occlusionObserver = window.map {
            NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: $0,
                                                   queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.visibilityChanged() }
            }
        }
        visibilityChanged()
    }
    override func viewDidHide() { super.viewDidHide(); visibilityChanged() }
    override func viewDidUnhide() { super.viewDidUnhide(); visibilityChanged() }

    private var isShowing: Bool {
        guard let window else { return false }
        return window.occlusionState.contains(.visible) && !isHiddenOrHasHiddenAncestor
    }
    private var wasShowing = false
    private func visibilityChanged() {
        let showing = isShowing
        defer { wasShowing = showing }
        if showing, !wasShowing { restart() } else { updateTimer() }
        if !showing { progress.removeAnimation(forKey: Self.animationKey) }
    }

    /// Puts the sweep and the label at the clock's time and starts what still runs.
    private func restart() {
        progress.removeAnimation(forKey: Self.animationKey)
        let remaining = deadline?.timeIntervalSinceNow ?? 0
        if remaining > 0, isShowing {
            let animation = CABasicAnimation(keyPath: "strokeEnd")
            animation.fromValue = min(remaining / duration, 1)
            animation.toValue = 0
            animation.duration = remaining
            progress.add(animation, forKey: Self.animationKey)
        }
        updateLabel()
        updateTimer()
    }
    private func updateTimer() {
        let remaining = deadline?.timeIntervalSinceNow ?? 0
        guard remaining > 0, isShowing else {
            timer?.invalidate()
            timer = nil
            return
        }
        guard timer == nil else { return }
        updateLabel()
        // Fires as each whole second of the time left runs out, so the label turns with the clock.
        let timer = Timer(fire: Date(timeIntervalSinceNow: remaining.truncatingRemainder(dividingBy: 1)), interval: 1,
                          repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
        timer.tolerance = 0.05
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }
    private func tick() {
        updateLabel()
        if (deadline?.timeIntervalSinceNow ?? 0) <= 0 {
            timer?.invalidate()
            timer = nil
        }
    }
    private func updateLabel() {
        let seconds = Int(max(0, deadline?.timeIntervalSinceNow ?? 0).rounded(.up))
        let text = String(format: "%d:%02d", seconds / 60, seconds % 60)
        if label.stringValue != text { label.stringValue = text }
    }
}

/// `MistCountdownRingView` in SwiftUI. Its ticks change the AppKit label alone, never SwiftUI state, so nothing
/// around it re-renders.
struct MistCountdownRing: NSViewRepresentable {
    let deadline: Date
    let duration: TimeInterval

    func makeNSView(context: Context) -> MistCountdownRingView { MistCountdownRingView() }
    func updateNSView(_ view: MistCountdownRingView, context: Context) { view.set(deadline: deadline, duration: duration) }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: MistCountdownRingView, context: Context) -> CGSize? {
        CGSize(width: MistCountdownRingView.side, height: MistCountdownRingView.side)
    }
}
