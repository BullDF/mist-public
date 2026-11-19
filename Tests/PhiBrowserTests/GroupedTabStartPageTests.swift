import XCTest
@testable import Phi

final class GroupedTabStartPageTests: XCTestCase {
    private let firstURL = "https://example.com"
    private let secondURL = "https://example.com/next"

    func testJoiningWithRealURLUsesThatPage() {
        var page = GroupedTabStartPage()
        join(&page, at: firstURL)
        page.pageChanged(to: secondURL)
        XCTAssertEqual(page.url, firstURL)
    }

    func testJoiningWithoutRealURLUsesFirstRealPage() {
        for placeholder in [nil, "", "about:blank", "about:blank#section", "chrome://newtab/", "phi://newtab"] {
            var page = GroupedTabStartPage()
            join(&page, at: placeholder)
            XCTAssertTrue(page.isEligible)
            XCTAssertNil(page.url)
            page.pageChanged(to: "chrome://newtab/")
            XCTAssertNil(page.url)
            page.pageChanged(to: firstURL)
            page.pageChanged(to: secondURL)
            XCTAssertEqual(page.url, firstURL)
        }
    }

    func testExcludedTabsAndAgentFoldersDoNotCapturePages() {
        for kind in [GroupedTabStartPage.TabKind.pinned, .bookmarkBacked, .app] {
            var page = GroupedTabStartPage()
            join(&page, at: firstURL, kind: kind)
            page.pageChanged(to: secondURL)
            XCTAssertFalse(page.isEligible)
            XCTAssertNil(page.url)
        }

        var page = GroupedTabStartPage()
        join(&page, title: "Agent Tabs" + BrowserAgentFolderState.titleMarker, at: firstURL)
        page.pageChanged(to: secondURL)
        XCTAssertFalse(page.isEligible)
        XCTAssertNil(page.url)
    }

    func testLeavingClearsAndMovingUsesTheCurrentPage() {
        var page = GroupedTabStartPage()
        join(&page, at: firstURL)
        join(&page, at: secondURL) // The confirmed join can follow an optimistic update.
        XCTAssertEqual(page.url, firstURL)
        join(&page, token: "second", at: secondURL)
        XCTAssertEqual(page.url, secondURL)
        page.updateMembership(token: nil, title: nil, kind: .regular, currentURL: secondURL)
        page.pageChanged(to: firstURL)
        XCTAssertFalse(page.isEligible)
        XCTAssertNil(page.url)
    }

    func testLateGroupMetadataPreservesTheJoinPage() {
        var page = GroupedTabStartPage()
        join(&page, title: nil, at: firstURL)
        XCTAssertNil(page.url)
        page.pageChanged(to: secondURL)
        join(&page, at: secondURL)
        XCTAssertEqual(page.url, firstURL)

        join(&page, title: "Agent Tabs" + BrowserAgentFolderState.titleMarker, at: secondURL)
        XCTAssertNil(page.url)
    }

    func testDriftUsesOriginEquivalenceAndCanSetARealPage() {
        var page = GroupedTabStartPage()
        join(&page, at: firstURL)
        XCTAssertFalse(page.hasDrifted(from: nil))
        XCTAssertFalse(page.hasDrifted(from: "https://www.example.com/"))
        XCTAssertFalse(page.canSetCurrentPage("https://www.example.com/"))
        XCTAssertTrue(page.hasDrifted(from: "https://example.com/?query=1"))
        XCTAssertTrue(page.hasDrifted(from: secondURL))
        XCTAssertFalse(page.canSetCurrentPage("about:blank"))
        page.setCurrentPage(secondURL)
        XCTAssertEqual(page.url, secondURL)
        XCTAssertFalse(page.hasDrifted(from: secondURL))
    }

    private func join(_ page: inout GroupedTabStartPage, token: String = "first", title: String? = "",
                      at url: String?, kind: GroupedTabStartPage.TabKind = .regular) {
        page.updateMembership(token: token, title: title, kind: kind, currentURL: url)
    }
}
