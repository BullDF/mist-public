import AppKit
import XCTest
@testable import Phi

@MainActor
final class ThemeResolutionStateTests: XCTestCase {
    private var originalState: ThemeResolutionState?
    private var originalAppearanceChoice: UserAppearanceChoice?

    override func setUp() async throws {
        try await super.setUp()
        originalState = ThemeManager.resolutionState
        originalAppearanceChoice = ThemeManager.shared.userAppearanceChoice
    }

    override func tearDown() async throws {
        let manager = ThemeManager.shared
        if let originalState { manager.currentTheme = originalState.theme }
        if let originalAppearanceChoice { manager.setUserAppearanceChoice(originalAppearanceChoice) }
        originalState = nil
        originalAppearanceChoice = nil
        try await super.tearDown()
    }

    func testMainThreadReadsLiveState() {
        let manager = ThemeManager.shared
        let state = ThemeManager.resolutionState

        XCTAssertTrue(state.theme === manager.currentTheme)
        XCTAssertEqual(state.appearance, manager.currentAppearance)
    }

    func testBackgroundResolutionFollowsThemeChanges() throws {
        let manager = ThemeManager.shared
        let theme = try XCTUnwrap(manager.orderedThemes.first { $0 !== manager.currentTheme })
        manager.currentTheme = theme
        let expectedState = ThemeManager.resolutionState
        let expectedColor = ThemedColor.textPrimary.resolved()
        let resolved = expectation(description: "Background theme and color resolution")

        DispatchQueue.global().async {
            XCTAssertFalse(Thread.isMainThread)
            let state = ThemeManager.resolutionState
            XCTAssertTrue(state.theme === expectedState.theme)
            XCTAssertEqual(state.appearance, expectedState.appearance)
            XCTAssertEqual(ThemedColor.textPrimary.resolved(), expectedColor)
            XCTAssertEqual(ThemedColor.textPrimary.resolve(in: nil as NSView?), expectedColor)
            resolved.fulfill()
        }
        wait(for: [resolved], timeout: 5)
    }

    func testBackgroundResolutionFollowsAppearanceChanges() {
        let manager = ThemeManager.shared
        for (choice, appearance) in [(UserAppearanceChoice.dark, Appearance.dark), (.light, .light), (.dark, .dark), (.system, nil)] {
            manager.setUserAppearanceChoice(choice)
            let expectedState = ThemeManager.resolutionState
            XCTAssertEqual(expectedState.appearance, appearance ?? NSApp.effectiveAppearance.phiAppearance)
            let resolved = expectation(description: "Background appearance follows \(choice)")
            DispatchQueue.global().async {
                XCTAssertFalse(Thread.isMainThread)
                XCTAssertEqual(ThemeManager.resolutionState.appearance, expectedState.appearance)
                resolved.fulfill()
            }
            wait(for: [resolved], timeout: 5)
        }
    }
}
