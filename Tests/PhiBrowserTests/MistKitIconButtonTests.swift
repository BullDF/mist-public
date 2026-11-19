import AppKit
import XCTest
@testable import Phi

@MainActor
final class MistKitIconButtonTests: XCTestCase {
    func testToggleKeepsSelectedShadeUntilTurnedOff() throws {
        let button = MistIconButton(symbol: "bold", title: MailStrings.bold)
        button.setButtonType(.toggle)
        let shade = try XCTUnwrap(button.subviews.first { !($0 is NSImageView) })
        XCTAssertTrue(shade.isHidden)
        button.state = .on
        XCTAssertFalse(shade.isHidden)
        let expected = ThemedColor.mistSelectedFill.resolve(theme: button.themeStateProvider.currentTheme, appearance: button.currentAppearance)
        XCTAssertEqual(shade.layer?.backgroundColor, expected.cgColor)
        button.state = .off
        XCTAssertTrue(shade.isHidden)
    }

    func testIconPillSizeAndAccessibleTitle() {
        let button = MistButton(symbol: "trash", title: MailStrings.delete, size: .regular)
        XCTAssertEqual(button.intrinsicContentSize, NSSize(width: 36, height: 28))
        XCTAssertEqual(button.accessibilityLabel(), MailStrings.delete)
        XCTAssertEqual(button.title, "")
    }

    func testReusedSidebarCellRestoresDefaultTitleStyle() throws {
        let cell = MistSidebarCellView()
        cell.configure(symbol: nil, title: MailStrings.mailboxes, titleStyle: .sectionHeader)
        XCTAssertEqual(cell.textField?.font, MistTextStyle.sectionHeader.nsFont)
        cell.configure(symbol: "envelope", title: MailStrings.messages)
        XCTAssertEqual(cell.textField?.font, MistTextStyle.rowTitle.nsFont)
    }
}
