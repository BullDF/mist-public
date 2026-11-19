import AppKit
import Combine
import SnapKit

enum MistSidebarAgentSections {
    private static let expandedSubject = CurrentValueSubject<[String: Bool], Never>([:])

    /// A folder follows its chat only while that chat is a member of this window's agent section.
    static func folderToken(for tab: Tab, in state: BrowserState) -> String? {
        guard isMember(tab, splits: state.splits, isIncognito: state.isIncognito),
              let id = MistApps.address(tab.url)?.chatId else { return nil }
        return MainActor.assumeIsolated {
            guard let folder = AgentChatStore.shared.browserFolder(for: id), folder.windowId == state.windowId,
                  state.groups[folder.token] != nil else { return nil }
            return folder.token
        }
    }

    static func folderTokens(in state: BrowserState) -> Set<String> {
        Set(state.normalTabs.compactMap { folderToken(for: $0, in: state) })
    }

    static func membersIncludingFolders(in state: BrowserState) -> [Tab] {
        let chats = members(in: state.normalTabs, splits: state.splits, isIncognito: state.isIncognito)
        let tokens = Set(chats.compactMap { folderToken(for: $0, in: state) })
        return chats + state.normalTabs.filter { $0.groupToken.map(tokens.contains) == true }
    }

    private static let removedLegacyKeys: Void = {
        for old in ["claudeCode", "browserAgent"] {
            UserDefaults.standard.removeObject(forKey: "mist.sidebar.agents.\(old).expanded")
        }
    }()

    static func expandedKey() -> String { "mist.sidebar.agents.drifter.expanded" }

    static func isExpanded() -> Bool {
        _ = removedLegacyKeys
        return UserDefaults.standard.object(forKey: expandedKey()) as? Bool ?? true
    }

    static func setExpanded(_ expanded: Bool) {
        _ = removedLegacyKeys
        UserDefaults.standard.set(expanded, forKey: expandedKey())
        expandedSubject.send([expandedKey(): expanded])
    }

    static func expandedPublisher() -> AnyPublisher<Bool, Never> {
        expandedSubject.map { _ in isExpanded() }.removeDuplicates().eraseToAnyPublisher()
    }

    static func isMember(_ tab: Tab, splits: [SplitGroup], isIncognito: Bool,
                         route: AgentChatRoute = .current) -> Bool {
        !isIncognito && tab.groupToken == nil && !splits.contains { $0.contains(tabId: tab.guid) }
            && route.conversationId(for: tab.url) != nil
    }

    static func members(in tabs: [Tab], splits: [SplitGroup], isIncognito: Bool,
                        route: AgentChatRoute = .current) -> [Tab] {
        tabs.filter { isMember($0, splits: splits, isIncognito: isIncognito, route: route) }
    }

    static func visibleMembers(_ members: [Tab], isExpanded: Bool, activeTabId: Int?) -> [Tab] {
        isExpanded ? members : members.filter { $0.guid == activeTabId }
    }

    /// Chromium's rule when a collapsing tab group holds the active tab: the
    /// nearest still-visible tab to its right, else the nearest to its left.
    static func focusTarget(after focused: Tab, in tabs: [Tab], hiding hiddenIds: Set<Int>) -> Tab? {
        guard let index = tabs.firstIndex(where: { $0 === focused }) else { return nil }
        let isVisible = { (tab: Tab) in !hiddenIds.contains(tab.guid) }
        return tabs[(index + 1)...].first(where: isVisible) ?? tabs[..<index].last(where: isVisible)
    }

    static func outlineItems(members: [Tab], header: MistSidebarAgentHeaderItem,
                             isExpanded: Bool, activeTabId: Int?) -> [SidebarItem] {
        guard !members.isEmpty else { return [] }
        return [header] + visibleMembers(members, isExpanded: isExpanded, activeTabId: activeTabId)
    }
}

final class MistSidebarAgentHeaderItem: SidebarItem {
    var id: AnyHashable { "agent-header:drifter" }
    var title: String { MistAppID.drifter.name }
    var url: String? { nil }
    var iconName: String? { "drifter-logo" }
    var faviconUrl: String? { nil }
    var isExpandable: Bool { false }
    var hasChildren: Bool { false }
    var childrenItems: [SidebarItem] { [] }
    var depth: Int { 0 }
    var itemType: SidebarItemType { .agentHeader }
    var isActive: Bool { false }
    var isSelectable: Bool { false }
    var isBookmark: Bool { false }
    func performAction(with owner: SidebarTabListItemOwner?) {
        owner?.toggleItemExpanded(self)
    }
}

final class MistSidebarAgentHeaderCell: SidebarCellView {
    private var content: MistSidebarSectionHeaderView?

    override func configure(with item: SidebarItem) {
        super.configure(with: item)
        cancellables.removeAll()
        content?.removeFromSuperview()
        guard let header = item as? MistSidebarAgentHeaderItem else { return }
        // Drifter is no single engine's, so the section shows its own logo, which is wide.
        let image = NSImage(named: "drifter-logo")
        let width = image.map { 14 * $0.size.width / max(1, $0.size.height) } ?? 14
        let content = MistSidebarSectionHeaderView(title: header.title, image: image, iconSize: NSSize(width: width, height: 14))
        self.content = content
        addSubview(content)
        content.snp.makeConstraints { $0.edges.equalToSuperview() }
        setAccessibilityLabel(header.title)
        MistSidebarAgentSections.expandedPublisher()
            .sink { content.isExpanded = $0 }
            .store(in: &cancellables)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) == nil ? nil : self
    }
}
