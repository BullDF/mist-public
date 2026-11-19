import Foundation

/// When the agent transcript keeps to its bottom as replies grow.
enum AgentChatBottomFollow {
    /// How far above the bottom a following transcript may drift on its own, as rows are re-measured.
    static let tolerance: CGFloat = 24

    /// Whether a scroll event's deltas scroll toward the top. A mostly sideways swipe doesn't.
    static func scrollsUp(deltaX: CGFloat, deltaY: CGFloat) -> Bool {
        deltaY > 0 && abs(deltaY) > abs(deltaX)
    }

    /// Whether a following transcript's live scroll sits at `y` above its `bottom` because the reader scrolled up,
    /// however little. AppKit tracks a trackpad gesture itself after its first events, so no deltas reach the app
    /// and the position decides. Two moves above the bottom aren't the reader's: the bounce back after the live
    /// scroll went past the bottom, and AppKit settling at a bottom the document had earlier in the live scroll.
    static func scrollsAway(y: CGFloat, bottom: CGFloat, overscrolled: Bool, earlierBottoms: [CGFloat]) -> Bool {
        !overscrolled && y < bottom - 0.5 && !earlierBottoms.contains { $0 < bottom - 0.5 && abs($0 - y) <= 1 }
    }

    /// Whether the transcript follows its bottom with the viewport `distance` above it. A following transcript
    /// tolerates a small gap, plus `slack` while a live scroll settles during growth; once the reader has
    /// scrolled away, only the bottom itself takes them back.
    static func follows(distance: CGFloat, following: Bool, slack: CGFloat = 0) -> Bool {
        distance <= (following ? tolerance + slack : 1)
    }
}
