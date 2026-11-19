import Foundation

/// What a chat link opens, and how it finds a tab already showing its page.
enum AgentChatLink {
    /// A link with no scheme is a file path, as Claude writes them: absolute, `~/`, or relative to the chat's
    /// folder. Chromium opened it as about:blank.
    static func target(_ url: URL, folder: URL?) -> URL {
        guard url.scheme == nil, url.host == nil, !url.path.isEmpty else { return url }
        let path = (url.path as NSString).expandingTildeInPath
        let base = folder ?? FileManager.default.homeDirectoryForCurrentUser
        let file = (path.hasPrefix("/") ? URL(fileURLWithPath: path) : base.appendingPathComponent(path)).standardizedFileURL
        guard let fragment = url.fragment, var components = URLComponents(url: file, resolvingAgainstBaseURL: false) else { return file }
        components.fragment = fragment
        return components.url ?? file
    }

    /// The URL a tab must show for a link to switch to it: the same URL, ignoring the fragment and a trailing slash.
    /// Scheme and host compare lowercased, as Chromium shows them.
    static func matchKey(_ url: String) -> String? {
        guard var components = URLComponents(string: url), let scheme = components.scheme else { return nil }
        components.scheme = scheme.lowercased()
        components.percentEncodedHost = components.percentEncodedHost?.lowercased()
        components.fragment = nil
        if components.percentEncodedPath.hasSuffix("/") { components.percentEncodedPath.removeLast() }
        return components.string
    }
}
