import Foundation

public enum MailVerificationCode {
    private static let keywords = try! NSRegularExpression(pattern:
        #"(?i)\b(?:code|passcode|OTP|one[- ]time|verification|verify|security|sign[- ]in|log in|login|confirm\w*|2FA|PIN|vérification|à usage unique|connexion|Bestätigung|Sicherheitscode)\b|验证码|驗證碼|認証|確認コード|인증"#)
    private static let tokens = try! NSRegularExpression(pattern:
        #"(?<![\w])(?:G-)?(?:[0-9]{3,4}[ -][0-9]{3,4}|[A-Z0-9]{3,4}-[A-Z0-9]{3,4}|[0-9]{4,8}|[A-Z0-9]{6,8})(?![\w])"#)
    private static let links = try! NSRegularExpression(pattern:
        #"(?i)(?:https?://|www\.)\S+|[\w.+-]+@[\w.-]+\.[\p{L}]{2,}"#)

    public static func extract(subject: String, body: String) -> String? {
        func clean(_ text: String) -> String {
            links.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: " ")
        }
        let subject = clean(subject), body = clean(body)
        let subjectKeywords = keywords.matches(in: subject, range: NSRange(subject.startIndex..., in: subject))
        let bodyKeywords = keywords.matches(in: body, range: NSRange(body.startIndex..., in: body))
        guard !subjectKeywords.isEmpty || !bodyKeywords.isEmpty else { return nil }
        func first(in text: String, near matches: [NSTextCheckingResult]?) -> String? {
            for match in tokens.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard let range = Range(match.range, in: text) else { continue }
                let before = text[..<range.lowerBound], after = text[range.upperBound...]
                if let last = before.last, "$€£#+".contains(last) { continue }
                if after.first == "%" { continue }
                // Reject fragments of prices, phone numbers, dates and times.
                if before.count >= 2, let last = before.last, ".,:/+-".contains(last),
                   before.dropLast().last?.isNumber == true { continue }
                if after.count >= 2, let first = after.first, ".,:/+-".contains(first),
                   after.dropFirst().first?.isNumber == true { continue }
                var code = String(text[range])
                if code.hasPrefix("G-") { code.removeFirst(2) }
                code = code.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "-", with: "")
                guard code.count >= 4, code.count <= 8, code.contains(where: \.isNumber) else { continue }
                if code.count == 4, let year = Int(code), (1900...2099).contains(year) { continue }
                if let matches, !matches.contains(where: {
                    guard let keyword = Range($0.range, in: text), keyword.upperBound <= range.lowerBound else { return false }
                    return text[keyword.upperBound..<range.lowerBound].count <= 200
                }) { continue }
                return code
            }
            return nil
        }
        return first(in: subject, near: nil) ?? first(in: body, near: bodyKeywords)
    }
}
