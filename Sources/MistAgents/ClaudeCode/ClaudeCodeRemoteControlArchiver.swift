import Foundation
import OSLog

enum ClaudeCodeArchiveOutcome: Equatable {
    case noSession, archived, needsRetry(String)

    static func classify(_ text: String) -> Self {
        var bridge: String?
        var teardown: String?
        for line in text.components(separatedBy: .newlines) {
            if let range = line.range(of: "v2 session URL: "),
               let id = line[range.upperBound...].split(separator: "/").last {
                bridge = String(id).trimmingCharacters(in: .whitespacesAndNewlines)
                teardown = nil
            } else if line.contains("Torn down (archive=") || line.contains("Teardown complete (skipArchive)") {
                teardown = line
            }
        }
        guard let bridge, !bridge.isEmpty else { return .noSession }
        if let teardown {
            if teardown.contains("Teardown complete (skipArchive)") { return .archived }
            if let start = teardown.range(of: "Torn down (archive="),
               let end = teardown[start.upperBound...].firstIndex(of: ")"),
               let status = Int(teardown[start.upperBound..<end]), (200...299).contains(status) || status == 409 {
                return .archived
            }
        }
        return .needsRetry(bridge)
    }
}

struct ClaudeCodeArchiveEntry: Codable, Equatable {
    var claudeSessionId: String
    var folder: String
    var bridgeSessionId: String?
    var attempts: Int
    var nextAttempt: Date?
}

@MainActor
protocol ClaudeCodeArchiveRetrying {
    func run(entry: ClaudeCodeArchiveEntry, log: URL) async
}

@MainActor
final class ClaudeCodeRemoteControlArchiver {
    #if !MIST_CLAUDE_CODE_HOSTLESS_TESTS
    static let shared = ClaudeCodeRemoteControlArchiver(directory: AgentChatRoute.current.directory.deletingLastPathComponent().appendingPathComponent("RemoteControl"))
    #endif
    private static let logger = Logger(subsystem: "com.bulldf.mist", category: "ClaudeCode")
    private let directory: URL
    private let runner: any ClaudeCodeArchiveRetrying
    private let now: () -> Date
    private let sleep: (TimeInterval) async -> Void
    private(set) var entries: [String: ClaudeCodeArchiveEntry] = [:]
    private var scheduled: [String: Task<Void, Never>] = [:]
    private var running: [String: Task<Void, Never>] = [:]
    private var processes: [String: ClaudeCodeProcess] = [:]
    private var processWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var started = false

