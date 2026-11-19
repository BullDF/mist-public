import AppKit

// One point per character keeps the expected elisions readable.
func width(_ text: String) -> CGFloat { CGFloat(text.count) }

func check(_ actual: String, _ expected: String, line: Int = #line) {
    guard actual == expected else {
        print("FAIL line \(line): \"\(actual)\" != \"\(expected)\"")
        exit(1)
    }
}

func title(_ active: String, others: Int, maxWidth: CGFloat = 400) -> String {
    TabWindowMoveMenu.windowTitle(activeTabTitle: active, otherTabCount: others,
                                  maxWidth: maxWidth, measure: width)
}

// A window with only its active tab shows the plain title.
check(title("Google", others: 0), "Google")
check(title("Google", others: 1), "Google and 1 other tab")
check(title("Google", others: 3), "Google and 3 other tabs")
check(title("", others: 2), " and 2 other tabs")

// The title gives way to the suffix: " and 2 other tabs" is 17 wide, leaving 13.
check(title("Starting a background bash job", others: 2, maxWidth: 30),
      "Starting a b… and 2 other tabs")
// Whitespace before the cut is dropped: "Starting a " trims to "Starting a".
check(title("Starting a background bash job", others: 0, maxWidth: 12), "Starting a…")
// A title that fits exactly stays whole.
check(title("Exactly13Wide", others: 2, maxWidth: 30), "Exactly13Wide and 2 other tabs")
// However long the suffix, the title keeps four characters' width.
check(title("Starting a background", others: 2, maxWidth: 10), "Sta… and 2 other tabs")

check(TabWindowMoveMenu.elide("é👍🏽abc", toWidth: 3, measure: width), "é👍🏽…")
check(TabWindowMoveMenu.elide("x", toWidth: 0, measure: width), "…")

// The menu font path: a short title stays whole, a long one is cut.
check(TabWindowMoveMenu.windowTitle(activeTabTitle: "Google", otherTabCount: 2),
      "Google and 2 other tabs")
let long = String(repeating: "Starting a background bash job that sleeps ", count: 4)
let cut = TabWindowMoveMenu.windowTitle(activeTabTitle: long, otherTabCount: 2)
guard cut.hasSuffix("… and 2 other tabs"), cut.count < long.count else {
    print("FAIL: menu-font title not elided: \(cut)")
    exit(1)
}
print("TabWindowMoveMenu: all checks passed")
