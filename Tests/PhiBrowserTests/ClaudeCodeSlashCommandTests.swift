import Foundation
import XCTest
#if !MIST_CLAUDE_CODE_HOSTLESS_TESTS
@testable import Phi
#endif

final class ClaudeCodeSlashCommandTests: XCTestCase {


    func testClearCommandMatchesOnlyWholeFirstTokenAndIgnoresArguments() {
        for text in ["/clear", "/reset ignored", "/new\nanything", " \t/clear "] { XCTAssertTrue(ClaudeCodeClearCommand.matches(text), text) }
        for text in ["", "/clearer", "please /clear", "/clear/path", "@News /clear", "!/clear", "/Clear"] { XCTAssertFalse(ClaudeCodeClearCommand.matches(text), text) }
    }

    private func command(_ name: String, hint: String = "", description: String = "A command") -> ClaudeCodeSlashCommand {
        .init(name: name, description: description, argumentHint: hint)
    }

    func testMatchingRanksPrefixThenSubstringThenSubsequenceAlphabetically() {
        let names = ["cart", "xct", "ct-first", "scaffold-test", "act", "CT-second", "other"]
        let matches = ClaudeCodeSlashMatcher.matches(names.map { command($0) }, query: "ct")
        XCTAssertEqual(matches.map { $0.command.name }, ["ct-first", "CT-second", "act", "xct", "cart", "scaffold-test"])
        XCTAssertEqual(matches.map(\.matchedCharacters), [[0, 1], [0, 1], [1, 2], [1, 2], [0, 3], [1, 9]])
    }

    func testNonemptyQueryAlphabetizesEveryTierAndDescriptionsFlattenWhitespace() {
        let commands = [command("compact"), command("continue"), command("Clear"), command("changes")]
        XCTAssertEqual(ClaudeCodeSlashMatcher.matches(commands, query: "c").map { $0.command.name }, ["changes", "Clear", "compact", "continue"])
        XCTAssertEqual(command("x", description: "  First\n\nsecond\t  third\r\nlast  ").displayDescription, "First second third last")
        XCTAssertEqual(command("x", description: " \n ").displayDescription, "")
    }

    func testEmptyQueryKeepsCatalogOrderAndMatchesOnlyNames() {
        let commands = [command("z"), command("a", hint: "needle", description: "needle")]
        XCTAssertEqual(ClaudeCodeSlashMatcher.matches(commands, query: "").map(\.command), commands)
        XCTAssertTrue(ClaudeCodeSlashMatcher.matches(commands, query: "needle").isEmpty)
        XCTAssertTrue(ClaudeCodeSlashMatcher.matches(commands, query: "zz").isEmpty)
    }

    func testCaseInsensitiveUnicodeMatchesUseCharacterOffsets() {
        let commands = [command("révision"), command("🛠Review")]
        let match = ClaudeCodeSlashMatcher.matches(commands, query: "RÉV")
        XCTAssertEqual(match.map(\.matchedCharacters), [[0, 1, 2]])
        XCTAssertEqual(ClaudeCodeSlashMatcher.matches(commands, query: "rvw").first?.matchedCharacters, [1, 3, 6])
    }

    func testQueryAtSlashAndWithinFirstToken() {
        XCTAssertEqual(ClaudeCodeSlashQuery.at(NSRange(location: 1, length: 0), in: "/")?.text, "")
        for caret in 1...4 {
            let query = ClaudeCodeSlashQuery.at(NSRange(location: caret, length: 0), in: "/end argument")
            XCTAssertEqual(query?.text, "end")
            XCTAssertEqual(query?.tokenRange, NSRange(location: 0, length: 4))
        }
    }

