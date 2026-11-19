import AppKit
import XCTest
@testable import Phi

@MainActor
final class MistSidebarBookmarksHeaderTests: XCTestCase {
    func testFlatteningKeepsDepthFirstOrderWithoutChangingTree() {
        let root = Bookmark(title: "Root", isFolder: true)
        let first = Bookmark(title: "First", url: "https://first.example")
        let folder = Bookmark(title: "Folder", isFolder: true)
        let nested = Bookmark(title: "Nested", isFolder: true)
        let second = Bookmark(title: "Second", url: "https://second.example")
        let third = Bookmark(title: "Third", url: "https://third.example")
        let fourth = Bookmark(title: "Fourth", url: "https://fourth.example")
        let last = Bookmark(title: "Last", url: "https://last.example")
        root.addChild(first)
        root.addChild(folder)
        root.addChild(last)
        folder.addChild(second)
        folder.addChild(nested)
        folder.addChild(fourth)
        nested.addChild(third)

        let flattened = MistSidebarBookmarksHeader.flattenedBookmarks(in: root)
        XCTAssertEqual(flattened.map(\.guid), [first, second, third, fourth, last].map(\.guid))
        XCTAssertFalse(flattened.contains(where: \.isFolder))
        XCTAssertEqual(root.children.map(\.guid), [first, folder, last].map(\.guid))
        XCTAssertEqual(folder.children.map(\.guid), [second, nested, fourth].map(\.guid))
        XCTAssertTrue(nested.children.first === third)
        XCTAssertTrue(first.parent === root)
        XCTAssertTrue(folder.parent === root)
        XCTAssertTrue(second.parent === folder)
        XCTAssertTrue(nested.parent === folder)
        XCTAssertTrue(third.parent === nested)
        XCTAssertTrue(fourth.parent === folder)
        XCTAssertTrue(last.parent === root)
        XCTAssertTrue(flattened[2] === third)
    }

    func testOutlineProjectionRespectsExpandedState() {
        let root = Bookmark(title: "Root", isFolder: true)
        let folder = Bookmark(title: "Folder", isFolder: true)
        root.addChild(folder)
        folder.addChild(Bookmark(title: "Example", url: "https://example.com"))
        root.addChild(Bookmark(title: "Last", url: "https://last.example"))

        XCTAssertTrue(MistSidebarBookmarksHeader.outlineItems(from: root, isExpanded: false).isEmpty)
        let items = MistSidebarBookmarksHeader.outlineItems(from: root, isExpanded: true)
        let flattened = MistSidebarBookmarksHeader.flattenedBookmarks(in: root)
        XCTAssertEqual(items.map(\.id), flattened.map(\.id))
        for (item, bookmark) in zip(items, flattened) {
            XCTAssertTrue(item as? Bookmark === bookmark)
        }
    }

    func testVisibilityForEmptyFolderPopulatedAndIncognitoRoots() {
        let root = Bookmark(title: "Root", isFolder: true)
        XCTAssertFalse(MistSidebarBookmarksHeader.shouldShow(root: root, isIncognito: false))
        let folder = Bookmark(title: "Folder", isFolder: true)
        root.addChild(folder)
        XCTAssertFalse(MistSidebarBookmarksHeader.shouldShow(root: root, isIncognito: false))
        folder.addChild(Bookmark(title: "Example", url: "https://example.com"))
        XCTAssertTrue(MistSidebarBookmarksHeader.shouldShow(root: root, isIncognito: false))
        XCTAssertFalse(MistSidebarBookmarksHeader.shouldShow(root: root, isIncognito: true))
    }
}
