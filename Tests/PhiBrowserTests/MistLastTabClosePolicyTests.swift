import XCTest
#if !MIST_LAST_TAB_CLOSE_HOSTLESS_TESTS
@testable import Phi
#endif

final class MistLastTabClosePolicyTests: XCTestCase {
    func testLastNormalPageIsReplaced() {
        XCTAssertEqual(decision(closing: [1], tabs: [(1, false)]), .replaceWithNewTab)
    }

    func testLastNormalHomePageClosesWindow() {
        XCTAssertEqual(decision(closing: [1], tabs: [(1, true)]), .closeWindow)
    }

    func testRemainingNormalTabProceeds() {
        XCTAssertEqual(decision(closing: [1], tabs: [(1, false), (2, true)]), .proceed)
    }

    func testInactiveCloseProceeds() {
        XCTAssertEqual(decision(closing: [1], tabs: [(1, false)], active: 9), .proceed)
        XCTAssertEqual(decision(closing: [1], tabs: [(1, true)], active: nil), .proceed)
    }

    func testIneligibleWindowProceeds() {
        for isNTP in [false, true] {
            XCTAssertEqual(decision(closing: [1], tabs: [(1, isNTP)], eligible: false), .proceed)
        }
    }

    func testMultiCloseWithPageIsReplaced() {
        XCTAssertEqual(decision(closing: [1, 2], tabs: [(1, true), (2, false)]), .replaceWithNewTab)
    }

    func testMultiCloseWithOnlyHomePagesClosesWindow() {
        XCTAssertEqual(decision(closing: [1, 2], tabs: [(1, true), (2, true)]), .closeWindow)
    }

    func testPinnedTabsDoNotCount() {
        // Pinned id 9 is deliberately absent from the normal-tab projection,
        // whether it has a live wrapper or only a persisted pinned record.
        for closingIds: Set<Int> in [[1], [1, 9]] {
            XCTAssertEqual(decision(closing: closingIds, tabs: [(1, false)]), .replaceWithNewTab)
            XCTAssertEqual(decision(closing: closingIds, tabs: [(1, true)]), .closeWindow)
        }
        XCTAssertEqual(decision(closing: [9], tabs: [(1, false)], active: 9), .proceed)
        XCTAssertEqual(decision(closing: [9], tabs: [], active: 9), .proceed)
    }

    func testEmptyCloseSetProceeds() {
        XCTAssertEqual(decision(closing: [], tabs: [(1, false)]), .proceed)
    }

    func testHomePagePrefixesMatchTabSemantics() {
        for url in ["chrome://newtab", "chrome://newtab/", "chrome://newtab?x=1", "phi://newtab", "phi://newtab/#x"] {
            XCTAssertTrue(MistLastTabClosePolicy.isNewTabURL(url), url)
        }
        for url: String? in [nil, "", "about:blank", "https://example.com", "https://example.com/chrome://newtab"] {
            XCTAssertFalse(MistLastTabClosePolicy.isNewTabURL(url), url ?? "nil")
        }
    }

    private func decision(closing ids: Set<Int>,
                          tabs: [(id: Int, isNTP: Bool)],
                          active: Int? = 1,
                          eligible: Bool = true) -> MistLastTabClosePolicy.Decision {
        MistLastTabClosePolicy.decision(closingTabIds: ids,
                                        normalTabs: tabs,
                                        activeTabId: active,
                                        isEligible: eligible)
    }
}
