import Foundation
import Darwin
import OSLog

final class ClaudeCodeProcess: @unchecked Sendable {
    enum Output: Sendable {
        case event(ClaudeCodeEvent)
        case exited(code: Int32, stderr: String)
        case writeFailed(String)
    }

    var processIdentifier: Int32 { process.processIdentifier }

    let output: AsyncStream<Output>
    private let continuation: AsyncStream<Output>.Continuation
    private let process = Process()
    private let input = Pipe()
    private let stdout = Pipe()
    private let stderr = Pipe()
    private let writer = DispatchQueue(label: "mist.claude.stdin")
    private let control = DispatchQueue(label: "mist.claude.lifecycle")
    private let delivery = DispatchQueue(label: "mist.claude.events")
    private let readers = DispatchGroup()
    private var stderrTail = Data() // Accessed only on delivery.
    private var closing = false // Accessed only on control.
    private static let logger = Logger(subsystem: "com.bulldf.mist", category: "ClaudeCode")

    init(executable: URL, arguments: [String], folder: URL, environment: [String: String], onTermination: (@Sendable () -> Void)? = nil) throws {
        var continuation: AsyncStream<Output>.Continuation!
        output = AsyncStream { continuation = $0 }
        self.continuation = continuation
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = folder
        process.environment = environment
        process.standardInput = input
        process.standardOutput = stdout
        process.standardError = stderr
        // Failed writes must throw rather than deliver SIGPIPE to the browser.
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        readers.enter()
        readers.enter()
        process.terminationHandler = { [weak self, onTermination] process in
            onTermination?()
            guard let self else { return }
            let code = process.terminationStatus
            self.readers.notify(queue: self.delivery) {
                self.continuation.yield(.exited(code: code, stderr: String(decoding: self.stderrTail, as: UTF8.self)))
                self.continuation.finish()
            }
        }
        do { try process.run() }
        catch {
            readers.leave()
            readers.leave()
            continuation.finish()
            throw error
        }
        try? input.fileHandleForReading.close()
        try? stdout.fileHandleForWriting.close()
        try? stderr.fileHandleForWriting.close()
        read(stdout.fileHandleForReading, isStdout: true)
        read(stderr.fileHandleForReading, isStdout: false)
    }

    func write(_ line: String) {
        writer.async { [self] in
            do { try input.fileHandleForWriting.write(contentsOf: Data((line + "\n").utf8)) }
            catch { continuation.yield(.writeFailed(error.localizedDescription)) }
        }
    }

    func terminate(grace: TimeInterval = 2) {
        control.async { [self] in
            guard !closing else { return }
            closing = true
            writer.async { [self] in try? input.fileHandleForWriting.close() }
            control.asyncAfter(deadline: .now() + grace) { [self] in
                guard process.isRunning else { return }
                process.terminate()
                control.asyncAfter(deadline: .now() + 2) { [self] in
                    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                }
            }
        }
    }

    /// For app termination: the delayed escalation in `terminate()` never runs
    /// once the app has exited, which would leave a turn running headless.
    func terminateNow() {
        control.sync { closing = true }
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
    }

    private func read(_ handle: FileHandle, isStdout: Bool) {
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            defer {
                try? handle.close()
                readers.leave()
            }
            var buffer = ClaudeCodeLineBuffer()
            readAgentPipe(handle) { data in
                if isStdout {
                    for line in buffer.append(data) { decode(line) }
                } else {
                    delivery.async { [self] in
                        stderrTail.append(data)
                        stderrTail = Data(stderrTail.suffix(8192))
                    }
                }
            }
            if isStdout, let last = buffer.finish() { decode(last) }
        }
    }

    private func decode(_ line: Data) {
        // Decoding and delivery share one FIFO, preserving event/exit ordering.
        delivery.async { [self] in
            if let event = ClaudeCodeProtocol.decode(line) { continuation.yield(.event(event)) }
            else { Self.logger.debug("Skipped unknown or malformed Claude Code stdout line (\(line.count) bytes)") }
        }
    }
}

/// Reads each chunk inside its own autorelease pool. Without one, availableData's
/// page-aligned buffers remain alive for the lifetime of the agent's reader block.
func readAgentPipe(_ handle: FileHandle, chunk: (Data) -> Void) {
    while autoreleasepool(invoking: { () -> Bool in
        let data = handle.availableData
        guard !data.isEmpty else { return false }
        chunk(data)
        return true
    }) {}
}

struct ClaudeCodeLineBuffer {
    private var data = Data()

    mutating func append(_ chunk: Data) -> [Data] {
        data.append(chunk)
        var lines: [Data] = []
        while let newline = data.firstIndex(of: 10) {
            let line = Data(data[..<newline])
            if !line.isEmpty { lines.append(line) }
            data.removeSubrange(...newline)
        }
        return lines
    }

    mutating func finish() -> Data? {
        defer { data.removeAll() }
        return data.isEmpty ? nil : data
    }
}
