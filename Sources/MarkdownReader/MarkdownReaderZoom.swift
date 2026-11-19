import Foundation

enum MarkdownReaderZoom {
    static let levels: [CGFloat] = [0.25, 0.33, 0.5, 0.67, 0.75, 0.8, 0.9, 1, 1.1, 1.25, 1.5, 1.75, 2, 2.5, 3, 4, 5]
    static func step(_ value: CGFloat, up: Bool) -> CGFloat {
        if up { return levels.first { $0 > value + 0.0001 } ?? levels.last! }
        return levels.last { $0 < value - 0.0001 } ?? levels.first!
    }
    /// Whether stepping from `value` changes it: false at the first level going down and the last going up.
    static func canStep(_ value: CGFloat, up: Bool) -> Bool {
        abs(step(value, up: up) - value) > 0.0001
    }
}
