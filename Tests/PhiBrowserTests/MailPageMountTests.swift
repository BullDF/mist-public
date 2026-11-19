import AppKit
import MistMailCore
import XCTest
@testable import Phi

@MainActor
final class MailPageMountTests: XCTestCase {
    func testRouteMountsFixturePageAndKeepsTabsIndependent() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LocalStore(account: Account(userID: UUID().uuidString), storeDirectoryURL: directory)
        let state = BrowserState(windowId: 12001, localStore: store, profileId: "Default")
        let source = FixtureMailPageDataSource()
        let firstTab = Tab(guid: 12001, url: MistAppRoute.current.url(.mail).absoluteString, isActive: true, index: 0, webContentView: nil)
        let secondTab = Tab(guid: 12002, url: MistAppRoute.current.url(.mail).absoluteString, isActive: false, index: 1, webContentView: nil)
        let defaults = makeTestDefaults().defaults
        let first = WebContentViewController(state: state, tab: firstTab, appPageFactory: { _ in MailPageViewController(source: source, defaults: defaults) })
        let second = WebContentViewController(state: state, tab: secondTab, appPageFactory: { _ in MailPageViewController(source: source, defaults: defaults) })
        XCTAssertTrue(first.shouldShowApp(for: firstTab))
        XCTAssertTrue(first.splitPaneContentView() === first.appPageController?.view)
        XCTAssertTrue(second.splitPaneContentView() === second.appPageController?.view)
        XCTAssertNotNil(first.appPageController)
        XCTAssertFalse(first.appPageController === second.appPageController)
        XCTAssertTrue(first.appPageController?.view is AgentChatBackgroundView)
        XCTAssertEqual((first.appPageController as? MailPageViewController)?.split.arrangedSubviews.count, 3)
        XCTAssertTrue((first.appPageController as? MailPageViewController)?.split.arrangedSubviews.first is MistSidebarView)
        XCTAssertTrue(Tab.supportsAIChat(urlString: firstTab.url))
    }
    func testIncognitoDoesNotMountMail() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LocalStore(account: Account(userID: UUID().uuidString), storeDirectoryURL: directory)
        let state = BrowserState(windowId: 12003, localStore: store, profileId: "Default", isIncognito: true)
        let tab = Tab(guid: 12003, url: MistAppRoute.current.url(.mail).absoluteString, isActive: true, index: 0, webContentView: nil)
        let defaults = makeTestDefaults().defaults
        let controller = WebContentViewController(state: state, tab: tab, appPageFactory: { _ in MailPageViewController(source: FixtureMailPageDataSource(), defaults: defaults) })
        XCTAssertFalse(controller.shouldShowApp(for: tab))
        XCTAssertNil(controller.splitPaneContentView())
        XCTAssertNil(controller.appPageController)
    }
    func testComposeKeepsTheThreeExistingSplitPanes() async throws {
        let source = FixtureMailPageDataSource(), controller = MailPageViewController(source: source, defaults: makeTestDefaults().defaults)
        _ = controller.view
        await controller.model.reloadState()
        let panes = controller.split.arrangedSubviews
        await controller.model.newMessage(); controller.updateReaderSelection()
        XCTAssertEqual(controller.split.arrangedSubviews.count, 3)
        XCTAssertTrue(zip(panes, controller.split.arrangedSubviews).allSatisfy { $0 === $1 })
        XCTAssertTrue(controller.readerContainer.subviews.contains { $0 is AgentChatBackgroundView && !$0.isHidden })
        await controller.model.closeCompose(); controller.updateReaderSelection()
        XCTAssertEqual(controller.split.arrangedSubviews.count, 3)
    }
}
