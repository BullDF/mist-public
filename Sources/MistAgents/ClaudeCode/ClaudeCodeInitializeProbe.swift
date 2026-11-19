import Darwin
import Foundation

/// A metadata-only CLI round trip shared by the model and connector catalogs.
enum ClaudeCodeInitializeProbe {
    private enum QueryError: Error { case missingExecutable, timeout, invalidResponse }

    static func fetch(folder: URL, connectors: Bool = false,
                      environment captured: ClaudeCodeEnvironment? = nil) async throws -> ClaudeCodeJSON {
        let deadline = ProcessInfo.processInfo.systemUptime + (connectors ? 15 : 10)
        let environment: ClaudeCodeEnvironment
        if let captured { environment = captured }
        else { environment = await ClaudeCodeEnvironment.shared.value }
        return try await Task.detached(priority: .utility) {
            try query(folder: folder, environment: environment, deadline: deadline, connectors: connectors)
        }.value
    }

    private static func query(folder: URL, environment: ClaudeCodeEnvironment, deadline: TimeInterval, connectors: Bool) throws -> ClaudeCodeJSON {
        guard let executable = environment.executable else { throw QueryError.missingExecutable }
        guard ProcessInfo.processInfo.systemUptime < deadline else { throw QueryError.timeout }
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        let finished = DispatchSemaphore(value: 0)
        process.executableURL = executable
        process.arguments = ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose"]
        process.environment = connectors ? environment.variables.filter { !$0.key.hasPrefix("ANTHROPIC_") && $0.key != "OPENAI_API_KEY" } : environment.variables
        process.currentDirectoryURL = folder
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { _ in finished.signal() }
        defer {
            if process.isRunning {
                process.terminate()
                if finished.wait(timeout: .now() + 0.5) == .timedOut, process.isRunning {
                    kill(process.processIdentifier, SIGKILL)
                    _ = finished.wait(timeout: .now() + 0.5)
                }
            }
            try? input.fileHandleForReading.close()
            try? input.fileHandleForWriting.close()
            try? output.fileHandleForReading.close()
            try? output.fileHandleForWriting.close()
        }
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        try process.run()
        try input.fileHandleForReading.close()
        try output.fileHandleForWriting.close()
        let requestId = UUID().uuidString
        let requests = ClaudeCodeProtocol.initialize(requestId: requestId) + "\n"
        try input.fileHandleForWriting.write(contentsOf: Data(requests.utf8))
        var reply: ClaudeCodeJSON?
        var statusReply: ClaudeCodeJSON?
        var statusRequestIds = Set<String>()
        var nextStatus = ProcessInfo.processInfo.systemUptime
        func receive(_ line: Data) throws -> ClaudeCodeJSON? {
            if reply == nil { reply = try ClaudeCodeProtocol.initializeReply(from: line, requestId: requestId) }
            if connectors {
                for id in statusRequestIds {
                    if let response = try ClaudeCodeProtocol.controlResponse(from: line, requestId: id) {
                        guard response["subtype"].string == "success", case .array = response["response"]["mcpServers"] else {
                            throw QueryError.invalidResponse
                        }
                        statusReply = response["response"]
                        if !ClaudeCodeProtocol.connectors(from: response["response"]).isEmpty { return response["response"] }
                        break
                    }
                }
                return nil
            }
            return reply
        }
        let descriptor = output.fileHandleForReading.fileDescriptor
        _ = fcntl(descriptor, F_SETFL, O_NONBLOCK)
        var buffer = ClaudeCodeLineBuffer()
        var bytes = [UInt8](repeating: 0, count: 8192)
        while ProcessInfo.processInfo.systemUptime < deadline {
            if connectors, reply != nil, ProcessInfo.processInfo.systemUptime >= nextStatus {
                let id = UUID().uuidString
                statusRequestIds.insert(id)
                try input.fileHandleForWriting.write(contentsOf: Data((ClaudeCodeProtocol.mcpStatus(requestId: id) + "\n").utf8))
                nextStatus = ProcessInfo.processInfo.systemUptime + 0.5
            }
            var state = pollfd(fd: descriptor, events: Int16(POLLIN | POLLHUP), revents: 0)
            _ = poll(&state, 1, 50)
            let count = Darwin.read(descriptor, &bytes, bytes.count)
            if count > 0 {
                for line in buffer.append(Data(bytes.prefix(count))) {
                    if let result = try receive(line) { return result }
                }
            } else if count == 0 {
                if let line = buffer.finish(), let result = try receive(line) { return result }
                if connectors, let statusReply { return statusReply }
                if !connectors, let reply { return reply }
                throw QueryError.invalidResponse
            } else if errno != EAGAIN && errno != EINTR {
                throw QueryError.invalidResponse
            }
        }
        if connectors, let statusReply { return statusReply }
        if !connectors, let reply { return reply }
        throw QueryError.timeout
    }
}
