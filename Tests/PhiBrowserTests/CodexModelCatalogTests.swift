import Foundation
import XCTest
#if !MIST_CODEX_HOSTLESS_TESTS
@testable import Phi
#endif

final class CodexModelCatalogTests: XCTestCase {
    func testModelsAndAccounts() throws {
        let model = try XCTUnwrap(CodexModelCatalog.parseModels(CodexFixtures.models).first)
        XCTAssertEqual(model.id, "gpt-6-luna"); XCTAssertEqual(model.displayName, "GPT-6-Luna")
        XCTAssertEqual(model.efforts, ["low", "medium"]); XCTAssertEqual(model.defaultEffort, "medium")
        XCTAssertEqual(model.inputModalities, ["text", "image"]); XCTAssertTrue(model.isDefault)
        XCTAssertEqual(try CodexAccount.parse(CodexFixtures.json(#"{"account":{"type":"chatgpt"}}"#)), .chatgpt)
        XCTAssertEqual(try CodexAccount.parse(CodexFixtures.json(#"{"account":null}"#)), .signedOut)
        XCTAssertEqual(try CodexAccount.parse(CodexFixtures.json(#"{"account":{"type":"apiKey"}}"#)), .other)
        XCTAssertThrowsError(try CodexAccount.parse(.null))
        XCTAssertThrowsError(try CodexModelCatalog.parseModels(CodexFixtures.json(#"{"data":[{"id":"broken"}]}"#)))
    }

    func testConcurrentLoadsAreCached() async throws {
        actor Counter {
            var count = 0
            func fetch() -> CodexModelCatalog.Snapshot { count += 1; return .init(models: [], account: .signedOut) }
        }
        let counter = Counter()
        let catalog = CodexModelCatalog(query: { await counter.fetch() })
        async let first = catalog.load()
        async let second = catalog.load()
        _ = try await (first, second)
        _ = try await catalog.load()
        let count = await counter.count
        XCTAssertEqual(count, 1)
    }

    func testHourOldCatalogRefreshesForTheNextLoad() async throws {
        actor State {
            var count = 0
            func fetch() -> CodexModelCatalog.Snapshot {
                count += 1
                return .init(models: [.init(id: "gpt-\(count)-sol", displayName: "", efforts: ["low"], defaultEffort: "low",
                                            inputModalities: [], isDefault: false)], account: .chatgpt)
            }
        }
        let state = State(), times = TimeBox()
        let catalog = CodexModelCatalog(clock: { times.now }, query: { await state.fetch() })
        func ids() async throws -> [String] { try await catalog.load().models.map(\.id) }
        var loaded = try await ids()
        XCTAssertEqual(loaded, ["gpt-1-sol"])
        times.now += 3599
        loaded = try await ids()
        XCTAssertEqual(loaded, ["gpt-1-sol"])
        times.now += 1
        // The stale result comes back at once, and a later load gets the refreshed one.
        loaded = try await ids()
        XCTAssertEqual(loaded, ["gpt-1-sol"])
        for _ in 0..<100 where loaded != ["gpt-2-sol"] {
            await Task.yield()
            loaded = try await ids()
        }
        XCTAssertEqual(loaded, ["gpt-2-sol"])
        let count = await state.count
        XCTAssertEqual(count, 2)
    }

    private final class TimeBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value = Date(timeIntervalSince1970: 0)
        var now: Date {
            get { lock.withLock { value } }
            set { lock.withLock { value = newValue } }
        }
    }

    func testFailedLoadStaysTypedAndRetries() async {
        actor Counter {
            var count = 0
            func fetch() throws -> CodexModelCatalog.Snapshot { count += 1; throw CodexError.missingExecutable }
        }
        let counter = Counter()
        let catalog = CodexModelCatalog(query: { try await counter.fetch() })
        for _ in 0..<2 {
            do { _ = try await catalog.load(); XCTFail("Expected a missing executable error") }
            catch CodexError.missingExecutable {} catch { XCTFail("Lost the typed error") }
        }
        let count = await counter.count
        XCTAssertEqual(count, 2)
    }
}
