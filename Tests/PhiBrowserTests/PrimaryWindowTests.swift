import XCTest
@testable import Phi

final class PrimaryWindowTests: XCTestCase {
    func testPrimarySelection() {
        let cases: [(Int?, Int?, [Bool], [Int], Int?)] = [
            (nil, nil, [false, true], [0, 0], 1),
            (0, nil, [true, true], [0, 10], 0),
            (0, 1, [true, true], [10, 0], 1),
            (0, 1, [true, false], [0, 10], 0),
            (0, nil, [false, true, true], [10, 2, 3], 2),
            (nil, nil, [true, true], [3, 3], 0),
            (nil, nil, [false, false], [0, 0], nil),
        ]
        for (current, restored, eligible, ordinals, expected) in cases {
            XCTAssertEqual(SpaceManager.resolvedPrimaryPosition(current: current, restored: restored,
                eligible: eligible, keyOrdinals: ordinals), expected)
        }
    }

    func testExternalLandingSpace() {
        let cases: [(String?, String?, [String], String?)] = [
            ("a", "b", ["a", "b"], "a"),
            ("agent", "b", ["a", "b"], "b"),
            ("incognito", "b", ["a", "b"], "b"),
            ("agent", "gone", ["a", "b"], "a"),
            (nil, nil, [], nil),
        ]
        for (visible, regular, hosted, expected) in cases {
            XCTAssertEqual(SpaceManager.externalOpenLandingSpaceId(visibleSpaceId: visible,
                lastRegularSpaceId: regular, hostedUserSpaceIds: hosted), expected)
        }
    }
}
