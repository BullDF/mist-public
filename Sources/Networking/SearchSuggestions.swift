import Foundation

enum SearchSuggestionsEngine: String, Hashable {
    case google = "google.com"
    case bing = "bing.com"

    init?(keyword: String) {
        self.init(rawValue: keyword.lowercased())
    }

    func suggestURL(query: String, language: String = Locale.preferredLanguages.first ?? "en") -> URL? {
        var components = URLComponents(string: self == .google
            ? "https://suggestqueries.google.com/complete/search" : "https://www.bing.com/osjson.aspx")!
        components.queryItems = self == .google ? [
            URLQueryItem(name: "client", value: "chrome"),
            URLQueryItem(name: "ie", value: "utf-8"),
            URLQueryItem(name: "oe", value: "utf-8"),
            URLQueryItem(name: "hl", value: language),
            URLQueryItem(name: "q", value: query)
        ] : [URLQueryItem(name: "language", value: language), URLQueryItem(name: "query", value: query)]
        return Self.encodingPlus(components).url
    }

    func resultsURL(query: String) -> URL? {
        var components = URLComponents(string: self == .google
            ? "https://www.google.com/search" : "https://www.bing.com/search")!
        components.queryItems = [URLQueryItem(name: "q", value: query)]
        return Self.encodingPlus(components).url
    }

    /// `URLComponents` leaves `+` unescaped in query items, and both engines read it as a space.
    private static func encodingPlus(_ components: URLComponents) -> URLComponents {
        var components = components
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return components
    }
}

struct SearchAnswer: Equatable {
    enum Kind {
        case calculation, conversion
    }

    let kind: Kind
    let text: String
    let value: String

    init?(text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("=") else { return nil }
        let result = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty else { return nil }
        self.text = trimmed
        if let number = result.range(of: #"^[+-]?(?:\d+(?:\.\d+)?|\.\d+)(?:[eE][+-]?\d+)?"#,
                                     options: .regularExpression) {
            value = String(result[number])
            kind = result[number.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? .calculation : .conversion
        } else {
            value = result
            kind = .calculation
        }
    }
}

struct SearchSuggestionsResult: Equatable {
    var texts: [String] = []
    var answer: SearchAnswer? = nil
}

enum SearchSuggestions {
    static func parse(_ data: Data) -> SearchSuggestionsResult {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [Any],
              json.count >= 2, json[0] is String, let entries = json[1] as? [Any] else { return SearchSuggestionsResult() }
        let metadata = json.dropFirst(2).first { $0 is [String: Any] } as? [String: Any]
        let types = metadata?["google:suggesttype"] as? [Any] ?? []
        var result = SearchSuggestionsResult()
        var seen = Set<String>()
        for (index, entry) in entries.enumerated() {
            guard let text = entry as? String else { continue }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let type = index < types.count ? types[index] as? String ?? "" : ""
            if type == "CALCULATOR" {
                if result.answer == nil { result.answer = SearchAnswer(text: trimmed) }
                continue
            }
            guard !type.contains("NAVIGATION"), type != "TAIL",
                  !trimmed.isEmpty, seen.insert(trimmed.lowercased()).inserted else { continue }
            result.texts.append(trimmed)
        }
        return result
    }
}
