import Foundation
import XCTest
#if !MIST_CLAUDE_CODE_HOSTLESS_TESTS
@testable import Phi
#endif

final class ClaudeCodeRemoteControlArchiveTests: XCTestCase {
    @MainActor
    private final class Clock {
        var date = Date(timeIntervalSince1970: 1000)
        var waits: [(TimeInterval, CheckedContinuation<Void, Never>)] = []
        func sleep(_ delay: TimeInterval) async { await withCheckedContinuation { waits.append((delay, $0)) } }
        func advance() { let (delay, continuation) = waits.removeFirst(); date.addTimeInterval(delay); continuation.resume() }
    }

    @MainActor
    private final class FailedRunner: ClaudeCodeArchiveRetrying {
        var calls = 0
        func run(entry: ClaudeCodeArchiveEntry, log: URL) async {
            calls += 1
            try? "v2 session URL: https://example.com/cse_old\nTorn down (archive=timeout)".write(to: log, atomically: true, encoding: .utf8)
        }
    }

    @MainActor
    func testThreeRetryScheduleAndGiveUp() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = Clock(), runner = FailedRunner()
        let archiver = ClaudeCodeRemoteControlArchiver(directory: root, runner: runner, now: { clock.date }, sleep: { await clock.sleep($0) })
        let log = await archiver.prepareLaunch(sessionId: "abc", folder: root)
        try "v2 session URL: https://example.com/cse_old".write(to: log, atomically: true, encoding: .utf8)
        archiver.exited("abc")
        for (index, delay) in [30.0, 300.0, 1800.0].enumerated() {
            while clock.waits.isEmpty { await Task.yield() }
            XCTAssertEqual(clock.waits.first?.0, delay)
            clock.advance()
            while runner.calls < index + 1 || (index < 2 && archiver.entries["abc"]?.nextAttempt == nil) { await Task.yield() }
        }
        while archiver.entries["abc"] != nil { await Task.yield() }
        XCTAssertFalse(FileManager.default.fileExists(atPath: log.path))
    }

    @MainActor
    func testLaunchSweepClassifiesUnsettledEntries() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = Clock()
        let first = ClaudeCodeRemoteControlArchiver(directory: root)
        let log = await first.prepareLaunch(sessionId: "abc", folder: root)
        try "v2 session URL: https://example.com/cse_old".write(to: log, atomically: true, encoding: .utf8)
        let emptyLog = await first.prepareLaunch(sessionId: "empty", folder: root)
        try "no bridge".write(to: emptyLog, atomically: true, encoding: .utf8)
        let restored = ClaudeCodeRemoteControlArchiver(directory: root, now: { clock.date }, sleep: { await clock.sleep($0) })
        restored.start()
        while clock.waits.isEmpty { await Task.yield() }
        clock.advance()
        while restored.entries["abc"]?.nextAttempt == nil { await Task.yield() }
        XCTAssertEqual(restored.entries["abc"]?.bridgeSessionId, "cse_old")
        XCTAssertNil(restored.entries["empty"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: emptyLog.path))
    }

    @MainActor
    func testSessionPassesDebugArguments() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("claude"), arguments = root.appendingPathComponent("args")
        try "#!/bin/sh\nprintf '%s\\n' \"$@\" > '\(arguments.path)'\nwhile IFS= read -r line; do :; done\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let archiver = ClaudeCodeRemoteControlArchiver(directory: root.appendingPathComponent("archive"))
        let request = ClaudeCodeLaunchRequest(prompt: "hello", attachments: [], config: .init(folder: root), launchArguments: [])
        let session = ClaudeCodeSession(request: request, conversation: AgentConversation(), environment: { .init(variables: [:], executable: executable) }, archiver: archiver)
        for _ in 0..<200 where !FileManager.default.fileExists(atPath: arguments.path) { try await Task.sleep(for: .milliseconds(10)) }
        let lines = try String(contentsOf: arguments, encoding: .utf8).components(separatedBy: .newlines)
        XCTAssertTrue(lines.contains("--debug=remote-bridge,code-session"))
        let index = try XCTUnwrap(lines.firstIndex(of: "--debug-file"))
        XCTAssertEqual(lines[index + 1], archiver.logURL(session.sessionId).path)
        session.close()
        for _ in 0..<200 where archiver.entries[session.sessionId] != nil { try await Task.sleep(for: .milliseconds(10)) }
    }
    func testClassification() {
        let session = "[remote-bridge] v2 session URL: https://api.anthropic.com/v1/code/sessions/cse_123\n"
        XCTAssertEqual(ClaudeCodeArchiveOutcome.classify(""), .noSession)
        XCTAssertEqual(ClaudeCodeArchiveOutcome.classify(session), .needsRetry("cse_123"))
        XCTAssertEqual(ClaudeCodeArchiveOutcome.classify(session + "[remote-bridge] Torn down (archive=timeout)"), .needsRetry("cse_123"))
        for status in [200, 409] {
            XCTAssertEqual(ClaudeCodeArchiveOutcome.classify(session + "[remote-bridge] Torn down (archive=\(status))"), .archived)
        }
        XCTAssertEqual(ClaudeCodeArchiveOutcome.classify(session + "[remote-bridge] Teardown complete (skipArchive): session=cse_123"), .archived)
        XCTAssertEqual(ClaudeCodeArchiveOutcome.classify(session + "Torn down (archive=200)\n" + session + "Torn down (archive=timeout)"), .needsRetry("cse_123"))
    }

    @MainActor
    func testPersistenceAndFailureSchedule() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 1000)
        let archiver = ClaudeCodeRemoteControlArchiver(directory: root, now: { now }, sleep: { _ in try? await Task.sleep(for: .seconds(3600)) })
        let log = await archiver.prepareLaunch(sessionId: "abc", folder: root)
        let failure = "v2 session URL: https://example.com/cse_old\nTorn down (archive=timeout)"
        try failure.write(to: log, atomically: true, encoding: .utf8)
        archiver.exited("abc")
        XCTAssertEqual(archiver.entries["abc"]?.nextAttempt, now.addingTimeInterval(30))
        let restored = ClaudeCodeRemoteControlArchiver(directory: root, now: { now }, sleep: { _ in try? await Task.sleep(for: .seconds(3600)) })
        XCTAssertEqual(restored.entries, archiver.entries)
        _ = await archiver.prepareLaunch(sessionId: "abc", folder: root)
        XCTAssertNil(archiver.entries["abc"]?.nextAttempt)
        XCTAssertFalse(FileManager.default.fileExists(atPath: log.path))
        try failure.write(to: log, atomically: true, encoding: .utf8)
        archiver.exited("abc")
        XCTAssertEqual(archiver.entries["abc"]?.bridgeSessionId, "cse_old")
    }

    @MainActor
    func testDifferentBridgeAndArchivedRemoveLog() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let archiver = ClaudeCodeRemoteControlArchiver(directory: root, sleep: { _ in try? await Task.sleep(for: .seconds(3600)) })
        let log = await archiver.prepareLaunch(sessionId: "abc", folder: root)
        try "v2 session URL: https://example.com/cse_old".write(to: log, atomically: true, encoding: .utf8)
        archiver.exited("abc")
        try "v2 session URL: https://example.com/cse_new\nTorn down (archive=200)".write(to: log, atomically: true, encoding: .utf8)
        archiver.settle("abc")
        XCTAssertNil(archiver.entries["abc"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: log.path))
        _ = await archiver.prepareLaunch(sessionId: "abc", folder: root)
        try "v2 session URL: https://example.com/cse_old\nTorn down (archive=200)".write(to: log, atomically: true, encoding: .utf8)
        archiver.exited("abc")
        XCTAssertNil(archiver.entries["abc"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: log.path))
    }
}
