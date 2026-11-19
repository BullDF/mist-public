import AppKit

/// Strips framework menu items for features Mist deleted (Kiosk's "Open in
/// Kiosk" link item) just before a menu shows. Chromium's context-menu items
/// carry model indexes as tags, not command IDs, so they are matched by title:
/// `rebrand_framework.py` writes every translation of the framework's own
/// string into `MistRemovedMenuItemTitles.plist` and fails the build when the
/// English source string moves.
enum MistRemovedMenuItems {
    static let titles: Set<String> = {
        guard let url = Bundle.main.url(forResource: "MistRemovedMenuItemTitles", withExtension: "plist"),
              let titles = NSArray(contentsOf: url) as? [String] else { return [] }
        return Set(titles)
    }()

    /// Removes matching items from `menu` and its submenus, then the
    /// separators a removal left leading, trailing or doubled.
    static func strip(_ menu: NSMenu, titles: Set<String> = titles) {
        guard !titles.isEmpty else { return }
        var removed = false
        for item in menu.items {
            if titles.contains(item.title) {
                menu.removeItem(item)
                removed = true
            } else if let submenu = item.submenu {
                strip(submenu, titles: titles)
            }
        }
        guard removed else { return }
        var previousIsSeparator = true
        for item in menu.items {
            if item.isSeparatorItem && previousIsSeparator {
                menu.removeItem(item)
            } else {
                previousIsSeparator = item.isSeparatorItem
            }
        }
        if let last = menu.items.last, last.isSeparatorItem {
            menu.removeItem(last)
        }
    }
}