    init(directory: URL, runner: (any ClaudeCodeArchiveRetrying)? = nil, now: @escaping () -> Date = Date.init,
         sleep: @escaping (TimeInterval) async -> Void = { try? await Task.sleep(for: .seconds(max(0, $0))) }) {
        self.directory = directory
        self.runner = runner ?? ClaudeCodeArchiveRetryRunner()
        self.now = now
        self.sleep = sleep
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: directory.appendingPathComponent("pending.json")),
           let saved = try? JSONDecoder().decode([ClaudeCodeArchiveEntry].self, from: data) {
            entries = Dictionary(saved.map { ($0.claudeSessionId, $0) }, uniquingKeysWith: { _, last in last })
        }
    }

    func start() {
        guard !started else { return }
        started = true
        Task { [weak self] in
            guard let self else { return }
            await self.sleep(30)
            for entry in Array(self.entries.values) {
                if entry.nextAttempt == nil && self.processes[entry.claudeSessionId] == nil && self.running[entry.claudeSessionId] == nil {
                    self.settle(entry.claudeSessionId)
                } else if entry.nextAttempt != nil { self.schedule(entry.claudeSessionId) }
            }
        }
    }

    func logURL(_ id: String) -> URL { directory.appendingPathComponent(id + ".log") }

    func prepareLaunch(sessionId: String, folder: URL) async -> URL {
        scheduled.removeValue(forKey: sessionId)?.cancel()
        if processes[sessionId] != nil {
            await withCheckedContinuation { processWaiters[sessionId, default: []].append($0) }
        }
        if let task = running[sessionId] {
            await task.value
            while running[sessionId] != nil { await Task.yield() }
        }
        scheduled.removeValue(forKey: sessionId)?.cancel()
        let attempts = entries[sessionId]?.attempts ?? 0
        try? FileManager.default.removeItem(at: logURL(sessionId))
        entries[sessionId] = .init(claudeSessionId: sessionId, folder: folder.path, bridgeSessionId: nil, attempts: attempts, nextAttempt: nil)
        save()
        return logURL(sessionId)
    }

    func retain(_ process: ClaudeCodeProcess, sessionId: String) {
        if let entry = entries[sessionId], entry.nextAttempt == nil { processes[sessionId] = process }
    }
    func exited(_ id: String) {
        processes[id] = nil
        settle(id)
        for waiter in processWaiters.removeValue(forKey: id) ?? [] { waiter.resume() }
    }

    func settle(_ id: String) {
        guard var entry = entries[id] else { return }
        let log = (try? String(contentsOf: logURL(id), encoding: .utf8)) ?? ""
        let outcome = ClaudeCodeArchiveOutcome.classify(log)
        // Compare the URL even when the new bridge successfully archived.
        let bridge = log.components(separatedBy: .newlines).last { $0.contains("v2 session URL: ") }
            .flatMap { $0.split(separator: "/").last }.map(String.init)
        if let expected = entry.bridgeSessionId, let bridge, expected != bridge {
            Self.logger.error("[RemoteControl] retry attached to a different session than \(expected, privacy: .public)")
            remove(id); return
        }
        switch outcome {
        case .noSession where entry.bridgeSessionId != nil:
            scheduleFailure(&entry)
        case .noSession, .archived:
            remove(id)
        case .needsRetry(let bridge):
            entry.bridgeSessionId = bridge
            scheduleFailure(&entry)
        }
    }

    private func scheduleFailure(_ entry: inout ClaudeCodeArchiveEntry) {
        let id = entry.claudeSessionId
        guard entry.attempts < 3 else {
            let bridge = entry.bridgeSessionId ?? "unknown"
            Self.logger.error("[RemoteControl] giving up on \(bridge, privacy: .public)")
            remove(id); return
        }
        entry.nextAttempt = now().addingTimeInterval([30, 300, 1800][entry.attempts])
        entries[id] = entry
        save()
        schedule(id)
    }

    private func schedule(_ id: String) {
        scheduled.removeValue(forKey: id)?.cancel()
        guard let date = entries[id]?.nextAttempt else { return }
        scheduled[id] = Task { [weak self] in
            guard let self else { return }
            await self.sleep(max(0, date.timeIntervalSince(self.now())))
            guard !Task.isCancelled, var entry = self.entries[id], entry.nextAttempt == date else { return }
            self.scheduled[id] = nil
            entry.attempts += 1
            entry.nextAttempt = nil
            self.entries[id] = entry
            self.save()
            try? FileManager.default.removeItem(at: self.logURL(id))
            let task = Task { await self.runner.run(entry: entry, log: self.logURL(id)) }
            self.running[id] = task
            await task.value
            self.running[id] = nil
            self.settle(id)
        }
    }

    private func remove(_ id: String) {
        entries[id] = nil
        scheduled.removeValue(forKey: id)?.cancel()
        try? FileManager.default.removeItem(at: logURL(id))
        save()
    }

    private func save() {
        do {
            let data = try JSONEncoder().encode(Array(entries.values))
            try data.write(to: directory.appendingPathComponent("pending.json"), options: .atomic)
        } catch { Self.logger.error("[RemoteControl] could not save pending archives: \(error.localizedDescription, privacy: .public)") }
    }
}

@MainActor
final class ClaudeCodeArchiveRetryRunner: ClaudeCodeArchiveRetrying {
    func run(entry: ClaudeCodeArchiveEntry, log: URL) async {
        let environment = await ClaudeCodeEnvironment.shared.value
        guard let executable = environment.executable else { return }
        let initialize = UUID().uuidString, remote = UUID().uuidString
        let arguments = ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
                         "--resume", entry.claudeSessionId, "--setting-sources", "", "--strict-mcp-config", "--tools", "",
                         "--model", "haiku", "--debug=remote-bridge,code-session", "--debug-file", log.path]
        guard let process = try? ClaudeCodeProcess(executable: executable, arguments: arguments,
                folder: URL(fileURLWithPath: entry.folder), environment: ClaudeCodeEnvironment.subscriptionVariables(environment.variables)) else { return }
        var ready = false, failed = false, exited = false
        let reader = Task { @MainActor in
            for await output in process.output {
                switch output {
                case .event(.controlResponse(let value)):
                    let response = value["response"]
                    if response["request_id"].string == initialize {
                        if response["subtype"].string == "success", response["response"]["remote_control_available"].bool {
                            process.write(ClaudeCodeProtocol.remoteControl(enabled: true, requestId: remote))
                        } else { failed = true }
                    } else if response["request_id"].string == remote {
                        if response["subtype"].string == "success" { ready = true } else { failed = true }
                    }
                case .event(.unsupportedControl(let id)): process.write(ClaudeCodeProtocol.unsupported(requestId: id))
                case .exited: exited = true
                case .writeFailed: failed = true
                default: break
                }
            }
            exited = true
        }
        process.write(ClaudeCodeProtocol.initialize(requestId: initialize))
        let deadline = Date().addingTimeInterval(20)
        var connectionDeadline: Date?
        while !failed && !exited {
            if ready {
                if connectionDeadline == nil { connectionDeadline = Date().addingTimeInterval(10) }
                if ((try? String(contentsOf: log, encoding: .utf8)) ?? "").contains("v2 transport connected") { break }
            }
            if Date() >= (connectionDeadline ?? deadline) { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        process.terminate(grace: 10)
        await reader.value
    }
}
