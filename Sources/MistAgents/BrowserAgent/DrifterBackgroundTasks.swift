import Foundation
import Darwin

/// Mist owns these processes independently of the engine and its per-turn connection.
@MainActor
final class DrifterBackgroundTasks {
    enum Kind: String { case command, monitor }
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
    private enum StopReason { case stopped, timeout, flood, shutdown }
    private final class Running {
        let id: String, label: String, output: URL, kind: Kind, pid: pid_t
        let timeout: TimeInterval?
        var reason: StopReason?
        var tail = Data(), partial = Data()
        var lines: [String] = []
        var omitted = 0, events = 0
        var outstanding: String?
        var delivering = false
        var ended = false
        var batch: Task<Void, Never>?
        var timer: Task<Void, Never>?
        init(id: String, label: String, output: URL, kind: Kind, pid: pid_t, timeout: TimeInterval?) {
            self.id = id; self.label = label; self.output = output; self.kind = kind; self.pid = pid; self.timeout = timeout
        }
    }

    let folder: URL, outputFolder: URL
    var environment: [String: String]?
    var onChange: ([AgentBackgroundTask]) -> Void = { _ in }
    var onEnded: (String, String, AgentChatItem.TaskNotificationStatus) -> Void = { _, _, _ in }
    var onWake: (AgentQueuedMessage) async -> Bool = { _ in false }
    var isQueued: (String) -> Bool = { _ in false }
    private let batchWindow: TimeInterval, killGrace: TimeInterval, drainWait: TimeInterval
    private var running: [Running] = []
    private var generation = 0

    init(folder: URL, outputFolder: URL, batchWindow: TimeInterval = 0.2,
         killGrace: TimeInterval = 2, drainWait: TimeInterval = 1) {
        self.folder = folder; self.outputFolder = outputFolder
        self.batchWindow = batchWindow; self.killGrace = killGrace; self.drainWait = drainWait
    }

    var tasks: [AgentBackgroundTask] {
        running.map { .init(id: $0.id, kind: $0.kind == .command ? .shell : .monitor, description: $0.label) }
    }

    func start(kind: Kind, command: String, description: String? = nil, timeout: TimeInterval? = nil) throws -> (taskId: String, outputFile: String) {
        guard let environment else { throw Failure(message: "Mist hasn't finished starting this chat.") }
        guard running.count < 16 else { throw Failure(message: "This chat already runs 16 background tasks; stop one first.") }
        guard !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              description.map({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) ?? true else {
            throw Failure(message: "A command and a non-empty description are required.")
        }
        let timeout = timeout ?? (kind == .monitor ? 300 : nil)
        if let timeout, !timeout.isFinite || timeout < 1 || timeout > (kind == .monitor ? 1800 : 86400) {
            throw Failure(message: "Background task timeout is out of range.")
        }
        try FileManager.default.createDirectory(at: outputFolder, withIntermediateDirectories: true)
        let alphabet = Array("0123456789abcdefghijklmnopqrstuvwxyz")
        var id: String, output: URL, log: Int32
        repeat {
            id = "task-" + String((0..<6).map { _ in alphabet.randomElement()! })
            output = outputFolder.appendingPathComponent(id + ".log")
            log = Darwin.open(output.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        } while log < 0 && errno == EEXIST
        guard log >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let pid: pid_t
        let reads: [(Int32, Bool)]
        do { (pid, reads) = try Self.spawn(command: command, folder: folder, environment: environment, monitor: kind == .monitor) }
        catch { Darwin.close(log); throw error }
        let rawLabel = description?.trimmingCharacters(in: .whitespacesAndNewlines) ?? String(command.split(separator: "\n", omittingEmptySubsequences: false).first ?? "")
        let label = rawLabel.count > 60 ? String(rawLabel.prefix(59)) + "…" : rawLabel
        let task = Running(id: id, label: label, output: output, kind: kind, pid: pid, timeout: timeout)
        running.append(task)
        let io = DrifterTaskIO(pid: pid, reads: reads, log: log, drainWait: drainWait,
            chunk: { [weak self] data, stdout in
                DispatchQueue.main.async { self?.received(data, stdout: stdout, task: task) }
            }, ended: { [weak self] status in
                DispatchQueue.main.async { self?.finished(task, status: status) }
            })
        io.start()
        if let timeout {
            task.timer = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self?.halt(task, reason: .timeout)
            }
        }
        onChange(tasks)
        return (id, output.path)
    }

    @discardableResult
    func stop(_ id: String) -> Bool {
        guard let task = running.first(where: { $0.id == id }) else { return false }
        halt(task, reason: .stopped)
        return true
    }

    func stopAll(immediately: Bool) {
        generation += 1
        let previous = running
        running.removeAll()
        for task in previous {
            task.reason = .shutdown; task.batch?.cancel(); task.timer?.cancel()
            Self.killGroup(task.pid, immediately: immediately, grace: killGrace)
        }
        if !previous.isEmpty { onChange(tasks) }
    }

    func queueChanged(_ ids: Set<String>) {
        for task in running where task.outstanding != nil && !ids.contains(task.outstanding!) {
            task.outstanding = nil
            flush(task)
        }
    }

    private func halt(_ task: Running, reason: StopReason) {
        guard !task.ended, task.reason == nil else { return }
        task.reason = reason; task.batch?.cancel(); task.timer?.cancel()
        Self.killGroup(task.pid, immediately: false, grace: killGrace)
    }

    private static func killGroup(_ pid: pid_t, immediately: Bool, grace: TimeInterval) {
        killpg(pid, immediately ? SIGKILL : SIGTERM)
        if !immediately {
            // This must outlive the runner and the shell: descendants can ignore TERM.
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + grace) {
                if killpg(pid, 0) == 0 || errno == EPERM { killpg(pid, SIGKILL) }
            }
        }
    }

