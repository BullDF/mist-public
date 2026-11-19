import Foundation
import MistMailCore

struct MailComposePrefill {
    var accountID: UUID?
    var to: [MailAddress] = []
    var cc: [MailAddress] = []
    var bcc: [MailAddress] = []
    var subject = ""
    var body = ""
}

struct MailComposeExport: Equatable {
    var html: String
    var plainText: String
}

enum MailComposeFormatting {
    static func addresses(_ text: String) -> [MailAddress] {
        var pieces: [String] = [], current = "", quoted = false, angle = false, escaped = false
        for character in text {
            if character == "\"", !escaped { quoted.toggle() }
            if !quoted, character == "<" { angle = true }
            if !quoted, character == ">" { angle = false }
            if !quoted, !angle, [",", ";", "\n", "\r"].contains(character) {
                pieces.append(current); current = ""
            } else { current.append(character) }
            escaped = character == "\\" && !escaped
        }
        pieces.append(current)
        return pieces.compactMap { piece in
            let value = piece.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { return nil }
            if let start = value.firstIndex(of: "<"), value.hasSuffix(">") {
                let name = String(value[..<start]).trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                let email = String(value[value.index(after: start)..<value.index(before: value.endIndex)])
                return .init(email, name: name.isEmpty ? nil : name)
            }
            return .init(value)
        }
    }
    static func isValid(_ address: MailAddress) -> Bool {
        let email = address.email
        guard !email.contains(where: { $0.isWhitespace || $0.isNewline }),
              !email.contains(where: { "<>;,\"".contains($0) }),
              address.name?.contains(where: { $0.isNewline }) != true else { return false }
        let parts = email.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty else { return false }
        let domain = parts[1].split(separator: ".", omittingEmptySubsequences: false)
        return domain.count > 1 && domain.allSatisfy { !$0.isEmpty }
    }
    static func display(_ address: MailAddress) -> String {
        guard let name = address.name, !name.isEmpty else { return address.email }
        let escaped = name.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return (name.contains(",") || name.contains(";") ? "\"\(escaped)\"" : name) + " <\(address.email)>"
    }
    static func mailto(_ url: URL, accountID: UUID? = nil) -> MailComposePrefill? {
        guard url.scheme?.lowercased() == "mailto" else { return nil }
        let raw = String(url.absoluteString.dropFirst(7)).components(separatedBy: "#")[0]
        let parts = raw.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        var result = MailComposePrefill(accountID: accountID)
        result.to = addresses(String(parts.first ?? "").removingPercentEncoding ?? "")
        if parts.count > 1 {
            for item in parts[1].split(separator: "&") {
                let pair = item.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard pair.count == 2, let key = pair[0].removingPercentEncoding?.lowercased(), let value = pair[1].removingPercentEncoding else { continue }
                switch key {
                case "to": result.to += addresses(value)
                case "cc": result.cc += addresses(value)
                case "bcc": result.bcc += addresses(value)
                case "subject": result.subject = value.replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: "")
                case "body": result.body = value.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
                default: break
                }
            }
        }
        return result
    }
    static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
    static func plainHTML(_ text: String) -> String {
        var result = "", level = 0
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n")
        for line in lines {
            var rest = line[...], depth = 0
            while rest.first == ">" { depth += 1; rest.removeFirst(); if rest.first == " " { rest.removeFirst() } }
            while level < depth { result += "<blockquote type=\"cite\">"; level += 1 }
            while level > depth { result += "</blockquote>"; level -= 1 }
            result += "<div>" + (rest.isEmpty ? "<br>" : escape(String(rest))) + "</div>"
        }
        while level > 0 { result += "</blockquote>"; level -= 1 }
        return result
    }
    static func document(html: String?, plainText: String = "") -> String {
        let body = html ?? plainHTML(plainText)
        if body.range(of: "<body\\b", options: [.regularExpression, .caseInsensitive]) != nil { return body }
        return "<!doctype html><html><head><meta charset=\"utf-8\"></head><body style=\"font-family:-apple-system,Helvetica,Arial,sans-serif;font-size:13px\">\(body)</body></html>"
    }
    static func referencedCIDs(_ html: String) -> Set<String> {
        guard let regex = try? NSRegularExpression(pattern: "cid:([^\\s\"'<>]+)", options: .caseInsensitive) else { return [] }
        return Set(regex.matches(in: html, range: NSRange(html.startIndex..., in: html)).compactMap {
            Range($0.range(at: 1), in: html).map { MailBodyPreparation.normalizedCID(String(html[$0])) }
        })
    }
    static func suggestions(_ values: [MailAddressSuggestion], matching query: String, excluding: [MailAddress]) -> [MailAddress] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        guard !query.isEmpty else { return [] }
        let skip = Set(excluding.map { $0.email.lowercased() })
        return Array(values.lazy.map(\.address).filter { address in
            guard !skip.contains(address.email.lowercased()) else { return false }
            let email = address.email.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            let name = (address.name ?? "").folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            return email.hasPrefix(query) || name.hasPrefix(query) || name.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).contains { $0.hasPrefix(query) }
        }.prefix(8))
    }
}
