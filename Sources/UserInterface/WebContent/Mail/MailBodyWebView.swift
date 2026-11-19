import AppKit
import WebKit
import UniformTypeIdentifiers

final class MailCIDSchemeHandler: NSObject, WKURLSchemeHandler {
    var messageID: UUID?
    var files: [String: URL] = [:]
    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url, url.host == messageID?.uuidString.lowercased(),
              let file = files[MailBodyPreparation.normalizedCID(String(url.path.dropFirst()))], file.isFileURL else {
            urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist)); return
        }
        do {
            let data = try Data(contentsOf: file)
            let mime = UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
            urlSchemeTask.didReceive(URLResponse(url: url, mimeType: mime, expectedContentLength: data.count, textEncodingName: nil))
            urlSchemeTask.didReceive(data); urlSchemeTask.didFinish()
        } catch { urlSchemeTask.didFailWithError(error) }
    }
    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {}
}

final class MailBodyWebView: WKWebView {
    /// WebKit constructs the menu in an internal child view; willOpenMenu reaches this view too.
    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        // Not WebKit's own Open Link: it navigates the message in place, which the reader cancels.
        let allowed = ["WKMenuItemIdentifierCopy", "WKMenuItemIdentifierCopyLink", "WKMenuItemIdentifierOpenLinkInNewWindow", "WKMenuItemIdentifierLookUp"]
        for item in menu.items {
            let identifier = item.identifier?.rawValue ?? ""
            if identifier == "WKMenuItemIdentifierOpenLinkInNewWindow" { item.title = MailStrings.openLink }
            if !allowed.contains(identifier) { menu.removeItem(item) }
        }
    }
}