    private func received(_ data: Data, stdout: Bool, task: Running) {
        guard !task.ended, task.reason != .shutdown else { return }
        task.tail.append(data)
        if task.tail.count > 65536 { task.tail.removeFirst(task.tail.count - 65536) }
        guard task.kind == .monitor, stdout else { return }
        task.partial.append(data)
        while let newline = task.partial.firstIndex(of: 10) {
            let line = String(decoding: task.partial[..<newline], as: UTF8.self)
            task.partial.removeSubrange(...newline)
            addLine(line, task: task)
        }
        // A script printing one unbounded line must not grow Mist's memory.
        if task.partial.count > 8192 { task.partial.removeFirst(task.partial.count - 8192) }
    }

    private func addLine(_ line: String, task: Running) {
        task.events += 1
        task.lines.append(line.hasSuffix("\r") ? String(line.dropLast()) : line)
        if task.lines.count + task.omitted > 500 { halt(task, reason: .flood) }
        while task.lines.count + (task.omitted > 0 ? 1 : 0) > 100 || task.lines.reduce(0, { $0 + $1.utf8.count + 1 }) > 7900 {
            task.lines.removeFirst(); task.omitted += 1
        }
        guard task.batch == nil, task.reason == nil else { return }
        task.batch = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: UInt64(self.batchWindow * 1_000_000_000))
            guard !Task.isCancelled else { return }
            task.batch = nil
            self.flush(task)
        }
    }

    private func pendingBody(_ task: Running) -> String {
        let prefix = task.omitted > 0 ? "(\(task.omitted) earlier lines omitted; see the output file)\n" : ""
        let body = prefix + task.lines.joined(separator: "\n")
        task.lines.removeAll(); task.omitted = 0
        return body.isEmpty ? "(no new lines)" : body
    }

    private func flush(_ task: Running) {
        guard !task.ended, task.reason == nil, task.outstanding == nil, !task.delivering,
              !task.lines.isEmpty || task.omitted > 0 else { return }
        let message = wake(task, body: pendingBody(task), note: "Monitor \(task.id) (\(task.label)) printed these lines; it keeps watching until its script exits, it times out, or you stop it with stop_task")
        let generation = generation
        task.delivering = true
        Task { [weak self] in
            guard let self, self.generation == generation, task.reason == nil else { return }
            let accepted = await self.onWake(message)
            task.delivering = false
            if accepted, self.isQueued(message.id) { task.outstanding = message.id }
            if !accepted { NSLog("Drifter dropped background wake for %@", task.id) }
            self.flush(task)
        }
    }

    private func wake(_ task: Running, body: String, note: String) -> AgentQueuedMessage {
        .init(text: body, sender: .init(id: task.id, title: task.label, kind: .task, note: note))
    }

    private func finished(_ task: Running, status: Int32) {
        guard !task.ended else { return }
        if task.kind == .monitor, !task.partial.isEmpty {
            addLine(String(decoding: task.partial, as: UTF8.self), task: task)
            task.partial.removeAll()
        }
        task.ended = true; task.batch?.cancel(); task.timer?.cancel()
        let generation = generation
        running.removeAll { $0 === task }
        guard task.reason != .shutdown else { return }
        onChange(tasks)
        let signal = status & 0x7f
        let code = (status >> 8) & 0xff
        let summary: String
        let rowStatus: AgentChatItem.TaskNotificationStatus
        let note: String
        let body: String
        let duration = Self.duration(task.timeout ?? 0)
        if task.kind == .command {
            let subject = "Background command \"\(task.label)\""
            let prefix = "Background task \(task.id) (\(task.label))"
            switch task.reason {
            case .stopped, .flood: summary = subject + " was stopped"; rowStatus = .stopped; note = ""
            case .timeout:
                summary = subject + " was stopped after reaching its background time limit"; rowStatus = .stopped
                note = prefix + " timed out after \(duration) and Mist stopped it."
            default:
                summary = subject + (signal != 0 ? " failed" : code == 0 ? " completed (exit code 0)" : " failed with exit code \(code)")
                rowStatus = signal == 0 && code == 0 ? .completed : .failed
                note = prefix + (signal != 0 ? " was killed by signal \(signal)." : " exited with code \(code).")
            }
            body = Self.outputTail(task.tail)
        } else {
            let subject = "Monitor \"\(task.label)\""
            let prefix = "Monitor \(task.id) (\(task.label))"
            switch task.reason {
            case .timeout:
                summary = subject + " stopped"; rowStatus = .stopped
                note = prefix + " timed out after \(duration) with \(task.events) events and Mist stopped it; start it again if you still need the watch"
            case .flood:
                summary = subject + " stopped"; rowStatus = .stopped
                note = "Mist stopped monitor \(task.id) (\(task.label)) because it printed too many lines; start it again with a tighter filter"
            case .stopped: summary = subject + " stopped"; rowStatus = .stopped; note = ""
            default:
                let ending = signal != 0 ? " script failed" : task.events == 0
                    ? " ended without producing output" + (code == 0 ? "" : " (exit \(code))")
                    : code == 0 ? " stream ended" : " script failed (exit \(code))"
                summary = subject + ending; rowStatus = signal == 0 && code == 0 ? .completed : .failed
                note = prefix + (signal != 0 ? " ended: its script was killed by signal \(signal) after \(task.events) events" : " ended: its script exited with code \(code) after \(task.events) events")
                    + (task.lines.isEmpty && task.omitted == 0 ? "" : ". Its last lines follow")
            }
            body = pendingBody(task)
        }
        onEnded(task.id, summary, rowStatus)
        guard task.reason != .stopped else { return }
        let finalNote = task.kind == .command ? note + " The end of its output follows; the full output is in \(task.output.path)" : note
        let message = wake(task, body: body, note: finalNote)
        Task { [weak self] in
            guard let self, self.generation == generation else { return }
            if !(await self.onWake(message)) { NSLog("Drifter dropped background wake for %@", task.id) }
        }
    }

    private static func duration(_ seconds: TimeInterval) -> String {
        seconds.truncatingRemainder(dividingBy: 60) == 0 ? "\(Int(seconds / 60)) min" : "\(Int(seconds)) s"
    }

    private static func outputTail(_ data: Data) -> String {
        guard !data.isEmpty else { return "(no output)" }
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines)
        guard !text.isEmpty else { return "(no output)" }
        let lines = text.components(separatedBy: "\n")
        var body = lines.suffix(40).joined(separator: "\n")
        let cut = data.count >= 65536 || lines.count > 40 || body.utf8.count > 8100
        if body.utf8.count > 8100 { body = String(decoding: Array(body.utf8.suffix(8100)), as: UTF8.self) }
        return (cut ? "(earlier output is in the output file)\n" : "") + body
    }

    private static func spawn(command: String, folder: URL, environment: [String: String], monitor: Bool) throws -> (pid_t, [(Int32, Bool)]) {
        var actions: posix_spawn_file_actions_t?, attributes: posix_spawnattr_t?
        posix_spawn_file_actions_init(&actions); posix_spawnattr_init(&attributes)
        defer { posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attributes) }
        var stdout: [Int32] = [0, 0], stderr: [Int32] = [0, 0]
        guard pipe(&stdout) == 0 else { throw POSIXError(.EMFILE) }
        var descriptors = stdout
        defer { for fd in descriptors { Darwin.close(fd) } }
        if monitor {
            guard pipe(&stderr) == 0 else { throw POSIXError(.EMFILE) }
            descriptors += stderr
        } else { stderr = stdout }
        posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, stdout[1], STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, stderr[1], STDERR_FILENO)
        if #available(macOS 26, *) { posix_spawn_file_actions_addchdir(&actions, folder.path) }
        else { posix_spawn_file_actions_addchdir_np(&actions, folder.path) }
        var defaults = sigset_t(), mask = sigset_t()
        sigfillset(&defaults); sigemptyset(&mask)
        posix_spawnattr_setsigdefault(&attributes, &defaults); posix_spawnattr_setsigmask(&attributes, &mask)
        posix_spawnattr_setpgroup(&attributes, 0)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
        let args = ["/bin/zsh", "-c", command].map { strdup($0) } + [nil]
        let env = environment.map { strdup($0.key + "=" + $0.value) } + [nil]
        defer { for value in args + env { free(value) } }
        var pid: pid_t = 0
        let result = args.withUnsafeBufferPointer { argv in
            env.withUnsafeBufferPointer { envp in
                posix_spawn(&pid, "/bin/zsh", &actions, &attributes, argv.baseAddress!, envp.baseAddress!)
            }
        }
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: result) ?? .EIO) }
        let reads = monitor ? [(stdout[0], true), (stderr[0], false)] : [(stdout[0], true)]
        descriptors.removeAll { fd in reads.contains { $0.0 == fd } }
        return (pid, reads)
    }
}

