import AppKit

func menu(_ entries: [String]) -> NSMenu {
    let menu = NSMenu()
    for entry in entries {
        menu.addItem(entry == "-" ? .separator() : NSMenuItem(title: entry, action: nil, keyEquivalent: ""))
    }
    return menu
}

func layout(_ menu: NSMenu) -> [String] {
    menu.items.map { $0.isSeparatorItem ? "-" : $0.title }
}

func check(_ entries: [String], _ expected: [String], line: Int = #line) {
    let subject = menu(entries)
    MistRemovedMenuItems.strip(subject, titles: ["Open in Kiosk"])
    guard layout(subject) == expected else {
        print("FAIL line \(line): \(layout(subject)) != \(expected)")
        exit(1)
    }
}

// The link menu as the framework builds it.
check(["New Tab", "New Window", "Open in Kiosk", "Split View", "-", "Save Link As…"],
      ["New Tab", "New Window", "Split View", "-", "Save Link As…"])
// Separators a removal leaves leading, doubled or trailing.
check(["Open in Kiosk", "-", "Copy"], ["Copy"])
check(["Copy", "-", "Open in Kiosk", "-", "Inspect"], ["Copy", "-", "Inspect"])
check(["Copy", "-", "Open in Kiosk"], ["Copy"])
// A menu without the item stays untouched, separators included.
check(["-", "Copy", "-", "-"], ["-", "Copy", "-", "-"])

let parent = menu(["Open Link", "Share"])
parent.items[1].submenu = menu(["Mail", "-", "Open in Kiosk"])
MistRemovedMenuItems.strip(parent, titles: ["Open in Kiosk"])
guard let submenu = parent.items[1].submenu, layout(submenu) == ["Mail"] else {
    print("FAIL: submenu not stripped")
    exit(1)
}
print("MistRemovedMenuItems: all checks passed")
