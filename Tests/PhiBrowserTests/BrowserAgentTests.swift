import Foundation
import XCTest
import Combine
#if !MIST_CLAUDE_CODE_HOSTLESS_TESTS
import AppKit
@testable import Phi
#endif

final class BrowserAgentTests: XCTestCase {
    private var scheduleCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Toronto")!
        return calendar
    }

    private func scheduleDate(_ iso8601: String) -> Date {
        ISO8601DateFormatter().date(from: iso8601)!
    }

    func testScheduleCronParsesNamesListsRangesAndSteps() throws {
        let cron = try DrifterCron("*/15 9,10 1-5/2 jAn,Feb mOn-Fri")
        XCTAssertEqual(cron.next(after: scheduleDate("2026-01-05T09:00:00-05:00"), calendar: scheduleCalendar),
                       scheduleDate("2026-01-05T09:15:00-05:00"))
        XCTAssertEqual(try DrifterCron("0 9 1-5/2 JAN *").next(
            after: scheduleDate("2026-01-01T09:00:00-05:00"), calendar: scheduleCalendar),
            scheduleDate("2026-01-03T09:00:00-05:00"))
        for invalid in ["* * * *", "60 * * * *", "* 24 * * *", "* * 0 * *", "* * * ABC *",
                        "* * * * 8", "* * * * MON-", "*/0 * * * *", "1,,2 * * * *", "5-1 * * * *"] {
            XCTAssertThrowsError(try DrifterCron(invalid), invalid)
        }
    }

    func testScheduleCronMatchesEitherRestrictedDayField() throws {
        let cron = try DrifterCron("0 9 15 * 7")
        let sunday = scheduleDate("2026-06-14T09:00:00-04:00")
        XCTAssertEqual(cron.next(after: scheduleDate("2026-06-13T09:00:00-04:00"), calendar: scheduleCalendar), sunday)
        XCTAssertEqual(cron.next(after: sunday, calendar: scheduleCalendar), scheduleDate("2026-06-15T09:00:00-04:00"))
        XCTAssertEqual(try DrifterCron("0 9 * * 0").next(after: sunday, calendar: scheduleCalendar),
                       scheduleDate("2026-06-21T09:00:00-04:00"))
    }

    func testScheduleCronSkipsMissingDatesAndRunsRepeatedTimesOnce() throws {
        XCTAssertEqual(try DrifterCron("0 9 31 * *").next(
            after: scheduleDate("2026-01-31T09:00:00-05:00"), calendar: scheduleCalendar),
            scheduleDate("2026-03-31T09:00:00-04:00"))
        XCTAssertNil(try DrifterCron("0 9 30 FEB *").next(
            after: scheduleDate("2026-01-31T09:00:00-05:00"), calendar: scheduleCalendar))
        XCTAssertEqual(try DrifterCron("30 2 * * *").next(
            after: scheduleDate("2026-03-07T02:30:00-05:00"), calendar: scheduleCalendar),
            scheduleDate("2026-03-09T02:30:00-04:00"))
        let fall = try DrifterCron("30 1 * * *")
        let first = scheduleDate("2026-11-01T01:30:00-04:00")
        XCTAssertEqual(fall.next(after: scheduleDate("2026-11-01T00:59:00-04:00"), calendar: scheduleCalendar), first)
        XCTAssertEqual(fall.next(after: first, calendar: scheduleCalendar), scheduleDate("2026-11-02T01:30:00-05:00"))
        XCTAssertEqual(fall.next(after: scheduleDate("2026-11-01T01:15:00-05:00"), calendar: scheduleCalendar),
                       scheduleDate("2026-11-02T01:30:00-05:00"))
    }

    func testScheduleResolvesOneTimeInputs() throws {
        let now = scheduleDate("2026-11-30T09:00:00-05:00")
        func resolve(cron: String? = nil, at: String? = nil, delay: Int? = nil) throws -> DrifterSchedule.Timing {
            try DrifterSchedule.Timing.resolve(cron: cron, at: at, delayMinutes: delay, now: now, calendar: scheduleCalendar).timing
        }
        XCTAssertEqual(try resolve(delay: 7), .at(now.addingTimeInterval(420)))
        XCTAssertEqual(try resolve(at: "2026-11-30T09:07"), try resolve(delay: 7))
        XCTAssertEqual(try resolve(at: "2026-11-30T14:07:00Z"), try resolve(delay: 7))
        XCTAssertEqual(try resolve(at: "2026-11-30T15:07:00+0100"), try resolve(delay: 7))
        XCTAssertThrowsError(try resolve(at: "2026-11-30T08:59:59"))
        XCTAssertThrowsError(try resolve(at: "2027-02-29T09:00"))
        XCTAssertThrowsError(try resolve(at: "2027-03-14T02:30"))
        XCTAssertThrowsError(try resolve(cron: "* * * * *", delay: 7))
        XCTAssertThrowsError(try resolve())
        XCTAssertThrowsError(try resolve(delay: 525601))
    }

    @MainActor func testScheduleStoreCollapsesMissedRunsAndPersistsAdvance() throws {
        let url = try memoryHome().appendingPathComponent("Schedules.json")
        var now = scheduleDate("2026-11-30T08:59:00-05:00")
        let calendar = scheduleCalendar
        let store = DrifterScheduleStore(url: url, now: { now }, calendar: { calendar })
        let schedule = try store.create(title: "Hourly", prompt: "Check", cron: "0 * * * *", at: nil,
                                        delayMinutes: nil, target: .thisChat, owner: UUID())
        let once = try store.create(title: "Once", prompt: "Check", cron: nil, at: nil, delayMinutes: 1,
                                    target: .thisChat, owner: UUID())
        now = scheduleDate("2026-11-30T12:30:00-05:00")
        let run = try XCTUnwrap(store.takeDue(schedule.id))
        let next = scheduleDate("2026-11-30T13:00:00-05:00")
        XCTAssertTrue(run.isLate)
        XCTAssertEqual(run.nextRun, next)
        XCTAssertEqual(run.header(label: "Hourly", timeZone: calendar.timeZone),
                       "[Scheduled prompt Hourly, due Mon Nov 30 09:00 EST, running late because Mist was closed or the Mac was asleep]. Next run: Mon Nov 30 13:00 EST. cancel_schedule \(schedule.id) stops it.")
        let oneRun = try XCTUnwrap(store.takeDue(once.id))
        XCTAssertTrue(oneRun.header(label: "Once", timeZone: calendar.timeZone).hasSuffix(". This was its only run."))
        XCTAssertNil(try store.takeDue(schedule.id))
        let reopened = DrifterScheduleStore(url: url, now: { now }, calendar: { calendar })
        XCTAssertEqual(try reopened.list().map(\.id), [schedule.id])
        XCTAssertEqual(try reopened.list().first?.nextRun, next)
        XCTAssertEqual(try reopened.list().first?.lastRun, now)
        now = next.addingTimeInterval(120)
        XCTAssertFalse(try XCTUnwrap(reopened.takeDue(schedule.id)).isLate)
    }

    @MainActor func testScheduleCancellationPermissions() throws {
        let url = try memoryHome().appendingPathComponent("Schedules.json")
        let store = DrifterScheduleStore(url: url)
        let owner = UUID(), another = UUID()
        let personal = try store.create(title: "Owner", prompt: "Check", cron: nil, at: nil, delayMinutes: 1,
                                        target: .thisChat, owner: owner)
        let independent = try store.create(title: "New", prompt: "Check", cron: nil, at: nil, delayMinutes: 1,
                                           target: .newChat(.init()), owner: owner)
        XCTAssertThrowsError(try store.cancel(personal.id, from: another))
        try store.cancel(personal.id, from: owner)
        try store.cancel(independent.id, from: another)
        XCTAssertTrue(try store.list().isEmpty)
    }

    func testScheduleSharesSpawnModelAndEffortRestrictions() throws {
        let opus = DrifterConfig(confirmation: .ask)
        let gpt = try XCTUnwrap(DrifterModel.codexPicks.first)
        let pickedModel = DrifterModel(engine: .codex, model: gpt, title: "GPT", efforts: ["medium"], defaultEffort: "medium")
        func resolve(_ base: DrifterConfig, _ model: String? = nil, effort: String? = nil) throws -> DrifterConfig {
            try DrifterModel.resolveSpawnConfig(from: base, models: [pickedModel], model: model, effort: effort).get()
        }
        let anyEngine = try resolve(opus, gpt)
        XCTAssertEqual(anyEngine.engine, .codex)
        XCTAssertEqual(anyEngine.effort, "medium")
        XCTAssertEqual(anyEngine.confirmation, .ask)
        XCTAssertThrowsError(try resolve(opus, gpt, effort: "xhigh"))
        let astra = DrifterConfig(engine: .codex, model: "gpt-6.2-astra", effort: "medium")
        XCTAssertEqual(try resolve(astra, gpt).model, gpt)
        XCTAssertThrowsError(try resolve(astra, "opus")) { guard case AgentSpawnError.restricted = $0 else { return XCTFail("\($0)") } }
        let own = DrifterConfig(model: "sonnet", effort: "medium")
        XCTAssertEqual(try resolve(own), own)
        XCTAssertThrowsError(try resolve(own, "opus")) { guard case AgentSpawnError.restricted = $0 else { return XCTFail("\($0)") } }
        XCTAssertThrowsError(try resolve(own, effort: "high")) { guard case AgentSpawnError.restricted = $0 else { return XCTFail("\($0)") } }
    }

    func testScheduleToolsFollowConfirmationModes() {
        for name in ["schedule_prompt", "cancel_schedule"] {
            let tool = "mcp__mistbrowser__" + name
            XCTAssertFalse(DrifterConfirmation.ask.automaticallyAllows(tool: tool, requiresInteraction: false))
            XCTAssertTrue(DrifterConfirmation.skip.automaticallyAllows(tool: tool, requiresInteraction: false))
            XCTAssertFalse(DrifterLaunchRequest.readOnlyTools.contains(name))
        }
        XCTAssertTrue(DrifterConfirmation.ask.automaticallyAllows(tool: "mcp__mistbrowser__notify", requiresInteraction: false))
        XCTAssertTrue(DrifterConfirmation.ask.automaticallyAllows(tool: "mcp__mistbrowser__list_schedules", requiresInteraction: false))
        XCTAssertTrue(DrifterLaunchRequest.readOnlyTools.contains("list_schedules"))
    }

    func testArtifactConsentFollowsConfirmationModes() {
        XCTAssertTrue(DrifterLaunchRequest.claudeTools.hasSuffix(",Artifact,ArtifactComments,ArtifactData,ArtifactCheck"))
        for tool in DrifterLaunchRequest.artifactTools {
            for interaction in [false, true] {
                XCTAssertFalse(DrifterConfirmation.ask.automaticallyAllows(tool: tool, requiresInteraction: interaction), tool)
                XCTAssertTrue(DrifterConfirmation.skip.automaticallyAllows(tool: tool, requiresInteraction: interaction), tool)
            }
        }
        XCTAssertFalse(DrifterConfirmation.skip.automaticallyAllows(tool: "AskUserQuestion", requiresInteraction: true))
    }

    func testScheduledPromptsAppearAsPeerMessagesInEveryEngine() {
        let header = "[Scheduled prompt abc12345 (Hourly), due Mon Nov 30 09:00 EST]. This was its only run."
        var sender = AgentMessageSender(id: "abc12345", title: "Hourly", kind: .schedule, note: header)
        sender.postsToSlack = true
        XCTAssertTrue(sender.header.hasPrefix(header + " "))
        XCTAssertTrue(sender.header.contains(AgentMessageSender.slackWakeNote))

        let message = AgentQueuedMessage(text: "Check the report", sender: sender)
        let kind = AgentChatItem.Kind.peerMessage(name: sender.label, body: message.text)
        var claude = ClaudeCodeTranscript()
        var codex = CodexTranscript()
        var gemini = GeminiTranscript()
        claude.userSent(text: message.text, attachments: [], sender: sender)
        codex.userSent(text: message.text, attachments: [], sender: sender)
        gemini.rows.userSent(text: message.text, attachments: [], sender: sender)
        XCTAssertEqual(claude.items.last?.kind, kind)
        XCTAssertEqual(codex.items.last?.kind, kind)
        XCTAssertEqual(gemini.rows.items.last?.kind, kind)
        claude.queuedMessageTaken(message)
        codex.queuedMessageTaken(message)
        gemini.rows.queuedMessageTaken(message)
        for items in [claude.items, codex.items, gemini.rows.items] {
            XCTAssertEqual(items.filter { $0.kind == kind }.count, 2)
            let slack = AgentChatItem(id: "slack", kind: .peerMessage(name: "Slack", body: "Check the report"))
            XCTAssertTrue(AgentChatTranscriptText.isSlackTurn([slack] + items))
        }
    }

    @MainActor private func taskRunner() throws -> DrifterBackgroundTasks {
        let folder = try memoryHome()
        let runner = DrifterBackgroundTasks(folder: folder, outputFolder: folder.appendingPathComponent("Tasks"),
            batchWindow: 0.03, killGrace: 0.05, drainWait: 0.1)
        runner.environment = ProcessInfo.processInfo.environment
        return runner
    }

    @MainActor private func eventually(_ predicate: () -> Bool, timeout: TimeInterval = 3,
                                       file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate(), Date() < deadline { try? await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(predicate(), file: file, line: line)
    }

    @MainActor func testBackgroundCommandExitWakesOnceAndLogsOutput() async throws {
        let runner = try taskRunner()
        defer { runner.stopAll(immediately: true) }
        var wakes: [AgentQueuedMessage] = [], ended: [(String, AgentChatItem.TaskNotificationStatus)] = []
        var lists: [[AgentBackgroundTask]] = []
        runner.onWake = { wakes.append($0); return true }
        runner.onEnded = { _, summary, status in ended.append((summary, status)) }
        runner.onChange = { lists.append($0) }
        let task = try runner.start(kind: .command, command: "printf 'a\\nb\\n'; exit 3", description: " Example ")
        await eventually { wakes.count == 1 }
        XCTAssertEqual(wakes.first?.sender?.kind, .task)
        XCTAssertTrue(wakes.first?.sender?.header.contains("exited with code 3") == true)
        XCTAssertEqual(wakes.first?.text, "a\nb")
        XCTAssertEqual(ended.first?.0, "Background command \"Example\" failed with exit code 3")
        XCTAssertEqual(ended.first?.1, .failed)
        XCTAssertEqual(ended.count, 1)
        XCTAssertEqual(lists.map(\.count), [1, 0])
        XCTAssertTrue(runner.tasks.isEmpty)
        XCTAssertEqual(try String(contentsOfFile: task.outputFile, encoding: .utf8), "a\nb\n")
        XCTAssertTrue(task.taskId.range(of: "^task-[a-z0-9]{6}$", options: .regularExpression) != nil)
    }

    @MainActor func testBackgroundCheckInOutputIncludesBoundedCommandTail() async throws {
        let runner = try taskRunner()
        defer { runner.stopAll(immediately: true) }
        let task = try runner.start(kind: .command, command: "for i in {1..30}; do echo line-$i; done; sleep 5", description: "Build")
        await eventually { runner.checkInOutput(for: task.taskId)?.tail?.contains("line-30") == true }
        let output = try XCTUnwrap(runner.checkInOutput(for: task.taskId))
        XCTAssertEqual(output.path, task.outputFile)
        let tail = try XCTUnwrap(output.tail)
        XCTAssertTrue(tail.hasPrefix("(earlier output is in the output file)\n"))
        XCTAssertFalse(tail.contains("line-10\n"))
        XCTAssertTrue(tail.contains("line-30"))
        let monitor = try runner.start(kind: .monitor, command: "sleep 5", description: "Watch")
        XCTAssertNil(runner.checkInOutput(for: monitor.taskId)?.tail)
    }

    @MainActor func testMonitorBatchesStdoutAndEndsOnce() async throws {
        let runner = try taskRunner()
        defer { runner.stopAll(immediately: true) }
        var wakes: [AgentQueuedMessage] = [], endings: [String] = []
        runner.onWake = { wakes.append($0); return true }
        runner.onEnded = { _, summary, status in endings.append(summary); XCTAssertEqual(status, .completed) }
        let task = try runner.start(kind: .monitor, command: "echo diagnostic >&2; for i in 1 2 3; do echo tick $i; sleep 0.3; done", description: "Ticks")
        await eventually { !endings.isEmpty && wakes.last?.sender?.note?.contains("ended:") == true }
        for i in 1...3 { XCTAssertTrue(wakes.contains { $0.text.contains("tick \(i)") }) }
        XCTAssertFalse(wakes.contains { $0.text.contains("diagnostic") })
        XCTAssertEqual(endings, ["Monitor \"Ticks\" stream ended"])
        XCTAssertTrue(try String(contentsOfFile: task.outputFile, encoding: .utf8).contains("diagnostic"))
    }

    @MainActor func testMonitorHoldsLinesUntilPreviousWakeLeavesQueue() async throws {
        let runner = try taskRunner()
        defer { runner.stopAll(immediately: true) }
        var wakes: [AgentQueuedMessage] = [], queued = Set<String>()
        runner.isQueued = { queued.contains($0) }
        runner.onWake = { wakes.append($0); queued.insert($0.id); return true }
        let task = try runner.start(kind: .monitor,
            command: "echo first; sleep 0.2; printf 'second\\nthird\\n'; sleep 30", description: "Held")
        await eventually { wakes.count == 1 }
        // A file marker proves the later lines were printed while the first wake was queued.
        await eventually { (try? String(contentsOfFile: task.outputFile, encoding: .utf8).contains("third")) == true }
        try? await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertEqual(wakes.count, 1)
        queued.removeAll(); runner.queueChanged([])
        await eventually { wakes.count == 2 }
        XCTAssertEqual(wakes.last?.text, "second\nthird")
        XCTAssertTrue(runner.stop(task.taskId))
        await eventually { runner.tasks.isEmpty }
    }

    @MainActor func testBackgroundStopReportsWithoutWake() async throws {
        let runner = try taskRunner()
        defer { runner.stopAll(immediately: true) }
        var summaries: [String] = [], wakes = 0
        runner.onEnded = { _, summary, status in summaries.append(summary); XCTAssertEqual(status, .stopped) }
        runner.onWake = { _ in wakes += 1; return true }
        let task = try runner.start(kind: .command, command: "sleep 30", description: "Sleep")
        XCTAssertTrue(runner.stop(task.taskId))
        await eventually { !summaries.isEmpty }
        XCTAssertEqual(summaries, ["Background command \"Sleep\" was stopped"])
        XCTAssertEqual(wakes, 0)
        XCTAssertFalse(runner.stop(task.taskId))
    }

    @MainActor func testBackgroundStopAllKillsProcessGroupWithoutReporting() async throws {
        for immediately in [false, true] {
            let runner = try taskRunner()
            defer { runner.stopAll(immediately: true) }
            var wakes = 0, endings = 0
            runner.onWake = { _ in wakes += 1; return true }
            runner.onEnded = { _, _, _ in endings += 1 }
            let task = try runner.start(kind: .command,
                command: "echo $$; sh -c 'trap \"\" TERM; sleep 30 & sleep 30'", description: "Group")
            await eventually { (try? String(contentsOfFile: task.outputFile, encoding: .utf8).isEmpty) == false }
            let pid = try XCTUnwrap(Int32(try String(contentsOfFile: task.outputFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
            runner.stopAll(immediately: immediately)
            await eventually { kill(-pid, 0) == -1 && errno == ESRCH }
            XCTAssertTrue(runner.tasks.isEmpty)
            XCTAssertEqual(wakes, 0); XCTAssertEqual(endings, 0)
        }
    }

    @MainActor func testBackgroundTimeoutReportsLimitAndWakes() async throws {
        let runner = try taskRunner()
        defer { runner.stopAll(immediately: true) }
        var wakes: [AgentQueuedMessage] = [], summaries: [String] = []
        runner.onWake = { wakes.append($0); return true }
        runner.onEnded = { _, summary, status in summaries.append(summary); XCTAssertEqual(status, .stopped) }
        _ = try runner.start(kind: .command, command: "sleep 30", description: "Limit", timeout: 1)
        await eventually { wakes.count == 1 }
        XCTAssertEqual(summaries, ["Background command \"Limit\" was stopped after reaching its background time limit"])
        XCTAssertTrue(wakes.first?.sender?.header.contains("timed out after 1 s") == true)
        XCTAssertEqual(wakes.first?.text, "(no output)")
    }

    @MainActor func testBackgroundStartupAndConcurrencyLimits() async throws {
        let runner = try taskRunner()
        defer { runner.stopAll(immediately: true) }
        let environment = runner.environment
        runner.environment = nil
        XCTAssertThrowsError(try runner.start(kind: .command, command: "true")) {
            XCTAssertEqual($0.localizedDescription, "Mist hasn't finished starting this chat.")
        }
        runner.environment = environment
        for _ in 0..<16 { _ = try runner.start(kind: .command, command: "sleep 30") }
        XCTAssertEqual(runner.tasks.count, 16)
        XCTAssertThrowsError(try runner.start(kind: .command, command: "true")) {
            XCTAssertEqual($0.localizedDescription, "This chat already runs 16 background tasks; stop one first.")
        }
        runner.stopAll(immediately: true)
        XCTAssertTrue(runner.tasks.isEmpty)
    }

    @MainActor func testBackgroundLogsAndWakeTailsAreBounded() async throws {
        let runner = try taskRunner()
        defer { runner.stopAll(immediately: true) }
        var wakes: [AgentQueuedMessage] = []
        runner.onWake = { wakes.append($0); return true }
        let task = try runner.start(kind: .command,
            command: "head -c 9000000 /dev/zero | tr '\\0' x; printf '\\nlast line\\n'", description: "Large")
        await eventually({ wakes.count == 1 }, timeout: 5)
        let output = try Data(contentsOf: URL(fileURLWithPath: task.outputFile))
        let marker = "\n[Mist: output truncated at 8 MiB]\n"
        XCTAssertEqual(output.count, 8 * 1024 * 1024 + marker.utf8.count)
        XCTAssertTrue(output.suffix(marker.utf8.count).elementsEqual(marker.utf8))
        XCTAssertLessThanOrEqual(wakes.first?.text.utf8.count ?? Int.max, 8192)
        XCTAssertTrue(wakes.first?.text.hasPrefix("(earlier output is in the output file)") == true)
        XCTAssertTrue(wakes.first?.text.hasSuffix("last line") == true)
    }

    @MainActor func testBackgroundShutdownCancelsAnExitWakeBeforeDelivery() async throws {
        let runner = try taskRunner()
        defer { runner.stopAll(immediately: true) }
        var ended = false, wakes = 0
        runner.onWake = { _ in wakes += 1; return true }
        runner.onEnded = { [weak runner] _, _, _ in ended = true; runner?.stopAll(immediately: false) }
        _ = try runner.start(kind: .command, command: "true")
        await eventually { ended }
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(wakes, 0)
    }

    @MainActor func testBackgroundSpawnUsesWorkingFolderAndEnvironmentAndHandlesSignals() async throws {
        let runner = try taskRunner()
        defer { runner.stopAll(immediately: true) }
        runner.environment?["MIST_TASK_TEST"] = "environment value"
        var wakes: [AgentQueuedMessage] = [], summaries: [String] = []
        runner.onWake = { wakes.append($0); return true }
        runner.onEnded = { _, summary, status in summaries.append(summary); XCTAssertEqual(status, .failed) }
        _ = try runner.start(kind: .command, command: "pwd; echo $MIST_TASK_TEST; kill -KILL $$", description: "Signal")
        await eventually { wakes.count == 1 }
        XCTAssertTrue(wakes[0].text.contains(runner.folder.path))
        XCTAssertTrue(wakes[0].text.contains("environment value"))
        XCTAssertTrue(wakes[0].sender?.header.contains("killed by signal 9") == true)
        XCTAssertEqual(summaries, ["Background command \"Signal\" failed"])
    }

    @MainActor func testBackgroundBlankOutputHasReadableWake() async throws {
        let runner = try taskRunner()
        defer { runner.stopAll(immediately: true) }
        var wakes: [AgentQueuedMessage] = []
        runner.onWake = { wakes.append($0); return true }
        _ = try runner.start(kind: .command, command: "printf '\\n\\n'")
        await eventually { wakes.count == 1 }
        XCTAssertEqual(wakes[0].text, "(no output)")
    }

    @MainActor func testMonitorExitIncludesPendingLinesInOneEndWake() async throws {
        let runner = try taskRunner()
        defer { runner.stopAll(immediately: true) }
        var wakes: [AgentQueuedMessage] = [], summaries: [String] = []
        runner.onWake = { wakes.append($0); return true }
        runner.onEnded = { _, summary, status in summaries.append(summary); XCTAssertEqual(status, .failed) }
        _ = try runner.start(kind: .monitor, command: "printf 'last line'; exit 2", description: "Partial")
        await eventually { wakes.count == 1 }
        XCTAssertEqual(wakes[0].text, "last line")
        XCTAssertTrue(wakes[0].sender?.header.contains("after 1 events. Its last lines follow") == true)
        XCTAssertEqual(summaries, ["Monitor \"Partial\" script failed (exit 2)"])
    }

    @MainActor func testMonitorFloodStopsAndBoundsHeldLines() async throws {
        let runner = try taskRunner()
        defer { runner.stopAll(immediately: true) }
        var wakes: [AgentQueuedMessage] = [], summaries: [String] = []
        runner.onWake = { wakes.append($0); return true }
        runner.onEnded = { _, summary, status in summaries.append(summary); XCTAssertEqual(status, .stopped) }
        _ = try runner.start(kind: .monitor, command: "for i in {1..600}; do echo tick $i; done; sleep 30", description: "Flood")
        await eventually { !summaries.isEmpty && !wakes.isEmpty }
        XCTAssertEqual(summaries, ["Monitor \"Flood\" stopped"])
        XCTAssertTrue(wakes.last?.sender?.header.contains("too many lines") == true)
        XCTAssertTrue(wakes.last?.text.contains("earlier lines omitted") == true)
        XCTAssertLessThanOrEqual(wakes.last?.text.utf8.count ?? Int.max, 8192)
        XCTAssertLessThanOrEqual(wakes.last?.text.components(separatedBy: "\n").count ?? Int.max, 100)
    }

    func testFinishTaskLaunchFlagForBothEngines() throws {
        let folder = URL(fileURLWithPath: "/tmp"), server = CodexMCPServer(command: "node", env: ["MIST_FINISH_TASK": "stale"])
        for mode in 0..<3 {
            var request = DrifterLaunchRequest(prompt: "", config: .init(), windowId: 1)
            if mode == 1 { request.parent = .init(id: "abcd", title: "Parent", kind: .parent) }
            request.slackThread = mode == 2
            XCTAssertEqual(request.finishesTasks, mode != 0)
            let expected: String? = mode == 0 ? nil : "1"
            XCTAssertEqual(request.codex(folder: folder, server: server).mcpServers["mistbrowser"]?.env["MIST_FINISH_TASK"], expected)
            let claude = request.claude(folder: folder, server: server)
            let index = try XCTUnwrap(claude.launchArguments.firstIndex(of: "--mcp-config"))
            let mcp = try JSONDecoder().decode(ClaudeCodeJSON.self, from: Data(claude.launchArguments[index + 1].utf8))
            XCTAssertEqual(mcp["mcpServers"]["mistbrowser"]["env"]["MIST_FINISH_TASK"].string, expected)
        }
        for mode in [DrifterConfirmation.ask, .skip] {
            for interaction in [false, true] {
                XCTAssertTrue(mode.automaticallyAllows(tool: "mcp__mistbrowser__finish_task", requiresInteraction: interaction))
                XCTAssertTrue(mode.automaticallyAllows(tool: "mcp__mistbrowser__group_tabs", requiresInteraction: interaction))
                XCTAssertTrue(mode.automaticallyAllows(tool: "mcp__mistbrowser__hand_off", requiresInteraction: interaction))
                XCTAssertTrue(mode.automaticallyAllows(tool: "mcp__mistbrowser__stop_recording", requiresInteraction: interaction))
                XCTAssertTrue(mode.automaticallyAllows(tool: "mcp__mistbrowser__mount_to_tab", requiresInteraction: interaction))
                XCTAssertTrue(mode.automaticallyAllows(tool: "mcp__mistbrowser__unmount_from_tab", requiresInteraction: interaction))
            }
        }
        XCTAssertFalse(DrifterConfirmation.ask.automaticallyAllows(tool: "mcp__mistbrowser__close_tab", requiresInteraction: false))
        XCTAssertFalse(DrifterConfirmation.ask.automaticallyAllows(tool: "mcp__mistbrowser__start_recording", requiresInteraction: false))
        XCTAssertTrue(DrifterConfirmation.skip.automaticallyAllows(tool: "mcp__mistbrowser__start_recording", requiresInteraction: false))
        XCTAssertFalse(DrifterConfirmation.ask.automaticallyAllows(tool: "mcp__mistbrowser__export_bookmarks", requiresInteraction: false))
        XCTAssertTrue(DrifterConfirmation.skip.automaticallyAllows(tool: "mcp__mistbrowser__export_bookmarks", requiresInteraction: false))
        XCTAssertTrue(Set(DrifterLaunchRequest.readOnlyTools).isDisjoint(with: ["export_bookmarks", "mount_to_tab", "unmount_from_tab"]))
    }

    func testBackgroundLaunchPermissionsAndSlackWakeHeader() {
        let request = DrifterLaunchRequest(prompt: "", config: .init(), windowId: 1)
        let folder = URL(fileURLWithPath: "/tmp"), server = CodexMCPServer(command: "node")
        let codex = request.codex(folder: folder, server: server)
        XCTAssertEqual(codex.mcpServers["mistbrowser"]?.env["MIST_BACKGROUND_TASKS"], "1")
        XCTAssertTrue(codex.developerInstructions.contains("run_in_background"))
        let claude = request.claude(folder: folder, server: server)
        let mcpIndex = claude.launchArguments.firstIndex(of: "--mcp-config")!
        let mcp = try! JSONDecoder().decode(ClaudeCodeJSON.self, from: Data(claude.launchArguments[mcpIndex + 1].utf8))
        XCTAssertNil(mcp["mcpServers"]["mistbrowser"]["env"]["MIST_BACKGROUND_TASKS"].string)
        XCTAssertTrue(DrifterConfirmation.ask.automaticallyAllows(tool: "mcp__mistbrowser__stop_task", requiresInteraction: false))
        XCTAssertFalse(DrifterConfirmation.ask.automaticallyAllows(tool: "mcp__mistbrowser__run_in_background", requiresInteraction: false))
        XCTAssertFalse(DrifterConfirmation.ask.automaticallyAllows(tool: "mcp__mistbrowser__monitor", requiresInteraction: false))
        var sender = AgentMessageSender(id: "task-abc123", title: "Task", kind: .task)
        sender.postsToSlack = true
        XCTAssertTrue(sender.header.contains(AgentMessageSender.slackWakeNote))
        XCTAssertTrue(AgentChatTranscriptText.isSlackTurn([
            .init(id: "slack", kind: .peerMessage(name: "Slack", body: "Build")),
            .init(id: "task", kind: .taskNotification(summary: "Done", status: .completed)),
        ]))
    }

    @MainActor func testConversationMergesBackgroundTasksOnlyWhenChanged() {
        let conversation = AgentConversation()
        let native = AgentBackgroundTask(id: "native", kind: .shell, description: "Native")
        let drifter = AgentBackgroundTask(id: "drifter", kind: .monitor, description: "Drifter")
        var updates = 0
        let subscription = conversation.$backgroundTasks.sink { _ in updates += 1 }
        conversation.update(items: [], status: .idle, backgroundTasks: [native])
        conversation.updateDrifterTasks([drifter])
        conversation.update(items: [], status: .running, backgroundTasks: [native])
        conversation.updateDrifterTasks([drifter])
        XCTAssertEqual(conversation.backgroundTasks, [native, drifter])
        XCTAssertEqual(updates, 3)
        conversation.update(items: [], status: .ended)
        XCTAssertTrue(conversation.backgroundTasks.isEmpty)
        withExtendedLifetime(subscription) {}
    }

    func testChatShortIDsAndCollisionResolution() throws {
        let first = UUID(uuidString: "00000000-0000-0001-0000-000000000000")!
        let collision = UUID(uuidString: "00000000-0019-a101-0000-000000000000")!
        let other = UUID(uuidString: "00000000-0000-0002-0000-000000000000")!
        XCTAssertEqual(AgentChatShortID.full(first), "100000000000")
        XCTAssertEqual(AgentChatShortID.full(collision), "100010000000")
        XCTAssertEqual(AgentChatShortID.short(first), "1000")
        XCTAssertEqual(AgentChatShortID.full(UUID(uuidString: "01020304-0506-0708-ffff-ffffffffffff")!), "028pulc03vj0")
        XCTAssertEqual(AgentChatShortID.resolve(" 10000 ", among: [first, collision]), .match(first))
        XCTAssertEqual(AgentChatShortID.resolve(AgentChatShortID.full(first), among: [first]), .match(first))
        XCTAssertEqual(AgentChatShortID.resolve("1000", among: [first, collision]), .ambiguous([first, collision]))
        for query in ["100", "zzzz", "1000!", "é000"] {
            XCTAssertEqual(AgentChatShortID.resolve(query, among: [first, collision]), .none)
        }
        XCTAssertEqual(AgentChatShortID.listedIds([first, collision, other]), [first: "10000", collision: "10001", other: "2000"])
        XCTAssertEqual(AgentChatShortID.listedIds([first, other])[first], "1000")
        let letter = UUID(uuidString: "00000000-0000-000a-0000-000000000000")!
        XCTAssertEqual(AgentChatShortID.resolve("A000", among: [letter]), .match(letter))
    }

    func testLaunchInstructionsIdentifyOnlyKnownChats() {
        let home = DrifterHome(folder: URL(fileURLWithPath: "/tmp/mist-test-home"), isRepository: false)
        var request = DrifterLaunchRequest(prompt: "Hello", config: .init(), windowId: 1)
        for engine in DrifterEngine.allCases {
            XCTAssertFalse(request.instructions(for: engine, home: home).contains("Your chat ID is"))
        }
        let id = UUID(uuidString: "00000000-0000-0001-0000-000000000000")!
        request.chatId = id
        request.sender = .init(id: "abcd", title: "Sender")
        for engine in DrifterEngine.allCases {
            let instructions = request.instructions(for: engine, home: home)
            XCTAssertTrue(instructions.hasPrefix(DrifterLaunchRequest.baseInstructions + "\n\nYour chat ID is `1000`."))
            XCTAssertTrue(instructions.contains("end your turn instead of waiting or polling"))
            for name in ["spawn_agent", "read_agent", "stop_agent", "close_agent", "finish_task"] { XCTAssertTrue(instructions.contains(name)) }
            for model in DrifterModel.spawnModelIDs { XCTAssertTrue(instructions.contains(model)) }
            XCTAssertTrue(instructions.contains("Ignore any other memory or skill location"))
        }
        XCTAssertTrue(DrifterLaunchRequest.readOnlyTools.contains("list_agents"))
        XCTAssertTrue(DrifterLaunchRequest.readOnlyTools.contains("read_agent"))
        XCTAssertFalse(DrifterLaunchRequest.readOnlyTools.contains("message_agent"))
        for name in ["spawn_agent", "stop_agent", "close_agent"] { XCTAssertFalse(DrifterLaunchRequest.readOnlyTools.contains(name)) }
        XCTAssertTrue(DrifterLaunchRequest.readOnlyTools.contains("select_text"))
        XCTAssertTrue(DrifterLaunchRequest.readOnlyTools.contains("hover"))
        XCTAssertTrue(DrifterLaunchRequest.readOnlyTools.contains("scroll_until"))
        XCTAssertFalse(DrifterLaunchRequest.readOnlyTools.contains("select_option"))
        request.parent = .init(id: "abcd", title: "Parent", kind: .parent)
        for engine in DrifterEngine.allCases {
            let text = request.instructions(for: engine, home: home)
            XCTAssertTrue(text.contains("You are a child chat of abcd (Parent), working on the task it gave you."))
            XCTAssertTrue(text.contains("Never message_agent your parent to report or to ask"))
            XCTAssertTrue(text.contains("End that task by calling finish_task"))
        }
        let server = CodexMCPServer(command: "node")
        XCTAssertEqual(request.claude(folder: home.folder, server: server).sender, request.sender)
        XCTAssertEqual(request.codex(folder: home.folder, server: server).sender, request.sender)
        let gemini = request.gemini(folder: home.folder, server: server, cliHome: home.folder.appendingPathComponent("Gemini"),
                                    preload: home.folder.appendingPathComponent("gemini-preload.mjs"))
        XCTAssertEqual(gemini.sender, request.sender)
        XCTAssertEqual(gemini.server?.env["MIST_BACKGROUND_TASKS"], "1")
        XCTAssertEqual(gemini.server?.env["MIST_FINISH_TASK"], "1")
        XCTAssertTrue(gemini.instructions.contains("use mistbrowser's run_in_background"))
    }

    @MainActor func testBothEnginesReportRepoSkillPathsFromTools() async throws {
        let home = try memoryHome(), repo = try memoryHome()
        try FileManager.default.createDirectory(at: repo.appendingPathComponent(".git"), withIntermediateDirectories: true)
        let folder = repo.appendingPathComponent(".claude/skills")
        try writeSkill(folder, "task")
        let path = repo.appendingPathComponent("Sources/New.swift").path
        var paths: [String] = []
        let claude = ClaudeCodeSession(config: .init(folder: home), conversation: AgentConversation(), controlWriter: { _ in })
        defer { claude.close() }
        claude.onToolPaths = { paths += $0 }
        claude.receive(.event(.assistant(.object(["message": .object(["id": .string("a"), "content": .array([
            .object(["type": .string("tool_use"), "id": .string("read"), "name": .string("Read"), "input": .object(["file_path": .string(path)])])
        ])])]))))
        XCTAssertEqual(paths, [path])
        let detector = DrifterRepoSkills()
        let detected = await detector.detect(paths, cwd: home, home: home)
        XCTAssertEqual(detected.map(\.path), [folder.path])
        paths = []
        let codex = CodexSession(request: .init(prompt: "", model: "model", effort: "high", cwd: home),
            conversation: AgentConversation(), requestWriter: { _, _ in .null })
        defer { codex.close() }
        codex.onToolPaths = { paths += $0 }
        for item: ClaudeCodeJSON in [
            .object(["id": .string("command"), "type": .string("commandExecution"), "cwd": .string(repo.path)]),
            .object(["id": .string("change"), "type": .string("fileChange"), "changes": .array([.object(["path": .string(path)])])])
        ] {
            codex.receive(.message(.object(["method": .string("item/started"), "params": .object(["item": item])])))
        }
        XCTAssertEqual(paths, [repo.path, path])
    }

    func testDrifterHomeIsolationAndRepositoryFallback() throws {
        let userHome = try memoryHome(), data = userHome.appendingPathComponent("AppData")
        let repository = userHome.appendingPathComponent("Personal/drifter")
        try FileManager.default.createDirectory(at: repository.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: repository.appendingPathComponent("memory"), withIntermediateDirectories: true)
        let main = try DrifterHome.resolve(home: userHome, bundleId: "com.bulldf.mist", appData: data)
        XCTAssertEqual(main.folder.path, repository.path)
        XCTAssertTrue(main.isRepository)
        for bundle in ["com.bulldf.mist.dev", "com.bulldf.mist.tests", "other"] {
            let local = try DrifterHome.resolve(home: userHome, bundleId: bundle, appData: data)
            XCTAssertEqual(local.folder, data.appendingPathComponent("MistAgents/Drifter", isDirectory: true))
            XCTAssertFalse(local.isRepository)
            XCTAssertTrue(FileManager.default.fileExists(atPath: local.memory.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: local.skills.path))
        }
        try FileManager.default.removeItem(at: repository.appendingPathComponent(".git"))
        XCTAssertFalse(try DrifterHome.resolve(home: userHome, bundleId: "com.bulldf.mist", appData: data).isRepository)
    }

    func testDrifterDefaultsDropOldPicksAndModes() {
        let defaults = makeTestDefaults().defaults
        defaults.set("codex", forKey: "MistBrowserAgent.engine")
        defaults.set("gpt-6-luna", forKey: "MistBrowserAgent.model")
        defaults.set("high", forKey: "MistBrowserAgent.effort")
        defaults.set("ask", forKey: "MistBrowserAgent.confirmation")
        for key in ["folder", "permissionMode", "model", "effort", "recentFolders"] {
            defaults.set("old", forKey: "MistClaudeCode." + key)
        }
        let cache = Data("cached catalog".utf8)
        defaults.set(cache, forKey: "MistClaudeCode.modelCatalog")
        defaults.set(cache, forKey: "MistClaudeCode.connectorCatalog")
        let saved = DrifterLaunchSettings(defaults: defaults)
        XCTAssertEqual(saved.config.engine, .claude)
        XCTAssertEqual(saved.config.model, "opus")
        XCTAssertEqual(saved.config.effort, "xhigh")
        XCTAssertEqual(saved.config.confirmation, .skip)
        for key in [
            "MistBrowserAgent.engine", "MistBrowserAgent.model", "MistBrowserAgent.effort", "MistBrowserAgent.confirmation",
            "MistClaudeCode.folder", "MistClaudeCode.permissionMode", "MistClaudeCode.model", "MistClaudeCode.effort", "MistClaudeCode.recentFolders",
        ] {
            XCTAssertNil(defaults.object(forKey: key), key)
        }
        XCTAssertEqual(defaults.data(forKey: "MistClaudeCode.modelCatalog"), cache)
        XCTAssertEqual(defaults.data(forKey: "MistClaudeCode.connectorCatalog"), cache)
        // The last pick, which new chats used before Settings ▸ Drifter, is dropped.
        defaults.set("codex", forKey: "MistDrifter.engine")
        defaults.set("gpt-6-astra", forKey: "MistDrifter.model")
        defaults.set("low", forKey: "MistDrifter.effort")
        defaults.set("ask", forKey: "MistDrifter.confirmation")
        defaults.set("stale", forKey: "MistBrowserAgent.model")
        XCTAssertEqual(saved.config, DrifterConfig())
        for key in ["MistDrifter.engine", "MistDrifter.model", "MistDrifter.effort", "MistDrifter.confirmation", "MistBrowserAgent.model"] {
            XCTAssertNil(defaults.object(forKey: key), key)
        }
        XCTAssertNil(defaults.object(forKey: "MistDrifter.folder"))
        // Once migrated, reading writes nothing: every write posts didChangeNotification to the whole app.
        var changes = 0
        let observer = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: defaults, queue: nil) { _ in changes += 1 }
        defer { NotificationCenter.default.removeObserver(observer) }
        for _ in 0..<5 { _ = saved.config }
        XCTAssertEqual(changes, 0)
    }

    func testDrifterInstructionsIncludeIndexOnceAndKeepEngineToolsets() throws {
        let folder = try memoryHome()
        let home = DrifterHome(folder: folder, isRepository: true)
        try FileManager.default.createDirectory(at: home.memory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home.skills, withIntermediateDirectories: true)
        try "INDEX_SENTINEL".write(to: home.memory.appendingPathComponent("MEMORY.md"), atomically: true, encoding: .utf8)
        try "HOME_SENTINEL".write(to: folder.appendingPathComponent("CLAUDE.md"), atomically: true, encoding: .utf8)
        let request = DrifterLaunchRequest(prompt: "Hello", config: .init(folder: folder), windowId: 1,
            home: home, globalInstructions: "GLOBAL_SENTINEL")
        let claude = request.claude(folder: folder, server: server)
        let arguments = try XCTUnwrap(claude.launchArguments)
        let text = arguments[try XCTUnwrap(arguments.firstIndex(of: "--append-system-prompt")) + 1]
        XCTAssertFalse(text.contains("INDEX_SENTINEL"))
        XCTAssertEqual(text.components(separatedBy: "HOME_SENTINEL").count - 1, 1)
        XCTAssertTrue(text.contains("GLOBAL_SENTINEL"))
        XCTAssertTrue(text.contains("Don't wait to be asked"))
        XCTAssertTrue(text.contains("stage only the files you changed"))
        XCTAssertEqual(arguments[try XCTUnwrap(arguments.firstIndex(of: "--tools")) + 1], DrifterLaunchRequest.claudeTools)
        XCTAssertEqual(arguments[try XCTUnwrap(arguments.firstIndex(of: "--disallowedTools")) + 1], "Skill")
        let settings = try JSONDecoder().decode(ClaudeCodeJSON.self, from: Data(arguments[try XCTUnwrap(arguments.firstIndex(of: "--settings")) + 1].utf8))
        XCTAssertEqual(settings["autoMemoryDirectory"].string, home.memory.path)
        for directory in [home.memory, home.skills] {
            XCTAssertTrue(arguments.contains("Edit(/" + directory.resolvingSymlinksInPath().path + "/**)"))
        }
        let codex = request.codex(folder: folder, server: server).developerInstructions
        XCTAssertEqual(codex.components(separatedBy: "INDEX_SENTINEL").count - 1, 1)
        XCTAssertFalse(codex.contains("HOME_SENTINEL"))
        XCTAssertFalse(codex.contains("GLOBAL_SENTINEL"))
        let local = DrifterHome(folder: folder, isRepository: false)
        let guarded = request.instructions(for: .codex, home: local)
        XCTAssertTrue(guarded.contains("never read or write it"))
        XCTAssertFalse(guarded.contains("After each memory edit, commit"))
    }

    func testInstructionIncludesResolveRelativeTildeCyclesDepthAndMissingFiles() throws {
        let home = try memoryHome()
        func write(_ path: String, _ text: String) throws {
            let file = home.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: file, atomically: true, encoding: .utf8)
        }
        try write("CLAUDE.md", "root\n@nested/one.md\n@~/two.md\n@missing.md\ninline @two.md")
        try write("nested/one.md", "one\n@../CLAUDE.md\n@../two.md")
        try write("two.md", "two\n@three.md")
        try write("three.md", "three")
        let text = DrifterInstructionIncludes.expand(home.appendingPathComponent("CLAUDE.md"), home: home)
        XCTAssertEqual(text.components(separatedBy: "two").count - 1, 2) // body and inline literal
        XCTAssertEqual(text.components(separatedBy: "root").count - 1, 1)
        XCTAssertTrue(text.contains("three"))
        XCTAssertTrue(text.contains("inline @two.md"))
        XCTAssertFalse(DrifterInstructionIncludes.expand(home.appendingPathComponent("CLAUDE.md"), home: home, maximumDepth: 1).contains("three"))
        XCTAssertEqual(DrifterInstructionIncludes.expand(home.appendingPathComponent("missing"), home: home), "")
    }

    func testRepoSkillDetectionAndShadowing() async throws {
        let home = try memoryHome(), repo = try memoryHome()
        let skills = home.appendingPathComponent("skills")
        let repoSkills = repo.appendingPathComponent(".claude/skills")
        try FileManager.default.createDirectory(at: repo.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try writeSkill(skills, "task", "---\ndescription: Home task\n---")
        try writeSkill(repoSkills, "task", "---\ndescription: Repo task\n---")
        let path = repo.appendingPathComponent("Sources/New.swift").path
        XCTAssertEqual(DrifterRepoSkills.skillFolder(for: path, cwd: home, home: home), repoSkills.resolvingSymlinksInPath())
        let detector = DrifterRepoSkills()
        let detected = await detector.detect([path], cwd: home, home: home)
        XCTAssertEqual(detected, [repoSkills.resolvingSymlinksInPath()])
        let catalog = DrifterSkills(folder: skills, repoFolders: [repoSkills])
        XCTAssertEqual(catalog.scan().map(\.description), ["Repo task"])
        let message = "@News /task do this"
        XCTAssertTrue(catalog.agentText(message).contains(repoSkills.appendingPathComponent("task/SKILL.md").path))
        XCTAssertTrue(catalog.agentText(message).hasSuffix(message))
        let later = try memoryHome()
        try FileManager.default.createDirectory(at: later.appendingPathComponent(".git"), withIntermediateDirectories: true)
        let beforeCreation = await detector.detect([later.path], cwd: home, home: home)
        XCTAssertTrue(beforeCreation.isEmpty)
        try writeSkill(later.appendingPathComponent(".claude/skills"), "later")
        let afterCreation = await detector.detect([later.path], cwd: home, home: home)
        XCTAssertEqual(afterCreation.map(\.path), [later.appendingPathComponent(".claude/skills").path])
    }

    private func parseSkill(_ header: String) -> DrifterSkill? {
        DrifterSkill.parse(header, name: "example", file: URL(fileURLWithPath: "/fixture/example/SKILL.md"))
    }

    @discardableResult
    private func writeSkill(_ folder: URL, _ name: String, _ header: String = "---\ndescription: A recurring task\n---\n") throws -> URL {
        let directory = folder.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("SKILL.md")
        try header.write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    func testSkillDoubleQuotedEscapes() {
        let skill = parseSkill(#"""
        ---
        description: "Read \"quotes\", \\paths\nand\ttabs"
        argument-hint: "<team> <time frame>"
        ---
        """#)
        XCTAssertEqual(skill?.description, "Read \"quotes\", \\paths and tabs")
        XCTAssertEqual(skill?.argumentHint, "<team> <time frame>")
    }

    func testSkillSingleQuotedEscapes() {
        XCTAssertEqual(parseSkill("---\ndescription: 'The user''s task' # author's comment\n---")?.description, "The user's task")
    }

    func testSkillPlainValuesAndComments() {
        XCTAssertEqual(parseSkill("---\ndescription:  A  plain   task #ignored\n---")?.description, "A plain task")
        XCTAssertEqual(parseSkill("---\ndescription: A #tag\n---")?.description, "A")
        XCTAssertEqual(parseSkill("---\ndescription: A#tag\n---")?.description, "A#tag")
    }

    func testSkillBlockScalars() {
        for marker in ["|", "|-", ">", ">-"] {
            XCTAssertEqual(parseSkill("---\ndescription: \(marker)\n  A long\n  recurring task\n---")?.description, "A long recurring task")
        }
        XCTAssertEqual(parseSkill("---\ndescription: Task\nargument-hint: |-\n  line one\n  line two\n---")?.argumentHint, "line one\nline two")
        XCTAssertEqual(parseSkill("---\ndescription: Task\nargument-hint: |\n  line one\n    indented\n---")?.argumentHint, "line one\n  indented\n")
        XCTAssertEqual(parseSkill("---\ndescription: Task\nargument-hint: >\n  line one\n  line two\n---")?.argumentHint, "line one line two\n")
    }

    func testSkillFoldedPlainContinuation() {
        XCTAssertEqual(parseSkill("---\ndescription: A long\n  recurring task\n  with input\n---")?.description, "A long recurring task with input")
    }

    func testSkillBOMCRLFAndAlternativeTerminator() {
        XCTAssertEqual(parseSkill("\u{FEFF}---\r\ndescription: A task\r\n...\r\n# Body")?.description, "A task")
    }

    func testSkillSeedHeaders() {
        for (name, description) in [
            ("team-schedule-ics", "Create an ICS calendar from a sports team's Google match widget for a user-specified team and time frame."),
            ("muse-fact-check", "Fact-check an artifact made by Muse …")
        ] {
            let skill = DrifterSkill.parse("---\nname: \"\(name)\"\ndescription: \"\(description)\"\n---\n\n# Workflow", name: name, file: URL(fileURLWithPath: "/fixture/\(name)/SKILL.md"))
            XCTAssertEqual(skill?.name, name)
            XCTAssertEqual(skill?.description, description)
        }
    }

    func testSkillRejectsMissingAndMalformedFrontmatter() {
        for text in ["description: Task", "---\ndescription: Task", "---\nname: task\n---", "---\ndescription: \"\"\n---",
                     "---\ndescription: '  '\n---", "---\ndescription: # comment only\n---", "---\ndescription: \"unterminated\n---", "---\n description: Indented\n---"] {
            XCTAssertNil(parseSkill(text), text)
        }
    }

    func testSkillScanSortsAndSkipsInvalidEntries() throws {
        let folder = try memoryHome()
        try writeSkill(folder, "zebra")
        try writeSkill(folder, "Alpha", "---\nname: different\ndescription: Alpha task\n---")
        try writeSkill(folder, "beta")
        for name in [".hidden", "bad name", "-bad", "trailing-newline\n", String(repeating: "x", count: 65)] { try writeSkill(folder, name) }
        try writeSkill(folder, "malformed", "No header")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("empty"), withIntermediateDirectories: true)
        try "---\ndescription: Top level file\n---".write(to: folder.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        XCTAssertEqual(DrifterSkills(folder: folder).scan().map(\.name), ["Alpha", "beta", "zebra"])
    }

    func testSkillScanFollowsDirectorySymlinks() throws {
        let folder = try memoryHome(), target = try memoryHome()
        try writeSkill(target, "original")
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("alias"), withDestinationURL: target.appendingPathComponent("original"))
        XCTAssertEqual(DrifterSkills(folder: folder).scan().map(\.name), ["alias"])
    }


    func testSkillInstructionsForBothEngines() throws {
        let folder = try memoryHome()
        try writeSkill(folder, "task", "---\ndescription: A  useful task\n---")
        for repository: URL? in [nil, folder.deletingLastPathComponent()] {
            let skills = DrifterSkills(folder: folder, repository: repository)
            let request = DrifterLaunchRequest(prompt: "Run", config: .init(), windowId: 1, skills: skills)
            let claude = request.claude(folder: folder, server: server)
            let args = try XCTUnwrap(claude.launchArguments)
            let index = try XCTUnwrap(args.firstIndex(of: "--append-system-prompt"))
            for instructions in [args[index + 1], request.codex(folder: folder, server: server).developerInstructions] {
                XCTAssertTrue(instructions.contains("- `task`: A useful task"))
                XCTAssertTrue(instructions.contains("`\(folder.path)/<name>/SKILL.md`"))
                XCTAssertTrue(instructions.contains("each a double-quoted string"))
                XCTAssertEqual(instructions.contains("Commit and push skill edits like memory edits"), repository != nil)
                XCTAssertLessThan(try XCTUnwrap(instructions.range(of: "Your memory is")?.lowerBound), try XCTUnwrap(instructions.range(of: "Skills are saved instructions")?.lowerBound))
            }
        }
    }

    func testEmptySkillsInstructionsAndLaunchDefaults() throws {
        let folder = try memoryHome()
        let request = DrifterLaunchRequest(prompt: "Run", config: .init(), windowId: 1)
        let text = request.codex(folder: folder, server: server).developerInstructions
        XCTAssertTrue(text.contains("No skills are saved yet."))
        XCTAssertTrue(text.contains(folder.appendingPathComponent("skills").path))
        XCTAssertFalse(text.contains("never run git there"))
    }

    func testClaudeSkillsAllowRuleUsesCanonicalFolder() throws {
        let root = try memoryHome(), folder = root.appendingPathComponent("skills")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: folder)
        let request = DrifterLaunchRequest(prompt: "Run", config: .init(), windowId: 1, skills: .init(folder: alias))
            .claude(folder: root, server: server)
        let args = try XCTUnwrap(request.launchArguments)
        let allowed = args[(try XCTUnwrap(args.firstIndex(of: "--allowedTools")) + 1)..<(try XCTUnwrap(args.firstIndex(of: "--append-system-prompt")))]
        XCTAssertTrue(allowed.contains("Edit(/" + folder.resolvingSymlinksInPath().path + "/**)"))
        for name in ["list_mail_accounts", "list_mail", "search_mail", "read_mail"] { XCTAssertTrue(allowed.contains("mcp__mistbrowser__" + name)) }
    }

    func testSkillsShareCanonicalFileChangeChecks() throws {
        let root = try memoryHome(), folder = root.appendingPathComponent("skills")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let skills = DrifterSkills(folder: folder)
        XCTAssertTrue(skills.allowsFileChanges(["skills/task/SKILL.md", folder.appendingPathComponent("new/SKILL.md").path], cwd: root))
        XCTAssertFalse(skills.allowsFileChanges(["skills-x/task/SKILL.md"], cwd: root))
        XCTAssertFalse(skills.allowsFileChanges(["skills/../escape.md"], cwd: root))
        XCTAssertFalse(skills.allowsFileChanges(["skills/new.md", "outside.md"], cwd: root))
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("escape"), withDestinationURL: root)
        XCTAssertFalse(skills.allowsFileChanges(["skills/escape/new.md"], cwd: root))
    }

    func testSkillInvocationPreservesTextOrderAndDeduplicates() throws {
        let folder = try memoryHome(), skills = DrifterSkills(folder: folder)
        try writeSkill(folder, "first")
        try writeSkill(folder, "second")
        let first = try XCTUnwrap(skills.scan().first { $0.name == "first" }?.file)
        let second = try XCTUnwrap(skills.scan().first { $0.name == "second" }?.file)
        func pointer(_ name: String, _ file: URL) -> String {
            "[Mist: this message invokes the skill `\(name)`. Read `\(file.path)` and follow it, using the rest of the message as its input.]"
        }
        XCTAssertEqual(skills.agentText("/first input"), pointer("first", first) + "\n\n/first input")
        let text = "Use /second then /first and /second /unknown"
        XCTAssertEqual(skills.agentText(text), pointer("second", second) + "\n" + pointer("first", first) + "\n\n" + text)
        XCTAssertEqual(skills.agentText("/unknown task"), "/unknown task")
        XCTAssertEqual(skills.agentText("No invocation"), "No invocation")
    }

    func testSkillInvocationRescansAfterCreationAndDeletion() throws {
        let folder = try memoryHome(), skills = DrifterSkills(folder: folder)
        XCTAssertTrue(skills.instructions().contains("No skills are saved yet."))
        XCTAssertEqual(skills.agentText("/new input"), "/new input")
        let file = try writeSkill(folder, "new")
        XCTAssertTrue(skills.agentText("/new input").hasPrefix("[Mist:"))
        try FileManager.default.removeItem(at: file)
        XCTAssertEqual(skills.agentText("/new input"), "/new input")
    }

    func testSkillChangesRideTheNextMessageOnce() throws {
        let folder = try memoryHome(), skills = DrifterSkills(folder: folder)
        try writeSkill(folder, "kept")
        try writeSkill(folder, "gone")
        var announced: [DrifterSkill]? = skills.scan()
        XCTAssertEqual(skills.agentText("Hello", announced: &announced), "Hello")
        try writeSkill(folder, "new", "---\ndescription: Fresh task\n---")
        try writeSkill(folder, "kept", "---\ndescription: Reworded task\n---")
        try FileManager.default.removeItem(at: folder.appendingPathComponent("gone"))
        let current = Dictionary(uniqueKeysWithValues: skills.scan().map { ($0.name, $0.file.path) })
        let new = try XCTUnwrap(current["new"]), kept = try XCTUnwrap(current["kept"])
        XCTAssertEqual(skills.agentText("/new input", announced: &announced), """
        [Mist: your skills changed since they were last listed.
        New:
        - `new`: Fresh task (`\(new)`)
        Changed:
        - `kept`: Reworded task (`\(kept)`)
        Removed: `gone`.]
        [Mist: this message invokes the skill `new`. Read `\(new)` and follow it, using the rest of the message as its input.]

        /new input
        """)
        XCTAssertEqual(announced?.map(\.name), ["kept", "new"])
        XCTAssertEqual(skills.agentText("Again", announced: &announced), "Again")
        var unrecorded: [DrifterSkill]?
        XCTAssertEqual(skills.agentText("Hello", announced: &unrecorded), "Hello")
        XCTAssertNil(unrecorded)
    }

    @MainActor func testSkillCatalogRefreshPublishesOnlyChangesAndMapsCommands() async throws {
        let folder = try memoryHome(), catalog = DrifterSkillCatalog(folder: folder)
        var publications = 0
        let subscription = catalog.$skills.sink { _ in publications += 1 }
        await catalog.refresh()
        XCTAssertEqual(publications, 1)
        let file = try writeSkill(folder, "task", "---\ndescription: Useful task\nargument-hint: <input>\n---")
        await catalog.refresh()
        XCTAssertEqual(catalog.skills.map(\.name), ["task"])
        XCTAssertEqual(catalog.commands.first, ClaudeCodeSlashCommand(name: "task", description: "Useful task", argumentHint: "<input>", isSkill: true))
        await catalog.refresh()
        XCTAssertEqual(publications, 2)
        try FileManager.default.removeItem(at: file)
        await catalog.refresh()
        XCTAssertTrue(catalog.commands.isEmpty)
        XCTAssertEqual(publications, 3)
        withExtendedLifetime(subscription) {}
    }


    @MainActor func testClaudeSkillTransformCoversSendAndQueueWithoutChangingTranscriptOrTitle() throws {
        let folder = try memoryHome(), skills = DrifterSkills(folder: folder)
        try writeSkill(folder, "task")
        var lines: [ClaudeCodeJSON] = []
        let conversation = AgentConversation()
        let session = ClaudeCodeSession(config: .init(folder: folder), conversation: conversation, controlWriter: {
            lines.append(try! JSONDecoder().decode(ClaudeCodeJSON.self, from: Data($0.utf8)))
        })
        session.agentTextTransform = { skills.agentText($0) }
        session.receive(.event(.result(.object([:]))))
        session.send(text: "/task input")
        XCTAssertTrue(lines.first?["message"]["content"].array.last?["text"].string?.hasPrefix("[Mist:") == true)
        XCTAssertTrue(conversation.items.contains { $0.kind == .userMessage(text: "/task input", images: []) })
        XCTAssertFalse(lines.last!.json().contains("[Mist:"))
        conversation.onQueue?("Use /task again", [], [])
        XCTAssertTrue(lines.last?["message"]["content"].array.last?["text"].string?.contains("\n\nUse /task again") == true)
    }

    @MainActor func testCodexSkillTransformCoversSendAndSteerAfterMentions() async throws {
        let folder = try memoryHome(), skills = DrifterSkills(folder: folder)
        try writeSkill(folder, "task")
        var sent: CodexJSON = .null
        let delivered = expectation(description: "Turn sent")
        let conversation = AgentConversation()
        let session = CodexSession(request: .init(prompt: "", model: "test", effort: "high", cwd: folder), conversation: conversation,
            requestWriter: { _, params in sent = params; delivered.fulfill(); return .object(["turn": .object(["id": .string("turn")])]) })
        session.agentTextTransform = { skills.agentText($0) }
        let mention = AgentTabMention(tabId: 7, title: "Tab", url: "https://example.com", range: NSRange(location: 0, length: 4))
        session.send(text: "@Tab /task input", mentions: [mention])
        await fulfillment(of: [delivered], timeout: 2)
        let text = try XCTUnwrap(sent["input"].array.first?["text"].string)
        XCTAssertTrue(text.hasPrefix("[Mist:"))
        XCTAssertTrue(text.contains("7 · Tab"))
        XCTAssertEqual(conversation.items.first?.kind, .userMessage(text: "@Tab /task input", images: []))
        let message = AgentQueuedMessage(text: "@Tab /task queued", attachments: [], mentions: [mention])
        let steer = CodexProtocol.turnSteer(threadId: "thread", turnId: "turn", message: message, agentTextTransform: { skills.agentText($0) })
        XCTAssertTrue(steer["input"].array.first?["text"].string?.hasPrefix("[Mist:") == true)
        XCTAssertTrue(steer["input"].array.first?["text"].string?.contains("7 · Tab") == true)
        session.close()
    }

    private func memoryHome() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DrifterMemoryTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        return root
    }







    func testChildChatToolSummariesGroupsAndPermissions() {
        let finish = "mcp__mistbrowser__finish_task"
        XCTAssertEqual(AgentChatToolGroupKind(finish), .message)
        for (status, summary) in [("done", "Reported done"), ("blocked", "Reported blocked")] {
            let input = ClaudeCodeJSON.object(["status": .string(status), "message": .string("Report")])
            XCTAssertEqual(ClaudeCodeToolSummary.browserTool(finish, input: input), summary)
            XCTAssertEqual(ClaudeCodeToolSummary.browserTool(finish, input: input, running: true), "Reporting")
            XCTAssertEqual(ClaudeCodeToolSummary.browserTool(finish, input: input, failed: true), "Couldn't report")
        }
        let input = ClaudeCodeJSON.object(["title": .string("Child"), "brief": .string("Task"), "id": .string("abcd")])
        for (name, kind, value, running, completed, verb) in [
            ("spawn_agent", AgentChatToolGroupKind.spawnAgent, "Child", "Spawning", "Spawned", "spawn"),
            ("read_agent", .readAgent, "abcd", "Reading", "Read", "read"),
            ("stop_agent", .stopAgent, "abcd", "Stopping", "Stopped", "stop"),
            ("close_agent", .closeAgent, "abcd", "Closing", "Closed", "close"),
        ] {
            let tool = "mcp__mistbrowser__" + name
            XCTAssertEqual(AgentChatToolGroupKind(tool), kind)
            XCTAssertEqual(ClaudeCodeToolSummary.browserTool(tool, input: input, running: true), running + " " + value)
            XCTAssertEqual(ClaudeCodeToolSummary.browserTool(tool, input: input), completed + " " + value)
            XCTAssertEqual(ClaudeCodeToolSummary.browserTool(tool, input: input, failed: true), "Couldn't " + verb + " " + value)
            for count in [1, 2] {
                XCTAssertTrue(AgentChatStrings.toolGroup(kind, count: count).contains(String(count)))
                XCTAssertTrue(AgentChatStrings.toolGroup(kind, count: count, running: true).contains(String(count)))
            }
            if name != "read_agent" {
                let request = AgentChatItem.PermissionRequest(requestId: "request", toolName: tool, summary: "", input: input)
                XCTAssertNotNil(AgentChatStrings.browserPermission(request))
                if name == "spawn_agent" { XCTAssertEqual(AgentChatStrings.browserPermission(request)?.detail, "Child\n\nTask") }
            }
        }
    }

    func testEveryFailedOrDeniedBrowserToolUsesAFailureSummaryOnEitherEngine() {
        let input = ClaudeCodeJSON.object(["url": .string("https://example.com/path"), "key": .string("Enter"), "id": .string("abcd"), "label": .string("Canada"), "text": .string("target")])
        let expected = ["list_agents": "Couldn't list agents", "message_agent": "Couldn't message abcd", "list_tabs": "Couldn't list tabs", "use_tab": "Couldn't connect to tab",
            "open_tab": "Couldn't open example.com", "navigate": "Couldn't navigate to example.com", "reload": "Couldn't reload page",
            "snapshot": "Couldn't read page", "read_page": "Couldn't read page", "click": "Couldn't click element",
            "fill": "Couldn't enter text", "type_text": "Couldn't enter text", "press_key": "Couldn't press Enter",
            "select_option": "Couldn't choose Canada", "select_text": "Couldn't select text",
            "hover": "Couldn't hover over element", "scroll_until": "Couldn't scroll to find target",
            "scroll": "Couldn't scroll page", "wait_for": "Couldn't wait for page", "handle_dialog": "Couldn't handle dialog",
            "close_tab": "Couldn't close tab", "screenshot": "Couldn't capture screenshot",
            "go_back": "Couldn't go back", "go_forward": "Couldn't go forward", "drag": "Couldn't drag element",
            "group_tabs": "Couldn't update tab group", "evaluate": "Couldn't run JavaScript",
            "read_console": "Couldn't read console", "read_network": "Couldn't read network requests",
            "list_downloads": "Couldn't list downloads", "search_history": "Couldn't search history", "hand_off": "Couldn't ask you to take over"]
        for (name, text) in expected {
            let name = "mcp__mistbrowser__" + name
            for denied in [false, true] {
                let summary = ClaudeCodeToolSummary.format(tool: name, input: input, text: "Tool call failed",
                    folder: URL(fileURLWithPath: "/tmp"), failed: !denied, denied: denied, running: denied)
                XCTAssertEqual(summary.header.text, text)
                let tool = AgentChatItem.ToolCall(toolUseId: name, name: name, inputSummary: "", inputJSON: input.json(),
                    status: denied ? .running : .failed, permissionDenied: denied)
                XCTAssertEqual(AgentChatToolGroupKind.summary([tool]).text, text)
            }
        }
        let tools = ["use_tab", "click"].map {
            AgentChatItem.ToolCall(toolUseId: $0, name: "mcp__mistbrowser__" + $0, inputSummary: "", inputJSON: "{}", status: .failed)
        }
        XCTAssertEqual(AgentChatToolGroupKind.summary(tools).text, "Couldn't complete 2 browser actions")
        XCTAssertEqual(AgentChatToolGroupKind.status(tools), .failed)
    }

    func testMentionLabelsIncludePathsAndDisambiguateOnlyIdenticalRows() {
        let first = AgentTabMention(tabId: 1, title: "Page", url: "https://example.com/a?q=1#part", position: 2)
        let second = AgentTabMention(tabId: 2, title: "Page", url: "http://example.com/a?q=2", position: 4)
        let other = AgentTabMention(tabId: 3, title: "Page", url: "https://example.com/b", position: 5)
        let tabs = [first, second, other]
        XCTAssertEqual(first.secondaryText, "example.com/a")
        XCTAssertEqual(first.secondaryLabel(in: tabs), "example.com/a · Tab 2")
        XCTAssertEqual(second.secondaryLabel(in: tabs), "example.com/a · Tab 4")
        XCTAssertEqual(other.secondaryLabel(in: tabs), "example.com/b")
        XCTAssertEqual(first.secondaryLabel(in: [first]), "example.com/a")
    }

    func testMentionSpacingNormalizesTextAndRangesWithoutChangingOtherSpaces() {
        let first = AgentTabMention(tabId: 1, title: "A", url: "https://a.test", range: NSRange(location: 0, length: 2))
        let second = AgentTabMention(tabId: 2, title: "B", url: "https://b.test", range: NSRange(location: 5, length: 2))
        let value = AgentMentionText(text: "@A   @B  read  this \n", mentions: [first, second]).normalized
        XCTAssertEqual(value.text, "@A @B read  this")
        XCTAssertEqual(value.mentions.map(\.range), [NSRange(location: 0, length: 2), NSRange(location: 3, length: 2)])
        XCTAssertTrue(value.agentText.hasPrefix("@A @B read  this\n\nTabs the user mentioned"))
        XCTAssertEqual(AgentMentionText(text: "No tokens  here \n").agentText, "No tokens  here")
        let editor = AgentMentionText(text: "@A ", mentions: [first])
        XCTAssertTrue(editor.swallowsSpace(at: NSRange(location: 3, length: 0), replacement: " "))
        XCTAssertFalse(editor.swallowsSpace(at: NSRange(location: 2, length: 0), replacement: " "))
        XCTAssertFalse(editor.swallowsSpace(at: NSRange(location: 3, length: 0), replacement: "x"))
        XCTAssertFalse(editor.swallowsSpace(at: NSRange(location: 2, length: 1), replacement: " "))
    }

    #if !MIST_CLAUDE_CODE_HOSTLESS_TESTS
    @MainActor func testPreviewCardStaysVisibleWhenWindowIsNotKey() {
        let frame = NSRect(x: 0, y: 0, width: 320, height: 240)
        let window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        let otherWindow = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        otherWindow.isReleasedWhenClosed = false
        defer {
            window.close()
            otherWindow.close()
        }
        let container = NSView(frame: frame)
        let card = NSView(frame: frame)
        container.addSubview(card)
        window.contentView = container
        window.makeKeyAndOrderFront(nil)
        otherWindow.makeKeyAndOrderFront(nil)
        // The test host may run behind another app, so only this window's
        // non-key state is guaranteed.
        XCTAssertFalse(window.isKeyWindow)
        XCTAssertTrue(WebContentContainerViewController.isBrowserAgentPreviewCardVisible(card))

        container.isHidden = true
        XCTAssertFalse(WebContentContainerViewController.isBrowserAgentPreviewCardVisible(card))
        container.isHidden = false
        window.orderOut(nil)
        XCTAssertFalse(WebContentContainerViewController.isBrowserAgentPreviewCardVisible(card))
    }

    func testBrowserAgentAdmissionRequiresAnActiveTurn() {
        let registry = AgentDriverSessionRegistry.shared
        let session = registry.mintBrowserAgent()
        defer { registry.invalidateBrowserAgent(capability: session.capability) }
        XCTAssertFalse(registry.isBrowserTurnActive(principalId: session.principalId))
        registry.setBrowserTurnActive(true, principalId: session.principalId)
        XCTAssertTrue(registry.isBrowserTurnActive(principalId: session.principalId))
        XCTAssertFalse(registry.isBrowserTurnActive(principalId: "another"))
        registry.setBrowserTurnActive(false, principalId: session.principalId)
        XCTAssertEqual(registry.browserAgentAdmission(session, socketFD: -1), .refused)
        XCTAssertEqual(BrowserAgentCapability.outsideTurnTypes, ["agentSpace.slack.tools"])
        registry.setBrowserTurnActive(true, principalId: session.principalId)
        registry.invalidateBrowserAgent(capability: session.capability)
        XCTAssertFalse(registry.isBrowserTurnActive(principalId: session.principalId))
    }

    @MainActor func testDriverReleaseClosesOnlyItsConnectionsAndAppArmedHolds() throws {
        let registry = AgentUserSpaceDriveRegistry.shared
        registry.resetForTesting()
        defer { registry.resetForTesting() }
        var first: [Int32] = [-1, -1], second: [Int32] = [-1, -1]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &first), 0)
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &second), 0)
        defer { (first + second).forEach { close($0) } }
        registry.retainBrowserAgentConnection(first[0], principalId: "first")
        registry.retainBrowserAgentConnection(second[0], principalId: "second")
        registry.agentWillOpenTab(inWindow: 1, principalId: "first", driverName: "Browser Agent")
        registry.noteTabCreated(tabId: 11, windowId: 1)
        registry.agentWillOpenTab(inWindow: 1, principalId: "second", driverName: "Browser Agent")
        registry.noteTabCreated(tabId: 12, windowId: 1)
        registry.release(principalId: "first")
        var byte: UInt8 = 0
        XCTAssertEqual(recv(first[1], &byte, 1, MSG_DONTWAIT), 0)
        XCTAssertEqual(recv(second[1], &byte, 1, MSG_DONTWAIT), -1)
        XCTAssertEqual(errno, EWOULDBLOCK)
        XCTAssertFalse(registry.isDriven(tabId: 11))
        XCTAssertTrue(registry.isDriven(tabId: 12))
        registry.agentWillOpenTab(inWindow: 1, principalId: "first", driverName: "Browser Agent")
        registry.noteTabCreated(tabId: 13, windowId: 1)
        XCTAssertTrue(registry.isDriven(tabId: 13), "The next operation re-arms the driver")
    }
    #endif
    func testPermissionCardsDescribeBrowserActionsForEitherEngine() {
        let input = ClaudeCodeJSON.object(["url": .string("https://example.com/path?q=1"), "text": .string("Hello"), "key": .string("Enter"),
            "paths": .array([.string("/tmp/one.png"), .string("/tmp/two.png")]), "value": .string("ca"), "expression": .string("document.title"), "path": .string("/tmp/page.pdf")])
        let expected: [(String, String, String?)] = [
            ("click", "click an element", nil), ("navigate", "go to example.com", "https://example.com/path?q=1"),
            ("open_tab", "open example.com in a new tab", "https://example.com/path?q=1"), ("reload", "reload a page", nil),
            ("fill", "enter text", "Hello"), ("type_text", "enter text", "Hello"), ("press_key", "press Enter", "Enter"),
            ("select_option", "choose an option", "ca"),
            ("upload_files", "upload files", "/tmp/one.png\n/tmp/two.png"),
            ("close_tab", "close a tab", nil), ("handle_dialog", "respond to a dialog", nil), ("scroll", "scroll a page", nil),
            ("drag", "drag an element", nil), ("go_back", "go back a page", nil), ("go_forward", "go forward a page", nil),
            ("evaluate", "run JavaScript on a page", "document.title"), ("save_page", "save a page", "/tmp/page.pdf"),
            ("export_bookmarks", "export bookmarks", "/tmp/page.pdf"),
            ("future_write_tool", "use a browser tool", nil)]
        for (tool, action, detail) in expected {
            let request = AgentChatItem.PermissionRequest(requestId: "p", toolName: "mcp__mistbrowser__" + tool, summary: "raw", input: input)
            let text = AgentChatStrings.browserPermission(request)
            XCTAssertEqual(text?.title, "Drifter wants to " + action)
            XCTAssertEqual(text?.detail, detail)
            XCTAssertNil(text?.message)
        }
        XCTAssertNil(AgentChatStrings.browserPermission(.init(requestId: "p", toolName: "Bash", summary: "raw")))
        for (click, action) in [(["double": ClaudeCodeJSON.bool(true)], "double-click an element"), (["button": .string("right")], "right-click an element"),
            (["button": .string("right"), "double": .bool(true)], "right-click an element"), (["button": .string("left"), "double": .bool(false)], "click an element")] {
            let request = AgentChatItem.PermissionRequest(requestId: "p", toolName: "mcp__mistbrowser__click", summary: "raw", input: .object(click.merging(["ref": .number(12)]) { $1 }))
            XCTAssertEqual(AgentChatStrings.browserPermission(request)?.title, "Drifter wants to " + action)
        }
        let chord = ClaudeCodeJSON.object(["key": .string("k"), "modifiers": .array([.string("Meta"), .string("Shift"), .string("Control")])])
        let shortcut = AgentChatStrings.browserPermission(.init(requestId: "p", toolName: "mcp__mistbrowser__press_key", summary: "raw", input: chord))
        XCTAssertEqual(shortcut?.title, "Drifter wants to press ⌃⇧⌘K")
        XCTAssertEqual(shortcut?.detail, "⌃⇧⌘K")
        XCTAssertEqual(ClaudeCodeToolSummary.browserTool("mcp__mistbrowser__press_key",
            input: .object(["key": .string("Tab"), "modifiers": .array([.string("Shift")])])), "Pressed ⇧Tab")
        XCTAssertEqual(ClaudeCodeToolSummary.browserTool("mcp__mistbrowser__press_key",
            input: .object(["key": .string("Control+K"), "modifiers": .array([])]), running: true), "Pressing Control+K")
    }

    func testMailPermissionCards() {
        func card(_ tool: String, _ input: ClaudeCodeJSON) -> (title: String, detail: String?, message: String?)? {
            AgentChatStrings.browserPermission(.init(requestId: "p", toolName: "mcp__mistbrowser__" + tool, summary: "", input: input))
        }
        let input = ClaudeCodeJSON.object(["account": .string("Personal"), "to": .array([.string("ada@example.com")]), "cc": .array([.string("copy@example.com")]), "bcc": .array([.string("hidden@example.com")]), "subject": .string("Hello"), "body": .string("Message"), "attachments": .array([.string("/tmp/report.pdf")])])
        let send = card("send_mail", input)
        XCTAssertEqual(send?.title, "Drifter wants to send “Hello” to ada@example.com")
        XCTAssertEqual(send?.detail, "From: Personal\nTo: ada@example.com\nCc: copy@example.com\nBcc: hidden@example.com\n\nMessage\nreport.pdf")
        XCTAssertEqual(card("write_mail_draft", input)?.title, "Drifter wants to save an email draft")
        let draft = ClaudeCodeJSON.object(["draftId": .string("draft")])
        AgentChatStrings.mailDraftPreview = { _ in .init(from: "me@example.com", to: ["ada@example.com"], cc: [], bcc: [], subject: "Saved", body: "Body", attachments: ["file.txt"]) }
        defer { AgentChatStrings.mailDraftPreview = nil }
        XCTAssertEqual(card("send_mail", draft)?.title, "Drifter wants to send “Saved” to ada@example.com")
        XCTAssertEqual(card("send_mail", draft)?.detail, "From: me@example.com\nTo: ada@example.com\n\nBody\nfile.txt")
        AgentChatStrings.mailDraftPreview = nil
        XCTAssertEqual(card("send_mail", draft)?.detail, "draft")
        let move = ClaudeCodeJSON.object(["action": .string("move"), "ids": .array([.string("1"), .string("2")]), "mailbox": .string("archive")])
        XCTAssertEqual(card("update_mail", move)?.title, "Drifter wants to move 2 emails to archive")
    }

    func testSlackAllowedToolsAndConfirmationModes() throws {
        let reads = ["slack_search_public", "slack_search_public_and_private", "slack_search_channels", "slack_search_users", "slack_search_emojis",
            "slack_read_channel", "slack_read_thread", "slack_read_canvas", "slack_read_user_profile", "slack_read_file", "slack_read_list",
            "slack_list_channel_members", "slack_list_user_channels", "slack_get_reactions"]
        XCTAssertEqual(Set(DrifterSlackTools.readOnly), Set(reads))
        let request = DrifterLaunchRequest(prompt: "Read Slack", config: .init(), windowId: 42)
        let arguments = try XCTUnwrap(request.claude(folder: URL(fileURLWithPath: "/owned"), server: server).launchArguments)
        for name in reads {
            XCTAssertTrue(DrifterLaunchRequest.readOnlyTools.contains(name))
            XCTAssertTrue(arguments.contains("mcp__mistbrowser__" + name))
            for mode in DrifterConfirmation.allCases {
                XCTAssertTrue(mode.automaticallyAllows(tool: "mcp__mistbrowser__" + name, requiresInteraction: false))
                XCTAssertFalse(mode.automaticallyAllows(tool: "mcp__mistbrowser__" + name, requiresInteraction: true))
            }
        }
        XCTAssertEqual(Set(DrifterSlackTools.alwaysConfirm), ["slack_send_message", "slack_schedule_message", "slack_complete_file_upload"])
        for name in ["slack_send_message", "slack_schedule_message", "slack_complete_file_upload"] {
            XCTAssertFalse(arguments.contains("mcp__mistbrowser__" + name))
            for mode in DrifterConfirmation.allCases {
                for interaction in [true, false] {
                    XCTAssertFalse(mode.automaticallyAllows(tool: "mcp__mistbrowser__" + name, requiresInteraction: interaction))
                }
            }
        }
        for name in ["slack_add_reaction", "slack_create_canvas", "slack_future_write"] {
            XCTAssertFalse(DrifterLaunchRequest.readOnlyTools.contains(name))
            XCTAssertFalse(DrifterConfirmation.ask.automaticallyAllows(tool: "mcp__mistbrowser__" + name, requiresInteraction: false))
            XCTAssertTrue(DrifterConfirmation.skip.automaticallyAllows(tool: "mcp__mistbrowser__" + name, requiresInteraction: false))
            XCTAssertFalse(DrifterConfirmation.skip.automaticallyAllows(tool: "mcp__mistbrowser__" + name, requiresInteraction: true))
        }
        XCTAssertTrue(DrifterLaunchRequest.baseInstructions.contains("outside email and Slack"))
        XCTAssertTrue(DrifterLaunchRequest.baseInstructions.contains("slack_send_message, slack_schedule_message and slack_complete_file_upload ask Johnny in their own card"))
    }

    func testSlackPermissionCards() {
        AgentChatStrings.slackChannelName = { id in
            switch id { case "C1": return ("#general", false); case "D1": return ("@Johnny", true); default: return nil }
        }
        AgentChatStrings.slackUserName = { $0 == "U123" ? "Manju Rao" : nil }
        defer { AgentChatStrings.slackChannelName = nil; AgentChatStrings.slackUserName = nil }
        func card(_ tool: String, channel: String = "C1", extra: [String: ClaudeCodeJSON] = [:]) -> (title: String, detail: String?, message: String?)? {
            var input: [String: ClaudeCodeJSON] = ["channel_id": .string(channel), "message": .string("Hello")]
            input.merge(extra) { _, new in new }
            return AgentChatStrings.browserPermission(.init(requestId: "p", toolName: "mcp__mistbrowser__" + tool, summary: "", input: .object(input)))
        }
        for (id, destination) in [("C1", "#general"), ("D1", "your own DM"), ("C-unknown", "C-unknown")] {
            XCTAssertEqual(card("slack_send_message", channel: id)?.title, "Drifter wants to send a Slack message to " + destination)
            XCTAssertEqual(card("slack_send_message", channel: id)?.message, "Hello")
            XCTAssertNil(card("slack_send_message", channel: id)?.detail)
            XCTAssertEqual(card("slack_schedule_message", channel: id)?.message, "Hello")
            XCTAssertEqual(card("slack_send_message", channel: id, extra: ["thread_ts": .string("123.4")])?.title,
                           "Drifter wants to reply in a Slack thread in " + destination)
            XCTAssertEqual(card("slack_schedule_message", channel: id)?.title, "Drifter wants to schedule a Slack message to " + destination)
            XCTAssertEqual(card("slack_add_reaction", channel: id, extra: ["emoji": .string("wave")])?.title,
                           "Drifter wants to react with :wave: in " + destination)
            XCTAssertEqual(card("slack_complete_file_upload", channel: id)?.title, "Drifter wants to share a file in " + destination)
        }
        XCTAssertEqual(card("slack_complete_file_upload", channel: "")?.title, "Drifter wants to upload a file to Slack")
        XCTAssertEqual(AgentChatStrings.browserPermission(.init(requestId: "p", toolName: "mcp__mistbrowser__slack_complete_file_upload", summary: "", input: .object([:])))?.title,
                       "Drifter wants to upload a file to Slack")
        XCTAssertEqual(card("slack_complete_file_upload", extra: ["title": .string("Report"), "initial_comment": .string("For review")])?.detail, "Report\nFor review")
        XCTAssertEqual(card("slack_complete_file_upload", extra: ["title": .string("Report")])?.detail, "Report")
        XCTAssertEqual(card("slack_complete_file_upload", extra: ["initial_comment": .string("For review")])?.detail, "For review")
        XCTAssertNil(card("slack_complete_file_upload")?.detail)
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        let expectedDate = formatter.string(from: Date(timeIntervalSince1970: 1_800_000_000))
        for value in [ClaudeCodeJSON.number(1_800_000_000), .string("1800000000")] {
            XCTAssertEqual(card("slack_schedule_message", extra: ["post_at": value])?.detail, "Scheduled for " + expectedDate)
        }
        XCTAssertEqual(card("slack_send_message", extra: ["message": .string(String(repeating: "é", count: 2100))])?.message?.count, 2000)
        XCTAssertEqual(card("slack_send_message", extra: ["message": .string("**Hi <@U123>** in <#C1> <!here>")])?.message, "**Hi @Manju Rao** in #general @here")
        XCTAssertNil(card("slack_add_reaction")?.message)
        XCTAssertNil(card("slack_complete_file_upload")?.message)
        XCTAssertNil(card("slack_add_reaction")?.detail)
        XCTAssertEqual(card("slack_create_canvas")?.title, "Drifter wants to make a change in Slack")
        XCTAssertEqual(card("slack_create_canvas")?.detail, "slack_create_canvas")
    }


    func testPreviewMountHandoffAndRemount() {
        var state = BrowserAgentPreviewState(principalId: "p", windowId: 42)
        let now = Date(timeIntervalSince1970: 100)
        XCTAssertEqual(state.mount(card: 2, chatVisible: true, tabExists: true), .hidden)
        XCTAssertTrue(state.report(principal: "p", tabId: 2, live: true, now: now))
        XCTAssertEqual(state.mount(card: 2, chatVisible: true, tabExists: true), .live)
        state.setTurnActive(true, now: now)
        XCTAssertEqual(state.mount(card: 2, chatVisible: false, tabExists: true), .hidden)
        XCTAssertEqual(state.mount(card: 2, chatVisible: true, tabExists: true), .live)
        XCTAssertEqual(state.mount(card: 2, chatVisible: true, tabExists: true), .live)
        XCTAssertEqual(state.mount(card: 2, chatVisible: true, tabExists: false), .hidden)
        state.dismiss(tabId: 2)
        XCTAssertEqual(state.mount(card: 2, chatVisible: true, tabExists: true), .hidden)
        state.report(principal: "p", tabId: 2, live: true, now: now)
        XCTAssertEqual(state.cards.map(\.tabId), [2])
        state.report(principal: "p", tabId: 3, live: true, now: now)
        XCTAssertEqual(state.mount(card: 2, chatVisible: true, tabExists: true), .still)
        state.removeTab(3)
        XCTAssertNil(state.tabId)
        XCTAssertEqual(state.cards.map(\.tabId), [2])
    }



    func testChildPreviewOrderingExpiryAndMount() {
        var state = BrowserAgentPreviewState(principalId: "p", windowId: 42)
        let start = Date(timeIntervalSince1970: 1000)
        let first = UUID(), second = UUID()
        state.report(principal: "p", tabId: 1, live: true, now: start)
        state.upsertChild(first, tabId: 2, working: true, now: start)
        state.upsertChild(second, tabId: 3, working: true, now: start)
        XCTAssertEqual(state.cards.map(\.tabId), [3, 2, 1])
        XCTAssertEqual(state.tabId, 1)
        XCTAssertTrue(state.workedThisTurn)
        XCTAssertEqual(state.mount(card: 2, chatVisible: true, tabExists: true), .agent)
        XCTAssertEqual(state.mount(card: 2, chatVisible: false, tabExists: true), .hidden)
        XCTAssertEqual(state.mount(card: 2, chatVisible: true, tabExists: false), .hidden)
        XCTAssertTrue(state.expire(now: start.addingTimeInterval(600)))
        XCTAssertEqual(state.cards.map(\.tabId), [3, 2], "Working children outlive the idle deadline")
        XCTAssertNil(state.nextExpiry)
        let stopped = start.addingTimeInterval(600)
        state.upsertChild(first, tabId: 2, working: false, now: stopped)
        XCTAssertEqual(state.cards.map(\.tabId), [3, 2], "Finishing keeps the card's place")
        XCTAssertNil(state.nextExpiry)
        XCTAssertFalse(state.expire(now: stopped.addingTimeInterval(10_000)))
        XCTAssertEqual(state.cards.map(\.tabId), [3, 2], "Idle children keep their cards")
        state.upsertChild(first, tabId: 2, working: true, now: stopped)
        XCTAssertEqual(state.cards.map(\.tabId), [2, 3])
        state.dismiss(tabId: 2)
        state.upsertChild(first, tabId: 2, working: false, now: stopped, insertIfMissing: false)
        XCTAssertEqual(state.cards.map(\.tabId), [3])
        state.upsertChild(first, tabId: 2, working: true, now: stopped.addingTimeInterval(10))
        XCTAssertEqual(state.cards.map(\.tabId), [2, 3])
        state.removeTab(2)
        XCTAssertEqual(state.cards.map(\.tabId), [3])
    }

    func testBorrowedFolderHasAnIndependentClock() {
        let start = Date(timeIntervalSince1970: 1000)
        var owner = BrowserAgentFolderState(windowId: 42, token: "family")
        var child = BrowserAgentFolderState(windowId: 42, token: "family", borrowed: true)
        XCTAssertFalse(owner.borrowed)
        XCTAssertTrue(child.borrowed)
        owner.join(1, now: start)
        child.join(2, now: start)
        child.setTurnActive(true, now: start)
        child.report(tabId: 2, now: start)
        XCTAssertEqual(owner.dueTabIds(now: start.addingTimeInterval(300)), [1])
        XCTAssertTrue(child.dueTabIds(now: start.addingTimeInterval(600)).isEmpty)
        child.setTurnActive(false, now: start.addingTimeInterval(600))
        XCTAssertEqual(child.nextExpiry, start.addingTimeInterval(900))
        child.remove(2)
        XCTAssertNil(child.nextExpiry)
        XCTAssertEqual(owner.members.keys.sorted(), [1])
    }

    func testPreviewCardOrderingAndRefresh() {
        var state = BrowserAgentPreviewState(principalId: "p", windowId: 42)
        let now = Date(timeIntervalSince1970: 100)
        for id in [1, 2, 3] { state.report(principal: "p", tabId: id, live: true, now: now) }
        XCTAssertEqual(state.cards.map(\.tabId), [3, 2, 1])
        state.report(principal: "p", tabId: 1, live: true, now: now.addingTimeInterval(1))
        XCTAssertEqual(state.cards.map(\.tabId), [1, 3, 2])
        state.report(principal: "p", tabId: 1, live: true, now: now.addingTimeInterval(2))
        XCTAssertEqual(state.cards.first?.lastWorked, now.addingTimeInterval(2))
        XCTAssertEqual(state.cards.map(\.tabId), [1, 3, 2])
        state.dismiss(tabId: 3)
        state.report(principal: "p", tabId: 3, live: true, now: now.addingTimeInterval(3))
        XCTAssertEqual(state.cards.map(\.tabId), [3, 1, 2])
    }

    func testReadCardsFollowWorkingCardAndLeaveItUntouched() {
        var state = BrowserAgentPreviewState(principalId: "p", windowId: 42)
        let start = Date(timeIntervalSince1970: 100)
        let later = start.addingTimeInterval(1)
        state.report(principal: "p", tabId: 1, live: true, now: start)
        state.setTurnActive(true, now: start)

        state.touch(principal: "p", tabId: 2, reading: true, live: true, now: start)
        state.touch(principal: "p", tabId: 2, reading: false, live: true, now: start)
        state.touch(principal: "p", tabId: 3, reading: true, live: true, now: start)
        XCTAssertEqual(state.cards.map(\.tabId), [1, 3, 2])
        state.touch(principal: "p", tabId: 2, reading: true, live: true, now: later)
        XCTAssertEqual(state.cards.map(\.tabId), [1, 2, 3])
        XCTAssertEqual(state.cards[1].lastWorked, later)
        XCTAssertEqual(state.mount(card: 2, chatVisible: true, tabExists: true), .still)
        XCTAssertFalse(state.workedThisTurn)
        let before = state
        XCTAssertFalse(state.touch(principal: "p", tabId: 1, reading: true, live: true, now: later))
        XCTAssertEqual(state, before)

        state.report(principal: "p", tabId: nil, live: true, now: later)
        state.touch(principal: "p", tabId: 3, reading: false, live: true, now: later)
        XCTAssertEqual(state.cards.map(\.tabId), [3, 1, 2])
        XCTAssertNil(state.tabId)
        state.report(principal: "p", tabId: 3, live: true, now: later)
        XCTAssertEqual(state.mount(card: 3, chatVisible: true, tabExists: true), .live)
    }

    func testReadCardExpiryAndReadCleanup() {
        var state = BrowserAgentPreviewState(principalId: "p", windowId: 42)
        let start = Date(timeIntervalSince1970: 100)
        let end = start.addingTimeInterval(10)
        state.setTurnActive(true, now: start)
        for id in [1, 2, 3, 4] {
            state.touch(principal: "p", tabId: id, reading: true, live: true, now: start)
        }
        state.touch(principal: "p", tabId: 1, reading: false, live: true, now: end)
        state.removeTab(2)
        state.dismiss(tabId: 4)
        state.touch(principal: "p", tabId: 4, reading: false, live: true, now: end)
        XCTAssertEqual(state.readingTabIds, [3])
        XCTAssertEqual(state.cards.map(\.tabId), [1, 3])
        state.setTurnActive(false, now: end)
        XCTAssertTrue(state.readingTabIds.isEmpty)
        XCTAssertFalse(state.touch(principal: "p", tabId: 3, reading: false, live: true, now: end))
        let lifetime = BrowserAgentPreviewState.idleLifetime
        XCTAssertTrue(state.expire(now: start.addingTimeInterval(lifetime)))
        XCTAssertEqual(state.cards.map(\.tabId), [1])
        XCTAssertFalse(state.expire(now: end.addingTimeInterval(lifetime - 1)))
        XCTAssertTrue(state.expire(now: end.addingTimeInterval(lifetime)))
    }

    func testPreviewCardExpiryAndTurnProtection() {
        var state = BrowserAgentPreviewState(principalId: "p", windowId: 42)
        let start = Date(timeIntervalSince1970: 100)
        func date(_ seconds: Double) -> Date { start.addingTimeInterval(seconds) }
        state.setTurnActive(true, now: date(0))
        state.report(principal: "p", tabId: 1, live: true, now: date(0))
        XCTAssertNil(state.nextExpiry)
        state.report(principal: "p", tabId: 2, live: true, now: date(60))
        XCTAssertEqual(state.nextExpiry, date(360))
        state.setTurnActive(false, now: date(120))
        XCTAssertFalse(state.expire(now: date(359)))
        XCTAssertTrue(state.expire(now: date(360)))
        XCTAssertEqual(state.cards.map(\.tabId), [2])
        XCTAssertEqual(state.nextExpiry, date(420))
        XCTAssertTrue(state.expire(now: date(420)))
        XCTAssertNil(state.nextExpiry)
        state.setTurnActive(true, now: date(500))
        state.report(principal: "p", tabId: 1, live: true, now: date(500))
        state.report(principal: "p", tabId: 2, live: true, now: date(560))
        XCTAssertTrue(state.expire(now: date(10_000)))
        XCTAssertEqual(state.cards.map(\.tabId), [2])
        XCTAssertNil(state.nextExpiry)
        state.setTurnActive(false, now: date(10_001))
        state.setTurnActive(true, now: date(10_100))
        XCTAssertEqual(state.nextExpiry, date(10_301))
        XCTAssertTrue(state.expire(now: date(10_301)))
        XCTAssertTrue(state.cards.isEmpty)
    }

    func testFolderExpiryFollowsAgentActivityAndMembership() {
        var folder = BrowserAgentFolderState(windowId: 42, token: "folder")
        func date(_ seconds: Double) -> Date { Date(timeIntervalSince1970: seconds) }
        folder.join(1, now: date(0))
        folder.join(2, now: date(10))
        folder.join(1, now: date(20)) // A duplicate event must not restart the clock.
        XCTAssertEqual(folder.nextExpiry, date(300))
        XCTAssertEqual(folder.dueTabIds(now: date(300)), [1])
        folder.setTurnActive(true, now: date(30))
        folder.report(tabId: 1, now: date(30))
        XCTAssertEqual(folder.dueTabIds(now: date(1000)), [2])
        folder.report(tabId: 2, now: date(100))
        XCTAssertEqual(folder.nextExpiry, date(400))
        XCTAssertTrue(folder.dueTabIds(now: date(399)).isEmpty)
        XCTAssertEqual(folder.dueTabIds(now: date(400)), [1])
        folder.setTurnActive(false, now: date(200))
        XCTAssertEqual(folder.members[2], date(200))
        XCTAssertEqual(folder.dueTabIds(now: date(500)), [1, 2])
        folder.remove(1)
        XCTAssertEqual(folder.nextExpiry, date(500))
        folder.setTurnActive(true, now: date(250))
        XCTAssertEqual(folder.nextExpiry, date(500)) // An unworked new turn grants no protection.
        folder.report(tabId: 2, now: date(260))
        XCTAssertNil(folder.nextExpiry)
        folder.report(tabId: nil, now: date(270))
        XCTAssertEqual(folder.nextExpiry, date(570))
        XCTAssertNil(folder.nextExpiry(excluding: [2]))
        folder.remove(2)
        XCTAssertTrue(folder.members.isEmpty)
        XCTAssertTrue(folder.dueTabIds(now: date(1000)).isEmpty)
        XCTAssertNil(folder.nextExpiry)
    }

    func testFolderReadTouchesOnlyMemberClock() {
        let start = Date(timeIntervalSince1970: 100)
        let read = start.addingTimeInterval(20)
        var folder = BrowserAgentFolderState(windowId: 42, token: "folder")
        folder.join(1, now: start)
        folder.join(2, now: start)
        folder.report(tabId: 1, now: start)
        folder.setTurnActive(true, now: start)
        folder.touch(tabId: 2, now: read)
        folder.touch(tabId: 3, now: read)
        XCTAssertEqual(folder.members, [1: start, 2: read])
        XCTAssertEqual(folder.workingTabId, 1)
        XCTAssertFalse(folder.workedThisTurn)
        let firstDeadline = start.addingTimeInterval(BrowserAgentPreviewState.idleLifetime)
        XCTAssertEqual(folder.dueTabIds(now: firstDeadline), [1])
        XCTAssertEqual(folder.dueTabIds(now: firstDeadline.addingTimeInterval(20)), [1, 2])
    }

    func testFolderTitleMarker() {
        XCTAssertTrue(BrowserAgentFolderState.isAgentFolderTitle("Agent tabs" + BrowserAgentFolderState.titleMarker))
        XCTAssertTrue(BrowserAgentFolderState.isAgentFolderTitle("智能体标签页" + BrowserAgentFolderState.titleMarker))
        XCTAssertFalse(BrowserAgentFolderState.isAgentFolderTitle("Agent tabs"))
        XCTAssertFalse(BrowserAgentFolderState.isAgentFolderTitle("Agent tabs" + BrowserAgentFolderState.titleMarker + "x"))
    }

    func testRestoreSkipsAgentFolderEntries() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BrowserAgentClosedFolders-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("AgentFolders.json")
        var folders = BrowserAgentClosedFolders(url: url)
        folders.insert("aa11")
        folders.insert("BB22")
        XCTAssertEqual(BrowserAgentClosedFolders(url: url).tokens, ["AA11", "BB22"])

        // The chat's folder closes after the chat's own tab.
        XCTAssertEqual(folders.pick([(9, "AA11"), (9, "aa11"), (8, ""), (7, "")]), .entry(8))
        // An expired agent tab, then a user tab closed from a user group.
        XCTAssertEqual(folders.pick([(9, "bb22"), (8, "CC33")]), .entry(8))
        // A window holding agent and user tabs is the user's.
        XCTAssertEqual(folders.pick([(9, "AA11"), (9, ""), (8, "")]), .chromium)
        XCTAssertEqual(folders.pick([(8, ""), (7, "AA11")]), .chromium)
        XCTAssertEqual(folders.pick([(9, "AA11"), (8, "BB22")]), .nothing)
        XCTAssertEqual(folders.pick([]), .chromium)

        for index in 0..<BrowserAgentClosedFolders.limit { folders.insert("T\(index)") }
        XCTAssertEqual(folders.tokens.count, BrowserAgentClosedFolders.limit)
        XCTAssertEqual(folders.pick([(9, "AA11"), (8, "")]), .chromium)
    }

    func testPreviewVisibleCardCount() {
        let heights: [CGFloat] = [287, 187, 187, 187, 187]
        func count(_ height: CGFloat, narrow: Bool = false) -> Int {
            BrowserAgentPreviewState.visibleCardCount(cardHeights: heights, spacing: 8, chipHeight: 22,
                availableHeight: height, narrow: narrow)
        }
        XCTAssertEqual(count(1000), 3)
        XCTAssertEqual(count(1000, narrow: true), 1)
        XCTAssertEqual(count(550), 2)
        XCTAssertEqual(count(300), 1)
        XCTAssertEqual(count(10), 1)
        XCTAssertEqual(BrowserAgentPreviewState.visibleCardCount(cardHeights: [], spacing: 8,
            chipHeight: 22, availableHeight: 1000, narrow: false), 0)
    }

    func testPreviewCardSizeFitsChipWhereThreeFullCardsFit() {
        func size(_ pageWidth: CGFloat, _ aspect: CGFloat) -> CGSize {
            BrowserAgentPreviewLayout.cardSize(pageWidth: pageWidth, aspect: aspect, spacing: 8, chipHeight: 28)
        }
        XCTAssertEqual(size(900, 10 / 16), CGSize(width: 381, height: 274))
        for pageWidth: CGFloat in [300, 432, 900] {
            for aspect: CGFloat in [0.3, 0.38, 10 / 16, 1, 1.3, 2.5] {
                let fullWidth = min(400, pageWidth - 32)
                let full = (BrowserAgentPreviewLayout.bodyHeight(width: fullWidth, aspect: aspect) + 37).rounded()
                let card = size(pageWidth, aspect)
                XCTAssertLessThanOrEqual(card.width, fullWidth)
                let available = 3 * full + 2 * 8
                XCTAssertEqual(BrowserAgentPreviewState.visibleCardCount(cardHeights: Array(repeating: card.height, count: 5),
                    spacing: 8, chipHeight: 28, availableHeight: available, narrow: false), 3, "\(pageWidth) × \(aspect)")
            }
        }
    }

    func testWorkingTabAttributionRejectsOtherAndEndedPrincipals() {
        var chats = [BrowserAgentPreviewState(principalId: "one", windowId: 42),
                     BrowserAgentPreviewState(principalId: "two", windowId: 42)]
        let now = Date(timeIntervalSince1970: 100)
        for i in chats.indices { chats[i].report(principal: "one", tabId: 7, live: true, now: now) }
        XCTAssertEqual(chats.map(\.tabId), [7, nil])
        XCTAssertFalse(chats[0].report(principal: nil, tabId: 9, live: true, now: now))
        XCTAssertFalse(chats[0].report(principal: "external", tabId: 9, live: true, now: now))
        XCTAssertFalse(chats[0].report(principal: "one", tabId: 9, live: false, now: now))
        XCTAssertEqual(chats[0].tabId, 7)
    }



    func testScreenshotModelSizesFitEveryWindow() {
        for size in [CGSize(width: 1527, height: 943), CGSize(width: 2560, height: 1200),
                     CGSize(width: 700, height: 1000), CGSize(width: 700, height: 5000),
                     CGSize(width: 1500, height: 30000)] {
            let model = BrowserAgentScreenshotGeometry.modelSize(for: size)
            XCTAssertLessThanOrEqual(max(model.width, model.height), 1568)
            XCTAssertLessThanOrEqual(model.width * model.height, 1_150_000)
            XCTAssertLessThanOrEqual(model.width, size.width)
            XCTAssertLessThanOrEqual(model.height, size.height)
            XCTAssertEqual(model.width / model.height, size.width / size.height, accuracy: 0.01)
            XCTAssertLessThan(abs(model.height - size.height * model.width / size.width), 1)
        }
        XCTAssertEqual(BrowserAgentScreenshotGeometry.modelSize(for: CGSize(width: 700, height: 1000)), CGSize(width: 700, height: 1000))
    }

    func testScreenshotFullPageTiling() throws {
        let viewport = CGSize(width: 1280, height: 800)
        for page in [viewport, CGSize(width: 1280, height: 1500), .zero] {
            XCTAssertNil(BrowserAgentScreenshotGeometry.fullPageTiling(page: page, viewport: viewport))
        }
        for page in [CGSize(width: 1280, height: 3000), CGSize(width: 1280, height: 20000),
                     CGSize(width: 1280, height: 42000), CGSize(width: 4000, height: 40000)] {
            let tiling = try XCTUnwrap(BrowserAgentScreenshotGeometry.fullPageTiling(page: page, viewport: viewport))
            XCTAssertLessThanOrEqual(tiling.pixelWidth, 1568)
            XCTAssertLessThanOrEqual(tiling.pixelHeight, 1568)
            XCTAssertLessThanOrEqual(tiling.pixelWidth * tiling.pixelHeight, 1_150_000)
            var bottom: CGFloat = 0
            for index in 0..<tiling.count {
                let rect = tiling.rect(index, pageWidth: page.width)
                XCTAssertEqual(rect.minY, bottom, accuracy: 0.000001)
                XCTAssertEqual(rect.width, page.width)
                bottom = rect.maxY
            }
            XCTAssertEqual(bottom, tiling.coveredHeight, accuracy: 0.000001)
            if page.height == 3000 {
                XCTAssertEqual(tiling.count, 2)
                XCTAssertEqual(tiling.scale, 0.75)
            } else if page.height == 20000 {
                XCTAssertEqual(tiling.count, 10)
                XCTAssertGreaterThanOrEqual(tiling.scale, 0.6)
                XCTAssertLessThanOrEqual(tiling.scale, 0.75)
                XCTAssertFalse(tiling.truncated)
                XCTAssertEqual(tiling.coveredHeight, page.height)
            } else if page.height == 42000 {
                XCTAssertEqual(tiling.count, 10)
                XCTAssertEqual(tiling.scale, 0.6)
                XCTAssertTrue(tiling.truncated)
                XCTAssertLessThan(tiling.coveredHeight, page.height)
            } else {
                XCTAssertEqual(tiling.pixelWidth, 1568)
            }
        }
    }

    func testScrollTurnsRecordOnceMarkAndSeparateChats() {
        var turns = BrowserAgentScrollTurns()
        let first = UUID(), second = UUID()
        XCTAssertTrue(turns.record(chat: first, tab: 1))
        XCTAssertFalse(turns.record(chat: first, tab: 1))
        XCTAssertTrue(turns.record(chat: first, tab: 2))
        XCTAssertTrue(turns.record(chat: second, tab: 1))
        turns.mark(chat: first, tab: 1)
        turns.mark(chat: first, tab: 99)
        let ended = turns.endTurn(chat: first)
        XCTAssertEqual(ended.restore, [1])
        XCTAssertEqual(ended.cleanup, [2])
        XCTAssertEqual(turns.endTurn(chat: first).restore, [])
        XCTAssertEqual(turns.endTurn(chat: second).cleanup, [1])
        XCTAssertTrue(turns.record(chat: first, tab: 1))
        XCTAssertEqual(turns.endTurn(chat: first).cleanup, [1])
    }

    func testScreenshotCloseUpScales() {
        XCTAssertEqual(BrowserAgentScreenshotGeometry.closeUpScale(for: CGSize(width: 30, height: 20)), 4)
        XCTAssertEqual(BrowserAgentScreenshotGeometry.closeUpScale(for: CGSize(width: 392, height: 100)), 4)
        let large = CGSize(width: 3000, height: 2000)
        let scale = BrowserAgentScreenshotGeometry.closeUpScale(for: large)
        XCTAssertLessThan(scale, 1)
        XCTAssertLessThanOrEqual(large.width * scale, 1568)
        XCTAssertLessThanOrEqual(large.width * large.height * scale * scale, 1_150_000.001)
    }

    func testScreenshotFullPageScalesRespectCaptureLimits() {
        let size = CGSize(width: 1500, height: 30000)
        for dpr: CGFloat in [1, 2] {
            for cap: CGFloat in [1, 2] {
                let scale = BrowserAgentScreenshotGeometry.fullPageScale(for: size, dpr: dpr, maxScale: cap)
                XCTAssertLessThanOrEqual(scale, cap)
                XCTAssertLessThanOrEqual(ceil(size.height * scale), 16384)
                XCTAssertLessThanOrEqual(ceil(size.width * scale) * ceil(size.height * scale), 64_000_000)
                XCTAssertEqual(size.height * scale, 16384, accuracy: 0.01)
            }
        }
    }

    func testPreviewBodyHeightAndAspectLifetime() {
        XCTAssertEqual(BrowserAgentPreviewLayout.bodyHeight(width: 400, aspect: 10 / 16), 248.75)
        XCTAssertEqual(BrowserAgentPreviewLayout.bodyHeight(width: 400, aspect: 0.1), 150)
        XCTAssertEqual(BrowserAgentPreviewLayout.bodyHeight(width: 400, aspect: 3), 500)
        var state = BrowserAgentPreviewState(principalId: "p", windowId: 42)
        state.cardAspect = 1
        XCTAssertNil(state.cardAspect)
        state.report(principal: "p", tabId: 1, live: true, now: Date())
        state.cardAspect = 0.8
        state.report(principal: "p", tabId: 1, live: true, now: Date())
        XCTAssertEqual(state.cardAspect, 0.8)
        state.report(principal: "p", tabId: 2, live: true, now: Date())
        XCTAssertEqual(state.cardAspect, 0.8)
        state.dismiss(tabId: 1)
        XCTAssertEqual(state.cardAspect, 0.8)
        state.dismiss(tabId: 2)
        XCTAssertNil(state.cardAspect)
    }

    func testScreenshotBeyondViewportUsesDocumentCoordinates() {
        let viewport = CGRect(x: 120, y: 300, width: 1600, height: 1000)
        XCTAssertFalse(BrowserAgentScreenshotGeometry.needsBeyondViewport(rect: viewport, viewport: viewport, fullPage: false))
        XCTAssertFalse(BrowserAgentScreenshotGeometry.needsBeyondViewport(
            rect: CGRect(x: 140, y: 330, width: 100, height: 80), viewport: viewport, fullPage: false))
        for rect in [CGRect(x: 1700, y: 330, width: 21, height: 80),
                     CGRect(x: 140, y: 1290, width: 100, height: 11),
                     CGRect(x: 119, y: 330, width: 100, height: 80),
                     CGRect(x: 140, y: 299, width: 100, height: 80)] {
            XCTAssertTrue(BrowserAgentScreenshotGeometry.needsBeyondViewport(rect: rect, viewport: viewport, fullPage: false))
        }
        XCTAssertTrue(BrowserAgentScreenshotGeometry.needsBeyondViewport(rect: viewport, viewport: viewport, fullPage: true))
        XCTAssertTrue(BrowserAgentScreenshotGeometry.needsBeyondViewport(
            rect: CGRect(x: 0, y: 0, width: 1600, height: 4000), viewport: viewport, fullPage: true))
    }



    func testPreviewReservesColumnSpaceOnlyAboveMinimumWidth() {
        XCTAssertEqual(BrowserAgentPreviewLayout.chatTrailingInset(pageWidth: 1000, cardLeading: 584), 408)
        XCTAssertEqual(BrowserAgentPreviewLayout.chatTrailingInset(pageWidth: 816, cardLeading: 400), 408)
        XCTAssertEqual(BrowserAgentPreviewLayout.chatTrailingInset(pageWidth: 815, cardLeading: 399), 0)
        XCTAssertEqual(BrowserAgentPreviewLayout.chatTrailingInset(pageWidth: 500, cardLeading: 84), 0)
    }

    func testMentionRefreshTakesLiveTabsAndKeepsClosedOnes() {
        let first = AgentTabMention(tabId: 1, title: "Old", url: "https://a.test/old", range: NSRange(location: 4, length: 4), position: 3)
        let closed = AgentTabMention(tabId: 2, title: "Gone", url: "https://b.test", range: NSRange(location: 13, length: 5))
        let same = AgentTabMention(tabId: 3, title: "Same", url: "https://c.test", range: NSRange(location: 19, length: 5))
        let model = AgentMentionText(text: "See @Old and @Gone @Same now", mentions: [first, closed, same])
        let value = model.refreshed(from: [AgentTabMention(tabId: 1, title: "New title", url: "https://a.test/new"),
                                           AgentTabMention(tabId: 3, title: "Same", url: "https://c.test")])
        XCTAssertEqual(value.text, "See @New title and @Gone @Same now")
        XCTAssertEqual(value.mentions.map(\.range), [NSRange(location: 4, length: 10), NSRange(location: 19, length: 5), NSRange(location: 25, length: 5)])
        XCTAssertEqual(value.mentions.map(\.url), ["https://a.test/new", "https://b.test", "https://c.test"])
        XCTAssertEqual(value.mentions.map(\.closed), [false, true, false])
        XCTAssertEqual(value.mentions.first?.position, 3)
        XCTAssertTrue(value.agentText.hasSuffix("1 · New title · https://a.test/new\n2 · Gone (closed) · https://b.test\n3 · Same · https://c.test"))
        XCTAssertEqual(model.refreshed(from: [first, closed, same]), model)
    }

    func testMentionPopupPinsCurrentTabWithoutDuplicatingIt() {
        let tabs = [AgentTabMention(tabId: 1, title: "Other", url: "https://other.test"),
                    AgentTabMention(tabId: 2, title: "Café notes", url: "https://notes.test")]
        let rows = AgentMentionText.popupRows(tabs, query: "", currentTabId: 2, mentioned: [])
        XCTAssertEqual(rows.current, tabs[1])
        XCTAssertEqual(rows.others, [tabs[0]])
        XCTAssertEqual(AgentMentionText.popupRows(tabs, query: "cafe", currentTabId: 2, mentioned: []).current, tabs[1])
        let mentioned = AgentMentionText.popupRows(tabs, query: "", currentTabId: 2, mentioned: ["tab:2"])
        XCTAssertNil(mentioned.current)
        XCTAssertEqual(mentioned.others, tabs)
        let filtered = AgentMentionText.popupRows(tabs, query: "other", currentTabId: 2, mentioned: [])
        XCTAssertNil(filtered.current)
        XCTAssertEqual(filtered.others, [tabs[0]])
        for id: Int? in [nil, 99] {
            let missing = AgentMentionText.popupRows(tabs, query: "", currentTabId: id, mentioned: [])
            XCTAssertNil(missing.current)
            XCTAssertEqual(missing.others, tabs)
        }
    }

    func testMentionMatchingRanksTitlePrefixesAndPreservesStripOrder() {
        let tabs = [AgentTabMention(tabId: 1, title: "Other", url: "https://cafe.test"),
                    AgentTabMention(tabId: 2, title: "Café notes", url: "https://notes.test"),
                    AgentTabMention(tabId: 3, title: "CAFE work", url: "https://work.test")]
        XCTAssertEqual(AgentMentionText.matches(tabs, query: "cafe").map(\.tabId), [2, 3, 1])
        XCTAssertEqual(AgentMentionText.matches(tabs, query: "").map(\.tabId), [1, 2, 3])
        XCTAssertTrue(AgentMentionText.matches(tabs, query: "missing").isEmpty)

        let pr = AgentTabMention(tabId: 4, title: "fix(agent-chat): recover Autopilot", url: "https://github.test/pull/9")
        XCTAssertEqual(AgentMentionText.matches(tabs + [pr], query: "agentc").map(\.tabId), [4])
        XCTAssertEqual(AgentMentionText.matches(tabs + [pr], query: "agent-chat").map(\.tabId), [4])
        XCTAssertEqual(AgentMentionText.matches(tabs + [pr], query: "fixagent").map(\.tabId), [4])
    }

    func testGroupMentionMatchingAndPopupOrder() {
        let tab = AgentTabMention(tabId: 7, title: "Tab", url: "https://cafe.test")
        let groups = ["Other café", "Café work", "CAFE notes"].enumerated().map {
            AgentTabMention(tabId: 0, title: $0.element, url: "", group: .init(token: "g\($0.offset)", color: "blue", tabs: [tab]))
        }
        XCTAssertEqual(AgentMentionText.matches(groups, query: "cafe").map(\.key), ["group:g1", "group:g2", "group:g0"])
        XCTAssertTrue(AgentMentionText.matches(groups, query: "https").isEmpty)
        XCTAssertEqual(AgentMentionText.matches(groups, query: "otherc").map(\.key), ["group:g0"])
        XCTAssertEqual(AgentMentionText.matches(groups, query: "cafen").map(\.key), ["group:g2"])
        let rows = AgentMentionText.popupRows([tab], groups: groups, query: "", currentTabId: 7, mentioned: [groups[0].key])
        XCTAssertEqual(rows.current, tab)
        XCTAssertEqual(rows.groups, groups)
        XCTAssertTrue(rows.others.isEmpty)
        XCTAssertNotEqual(tab.key, groups[0].key)
    }

    func testGroupMentionRefreshSnapshotsLiveMembersAndKeepsClosedGroup() {
        let tab = AgentTabMention(tabId: 7, title: "Tab", url: "https://example.test")
        let old = AgentTabMention(tabId: 0, title: "Old", url: "", range: NSRange(location: 0, length: 4), group: .init(token: "g", color: "blue", tabs: []))
        let live = AgentTabMention(tabId: 0, title: "PRs", url: "", group: .init(token: "g", color: "red", tabs: [tab]))
        let model = AgentMentionText(text: "@Old", mentions: [old])
        let fresh = model.refreshed(from: [tab], groups: [live])
        XCTAssertEqual(fresh.text, "@PRs")
        XCTAssertEqual(fresh.mentions[0].group, live.group)
        XCTAssertFalse(fresh.mentions[0].closed)
        let closed = fresh.refreshed(from: [AgentTabMention(tabId: 0, title: "Wrong", url: "")])
        XCTAssertEqual(closed.mentions[0].title, "PRs")
        XCTAssertEqual(closed.mentions[0].group, live.group)
        XCTAssertTrue(closed.mentions[0].closed)
    }

    func testGroupMentionAgentTextIncludesSnapshotAndDeduplicatesGroups() {
        let tab = AgentTabMention(tabId: 7, title: "Fix\nrouting", url: "https://example.test\npath")
        let group = AgentTabMention(tabId: 0, title: "PRs\nnow", url: "", closed: true, group: .init(token: "g", color: "blue", tabs: [tab]))
        let value = AgentMentionText(text: "Review", mentions: [tab, group, group])
        XCTAssertEqual(value.agentText, "Review\n\nTabs the user mentioned (tabId · title · URL):\n7 · Fix routing · https://example.test path\n\nTab groups the user mentioned, with their tabs when the message was sent (groupId · name, then tabId · title · URL):\ng · PRs now (closed)\n  7 · Fix routing · https://example.test path")
        XCTAssertEqual(value.agentText(tabIds: false), "Review\n\nTabs the user mentioned (title · URL):\nFix routing · https://example.test path\n\nTab groups the user mentioned, with their tabs when the message was sent (name, then title · URL):\nPRs now (closed)\n  Fix routing · https://example.test path")
        let empty = AgentTabMention(tabId: 0, title: "Empty", url: "", group: .init(token: "empty", color: "blue", tabs: []))
        XCTAssertTrue(AgentMentionText(text: "", mentions: [empty]).agentText.hasSuffix("empty · Empty"))
    }

    func testOldTabMentionJSONDecodesWithoutGroup() throws {
        let json = #"{"tabId":7,"title":"Tab","url":"https://example.test","closed":false,"range":[0,4]}"#
        let mention = try JSONDecoder().decode(AgentTabMention.self, from: Data(json.utf8))
        XCTAssertNil(mention.group)
        XCTAssertFalse(mention.isGroup)
        XCTAssertEqual(mention.key, "tab:7")
    }

    func testMentionInsertionAtomicReplacementAndRangeTracking() {
        var model = AgentMentionText(text: "Read @ca please")
        let query = AgentMentionText.query(in: model.text, selection: NSRange(location: 8, length: 0), mentions: [])!
        let tab = AgentTabMention(tabId: 7, title: "Café", url: "https://cafe.test")
        model.replace(query, with: tab.tokenText, mention: tab)
        XCTAssertEqual(model.text, "Read @Café please")
        XCTAssertEqual(model.mentions.first?.range, NSRange(location: 5, length: 5))
        model.replace(NSRange(location: 0, length: 0), with: "🙂 ")
        XCTAssertEqual(model.mentions.first?.range.location, 8)
        XCTAssertNil(AgentMentionText.query(in: model.text, selection: NSRange(location: 11, length: 0), mentions: model.mentions))
        model.replace(NSRange(location: 12, length: 1), with: "")
        XCTAssertEqual(model.text, "🙂 Read  please")
        XCTAssertTrue(model.mentions.isEmpty)
        XCTAssertNil(AgentMentionText.query(in: "mail@ca", selection: NSRange(location: 7, length: 0), mentions: []))
        XCTAssertEqual(AgentMentionText.query(in: "Read @cafe later", selection: NSRange(location: 7, length: 0), mentions: []), NSRange(location: 5, length: 5))
    }

    func testMentionContextAndBothEngineLaunchesKeepDisplayTextSeparate() {
        let tab = AgentTabMention(tabId: 9, title: "News", url: "https://news.test", closed: true, range: NSRange(location: 5, length: 5))
        let text = "Read @News"
        let expected = text + "\n\nTabs the user mentioned (tabId · title · URL):\n9 · News (closed) · https://news.test"
        XCTAssertEqual(AgentMentionText(text: text, mentions: [tab]).agentText, expected)
        XCTAssertEqual(AgentMentionText(text: text, mentions: [tab]).agentText(tabIds: false),
                       text + "\n\nTabs the user mentioned (title · URL):\nNews (closed) · https://news.test")
        XCTAssertEqual(AgentMentionText(text: "ordinary").agentText, "ordinary")
        let request = DrifterLaunchRequest(prompt: text, config: .init(), windowId: 42, mentions: [tab])
        XCTAssertEqual(request.claude(folder: URL(fileURLWithPath: "/owned"), server: server).mentions, [tab])
        XCTAssertEqual(request.codex(folder: URL(fileURLWithPath: "/owned"), server: server).mentions, [tab])
        var claude = ClaudeCodeTranscript()
        claude.userSent(text: text, attachments: [], mentions: [tab])
        claude.apply(.user(.object(["isReplay": .bool(true), "message": .object(["content": .string(expected)])])))
        var codex = CodexTranscript()
        codex.userSent(text: text, attachments: [], mentions: [tab])
        for items in [claude.items, codex.items] {
            XCTAssertEqual(items.count, 1)
            XCTAssertEqual(items.first?.mentions, [tab])
            XCTAssertEqual(items.first?.kind, .userMessage(text: text, images: []))
        }
    }

    @MainActor func testClaudeSendCarriesMentionContextButDisplaysOnlyTypedText() throws {
        let conversation = AgentConversation()
        var lines: [String] = []
        let session = ClaudeCodeSession(config: .init(folder: URL(fileURLWithPath: "/owned")), conversation: conversation, controlWriter: { lines.append($0) })
        conversation.update(items: [], status: .idle)
        let tab = AgentTabMention(tabId: 9, title: "News", url: "https://news.test")
        conversation.onSend?("@News", [], [tab])
        let message = try JSONDecoder().decode(ClaudeCodeJSON.self, from: Data(try XCTUnwrap(lines.first).utf8))
        XCTAssertEqual(message["message"]["content"].array.last?["text"].string,
                       "@News\n\nTabs the user mentioned (tabId · title · URL):\n9 · News · https://news.test")
        XCTAssertEqual(session.transcript.items.first?.kind, .userMessage(text: "@News", images: []))
    }

    private var server: CodexMCPServer {
        DrifterLaunchRequest.server(node: URL(fileURLWithPath: "/runtime/node"),
            resources: URL(fileURLWithPath: "/Mist Dev.app/Contents/Resources"),
            bundleId: "com.bulldf.mist.dev", windowId: 42, capability: "secret")
    }
    func testClaudeCLIServersAreExplicitAndMistbrowserWins() throws {
        var request = DrifterLaunchRequest(prompt: "Read", config: .init(), windowId: 42)
        let folder = URL(fileURLWithPath: "/owned")
        let isolated = try XCTUnwrap(request.claude(folder: folder, server: server).launchArguments)
        let isolatedIndex = try XCTUnwrap(isolated.firstIndex(of: "--mcp-config"))
        XCTAssertEqual(isolated[isolatedIndex + 2], "--strict-mcp-config")
        let isolatedJSON = try JSONDecoder().decode(ClaudeCodeJSON.self, from: Data(isolated[isolatedIndex + 1].utf8))
        guard case let .object(isolatedServers) = isolatedJSON["mcpServers"] else { return XCTFail("Missing servers") }
        XCTAssertEqual(Set(isolatedServers.keys), ["mistbrowser"])
        let connector = ClaudeCodeConnector(url: "https://mcp.slack.com/mcp", id: "account-id")
        request.cliServers = .init(userServers: ["user": .object(["command": .string("aside")]),
                                                 "claude.ai Slack": .object(["command": .string("user-slack")]),
                                                 "mistbrowser": .object(["command": .string("wrong")])],
                                   connectors: ["claude.ai Slack": connector, "claude.ai Drive": connector, "mistbrowser": connector])
        let args = try XCTUnwrap(request.claude(folder: folder, server: server).launchArguments)
        let index = try XCTUnwrap(args.firstIndex(of: "--mcp-config"))
        XCTAssertEqual(args[index + 2], "--strict-mcp-config")
        XCTAssertFalse(args.contains("/user/.claude.json"))
        let json = try JSONDecoder().decode(ClaudeCodeJSON.self, from: Data(args[index + 1].utf8))
        XCTAssertEqual(json["mcpServers"]["claude.ai Slack"]["command"].string, "user-slack")
        XCTAssertEqual(json["mcpServers"]["user"]["command"].string, "aside")
        XCTAssertEqual(json["mcpServers"]["claude.ai Drive"], .object(["type": .string("claudeai-proxy"), "url": .string(connector.url), "id": .string(connector.id)]))
        XCTAssertEqual(json["mcpServers"]["mistbrowser"]["command"].string, server.command)
    }

    func testMistSlackFiltersOnlyTheSlackConnectorWhenConfigured() {
        let connector = ClaudeCodeConnector(url: "https://example.invalid/mcp", id: "fake")
        let names = ["Slack", "sLaCk", "claude.ai Slack", "CLAUDE.AI SLACK", "claude.ai GitHub", "slack-other", "claude.ai Slack workspace"]
        let all = Dictionary(uniqueKeysWithValues: names.map { ($0, connector) })
        XCTAssertEqual(DrifterCLIServers.connectors(all, mistSlackConfigured: false), all)
        XCTAssertEqual(DrifterCLIServers.connectors(all, mistSlackConfigured: true), [
            "claude.ai GitHub": connector, "slack-other": connector, "claude.ai Slack workspace": connector])
        XCTAssertEqual(DrifterCLIServers.connectors([:], mistSlackConfigured: true), [:])
    }

    func testCodexCLIInheritanceIsExplicit() {
        var request = DrifterLaunchRequest(prompt: "Read", config: .init(engine: .codex), windowId: 42)
        let folder = URL(fileURLWithPath: "/owned")
        XCTAssertFalse(request.codex(folder: folder, server: server).inheritsCLIServers)
        request.inheritsCLIServers = true
        XCTAssertTrue(request.codex(folder: folder, server: server).inheritsCLIServers)
    }

    func testClaudeUserServersFiltersCodexAndHonorsConfigDirectory() throws {
        let home = try memoryHome()
        let file = home.appendingPathComponent(".claude.json")
        XCTAssertEqual(DrifterCLIServers.userServers(environment: [:], home: home), [:])
        for text in ["invalid", "{}", #"{"mcpServers":{}}"#, #"{"mcpServers":[]}"#] {
            try text.write(to: file, atomically: true, encoding: .utf8)
            XCTAssertEqual(DrifterCLIServers.userServers(environment: [:], home: home), [:])
        }
        try #"{"mcpServers":{"aside":{"command":"aside"},"CoDeX":{"command":"other"},"renamed":{"command":"/opt/homebrew/bin/codex"},"http":{"url":"https://example.invalid/mcp"}}}"#.write(to: file, atomically: true, encoding: .utf8)
        let expected: [String: ClaudeCodeJSON] = ["aside": .object(["command": .string("aside")]), "http": .object(["url": .string("https://example.invalid/mcp")])]
        XCTAssertEqual(DrifterCLIServers.userServers(environment: [:], home: home), expected)
        XCTAssertEqual(DrifterCLIServers.userServers(environment: ["CLAUDE_CONFIG_DIR": home.path], home: URL(fileURLWithPath: "/missing")), expected)
    }


    func testCodexLaunchAndNextTurnUseChosenModelAndEffort() {
        let config = DrifterConfig(engine: .codex, model: "gpt-test", effort: "high", confirmation: .skip)
        let request = DrifterLaunchRequest(prompt: "Read my tabs", config: config, windowId: 42)
            .codex(folder: URL(fileURLWithPath: "/owned"), server: server)
        var backgroundServer = server
        backgroundServer.env["MIST_BACKGROUND_TASKS"] = "1"
        XCTAssertEqual(request.mcpServers, ["mistbrowser": backgroundServer])
        XCTAssertTrue(request.developerInstructions.hasPrefix(DrifterLaunchRequest.baseInstructions))
        XCTAssertTrue(request.developerInstructions.contains("Your memory is `/owned/memory`"))
        XCTAssertTrue(request.developerInstructions.contains("To attach local files to a page, use upload_files."))
        let thread = CodexProtocol.threadStart(request, inherited: ["untrusted"])
        XCTAssertEqual(thread["sandbox"].string, "danger-full-access")
        XCTAssertEqual(thread["approvalPolicy"].string, "untrusted")
        XCTAssertEqual(thread["config"]["features.shell_tool"], .bool(true))
        XCTAssertEqual(thread["config"]["mcp_servers"]["mistbrowser"]["default_tools_approval_mode"].string, "writes")
        XCTAssertEqual(thread["config"]["mcp_servers"]["untrusted"]["enabled"], .bool(false))
        let turn = CodexProtocol.turnStart(threadId: "t", text: "next", attachments: [], effort: "low", model: "gpt-next")
        XCTAssertEqual(turn["model"].string, "gpt-next")
        XCTAssertEqual(turn["effort"].string, "low")
    }

    func testResumePassesThroughBothEnginesWithRestoredWindow() {
        let resume = AgentChatResume(sessionId: "saved", items: [.init(id: "old", kind: .assistantText(text: "Earlier", isStreaming: false))])
        let request = DrifterLaunchRequest(prompt: "", config: .init(), windowId: 222, resume: resume)
        let rebound = DrifterLaunchRequest.server(node: URL(fileURLWithPath: "/node"), resources: URL(fileURLWithPath: "/resources"),
            bundleId: "com.bulldf.mist.dev", windowId: request.windowId, capability: "new")
        XCTAssertEqual(request.claude(folder: URL(fileURLWithPath: "/owned"), server: rebound).resume, resume)
        let codex = request.codex(folder: URL(fileURLWithPath: "/owned"), server: rebound)
        XCTAssertEqual(codex.resume, resume)
        XCTAssertEqual(codex.mcpServers["mistbrowser"]?.env["MIST_BROWSER_WINDOW_ID"], "222")
        XCTAssertEqual(codex.mcpServers["mistbrowser"]?.env["PHI_AGENT_CAPABILITY"], "new")
    }

    func testMCPCommandAndEnvironmentAreBoundToWindow() {
        XCTAssertEqual(server.command, "/runtime/node")
        XCTAssertEqual(server.args, ["/Mist Dev.app/Contents/Resources/phi-browser-skill/scripts/mist-browser-mcp.mjs"])
        XCTAssertEqual(server.env, ["PHI_BUNDLE_ID": "com.bulldf.mist.dev", "MIST_BROWSER_WINDOW_ID": "42", "PHI_AGENT_CAPABILITY": "secret"])
    }

    func testMergedCatalogAndEffortFallback() throws {
        func codex(_ id: String, _ name: String) -> CodexModelInfo {
            .init(id: id, displayName: name, efforts: ["low", "high"], defaultEffort: "high", inputModalities: ["text", "image"], isDefault: false)
        }
        let models = DrifterModel.merged(claude: ["opus": .init(resolvedModel: "claude-opus", displayName: "Opus current")],
            codex: [codex("gpt-6-luna", "GPT-6-Luna"), codex("gpt-6-sol", "GPT-6-Sol"), codex("gpt-5.6-terra", "GPT-5.6-Terra"), codex("gpt-6.1-terra", "GPT-6.1 Terra"), codex("gpt-6.1-sol", "GPT-6.1-Sol")])
        XCTAssertEqual(models.first?.title, "Opus current")
        // The newest of each family Codex lists, in the picker's family order, labeled from the ID.
        XCTAssertEqual(models.filter { $0.engine == .codex }.map(\.title), ["GPT-6.1 Sol", "GPT-6.1 Terra", "GPT-6 Luna"])
        let model = try XCTUnwrap(models.last)
        XCTAssertEqual(model.engine, .codex)
        XCTAssertEqual(model.effort("max"), "high")
        XCTAssertEqual(model.effort("low"), "low")
        XCTAssertEqual(Set(models.map(\.id)).count, models.count)
    }

    func testCodexPicksAreNewestOfEachFamily() {
        XCTAssertEqual(DrifterCodexPicks.picks(from: [
            "gpt-6-chat", "gpt-6.2-sol", "gpt-6.2-astra", "gpt-6.1-terra", "gpt-6.1-sol", "gpt-6-astra", "gpt-6-sol", "gpt-6-luna",
            "gpt-5.10-nova", "gpt-5.9-nova", "gpt-5.6-terra", "codex-auto-review", "gpt-x-sol",
        ]), ["gpt-6.2-sol", "gpt-6.1-terra", "gpt-6.2-astra", "gpt-6-luna", "gpt-6-chat", "gpt-5.10-nova"])
        XCTAssertEqual(DrifterCodexPicks.picks(from: ["gpt-6-sol", "gpt-6.1-sol", "gpt-6.0.1-sol"]), ["gpt-6.1-sol"])
        XCTAssertEqual(DrifterCodexPicks.picks(from: []), [])
    }

    func testCodexPicksPersistTheCatalogsLastList() {
        func info(_ id: String) -> CodexModelInfo {
            .init(id: id, displayName: id, efforts: ["low"], defaultEffort: "low", inputModalities: [], isDefault: false)
        }
        let defaults = makeTestDefaults().defaults
        XCTAssertEqual(DrifterCodexPicks(defaults: defaults).ids, DrifterCodexPicks.seed)
        DrifterCodexPicks(defaults: defaults).update(from: [info("gpt-7-luna"), info("gpt-7-sol")])
        XCTAssertEqual(DrifterCodexPicks(defaults: defaults).ids, ["gpt-7-sol", "gpt-7-luna"])
        // An empty or signed-out catalog never replaces the list.
        DrifterCodexPicks(defaults: defaults).update(from: [])
        XCTAssertEqual(DrifterCodexPicks(defaults: defaults).ids, ["gpt-7-sol", "gpt-7-luna"])
        // Tests keep the seed whatever a catalog says.
        let frozen = DrifterCodexPicks(defaults: defaults, updatesFromCatalog: false)
        frozen.update(from: [info("gpt-8-sol")])
        XCTAssertEqual(frozen.ids, DrifterCodexPicks.seed)
        XCTAssertEqual(DrifterModel.codexPicks, DrifterCodexPicks.seed)
    }

    func testSavedDefaultFallsBackToNearestOfferedModel() {
        XCTAssertEqual(DrifterModel.offered("gpt-6-sol", engine: .codex), "gpt-6.2-sol")
        XCTAssertEqual(DrifterModel.offered("gpt-5.6-terra", engine: .codex), "gpt-6.1-terra")
        XCTAssertEqual(DrifterModel.offered("gpt-6-astra", engine: .codex), "gpt-6.2-astra")
        XCTAssertEqual(DrifterModel.offered("gpt-6-luna", engine: .codex), "gpt-6-luna")
        XCTAssertEqual(DrifterModel.offered("gpt-5.3-codex-spark", engine: .codex), "gpt-6.2-sol")
        XCTAssertEqual(DrifterModel.offered("opus", engine: .codex), "gpt-6.2-sol")
        XCTAssertEqual(DrifterModel.offered("sonnet", engine: .claude), "sonnet")
        XCTAssertEqual(DrifterModel.offered("gpt-6-sol", engine: .claude), "opus")
        let defaults = makeTestDefaults().defaults
        DrifterLaunchSettings(defaults: defaults).save(.init(engine: .codex, model: "gpt-6-sol"))
        XCTAssertEqual(DrifterLaunchSettings(defaults: defaults).config.model, "gpt-6.2-sol")
    }

    @MainActor func testChatOnRemovedModelShowsProperLabel() {
        XCTAssertEqual(DrifterModel.title("gpt-6-sol", engine: .codex), "GPT-6 Sol")
        XCTAssertEqual(DrifterModel.title("gpt-6.1-terra", engine: .codex), "GPT-6.1 Terra")
        XCTAssertEqual(DrifterModel.title("gpt-5.3-codex-spark", engine: .codex), "GPT-5.3 Codex Spark")
        XCTAssertEqual(DrifterModel.title("haiku", engine: .claude), ClaudeCodeModel.haiku.title)
        // A running chat keeps its removed model, and its label never shows the raw ID.
        let settings = DrifterSettings(config: .init(engine: .codex, model: "gpt-6-sol"), running: true)
        XCTAssertEqual(settings.config.model, "gpt-6-sol")
        XCTAssertEqual(settings.modelTitle, "GPT-6 Sol")
    }

    @MainActor func testComposerPicksNeverSaveAndRunningEngineCannotChange() {
        let defaults = makeTestDefaults().defaults
        let saved = DrifterLaunchSettings(defaults: defaults)
        XCTAssertEqual(saved.config, DrifterConfig())
        let settings = DrifterSettings(config: saved.config, saved: saved, running: true)
        settings.selectConfirmation(.ask)
        XCTAssertEqual(settings.config.confirmation, .ask)
        XCTAssertEqual(saved.config.confirmation, .skip)
        let next = DrifterConfig(engine: .codex, model: "gpt-6.1-terra", effort: "high", confirmation: .ask)
        saved.save(next)
        XCTAssertEqual(DrifterLaunchSettings(defaults: defaults).config, next)
        settings.selectModel(.init(engine: .codex, model: "gpt", title: "GPT", efforts: ["low"], defaultEffort: "low"))
        XCTAssertEqual(settings.config.engine, .claude)
    }

    func testConfirmationCoversBrowserFileAndShellActions() {
        for name in ["Write", "Edit", "Bash", "mcp__mistbrowser__message_agent", "mcp__mistbrowser__spawn_agent", "mcp__mistbrowser__stop_agent", "mcp__mistbrowser__close_agent"] {
            XCTAssertTrue(DrifterConfirmation.skip.automaticallyAllows(tool: name, requiresInteraction: false))
            XCTAssertFalse(DrifterConfirmation.ask.automaticallyAllows(tool: name, requiresInteraction: false))
            XCTAssertFalse(DrifterConfirmation.skip.automaticallyAllows(tool: name, requiresInteraction: true))
        }
        for name in ["Read", "Glob", "Grep", "mcp__mistbrowser__list_agents", "mcp__mistbrowser__read_agent", "mcp__mistbrowser__list_mail_accounts", "mcp__mistbrowser__list_mail", "mcp__mistbrowser__search_mail", "mcp__mistbrowser__read_mail"] {
            XCTAssertTrue(DrifterConfirmation.ask.automaticallyAllows(tool: name, requiresInteraction: false))
            XCTAssertTrue(DrifterConfirmation.skip.automaticallyAllows(tool: name, requiresInteraction: false))
        }
        XCTAssertTrue(DrifterConfirmation.skip.automaticallyAllows(tool: "mcp__mistbrowser__click", requiresInteraction: false))
        XCTAssertFalse(DrifterConfirmation.skip.automaticallyAllows(tool: "mcp__mistbrowser__send_mail", requiresInteraction: false))
        XCTAssertFalse(DrifterConfirmation.ask.automaticallyAllows(tool: "mcp__mistbrowser__send_mail", requiresInteraction: false))
        XCTAssertFalse(DrifterConfirmation.ask.automaticallyAllows(tool: "mcp__mistbrowser__click", requiresInteraction: false))
        XCTAssertFalse(DrifterConfirmation.skip.automaticallyAllows(tool: "AskUserQuestion", requiresInteraction: true))
        XCTAssertTrue(DrifterConfirmation.skip.automaticallyAllows(tool: "mcp__other__click", requiresInteraction: false))
        XCTAssertTrue(DrifterConfirmation.skip.automaticallyAllows(tool: "mcp__claude_ai_Slack__slack_send_message", requiresInteraction: false))
        XCTAssertFalse(DrifterConfirmation.ask.automaticallyAllows(tool: "mcp__claude_ai_Slack__slack_send_message", requiresInteraction: false))
        XCTAssertFalse(DrifterConfirmation.skip.automaticallyAllows(tool: "mcp__claude_ai_Slack__slack_send_message", requiresInteraction: true))
    }

    @MainActor func testSkipNeverPublishesPendingPermissionAndFlipResolvesAsk() throws {
        let conversation = AgentConversation()
        var sent: [String] = []
        let session = ClaudeCodeSession(config: .init(folder: URL(fileURLWithPath: "/owned")), conversation: conversation, controlWriter: { sent.append($0) })
        var mode = DrifterConfirmation.skip
        session.automaticallyAllows = { mode.automaticallyAllows(tool: $0, requiresInteraction: $1) }
        func permission(_ id: String) -> ClaudeCodeEvent {
            .permission(.object(["request_id": .string(id), "request": .object([
                "tool_name": .string("mcp__mistbrowser__click"), "input": .object(["ref": .number(1)])])]))
        }
        session.receive(.event(permission("skip")))
        XCTAssertEqual(sent.count, 1)
        XCTAssertFalse(conversation.items.contains { if case .permissionRequest = $0.kind { return true }; return false })
        mode = .ask
        session.receive(.event(permission("ask")))
        XCTAssertEqual(conversation.status, .awaitingPermission)
        XCTAssertEqual(sent.count, 1)
        mode = .skip
        session.approvePendingBrowserTools()
        XCTAssertEqual(sent.count, 2)
        XCTAssertFalse(conversation.items.contains { if case let .permissionRequest(request) = $0.kind { return request.status == .pending }; return false })
        let reply = try JSONDecoder().decode(ClaudeCodeJSON.self, from: Data(sent[1].utf8))
        XCTAssertEqual(reply["response"]["response"]["behavior"].string, "allow")
        session.receive(.event(.permission(.object(["request_id": .string("send"), "request": .object([
            "tool_name": .string("mcp__mistbrowser__send_mail"), "input": .object(["draftId": .string("draft")])])]))))
        session.approvePendingBrowserTools()
        XCTAssertEqual(sent.count, 2)
        XCTAssertTrue(conversation.items.contains { if case let .permissionRequest(request) = $0.kind { return request.toolName == "mcp__mistbrowser__send_mail" && request.status == .pending }; return false })
    }

    func testCapabilityRequiresExactLiveCLIAncestryAndMistParent() {
        let parents: [Int32: Int32] = [10: 2, 11: 10, 12: 11, 20: 2, 30: 30]
        func admits(_ peer: Int32?, cli: Int32? = 10, live: Bool = true, mist: Int32 = 2) -> Bool {
            BrowserAgentCapability.admits(peer: peer, cli: cli, mist: mist, sameLaunch: live, parent: { parents[$0] })
        }
        XCTAssertTrue(admits(12))
        XCTAssertTrue(admits(10))
        XCTAssertFalse(admits(20))
        XCTAssertFalse(admits(nil))
        XCTAssertFalse(admits(12, cli: nil))
        XCTAssertFalse(admits(12, live: false))
        XCTAssertFalse(admits(12, mist: 3))
        XCTAssertFalse(admits(30))
    }

    @MainActor func testCodexConfirmationAndContextUsage() throws {
        let conversation = AgentConversation()
        let request = DrifterLaunchRequest(prompt: "Read tabs", config: .init(engine: .codex), windowId: 42)
            .codex(folder: URL(fileURLWithPath: "/owned"), server: server)
        var replies: [CodexJSON] = []
        let session = CodexSession(request: request, conversation: conversation, replyWriter: { _, result in replies.append(result) })
        var mode = DrifterConfirmation.skip
        session.automaticallyAllows = { mode.automaticallyAllows(tool: $0, requiresInteraction: $1) }
        func receive(_ json: String) throws {
            session.receive(.message(try JSONDecoder().decode(CodexJSON.self, from: Data(json.utf8))))
        }
        try receive(#"{"method":"turn/started","params":{"turn":{"id":"turn"}}}"#)
        try receive(#"{"method":"item/started","params":{"item":{"id":"click","type":"mcpToolCall","server":"mistbrowser","tool":"click","status":"inProgress","arguments":{"ref":1}}}}"#)
        let permission = #"{"id":"approval","method":"mcpServer/elicitation/request","params":{"serverName":"mistbrowser","message":"run tool \"click\"","_meta":{"codex_approval_kind":"mcp_tool_call","tool_params":{"ref":1}}}}"#
        try receive(permission)
        XCTAssertEqual(replies.last?["action"].string, "accept")
        XCTAssertEqual(conversation.status, .running)
        XCTAssertFalse(conversation.items.contains { if case .permissionRequest = $0.kind { return true }; return false })
        mode = .ask
        try receive(permission)
        XCTAssertEqual(conversation.status, .awaitingPermission)
        mode = .skip
        session.approvePendingBrowserTools()
        XCTAssertEqual(replies.count, 2)
        XCTAssertEqual(conversation.status, .running)
        try receive(#"{"method":"thread/tokenUsage/updated","params":{"tokenUsage":{"last":{"totalTokens":1234},"modelContextWindow":200000}}}"#)
        XCTAssertEqual(conversation.contextTokens, 1234)
        XCTAssertEqual(conversation.contextWindowSize, 200000)
    }

    @MainActor func testCodexInheritedToolsUseLiveConfirmationAndDisplayNames() throws {
        for (name, tool) in [("aside", "poke"), ("codex_apps", "sites.list_sites")] {
            let conversation = AgentConversation()
            let request = DrifterLaunchRequest(prompt: "Probe", config: .init(engine: .codex), windowId: 42, inheritsCLIServers: true)
                .codex(folder: URL(fileURLWithPath: "/owned"), server: server)
            var replies: [CodexJSON] = []
            let session = CodexSession(request: request, conversation: conversation, replyWriter: { _, result in replies.append(result) })
            var mode = DrifterConfirmation.ask
            session.automaticallyAllows = { mode.automaticallyAllows(tool: $0, requiresInteraction: $1) }
            session.receive(.message(.object(["method": .string("turn/started"), "params": .object(["turn": .object(["id": .string("turn")])])])))
            session.receive(.message(.object(["method": .string("item/started"), "params": .object(["item": .object([
                "id": .string("call"), "type": .string("mcpToolCall"), "server": .string(name), "tool": .string(tool),
                "status": .string("inProgress"), "arguments": .object([:]),
            ])])])))
            let permission = CodexJSON.object(["id": .string("approval"), "method": .string("mcpServer/elicitation/request"), "params": .object([
                "serverName": .string(name), "message": .string("Allow server to run tool \"" + tool + "\"?"),
                "_meta": .object(["codex_approval_kind": .string("mcp_tool_call"), "tool_params": .object([:])]),
            ])])
            session.receive(.message(permission))
            XCTAssertEqual(conversation.status, .awaitingPermission)
            XCTAssertTrue(replies.isEmpty)
            let fullName = "mcp__" + name + "__" + tool
            XCTAssertEqual(AgentChatToolGroupKind.displayName(fullName), tool)
            XCTAssertTrue(conversation.items.contains { if case let .toolCall(call) = $0.kind { return call.name == fullName }; return false })
            mode = .skip
            session.approvePendingBrowserTools()
            XCTAssertEqual(replies.last?["action"].string, "accept")
            session.receive(.message(permission))
            XCTAssertEqual(replies.count, 2, "New inherited calls also auto-approve in Skip")
            session.close()
        }
    }

    @MainActor func testCodexNativePermissionsFollowTheLiveConfirmationMode() throws {
        let conversation = AgentConversation()
        let request = DrifterLaunchRequest(prompt: "Save report", config: .init(engine: .codex), windowId: 42)
            .codex(folder: URL(fileURLWithPath: "/owned"), server: server)
        var replies: [CodexJSON] = []
        let session = CodexSession(request: request, conversation: conversation, replyWriter: { _, result in replies.append(result) })
        var mode = DrifterConfirmation.ask
        session.automaticallyAllows = { mode.automaticallyAllows(tool: $0, requiresInteraction: $1) }
        func receive(_ json: String) throws { session.receive(.message(try JSONDecoder().decode(CodexJSON.self, from: Data(json.utf8)))) }
        try receive(#"{"id":"cmd","method":"item/commandExecution/requestApproval","params":{"command":"python3 task.py","cwd":"/outside"}}"#)
        XCTAssertEqual(conversation.status, .awaitingPermission)
        XCTAssertTrue(replies.isEmpty)
        mode = .skip
        session.approvePendingBrowserTools()
        XCTAssertEqual(replies.last?["decision"].string, "accept")
        try receive(#"{"method":"item/started","params":{"item":{"id":"patch","type":"fileChange","status":"inProgress","changes":[{"path":"/outside/new.txt","kind":{"type":"add"},"diff":"new"}]}}}"#)
        try receive(#"{"id":"file","method":"item/fileChange/requestApproval","params":{"itemId":"patch"}}"#)
        XCTAssertEqual(replies.count, 2)
        XCTAssertEqual(replies.last?["decision"].string, "accept")
        XCTAssertFalse(conversation.items.contains { if case let .permissionRequest(p) = $0.kind { return p.status == .pending }; return false })
    }

    func testBrowserToolRowsHaveReadableSummaries() {
        XCTAssertEqual(ClaudeCodeToolSummary.browserTool("mcp__mistbrowser__save_screenshot", input: .object(["path": .string("/tmp/test.png")])), "Saved test.png")
        XCTAssertEqual(ClaudeCodeToolSummary.browserTool("mcp__mistbrowser__save_screenshot", input: .object(["path": .string("/tmp/test.png")]), failed: true), "Couldn't save test.png")
        XCTAssertEqual(ClaudeCodeToolSummary.browserTool("mcp__mistbrowser__screenshot", input: .object(["fullPage": .bool(true)])), "Captured full page")
        let saved = ClaudeCodeToolSummary.format(tool: "mcp__mistbrowser__save_screenshot", input: .null,
            text: #"{"path":"/tmp/screen shot.png"}"#, folder: URL(fileURLWithPath: "/"))
        XCTAssertEqual(saved.summary.first?.spans.first?.link, URL(fileURLWithPath: "/tmp/screen shot.png"))
        XCTAssertEqual(ClaudeCodeToolSummary.browserTool("mcp__mistbrowser__open_tab", input: .object(["url": .string("https://example.com/path")])), "Opened example.com")
        XCTAssertEqual(ClaudeCodeToolSummary.browserTool("mcp__mistbrowser__read_page", input: .null), "Read page")
        XCTAssertEqual(ClaudeCodeToolSummary.browserTool("mcp__mistbrowser__list_tabs", input: .null), "Listed tabs")
        XCTAssertNil(ClaudeCodeToolSummary.browserTool("mcp__other__list_tabs", input: .null))
    }

    func testFileUploadRowsAndGroupsDescribeFilesAndOperationCounts() {
        let input = ClaudeCodeJSON.object(["paths": .array([.string("/tmp/one.png"), .string("~/Downloads/two.png")])])
        let tool = "mcp__mistbrowser__upload_files"
        XCTAssertEqual(ClaudeCodeToolSummary.browserTool(tool, input: input), "Uploaded one.png, two.png")
        XCTAssertEqual(ClaudeCodeToolSummary.browserTool(tool, input: input, running: true), "Uploading one.png, two.png")
        XCTAssertEqual(ClaudeCodeToolSummary.browserTool(tool, input: input, failed: true), "Couldn't upload one.png, two.png")
        XCTAssertNil(ClaudeCodeToolSummary.browserTool(tool, input: .null))
        XCTAssertNil(ClaudeCodeToolSummary.browserTool(tool, input: .object(["paths": .array([])])))
        XCTAssertEqual(AgentChatToolGroupKind(tool), .browserUpload)
        XCTAssertEqual(AgentChatStrings.toolGroup(.browserUpload, count: 1), "uploaded files 1 time")
        XCTAssertEqual(AgentChatStrings.toolGroup(.browserUpload, count: 2), "uploaded files 2 times")
        XCTAssertEqual(AgentChatStrings.toolGroup(.browserUpload, count: 1, running: true), "uploading files 1 time")
        XCTAssertEqual(AgentChatStrings.toolGroup(.browserUpload, count: 2, running: true), "uploading files 2 times")
    }

    func testRecordingRowsShowTheTabTitleAndLinkTheSavedRecording() {
        let start = "mcp__mistbrowser__start_recording"
        let stop = "mcp__mistbrowser__stop_recording"
        let folder = URL(fileURLWithPath: "/")
        XCTAssertEqual(ClaudeCodeToolSummary.browserTool(start, input: .null, running: true), "Starting recording")
        XCTAssertEqual(ClaudeCodeToolSummary.browserTool(start, input: .null, failed: true), "Couldn't start recording")
        XCTAssertEqual(ClaudeCodeToolSummary.browserTool(stop, input: .null, running: true), "Saving recording")
        XCTAssertEqual(ClaudeCodeToolSummary.browserTool(stop, input: .null, failed: true), "Couldn't save recording")
        let started = ClaudeCodeToolSummary.format(tool: start, input: .null,
            text: #"{"tab":{"title":"Example"},"recording":true}"#, folder: folder)
        XCTAssertEqual(started.header.text, "Recording Example")
        let saved = ClaudeCodeToolSummary.format(tool: stop, input: .null,
            text: #"{"path":"/tmp/demo recording.mp4","stills":1}"# + "\nAt 0:00\n[Image]", folder: folder)
        XCTAssertEqual(saved.header.text, "Saved demo recording.mp4")
        XCTAssertEqual(saved.summary.first?.spans.first?.link, URL(fileURLWithPath: "/tmp/demo recording.mp4"))
    }

    func testBookmarkExportAndMountRowsUseTheResultAndDescribeFailures() {
        let cases = [
            ("export_bookmarks", #"{"path":"/tmp/Space bookmarks.html"}"#, "Exported bookmarks to Space bookmarks.html",
             "Exporting bookmarks", "Couldn't export bookmarks"),
            ("mount_to_tab", #"{"mountedTo":{"tabId":2,"title":"Example"}}"#, "Mounted to Example",
             "Mounting to tab", "Couldn't mount to tab"),
            ("unmount_from_tab", #"{"unmountedFrom":{"tabId":2,"title":"Example"}}"#, "Unmounted from Example",
             "Unmounting from tab", "Couldn't unmount from tab"),
        ]
        for (name, result, succeeded, running, failed) in cases {
            let tool = "mcp__mistbrowser__" + name
            let formatted = ClaudeCodeToolSummary.format(tool: tool, input: .null, text: result, folder: URL(fileURLWithPath: "/"))
            XCTAssertEqual(formatted.header.text, succeeded)
            if name == "export_bookmarks" {
                XCTAssertEqual(formatted.summary.first?.spans.first?.link, URL(fileURLWithPath: "/tmp/Space bookmarks.html"))
            }
            let call = AgentChatItem.ToolCall(toolUseId: name, name: tool, inputSummary: "", inputJSON: "{}", status: .succeeded, output: result)
            XCTAssertEqual(AgentChatToolGroupKind.summary([call]).text, succeeded)
            XCTAssertEqual(ClaudeCodeToolSummary.browserTool(tool, input: .null, running: true), running)
            XCTAssertEqual(ClaudeCodeToolSummary.browserTool(tool, input: .null, failed: true), failed)
        }
    }
}
