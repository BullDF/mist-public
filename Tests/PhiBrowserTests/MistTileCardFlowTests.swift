import XCTest
@testable import Phi

final class MistTileCardFlowTests: XCTestCase {
    private let lineHeight: CGFloat = 16
    private let baseline: CGFloat = 12.2
    private let capHeight: CGFloat = 8.8
    private let lineSpacing: CGFloat = 5
    private let fullWidth: CGFloat = 320
    private let narrowWidth: CGFloat = 150
    private let trailing = CGRect(x: 160, y: 0, width: 160, height: 28)

    func testParagraphsFlowBesideAndThenUnderTrailingControl() {
        let tokens = [token(width: 100, paragraph: 0)]
            + Array(repeating: token(width: 25, paragraph: 1), count: 30)
        let result = MistTileCardFlow.layout(tokens, fullWidth: fullWidth, narrowWidth: narrowWidth,
                                             trailing: trailing, capHeight: capHeight, top: capHeight - baseline,
                                             lineSpacing: lineSpacing) { _, _ in
            XCTFail("Short tokens should keep their intrinsic size")
            return self.metrics(width: 0)
        }
        let beside = result.lines.prefix { $0.frame.minY + $0.firstBaseline - capHeight < trailing.maxY + lineSpacing }
        XCTAssertEqual(beside.count, 2)
        XCTAssertTrue(beside.allSatisfy { $0.frame.width <= narrowWidth })
        XCTAssertEqual(result.lines.dropFirst(beside.count).first?.frame.width, 300)
        let tops = result.lines.map(\.frame.minY)
        guard tops.count >= 3 else { return XCTFail("Expected at least three lines") }
        XCTAssertEqual(tops[1] - tops[0], lineHeight + lineSpacing, accuracy: 0.001)
        for index in 2..<tops.count {
            XCTAssertEqual(tops[index] - tops[index - 1], lineHeight, accuracy: 0.001)
        }
    }

    func testOverlongTokenUsesItsOwnLineAndMeasuredHeight() {
        let tokens = [token(width: 400, paragraph: 0), token(width: 20, paragraph: 0)]
        let top = trailing.maxY + lineSpacing
        let result = MistTileCardFlow.layout(tokens, fullWidth: fullWidth, narrowWidth: narrowWidth,
                                             trailing: trailing, capHeight: capHeight, top: top,
                                             lineSpacing: lineSpacing) { index, width in
            XCTAssertEqual(index, 0)
            XCTAssertEqual(width, self.fullWidth)
            return .init(size: CGSize(width: width, height: self.lineHeight * 2),
                         firstBaseline: self.baseline, lastBaseline: self.baseline + self.lineHeight)
        }
        XCTAssertEqual(result.lines.count, 2)
        XCTAssertEqual(result.placements.first?.proposedWidth, fullWidth)
        XCTAssertEqual(result.placements.last?.frame.origin, CGPoint(x: 0, y: top + lineHeight * 2))
    }

    func testLongWordBreaksBetweenCharactersAndTheNextWordFollowsIt() {
        let longWord = (0..<40).map { token(width: 10, paragraph: 1, glued: $0 > 0) }
        let tokens = [token(width: 100, paragraph: 0), token(width: 40, paragraph: 1)] + longWord + [token(width: 30, paragraph: 1)]
        let result = MistTileCardFlow.layout(tokens, fullWidth: fullWidth, narrowWidth: narrowWidth,
                                             trailing: trailing, capHeight: capHeight, top: capHeight - baseline,
                                             lineSpacing: lineSpacing) { _, _ in
            XCTFail("A long word's characters keep their intrinsic size")
            return self.metrics(width: 0)
        }
        XCTAssertEqual(result.lines.map(\.frame.width), [100, 40, 320, 110],
                       "The long word starts a full-width line under the control and the next word follows its last character")
        XCTAssertEqual(result.placements.count, tokens.count)
        XCTAssertEqual(result.placements.last?.frame.minX, 80)
        XCTAssertEqual(result.placements.last?.frame.minY ?? 0, result.lines.last?.frame.minY ?? -1, accuracy: 0.001)
    }

    private func token(width: CGFloat, paragraph: Int, glued: Bool = false) -> MistTileCardFlow.Token {
        .init(paragraph: paragraph, glued: glued, metrics: metrics(width: width))
    }

    private func metrics(width: CGFloat) -> MistTileCardFlow.Metrics {
        .init(size: CGSize(width: width, height: lineHeight), firstBaseline: baseline, lastBaseline: baseline)
    }
}
