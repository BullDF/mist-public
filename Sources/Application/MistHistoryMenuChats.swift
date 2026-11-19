import AppKit

/// Lays out the History menu as it opens: Chromium's Recently Closed and
/// Recently Visited keep at most five rows and no agent chats, Recently Closed
/// no agent folder tabs either (as ⌘⇧T skips them), and each agent's recent
/// chats follow in a section of their own, above Show Full History. Chromium
/// rebuilds its sections while the menu is closed, finding its rows by tag, so
/// they are hidden rather than removed.
enum MistHistoryMenuChats {
    struct Section {
        let title: String
        let chats: [(id: UUID, title: String)]
    }

    static let rowLimit = 5
    static let identifier = NSUserInterfaceItemIdentifier("mist.historyMenu.chats")

    /// `HistoryMenuBridge`'s tags: each section's separator, title and rows.
    private static let chromiumSections = [(separator: 400, title: 401, rows: 420), (separator: 440, title: 441, rows: 460)]
    /// The separator above Show Full History.
    private static let showFullSeparatorTag = 480

    /// `isChat` gets a Chromium row's URL; `isAgentFolderRow` a Recently Closed
    /// row's URL (nil for a closed window or group) and title. A menu without
    /// Chromium's sections is left alone.
    static func update(_ menu: NSMenu, sections: [Section], isChat: (String) -> Bool,
                       isAgentFolderRow: (String?, String) -> Bool, target: AnyObject?, action: Selector?) {
        guard let template = menu.item(withTag: chromiumSections[1].title) else { return }
        for item in menu.items where item.identifier == identifier {
            menu.removeItem(item)
        }
        for tags in chromiumSections {
            var shown = 0
            for item in menu.items where item.tag == tags.rows {
                // A single page carries "title\nURL" as its tooltip, or just the
                // URL when untitled; a closed window or group carries none.
                let url = item.toolTip?.components(separatedBy: "\n").last
                let isAgentFolder = tags.rows == chromiumSections[0].rows && isAgentFolderRow(url, item.title)
                item.isHidden = shown == rowLimit || url.map(isChat) == true || isAgentFolder
                if !item.isHidden { shown += 1 }
            }
            menu.item(withTag: tags.title)?.isHidden = shown == 0
            menu.item(withTag: tags.separator)?.isHidden = shown == 0
        }
        var index = menu.indexOfItem(withTag: showFullSeparatorTag)
        if index < 0 { index = menu.numberOfItems }
        for section in sections where !section.chats.isEmpty {
            let rows = section.chats.map { chat in
                let row = NSMenuItem(title: chat.title, action: action, keyEquivalent: "")
                row.target = target
                row.representedObject = chat.id
                return row
            }
            for item in [.separator(), header(section.title, like: template)] + rows {
                item.identifier = identifier
                menu.insertItem(item, at: index)
                index += 1
            }
        }
    }

    /// A copy of Chromium's section title, so the new sections look the same.
    private static func header(_ title: String, like template: NSMenuItem) -> NSMenuItem {
        let header = template.copy() as! NSMenuItem
        header.tag = 0
        header.isHidden = false
        header.target = nil
        header.action = nil
        if let styled = header.attributedTitle, styled.length > 0 {
            header.attributedTitle = NSAttributedString(string: title, attributes: styled.attributes(at: 0, effectiveRange: nil))
        } else {
            header.title = title
        }
        return header
    }
}
