import Foundation

enum MistAppMatcher {
    static func matches(_ query: String, in apps: [(id: MistAppID, keywords: [String])]) -> [MistAppID] {
        func fold(_ value: String) -> String {
            value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        }
        let query = fold(query.trimmingCharacters(in: .whitespacesAndNewlines))
        guard query.count >= 2 else { return [] }
        let names = apps.filter { fold($0.id.name).hasPrefix(query) }
        let keywords = apps.filter { !fold($0.id.name).hasPrefix(query) && $0.keywords.contains { fold($0).hasPrefix(query) } }
        return (names + keywords).map(\.id)
    }
}