/// All pipe and log I/O is serialized off the main actor. Sources retain this until the child is reaped and pipes drain.
private final class DrifterTaskIO {
    private let queue = DispatchQueue(label: "Mist.backgroundTask.io", qos: .utility)
    private let pid: pid_t, reads: [(Int32, Bool)], log: Int32, drainWait: TimeInterval
    private let chunk: (Data, Bool) -> Void, ended: (Int32) -> Void
    private var sources: [Int32: DispatchSourceRead] = [:]
    private var process: DispatchSourceProcess?
    private var status: Int32?, written = 0
    private var truncated = false, finished = false

    init(pid: pid_t, reads: [(Int32, Bool)], log: Int32, drainWait: TimeInterval,
         chunk: @escaping (Data, Bool) -> Void, ended: @escaping (Int32) -> Void) {
        self.pid = pid; self.reads = reads; self.log = log; self.drainWait = drainWait
        self.chunk = chunk; self.ended = ended
    }

    func start() {
        queue.async { self.startOnQueue() }
    }

    private func startOnQueue() {
        for (fd, stdout) in reads {
            _ = fcntl(fd, F_SETFL, O_NONBLOCK)
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            sources[fd] = source
            source.setEventHandler { self.read(fd, stdout: stdout) }
            source.setCancelHandler { Darwin.close(fd) }
            source.resume()
        }
        let process = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
        self.process = process
        process.setEventHandler {
            var status: Int32 = 0
            while waitpid(self.pid, &status, 0) < 0 && errno == EINTR {}
            self.status = status
            self.process?.cancel(); self.process = nil
            if self.sources.isEmpty { self.finish() }
            else { self.queue.asyncAfter(deadline: .now() + self.drainWait) { self.finish() } }
        }
        process.resume()
    }

