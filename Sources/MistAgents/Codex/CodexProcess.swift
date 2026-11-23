import Foundation
import Darwin

/// A private stdio JSON transport. All reads, writes, and response correlation run off the main actor.
final class CodexProcess: @unchecked Sendable {
    enum Wire { case appServer, acp }
    var processIdentifier: Int32 { process.processIdentifier }
    enum Output: Sendable {
        case message(CodexJSON)
        case exited(code: Int32, stderr: String)
        case writeFailed(String)
    }

    enum TransportError: LocalizedError {
        case closed, timedOut, server(CodexJSON), exited(stderr: String)
        var errorDescription: String? {
            switch self {
            case let .exited(stderr): return CodexStrings.exited + (stderr.isEmpty ? "" : "\n" + stderr)
            case let .server(value): return value["message"].string ?? CodexStrings.invalidResponse
            case .closed: return CodexStrings.exited
            case .timedOut: return CodexStrings.timedOut
            }
        }
    }
    let output: AsyncStream<Output>
    private let continuation: AsyncStream<Output>.Continuation
    private let process = Process()
    private let input = Pipe(), stdout = Pipe(), stderr = Pipe()
    private let writer = DispatchQueue(label: "mist.codex.stdin")
    private let control = DispatchQueue(label: "mist.codex.lifecycle")
    private let delivery = DispatchQueue(label: "mist.codex.events")
    private let readers = DispatchGroup()
    private let wire: Wire
    private var stderrTail = Data() // Delivery queue only.
    private var pending: [Int: CheckedContinuation<CodexJSON, Error>] = [:]
    private var nextId = 0
    private var exited = false
    private var closing = false // Control queue only.

    init(executable: URL, arguments: [String] = CodexProtocol.arguments, folder: URL, environment: [String: String],
         wire: Wire = .appServer) throws {
        self.wire = wire
        var continuation: AsyncStream<Output>.Continuation!
        output = AsyncStream { continuation = $0 }
        self.continuation = continuation
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = folder
        process.environment = wire == .acp ? environment : CodexProtocol.environment(environment)
        process.standardInput = input; process.standardOutput = stdout
        process.standardError = wire == .acp ? FileHandle.nullDevice : stderr
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        readers.enter()
        if wire == .appServer { readers.enter() }
        process.terminationHandler = { [weak self] process in
            guard let self else { return }
            let code = process.terminationStatus
            self.readers.notify(queue: self.delivery) {
                self.exited = true
                let detail = String(decoding: self.stderrTail, as: UTF8.self)
                self.failPending(TransportError.exited(stderr: detail))
                self.continuation.yield(.exited(code: code, stderr: detail))
                self.continuation.finish()
            }
        }
        do { try process.run() }
        catch {
            readers.leave()
            if wire == .appServer { readers.leave() }
            continuation.finish()
            throw error
        }
        try? input.fileHandleForReading.close(); try? stdout.fileHandleForWriting.close()
        read(stdout.fileHandleForReading, isStdout: true)
        if wire == .appServer {
            try? stderr.fileHandleForWriting.close()
            read(stderr.fileHandleForReading, isStdout: false)
        }
    }

    func request(_ method: String, _ params: CodexJSON, timeout: TimeInterval = 30) async throws -> CodexJSON {
        try await withCheckedThrowingContinuation { reply in
            delivery.async { [self] in
                guard !exited else { reply.resume(throwing: TransportError.closed); return }
                nextId += 1
                let id = nextId
                pending[id] = reply
                write(["id": .number(Double(id)), "method": .string(method), "params": params])
                delivery.asyncAfter(deadline: .now() + timeout) { [self] in
                    pending.removeValue(forKey: id)?.resume(throwing: TransportError.timedOut)
                }
            }
        }
    }

    func notify(_ method: String, _ params: CodexJSON = .object([:])) {
        write(["method": .string(method), "params": params])
    }

    /// ACP prompt replies share the notification stream so the final update always precedes the reply.
    func requestInStream(id: String, method: String, params: CodexJSON) {
        write(["id": .string(id), "method": .string(method), "params": params])
    }

    func reply(id: CodexJSON, result: CodexJSON) { write(["id": id, "result": result]) }
    func reject(id: CodexJSON) {
        write(["id": id, "error": .object(["code": .number(-32601), "message": .string("Unsupported by Mist")])])
    }

    private func write(_ fields: [String: CodexJSON]) {
        var fields = fields
        if wire == .acp { fields["jsonrpc"] = .string("2.0") }
        let value = CodexJSON.object(fields)
        writer.async { [self] in
            do { try input.fileHandleForWriting.write(contentsOf: Data((value.json() + "\n").utf8)) }
            catch {
                delivery.async { [self] in
                    failPending(error)
                    continuation.yield(.writeFailed(error.localizedDescription))
                }
            }
        }
    }

    func terminate() {
        control.async { [self] in
            guard !closing else { return }
            closing = true
            writer.async { [self] in try? input.fileHandleForWriting.close() }
            control.asyncAfter(deadline: .now() + 2) { [self] in
                guard process.isRunning else { return }
                process.terminate()
                control.asyncAfter(deadline: .now() + 2) { [self] in
                    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                }
            }
        }
    }

    func terminateNow() {
        control.sync { closing = true }
        writer.async { [self] in try? input.fileHandleForWriting.close() }
        if process.isRunning { process.terminate() }
    }

    private func failPending(_ error: Error) {
        let replies = pending.values
        pending.removeAll()
        for reply in replies { reply.resume(throwing: error) }
    }

    private func read(_ handle: FileHandle, isStdout: Bool) {
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            defer { try? handle.close(); readers.leave() }
            var buffer = ClaudeCodeLineBuffer()
            readAgentPipe(handle) { data in
                if isStdout { for line in buffer.append(data) { decode(line) } }
                else { delivery.async { [self] in stderrTail.append(data); stderrTail = Data(stderrTail.suffix(8192)) } }
            }
            if isStdout, let last = buffer.finish() { decode(last) }
        }
    }

    private func decode(_ line: Data) {
        delivery.async { [self] in
            guard let value = try? JSONDecoder().decode(CodexJSON.self, from: line) else { return }
            if wire == .acp, value["jsonrpc"].string != "2.0" { return }
            if value["method"].string != nil || (wire == .acp && value["id"].string != nil) { continuation.yield(.message(value)) }
            else if case .number = value["id"], let reply = pending.removeValue(forKey: value["id"].integer) {
                if value["error"] != .null { reply.resume(throwing: TransportError.server(value["error"])) }
                else { reply.resume(returning: value["result"]) }
            }
        }
    }
}
