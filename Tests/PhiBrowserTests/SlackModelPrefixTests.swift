import Foundation
import XCTest
#if !MIST_CLAUDE_CODE_HOSTLESS_TESTS
@testable import Phi
#endif

/// The picker's list as `DrifterModel.merged` builds it from both catalogs' replies.
enum SlackModelCatalogFixture {
    static let claude: [String: ClaudeCodeModelInfo] = [
        "opus": .init(resolvedModel: "claude-opus-5-5", displayName: "Opus 5.5"),
        "fable": .init(resolvedModel: "claude-fable-5-1", displayName: "Fable 5.1"),
        "sonnet": .init(resolvedModel: "claude-sonnet-5-5", displayName: "Sonnet 5.5"),
        "haiku": .init(resolvedModel: "claude-haiku-5-5", displayName: "Haiku 5.5"),
    ]
    static let codex: [CodexModelInfo] = [
        info("gpt-6.1-sol", "GPT-6.1-Sol", ultra: true, default: "low"),
        info("gpt-6-astra", "GPT-6-Astra", ultra: true, default: "medium"),
        info("gpt-6.1-terra", "GPT-6.1 Terra", ultra: true, default: "low"),
        info("gpt-6-luna", "GPT-6-Luna", ultra: false, default: "medium"),
        info("gpt-6-sol", "GPT-6-Sol", ultra: true, default: "medium"),
    ]
    static let models = DrifterModel.merged(claude: claude, codex: codex)
    static let claudeOnly = DrifterModel.merged(claude: claude, codex: [])

    private static func info(_ id: String, _ name: String, ultra: Bool, default effort: String) -> CodexModelInfo {
        .init(id: id, displayName: name, efforts: ["low", "medium", "high", "xhigh", "max"] + (ultra ? ["ultra"] : []),
              defaultEffort: effort, inputModalities: ["text"], isDefault: false)
    }
}

final class SlackModelPrefixTests: XCTestCase {
    private func parse(_ text: String, _ models: [DrifterModel] = SlackModelCatalogFixture.models) -> SlackModelPrefix? {
        SlackModelPrefix.parse(text, models: models)
    }

    private func XCTAssertPrefix(_ text: String, _ engine: DrifterEngine, _ model: String, _ effort: String, _ rest: String,
                                 file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(parse(text), .init(engine: engine, model: model, effort: effort, rest: rest), file: file, line: line)
    }

    func testFullNames() {
        XCTAssertPrefix("fable 5.1 medium catch me up on #standup", .claude, "fable", "medium", "catch me up on #standup")
        XCTAssertPrefix("Opus 5.5 HIGH do it", .claude, "opus", "high", "do it")
        XCTAssertPrefix("gpt 6.1 terra low hi", .codex, "gpt-6.1-terra", "low", "hi")
        XCTAssertPrefix("GPT-6.1 Terra xhigh hi", .codex, "gpt-6.1-terra", "xhigh", "hi")
        XCTAssertPrefix("gpt-6.1-sol max\nline two", .codex, "gpt-6.1-sol", "max", "line two")
        XCTAssertPrefix("gpt 6 astra ultra go", .codex, "gpt-6-astra", "ultra", "go")
    }

    func testBareAliases() {
        XCTAssertPrefix("sonnet low reply with one word: ok", .claude, "sonnet", "low", "reply with one word: ok")
        XCTAssertPrefix("haiku hi", .claude, "haiku", "medium", "hi")
        XCTAssertPrefix("Sol what's new", .codex, "gpt-6.1-sol", "medium", "what's new")
        XCTAssertPrefix("terra ultra go", .codex, "gpt-6.1-terra", "ultra", "go")
        XCTAssertPrefix("opus, high: do it", .claude, "opus", "high", "do it")
        XCTAssertPrefix("Sonnet 18 is my favorite poem", .claude, "sonnet", "medium", "18 is my favorite poem")
    }

    func testEffortTheModelLacksStaysInTheText() {
        XCTAssertPrefix("opus ultra plan", .claude, "opus", "medium", "ultra plan")
        XCTAssertPrefix("luna ultra plan", .codex, "gpt-6-luna", "medium", "ultra plan")
        XCTAssertPrefix("fable 4.0 hi", .claude, "fable", "medium", "4.0 hi")
    }

    func testPrefixOnly() {
        XCTAssertPrefix("fable", .claude, "fable", "medium", "")
        XCTAssertPrefix("  Terra Low  ", .codex, "gpt-6.1-terra", "low", "")
    }

    func testNoPrefix() {
        for text in ["reply with one word: ok", "gpt is great", "high opus", "solar panels", "sol-searching", "fable5.1 hi",
                     "an opus", "6.1 terra", "gpt-6-sol hi", ""] {
            XCTAssertNil(parse(text), text)
        }
        XCTAssertNil(parse("terra low hi", SlackModelCatalogFixture.claudeOnly))
    }

    func testMentionComesFirstAndIsIgnored() {
        let router = SlackEventRouter(owner: "U1", botUserID: "B1", teamID: nil)
        let event: [String: Any] = ["type": "app_mention", "user": "U1", "channel": "C1", "ts": "1.0",
                                    "text": "<@B1> fable 5.1 medium catch me up on <#C2|standup>"]
        guard case let .message(message)? = router.route(["type": "events_api", "payload": ["event": event]]).first else {
            return XCTFail("mention not routed")
        }
        XCTAssertEqual(parse(message.text), .init(engine: .claude, model: "fable", effort: "medium", rest: "catch me up on <#C2|standup>"))
    }

    func testDefaultsAndLabel() {
        // The catalog's Sol, else the newest Sol Codex last listed.
        for (models, id) in [(SlackModelCatalogFixture.models, "gpt-6.1-sol"), (SlackModelCatalogFixture.claudeOnly, "gpt-6.2-sol")] {
            let sol = SlackModelPrefix.defaultModel(in: models)
            XCTAssertEqual([sol.engine.rawValue, sol.model, sol.effort], ["codex", id, "medium"])
        }
        XCTAssertEqual(SlackModelPrefix.label(engine: .claude, model: "fable", effort: "medium", models: SlackModelCatalogFixture.models), "Fable 5.1 · medium")
        XCTAssertEqual(SlackModelPrefix.label(engine: .codex, model: "gpt-6.1-sol", effort: "medium", models: SlackModelCatalogFixture.models), "GPT-6.1 Sol · medium")
        let high = DrifterModel(engine: .codex, model: "gpt-x-y", title: "X", efforts: ["high", "xhigh"], defaultEffort: "xhigh")
        XCTAssertEqual(SlackModelPrefix.unnamedEffort(for: high), "high")
    }
}
