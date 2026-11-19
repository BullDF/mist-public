import Foundation

struct MailPreparedBody {
    let html: String
    let isHTML: Bool
}

enum MailBodyPreparation {
    /// The CSS custom property holding the page's side margin, which the reader updates when it zooms.
    static let gutterProperty = "--mist-gutter"
    /// The reader insets the web view's left side to the header's text edge, so the body has no left margin of
    /// its own, but its right side reaches the pane's edge: the body pads its right side by `gutter` CSS pixels,
    /// where the overlay scroll bar draws. `framed` HTML, shown as a white page on a dark one, pads both sides.
    static func prepare(html: String?, text: String?, messageID: UUID, textColor: String = "#222222", background: String = "#ffffff", framed: Bool = false, gutter: CGFloat = 20) -> MailPreparedBody {
        let isHTML = html != nil
        let source: String
        if let html { source = rewriteCIDs(html, messageID: messageID) }
        else { source = "<div class=\"plain\">" + linkify(text ?? "") + "</div>" }
        // Remote images, styles and fonts load; scripts, frames, forms and other schemes don't.
        let csp = "default-src 'none'; img-src data: mist-mail-cid: http: https:; style-src 'unsafe-inline' http: https:; font-src data: http: https:; script-src 'none'; frame-src 'none'; object-src 'none'; connect-src 'none'; form-action 'none'; base-uri 'none'"
        // Important, so a message's own CSS can't put its text under the scroll bar.
        let padding = "\(gutterProperty):\(cssPixels(gutter));padding:0 var(\(gutterProperty)) 0 \(framed ? "var(\(gutterProperty))" : "0")!important"
        let style = isHTML ? "html{background:white;color:black;\(padding)}body{margin:20px 0;overflow-wrap:anywhere}img{max-width:100%;height:auto}" : "html{background:\(background);color:\(textColor);\(padding)}body{margin:20px 0}.plain{white-space:pre-wrap;overflow-wrap:anywhere;font:14px -apple-system}a{color:inherit}"
        return .init(html: "<!doctype html><html><head><meta charset=\"utf-8\"><meta http-equiv=\"Content-Security-Policy\" content=\"\(csp)\"><meta name=\"viewport\" content=\"width=device-width\"><style>\(style)</style></head><body>\(source)</body></html>", isHTML: isHTML)
    }
    static func cssPixels(_ value: CGFloat) -> String {
        var number = String(format: "%.3f", Double(value))
        while number.hasSuffix("0") { number.removeLast() }
        if number.hasSuffix(".") { number.removeLast() }
        return number + "px"
    }
    static func cidURL(messageID: UUID, cid: String) -> URL? {
        var components = URLComponents(); components.scheme = "mist-mail-cid"; components.host = messageID.uuidString.lowercased(); components.path = "/" + normalizedCID(cid)
        return components.url
    }
    static func normalizedCID(_ cid: String) -> String { (cid.removingPercentEncoding ?? cid).trimmingCharacters(in: CharacterSet(charactersIn: "<>")) }
    static func rewriteCIDs(_ html: String, messageID: UUID) -> String {
        guard let regex = try? NSRegularExpression(pattern: "cid:([^\\s\"'<>]+)", options: .caseInsensitive) else { return html }
        var value = html
        for match in regex.matches(in: html, range: NSRange(html.startIndex..., in: html)).reversed() {
            guard let range = Range(match.range, in: value), let cidRange = Range(match.range(at: 1), in: html), let url = cidURL(messageID: messageID, cid: String(html[cidRange])) else { continue }
            value.replaceSubrange(range, with: MistAppPlaceholder.escape(url.absoluteString))
        }
        return value
    }
    static func linkify(_ text: String) -> String {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return MistAppPlaceholder.escape(text) }
        var output = "", start = text.startIndex
        for match in detector.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range, in: text), let url = match.url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { continue }
            output += MistAppPlaceholder.escape(String(text[start..<range.lowerBound]))
            output += "<a href=\"\(MistAppPlaceholder.escape(url.absoluteString))\">\(MistAppPlaceholder.escape(String(text[range])))</a>"
            start = range.upperBound
        }
        return output + MistAppPlaceholder.escape(String(text[start...]))
    }
}
