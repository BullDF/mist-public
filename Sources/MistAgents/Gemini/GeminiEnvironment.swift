import Foundation

enum GeminiEnvironment {
    static let keyName = "GEMINI_API_KEY"

    static func envFile(in home: URL) -> URL { home.appendingPathComponent(".env") }

    static func key(in home: URL) -> String? {
        guard let text = try? String(contentsOf: envFile(in: home), encoding: .utf8) else { return nil }
        return key(from: text)
    }

    static func key(from text: String) -> String? {
        for line in text.split(whereSeparator: \.isNewline) {
            var assignment = line.trimmingCharacters(in: .whitespaces)
            if assignment.hasPrefix("export ") || assignment.hasPrefix("export\t") {
                assignment = assignment.dropFirst("export".count).trimmingCharacters(in: .whitespaces)
            }
            let parts = assignment.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces) == keyName else { continue }
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            if let quote = value.first, quote == "'" || quote == "\"" {
                guard let end = value.dropFirst().firstIndex(of: quote) else { continue }
                let suffix = value[value.index(after: end)...].trimmingCharacters(in: .whitespaces)
                guard suffix.isEmpty || suffix.hasPrefix("#") else { continue }
                let key = String(value[value.index(after: value.startIndex)..<end])
                if !key.isEmpty { return key }
            } else {
                let key = value.prefix(while: { $0 != "#" }).trimmingCharacters(in: .whitespaces)
                if !key.isEmpty { return key }
            }
        }
        return nil
    }

    static func sanitized(_ captured: [String: String]) -> [String: String] {
        captured.filter { name, _ in
            !["ANTHROPIC_", "GEMINI_", "GOOGLE_", "CLOUDSDK_"].contains { name.hasPrefix($0) }
                && name != "OPENAI_API_KEY"
        }
    }

    static func variables(_ captured: [String: String], key: String, cliHome: URL) -> [String: String] {
        sanitized(captured).merging([
            keyName: key,
            "GEMINI_CLI_HOME": cliHome.path,
            "GEMINI_CLI_TRUST_WORKSPACE": "true",
            // The CLI's bootstrap supervisor would otherwise sit between Mist and ACP.
            "GEMINI_CLI_NO_RELAUNCH": "true",
            // System settings win over workspace settings. Use the per-chat file at both scopes.
            "GEMINI_CLI_SYSTEM_SETTINGS_PATH": cliHome.appendingPathComponent(".gemini/settings.json").path,
        ]) { _, value in value }
    }
}
