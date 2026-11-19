import AppKit

func fail(_ message: String, line: Int = #line) -> Never {
    print("FAIL line \(line): \(message)")
    exit(1)
}

func item(_ title: String, tag: Int = 0, url: String? = nil) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
    item.tag = tag
    item.toolTip = url.map { "\(title)\n\($0)" }
    return item
}

func separator(tag: Int) -> NSMenuItem {
    let item = NSMenuItem.separator()
    item.tag = tag
    return item
}

/// Chromium's History menu: `closed` and `visited` rows titled by their URL,
/// those starting with "chat" being agent chats.
func historyMenu(closed: [String], visited: [String]) -> NSMenu {
    let menu = NSMenu()
    for title in ["Home", "Back", "Forward"] { menu.addItem(item(title)) }
    menu.addItem(separator(tag: 400))
    let closedTitle = item("Recently Closed", tag: 401)
    closedTitle.attributedTitle = NSAttributedString(string: "Recently Closed", attributes: [.font: NSFont.boldSystemFont(ofSize: 11)])
    menu.addItem(closedTitle)
    for url in closed {
        // A closed window or group carries no URL.
        let isEntry = url == "window" || url.hasPrefix("Agent tabs")
        let row = item(url, tag: 420, url: isEntry ? nil : url)
        if isEntry { row.submenu = NSMenu() }
        menu.addItem(row)
    }
    menu.addItem(separator(tag: 440))
    let visitedTitle = item("Recently Visited", tag: 441)
    visitedTitle.attributedTitle = NSAttributedString(string: "Recently Visited", attributes: [.font: NSFont.boldSystemFont(ofSize: 11)])
    menu.addItem(visitedTitle)
    for url in visited { menu.addItem(item(url, tag: 460, url: url)) }
    menu.addItem(separator(tag: 480))
    menu.addItem(item("Show Full History"))
    return menu
}

func layout(_ menu: NSMenu) -> [String] {
    menu.items.filter { !$0.isHidden }.map { $0.isSeparatorItem ? "-" : $0.title }
}

final class Target: NSObject {
    @objc func open(_ sender: NSMenuItem) {}
}
let target = Target()
let ids = (0..<3).map { _ in UUID() }

func update(_ menu: NSMenu, claudeCode: Int = 2, browserAgent: Int = 1) {
    MistHistoryMenuChats.update(menu, sections: [
        .init(title: "Claude Code", chats: ids.prefix(claudeCode).enumerated().map { ($1, "cc\($0)") }),
        .init(title: "Browser Agents", chats: ids.prefix(browserAgent).enumerated().map { ($1, "ba\($0)") }),
    ], isChat: { $0.hasPrefix("chat") },
    isAgentFolderRow: { url, title in url.map { $0.hasPrefix("agent") } ?? title.contains("\u{2060}") },
    target: target, action: #selector(Target.open(_:)))
}

// Chromium's 12 closed and 16 visited rows: five each are left, chats skipped,
// agent folder tabs and folders skipped in Recently Closed only, and the chat
// sections follow in order, above Show Full History.
let menu = historyMenu(closed: ["c1", "chat1", "window", "agent1", "c2", "Agent tabs\u{2060} - 2 tabs", "chat2",
                                "c3", "c4", "c5", "c6", "c7"],
                       visited: ["chat3", "agent2"] + (1...14).map { "v\($0)" })
update(menu)
let expected = ["Home", "Back", "Forward",
                "-", "Recently Closed", "c1", "window", "c2", "c3", "c4",
                "-", "Recently Visited", "agent2", "v1", "v2", "v3", "v4",
                "-", "Claude Code", "cc0", "cc1",
                "-", "Browser Agents", "ba0",
                "-", "Show Full History"]
guard layout(menu) == expected else { fail("\(layout(menu))") }

// Opening again rebuilds the sections instead of adding more.
update(menu)
guard layout(menu) == expected else { fail("\(layout(menu))") }

let header = menu.items.first { $0.title == "Claude Code" }!
guard header.attributedTitle?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont == NSFont.boldSystemFont(ofSize: 11),
      header.tag == 0 else { fail("header not styled like Chromium's") }
let row = menu.items.first { $0.title == "cc1" }!
guard row.target === target, row.action == #selector(Target.open(_:)), row.representedObject as? UUID == ids[1]
else { fail("row not wired") }

// Chromium's rebuild while closed brings back all rows, which the next
// opening trims again; sections without chats, or with only chats, go away.
let rebuilt = historyMenu(closed: ["chat1", "chat2"], visited: ["v1", "chat3"])
update(rebuilt, claudeCode: 0, browserAgent: 3)
guard layout(rebuilt) == ["Home", "Back", "Forward",
                          "-", "Recently Visited", "v1",
                          "-", "Browser Agents", "ba0", "ba1", "ba2",
                          "-", "Show Full History"] else { fail("\(layout(rebuilt))") }

// Another menu the controller delegates is left alone.
let other = NSMenu()
other.addItem(item("Restore All Tabs"))
update(other)
guard layout(other) == ["Restore All Tabs"] else { fail("\(layout(other))") }

print("MistHistoryMenuChats: all checks passed")
