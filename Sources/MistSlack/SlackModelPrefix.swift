import Foundation

/// A model, and optionally an effort, at the start of a Slack message: `fable 5.1 medium catch me up`,
/// `gpt 6.1 terra high …`, `opus …`. Names come from the picker's catalog (`DrifterModel`): a model's
/// full title or its short alias (`fable`, `sol`), hyphens and spaces alike, case-insensitive.
struct SlackModelPrefix: Equatable {
    let engine: DrifterEngine
    let model: String
    /// The named effort, else medium or the closest one the model offers.
    let effort: String
    let rest: String

    /// Slack's own default for a thread started without a prefix.
    static let defaultFamily = "sol"
    static let defaultEffort = "medium"
    private static let effortOrder = ["none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra"]

    static func parse(_ text: String, models: [DrifterModel]) -> SlackModelPrefix? {
        let words = Self.words(text)
        var best: (model: DrifterModel, words: Int)?
        for model in models {
            for name in names(of: model) {
                guard let count = match(name, in: words), count > (best?.words ?? 0) else { continue }
                best = (model, count)
            }
        }
        guard let best else { return nil }
        var used = best.words, effort = unnamedEffort(for: best.model)
        if used < words.count, let named = best.model.efforts.first(where: { $0.lowercased() == words[used].token }) {
            effort = named; used += 1
        }
        let end = words[used - 1].range.upperBound
        let rest = String(text[end...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return .init(engine: best.model.engine, model: best.model.model, effort: effort, rest: rest)
    }

    /// Medium, or the closest effort the model offers.
    static func unnamedEffort(for model: DrifterModel) -> String {
        if model.efforts.contains(defaultEffort) { return defaultEffort }
        let target = effortOrder.firstIndex(of: defaultEffort)!
        func distance(_ effort: String) -> Int { abs((effortOrder.firstIndex(of: effort) ?? effortOrder.count * 2) - target) }
        return model.efforts.min { distance($0) < distance($1) } ?? model.defaultEffort
    }

    /// The Codex model Slack threads default to, with its catalog entry when Codex is signed in.
    static func defaultModel(in models: [DrifterModel]) -> (engine: DrifterEngine, model: String, effort: String) {
        if let sol = models.first(where: { $0.engine == .codex && family($0.model) == defaultFamily }) {
            return (.codex, sol.model, unnamedEffort(for: sol))
        }
        let id = DrifterModel.codexPicks.first { family($0) == defaultFamily } ?? DrifterModel.codexPicks[0]
        return (.codex, id, defaultEffort)
    }

    /// `Fable 5.1 · medium`, the line under a Slack reply naming what answered.
    static func label(engine: DrifterEngine, model: String, effort: String, models: [DrifterModel]) -> String {
        title(engine: engine, model: model, models: models) + " · " + effort
    }

    static func title(engine: DrifterEngine, model: String, models: [DrifterModel]) -> String {
        models.first { $0.engine == engine && $0.model == model }?.title ?? DrifterModel.title(model, engine: engine)
    }

    private struct Word { let token: String; let parts: [String]; let range: Range<String.Index> }

    private static func words(_ text: String) -> [Word] {
        var words: [Word] = [], index = text.startIndex
        while index < text.endIndex {
            guard !text[index].isWhitespace else { index = text.index(after: index); continue }
            var end = index
            while end < text.endIndex, !text[end].isWhitespace { end = text.index(after: end) }
            let token = text[index..<end].lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ",:;"))
            words.append(.init(token: token, parts: token.split(separator: "-").map(String.init), range: index..<end))
            index = end
        }
        return words
    }

    /// A name's parts, split at spaces and hyphens: `GPT-6.1 Terra` and `gpt-6.1-terra` both read `gpt 6.1 terra`.
    private static func names(of model: DrifterModel) -> [[String]] {
        let alias = switch model.engine {
        case .claude: model.model
        case .codex: family(model.model)
        case .gemini: GeminiModelInfo.family(model.model)
        }
        return [model.title, model.model, alias].map {
            $0.lowercased().split(whereSeparator: { $0 == " " || $0 == "-" }).map(String.init)
        }.filter { !$0.isEmpty }
    }

    /// The number of leading words that spell exactly `name`, or nil.
    private static func match(_ name: [String], in words: [Word]) -> Int? {
        var parts = 0, count = 0
        for word in words {
            guard parts < name.count, !word.parts.isEmpty, parts + word.parts.count <= name.count,
                  Array(name[parts..<parts + word.parts.count]) == word.parts else { return nil }
            parts += word.parts.count; count += 1
            if parts == name.count { return count }
        }
        return nil
    }

    private static func family(_ id: String) -> String { id.split(separator: "-").dropFirst(2).joined(separator: "-") }
}
