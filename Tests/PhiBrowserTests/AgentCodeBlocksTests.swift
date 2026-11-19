import Foundation
import XCTest
#if !MIST_CLAUDE_CODE_HOSTLESS_TESTS
@testable import Phi
#endif

final class AgentCodeBlocksTests: XCTestCase {
    func testClosedAndUnclosed() {
        XCTAssertEqual(AgentCodeBlocks.blocks(in: "```swift\na\n```\ntext").count, 1)
        XCTAssertTrue(AgentCodeBlocks.blocks(in: "```swift\na").isEmpty)
    }

    func testFenceRule() throws {
        let block = try XCTUnwrap(AgentCodeBlocks.blocks(in: "  ~~~~ js \nx\n  ~~~~~ ").first)
        XCTAssertEqual(block.language, "js")
        XCTAssertEqual(block.content, NSRange(location: 11, length: 2))
        XCTAssertTrue(AgentCodeBlocks.blocks(in: "````\nx\n``` ").isEmpty)
        XCTAssertTrue(AgentCodeBlocks.blocks(in: "```\nx\n~~~").isEmpty)
    }

    func testEmptyAndZeroLineBlocks() throws {
        let empty = try XCTUnwrap(AgentCodeBlocks.blocks(in: "```\n\n```").first)
        XCTAssertEqual(empty.content, NSRange(location: 4, length: 1))
        XCTAssertTrue(empty.contains(NSRange(location: 4, length: 0)))
        let zero = try XCTUnwrap(AgentCodeBlocks.blocks(in: "```\n```").first)
        XCTAssertEqual(zero.content, NSRange(location: 4, length: 0))
    }

    func testUTF16Ranges() throws {
        let text = "🙂\n```swift\n🐈 x\n```"
        let block = try XCTUnwrap(AgentCodeBlocks.blocks(in: text).first)
        XCTAssertEqual(block.opening, NSRange(location: 3, length: 8))
        XCTAssertEqual((text as NSString).substring(with: block.content), "🐈 x\n")
        XCTAssertEqual(block.closing, NSRange(location: 17, length: 3))
    }

    func testOpen() throws {
        XCTAssertNil(AgentCodeBlocks.typedBacktick(in: "hello\n```", caret: 9))
        XCTAssertNil(AgentCodeBlocks.typedBacktick(in: " ```", caret: 4))
        XCTAssertNil(AgentCodeBlocks.typedBacktick(in: "x```", caret: 4))
    }

    func testModifiedEnterOpensFence() throws {
        for line in ["```", "```python", "````swift"] {
            let caret = (line as NSString).length
            let edit = try XCTUnwrap(AgentCodeBlocks.openFence(in: line, caret: caret))
            XCTAssertEqual(edit.applying(to: line), line + "\n\n" + String(repeating: "`", count: line.prefix { $0 == "`" }.count))
            XCTAssertEqual(edit.caret, caret + 1)
        }
    }

    func testModifiedEnterRejectsInvalidFence() {
        for (text, caret) in [("```python", 4), (" ```", 4), ("```py`thon", 10), ("```\n```python\n```", 13)] {
            XCTAssertNil(AgentCodeBlocks.openFence(in: text, caret: caret))
        }
    }

    func testEditingFenceDoesNotOpenBlock() throws {
        let text = "```\nplain\n```\nx\n```"
        let normal = AgentCodeBlocks.blocks(in: text)
        XCTAssertEqual(normal.first?.opening.location, 0)
        let editing = AgentCodeBlocks.blocks(in: text, editingAt: 3)
        XCTAssertEqual(editing.count, 1)
        XCTAssertEqual(editing.first?.opening.location, 10)
        XCTAssertEqual(AgentCodeBlocks.blocks(in: text, editingAt: 12), normal)
        XCTAssertEqual(AgentCodeBlocks.blocks(in: text, editingAt: 5), normal)
    }

    func testLanguageRange() throws {
        let text = "🙂\n  ```swift  \nx\n```"
        let block = try XCTUnwrap(AgentCodeBlocks.blocks(in: text).first)
        XCTAssertEqual((text as NSString).substring(with: try XCTUnwrap(block.languageRange)), "swift")
        XCTAssertNil(AgentCodeBlocks.blocks(in: "```\nx\n```").first?.languageRange)
    }

    private func split(_ content: String, expected: String, caret: Int) throws {
        let text = "```swift\n" + content + "\n```"
        let typed = (text as NSString).range(of: "```\n")
        let edit = try XCTUnwrap(AgentCodeBlocks.typedBacktick(in: text, caret: NSMaxRange(typed) - 1))
        XCTAssertEqual(edit.applying(to: text), expected)
        XCTAssertEqual(edit.caret, caret)
    }

    func testSplitLastLine() throws { try split("a\n```", expected: "```swift\na\n```\n", caret: 15) }
    func testSplitFirstLine() throws { try split("```\nb", expected: "\n```swift\nb\n```", caret: 0) }
    func testSplitMiddleLine() throws { try split("a\n```\nb", expected: "```swift\na\n```\n\n```swift\nb\n```", caret: 15) }
    func testSplitOnlyLine() throws { try split("```", expected: "", caret: 0) }

