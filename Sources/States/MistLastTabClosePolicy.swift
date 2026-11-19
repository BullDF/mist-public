/// Decides user closes before an eligible window's normal tab strip empties.
enum MistLastTabClosePolicy {
    enum Intent {
        case tabDriven
        case windowDriven
    }

    enum Decision: Equatable {
        case proceed
        case closeWindow
        case replaceWithNewTab
    }

    static func decision(closingTabIds: Set<Int>,
                         normalTabs: [(id: Int, isNTP: Bool)],
                         activeTabId: Int?,
                         isEligible: Bool) -> Decision {
        guard isEligible,
              let activeTabId, closingTabIds.contains(activeTabId),
              !normalTabs.isEmpty,
              normalTabs.allSatisfy({ closingTabIds.contains($0.id) }) else {
            return .proceed
        }
        return normalTabs.allSatisfy(\.isNTP) ? .closeWindow : .replaceWithNewTab
    }

    /// Matches String.isNTP without importing the app's Tab implementation.
    static func isNewTabURL(_ url: String?) -> Bool {
        guard let url else { return false }
        return url.hasPrefix("chrome://newtab") || url.hasPrefix("phi://newtab")
    }
}