    private func read(_ fd: Int32, stdout: Bool) {
        // Bound each callback so a continuously writing child cannot starve the exit source.
        for _ in 0..<32 {
            let count: Int = autoreleasepool {
                var buffer = [UInt8](repeating: 0, count: 16384)
                let count = Darwin.read(fd, &buffer, buffer.count)
                if count > 0 {
                    let data = Data(buffer.prefix(count))
                    let remaining = max(0, 8 * 1024 * 1024 - written)
                    if remaining > 0 {
                        writeLog(Data(data.prefix(remaining)))
                        written += min(remaining, count)
                    }
                    if count > remaining, !truncated {
                        truncated = true
                        writeLog(Data("\n[Mist: output truncated at 8 MiB]\n".utf8))
                    }
                    chunk(data, stdout)
                }
                return count
            }
            if count > 0 { continue }
            if count < 0 && errno == EINTR { continue }
            if count == 0 || (errno != EAGAIN && errno != EWOULDBLOCK) {
                sources.removeValue(forKey: fd)?.cancel()
                if status != nil && sources.isEmpty { finish() }
            }
            break
        }
    }

    private func writeLog(_ data: Data) {
        data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(log, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { break }
                offset += count
            }
        }
    }

    private func finish() {
        guard !finished, let status else { return }
        finished = true
        for source in sources.values { source.cancel() }
        sources.removeAll()
        Darwin.close(log)
        ended(status)
    }
}
