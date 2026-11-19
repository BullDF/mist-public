import AppKit
import SwiftMath

enum MarkdownMathTypesetter {
    private final class Entry: NSObject {
        let value: MarkdownMathTypeset
        init(_ value: MarkdownMathTypeset) { self.value = value }
    }
    private static let cache = NSCache<NSString, Entry>()

    static func typeset(latex: String, display: Bool, pointSize: CGFloat, color: NSColor) -> MarkdownMathTypeset? {
        let key = "\(latex.utf16.count):\(latex):\(display):\(pointSize):\(color)" as NSString
        if let entry = cache.object(forKey: key) { return entry.value }
        var math = MathImage(latex: MarkdownMath.normalized(latex), fontSize: pointSize, textColor: color, labelMode: display ? .display : .text, textAlignment: .left)
        let (error, image, layout) = math.asImage()
        guard error == nil, let image, let layout else { return nil }
        // Where SwiftMath's layoutImage puts the baseline, measured from the image bottom.
        let baseline = (image.size.height - max(layout.ascent + layout.descent, pointSize / 2)) / 2 + layout.descent
        let value = MarkdownMathTypeset(image: image, baseline: baseline)
        cache.setObject(Entry(value), forKey: key)
        return value
    }
}
