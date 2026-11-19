import Foundation

struct GroupedTabStartPage {
    enum TabKind {
        case regular, pinned, bookmarkBacked, app
    }

    private var token: String?
    private var title: String?
    private var kind: TabKind = .regular
    private var candidate: String?

    var isEligible: Bool {
        guard token != nil, let title else { return false }
        return kind == .regular && !BrowserAgentFolderState.isAgentFolderTitle(title)
    }

    var url: String? { isEligible ? candidate : nil }

    mutating func updateMembership(token: String?, title: String?, kind: TabKind, currentURL: String?) {
        if self.token != token {
            candidate = nil
        }
        self.token = token
        self.title = title
        self.kind = kind
        if token == nil || kind != .regular || (title != nil && !isEligible) {
            candidate = nil
        } else {
            pageChanged(to: currentURL)
        }
    }

    mutating func pageChanged(to currentURL: String?) {
        // Group metadata can arrive after the tab. Keep its first page
        // privately until the group title confirms eligibility.
        guard token != nil, kind == .regular, title == nil || isEligible, candidate == nil else { return }
        candidate = Self.realPage(currentURL)
    }

    mutating func setCurrentPage(_ currentURL: String?) {
        guard canSetCurrentPage(currentURL) else { return }
        candidate = currentURL
    }

    func canSetCurrentPage(_ currentURL: String?) -> Bool {
        Self.realPage(currentURL) != nil && hasDrifted(from: currentURL)
    }

    func hasDrifted(from currentURL: String?) -> Bool {
        guard let url, let currentURL, !currentURL.isEmpty else { return false }
        return !URLProcessor.areEquivalentForOriginNavigation(currentURL, url)
    }

    private static func realPage(_ currentURL: String?) -> String? {
        guard let currentURL, let components = URLComponents(string: currentURL),
              let scheme = components.scheme?.lowercased() else { return nil }
        if scheme == "about", components.path.lowercased() == "blank" { return nil }
        if (scheme == "chrome" || scheme == "phi"), components.host?.lowercased() == "newtab" { return nil }
        return currentURL
    }
}