    func testQueryRejectsWhitespaceArgumentsSelectionAndInvalidCaret() {
        for (text, caret) in [("", 0), ("x/end", 5), ("hello(/end", 10), ("/end ", 5),
                              ("/end\n", 5), ("/end\targ", 8), ("/end", 0), ("/end", 5)] {
            XCTAssertNil(ClaudeCodeSlashQuery.at(NSRange(location: caret, length: 0), in: text), text)
        }
        XCTAssertNil(ClaudeCodeSlashQuery.at(NSRange(location: 1, length: 1), in: "/end"))
        XCTAssertNil(ClaudeCodeSlashQuery.at(NSRange(location: NSNotFound, length: 0), in: "/end"))
    }

    func testQueryUsesUTF16CaretOffsets() {
        XCTAssertEqual(ClaudeCodeSlashQuery.at(NSRange(location: 4, length: 0), in: "/🛠r")?.text, "🛠r")
        XCTAssertNil(ClaudeCodeSlashQuery.at(NSRange(location: 2, length: 0), in: "/🛠r"))
        XCTAssertNil(ClaudeCodeSlashQuery.at(NSRange(location: 5, length: 0), in: "/🛠r "))
    }

    func testMidMessageQueryFindsOnlyTheTokenAtTheCaret() {
        let text = "Please /review file then /end"
        for caret in 8...14 {
            let query = ClaudeCodeSlashQuery.at(NSRange(location: caret, length: 0), in: text)
            XCTAssertEqual(query?.text, "review")
            XCTAssertEqual(query?.tokenRange, NSRange(location: 7, length: 7))
            XCTAssertEqual(query?.isFirstToken, false)
        }
        XCTAssertNil(ClaudeCodeSlashQuery.at(NSRange(location: 7, length: 0), in: text))
        XCTAssertNil(ClaudeCodeSlashQuery.at(NSRange(location: 15, length: 0), in: text))
        XCTAssertEqual(ClaudeCodeSlashQuery.at(NSRange(location: text.utf16.count, length: 0), in: text)?.text, "end")
        XCTAssertEqual(ClaudeCodeSlashQuery.at(NSRange(location: 4, length: 0), in: "/end")?.isFirstToken, true)
    }

    func testMidMessageQueryUsesUTF16RangesAndWhitespaceBoundaries() {
        let text = "🛠 请\n/🛠r arg"
        let start = (text as NSString).range(of: "/").location
        XCTAssertEqual(ClaudeCodeSlashQuery.at(NSRange(location: start + 4, length: 0), in: text)?.tokenRange,
                       NSRange(location: start, length: 4))
        XCTAssertNil(ClaudeCodeSlashQuery.at(NSRange(location: start + 2, length: 0), in: text))
        XCTAssertNil(ClaudeCodeSlashQuery.at(NSRange(location: start + 5, length: 0), in: text))
    }


    func testCompletionRangeSwallowsOnlyOneSpaceAfterTheMatchedToken() throws {
        for (text, caret, expected) in [("/re file", 3, NSRange(location: 0, length: 4)),
                                        ("🛠 /re  file", 6, NSRange(location: 3, length: 4)),
                                        ("do /re\nfile", 6, NSRange(location: 3, length: 3)),
                                        ("do /re", 6, NSRange(location: 3, length: 3))] {
            let query = try XCTUnwrap(ClaudeCodeSlashQuery.at(NSRange(location: caret, length: 0), in: text))
            XCTAssertEqual(query.completionRange(in: text), expected)
        }
    }

    func testSharedTokenizerStylesKnownCommandsWithPunctuationAndNotPaths() {
        let text = "/review, (/end) \"/review!\" '/end' /usr/bin x/end /unknown /plugin:check."
        let ranges = ClaudeCodeSlashTokenizer.styledRanges(in: text, commands: ["review", "end", "usr", "plugin:check"])
        XCTAssertEqual(ranges.map { (text as NSString).substring(with: $0) }, ["/review", "/end", "/review", "/end", "/plugin:check"])
        XCTAssertEqual(ClaudeCodeSlashTokenizer.tokens(in: "🛠 /review").first?.range, NSRange(location: 3, length: 7))
        XCTAssertTrue(ClaudeCodeSlashTokenizer.styledRanges(in: text, commands: []).isEmpty)
    }





}