    func testUnwrap() throws {
        let text = "before\n```swift\na\nb\n```\nafter"
        let edit = try XCTUnwrap(AgentCodeBlocks.backwardDelete(in: text, caret: 16))
        XCTAssertEqual(edit.applying(to: text), "before\na\nb\nafter")
        XCTAssertEqual(edit.caret, 7)
    }

    func testUnwrapEmpty() throws {
        for text in ["```\n\n```", "```\n```"] {
            let edit = try XCTUnwrap(AgentCodeBlocks.backwardDelete(in: text, caret: 4))
            XCTAssertEqual(edit.applying(to: text), "")
            XCTAssertEqual(edit.caret, 0)
        }
    }

    func testBackwardJoin() throws {
        let text = "```swift\na\n```\nb\nnext"
        let edit = try XCTUnwrap(AgentCodeBlocks.backwardDelete(in: text, caret: 15))
        XCTAssertEqual(edit.applying(to: text), "```swift\nab\n```\nnext")
        XCTAssertEqual(edit.caret, 10)
    }

    func testForwardJoinAndBoundaryNoOps() throws {
        let text = "```\na\n```\nb"
        let edit = try XCTUnwrap(AgentCodeBlocks.forwardDelete(in: text, caret: 5))
        XCTAssertEqual(edit.applying(to: text), "```\nab\n```")
        XCTAssertEqual(edit.caret, 5)
        let end = "```\na\n```"
        XCTAssertEqual(AgentCodeBlocks.forwardDelete(in: end, caret: 5)?.applying(to: end), end)
        let before = "x\n```\na\n```"
        XCTAssertEqual(AgentCodeBlocks.forwardDelete(in: before, caret: 1)?.applying(to: before), before)
    }

    func testJoinEmptyLine() throws {
        let text = "```\n\n```\n"
        let edit = try XCTUnwrap(AgentCodeBlocks.backwardDelete(in: text, caret: 9))
        XCTAssertEqual(edit.applying(to: text), "```\n\n```")
        XCTAssertEqual(edit.caret, 4)
    }

    func testExitsInsertOnlyAtTextEdges() throws {
        let text = "```\nx\n```"
        let block = try XCTUnwrap(AgentCodeBlocks.blocks(in: text).first)
        let down = AgentCodeBlocks.exit(block, down: true, in: text)
        XCTAssertEqual(down.applying(to: text), text + "\n")
        XCTAssertEqual(down.caret, 10)
        let up = AgentCodeBlocks.exit(block, down: false, in: text)
        XCTAssertEqual(up.applying(to: text), "\n" + text)
        XCTAssertEqual(up.caret, 0)
        let surrounded = "a\n" + text + "\nb"
        let middle = try XCTUnwrap(AgentCodeBlocks.blocks(in: surrounded).first)
        XCTAssertEqual(AgentCodeBlocks.exit(middle, down: false, in: surrounded).caret, 1)
        XCTAssertEqual(AgentCodeBlocks.exit(middle, down: true, in: surrounded).caret, 12)
        XCTAssertEqual(AgentCodeBlocks.exit(middle, down: true, in: surrounded).replacement, "")
    }

    func testClampFenceCaretsAndSelectionEndpoints() {
        let text = "a\n```\nx\n```\nb"
        func clamp(_ target: Int, from: Int) -> Int {
            AgentCodeBlocks.clamp(NSRange(location: target, length: 0), from: NSRange(location: from, length: 0), in: text).location
        }
        XCTAssertEqual(clamp(3, from: 1), 6)
        XCTAssertEqual(clamp(3, from: 6), 1)
        XCTAssertEqual(clamp(9, from: 7), 12)
        XCTAssertEqual(clamp(9, from: 12), 7)
        XCTAssertEqual(AgentCodeBlocks.clamp(NSRange(location: 3, length: 6), from: .init(location: 0, length: 0), in: text), NSRange(location: 2, length: 9))
    }

    func testTitleSkipsFences() {
        XCTAssertEqual(AgentCodeBlocks.firstTitleLine(in: "```swift\nprint(1)\n```"), "print(1)")
        XCTAssertEqual(AgentCodeBlocks.firstTitleLine(in: "~~~\n~~~\nTitle"), "Title")
        XCTAssertNil(AgentCodeBlocks.firstTitleLine(in: "```\n```"))
    }

    @MainActor
    func testChatAndConversationTitlesSkipFences() {
        let prompt = "```swift\nprint(1)\n```"
        XCTAssertEqual(AgentChatRoute.title(for: prompt), "print(1)")
        XCTAssertEqual(AgentConversation(firstPrompt: prompt).title, "print(1)")
        XCTAssertEqual(AgentChatRoute.title(for: "~~~\n~~~\nA title"), "A title")
        XCTAssertEqual(AgentConversation(firstPrompt: "~~~\n~~~\nA title").title, "A title")
    }
}
