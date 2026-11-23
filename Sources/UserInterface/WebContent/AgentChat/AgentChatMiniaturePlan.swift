import CoreGraphics
import Foundation

/// What a child chat's preview card pictures of its transcript, where the picture sits, and when it's redrawn.
enum AgentChatMiniaturePlan {
    /// The child's tab shows its rows in the chat column with the page's margins; the picture keeps that width,
    /// so its lines wrap as they do there.
    static let sourceWidth: CGFloat = 760 + 2 * 24
    /// A running child's picture is redrawn at most this often, a twentieth of its transcript's own rate.
    static let interval: TimeInterval = 2
    /// Scrolling or typing anywhere puts a redraw off until this long after the last such event.
    static let inputQuiet: TimeInterval = 0.4
    /// The last rows a picture tries first, then the most it takes when those don't fill the card.
    static let rowCounts = [12, 36]
    /// The items whose rows can reach the picture.
    static let itemLimit = 160
    /// At least `textLimit - textStep` bytes of one message: more than the tallest card shows.
    static let textLimit = 8_000
    /// The cut moves in steps, so a streamed reply keeps its start, and its render stays incremental, between them.
    static let textStep = 2_000

    /// Renders of different cards stay this far apart, so several busy children never stall one frame together.
    static let spacing: TimeInterval = 0.25

    static func delay(sinceRender: TimeInterval, sinceInput: TimeInterval, sinceAnyRender: TimeInterval = .infinity) -> TimeInterval {
        max(0, interval - sinceRender, inputQuiet - sinceInput, spacing - sinceAnyRender)
    }

    /// The transcript height a picture covers for a card body, rounded up so small size changes keep it.
    static func sourceHeight(body: CGSize) -> CGFloat {
        guard body.width >= 1, body.height >= 1 else { return 0 }
        return (body.height * sourceWidth / body.width / 100).rounded(.up) * 100
    }

    /// The picture of a transcript's last `rendered` points, filling the body's width: a picture that fits the body
    /// starts at the top, as in its tab; a taller one ends at the bottom. A whole transcript can be taller than the
    /// body yet within `sourceHeight`, which is rounded up, and still has to show its end.
    static func pictureFrame(rendered: CGFloat, body: CGSize) -> CGRect {
        let height = rendered * body.width / sourceWidth
        return CGRect(x: 0, y: min(0, body.height - height), width: body.width, height: height)
    }

    /// The end of a long message, from a line start. A markdown code fence left open above the cut opens again,
    /// so the kept lines render as they do in the whole message.
    static func tail(_ text: String, limit: Int = textLimit, step: Int = textStep, markdown: Bool) -> String {
        let utf8 = text.utf8
        guard utf8.count > limit else { return text }
        let cut = utf8.index(utf8.startIndex, offsetBy: (utf8.count - limit + step - 1) / step * step)
        var start: String.Index
        if let newline = utf8[cut...].firstIndex(of: UInt8(ascii: "\n")) {
            start = utf8.index(after: newline)
        } else {
            start = cut
            while start < text.endIndex, start.samePosition(in: text) == nil { start = utf8.index(after: start) }
        }
        let kept = text[start...]
        guard markdown else { return String(kept) }
        let fences = text[..<start].split(separator: "\n", omittingEmptySubsequences: false).filter {
            let line = $0.drop { $0 == " " }
            return line.hasPrefix("```") || line.hasPrefix("~~~")
        }.count
        return fences % 2 == 1 ? "```\n" + kept : String(kept)
    }
}
