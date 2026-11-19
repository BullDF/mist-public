import Foundation

enum ClaudeCodeSessionMetadata {
    struct Context: Equatable, Sendable {
        let tokens: Int
        let size: Int
        var fraction: Double { min(1, max(0, Double(tokens) / Double(size))) }
        var percent: Int { Int((fraction * 100).rounded()) }
        enum Level { case normal, warning, critical }
        var level: Level { Self.level(fraction: fraction) }
        static func level(fraction: Double) -> Level {
            fraction >= 0.75 ? .critical : fraction >= 0.5 ? .warning : .normal
        }
    }
    static func context(tokens: Int?, size: Int?) -> Context? {
        guard let tokens, let size, size > 0 else { return nil }
        return Context(tokens: max(0, tokens), size: size)
    }

}
