import XCTest
@testable import Phi

@MainActor
final class SideAddressBarTests: XCTestCase {
    func testSidebarDoesNotDisplayPinnedExtensionsAtAnyWidth() {
        XCTAssertFalse(SideAddressBar.shouldDisplayPinnedExtensionsWithinSidebar(
            pinnedExtensionCount: 3, containerWidth: 220))
        XCTAssertFalse(SideAddressBar.shouldDisplayPinnedExtensionsWithinSidebar(
            pinnedExtensionCount: 2, containerWidth: 193))
        XCTAssertFalse(SideAddressBar.shouldDisplayPinnedExtensionsWithinSidebar(
            pinnedExtensionCount: 3, containerWidth: 193))
        XCTAssertFalse(SideAddressBar.shouldDisplayPinnedExtensionsWithinSidebar(
            pinnedExtensionCount: 3, containerWidth: 300))
    }

    func testSidebarDoesNotDisplayPinnedExtensionsAtFormerPlacementBoundary() {
        XCTAssertFalse(SideAddressBar.shouldDisplayPinnedExtensionsWithinSidebar(
            pinnedExtensionCount: 3, containerWidth: 213))
        XCTAssertFalse(SideAddressBar.shouldDisplayPinnedExtensionsWithinSidebar(
            pinnedExtensionCount: 3, containerWidth: 214))
    }

    func testSidebarDoesNotReservePinnedExtensionShelfWhenNoneArePinned() {
        XCTAssertFalse(SideAddressBar.shouldDisplayPinnedExtensionsWithinSidebar(
            pinnedExtensionCount: 0, containerWidth: 0))
    }

}
