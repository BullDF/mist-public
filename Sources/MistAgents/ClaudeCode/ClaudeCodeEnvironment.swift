import Foundation
import Darwin

struct ClaudeCodeEnvironment: Sendable {
    let variables: [String: String]
    let executable: URL?

    // Static initialization shares one capture across all sessions in this app run.
    static let shared = Task.detached(priority: .userInitiated) { capture() }

    static func parse(_ data: Data) -> [String: String] {
        var result: [String: String] = [:]
        for field in data.split(separator: 0) {
            guard let entry = String(data: Data(field), encoding: .utf8),
                  let separator = entry.firstIndex(of: "="), separator != entry.startIndex else { continue }
            result[String(entry[..<separator])] = String(entry[entry.index(after: separator)...])
        }
        return sanitized(result)
    }

    static func sanitized(_ environment: [String: String]) -> [String: String] {
        environment.filter { $0.key != "CLAUDECODE" && !$0.key.hasPrefix("CLAUDE_CODE_") }
    }

    static func subscriptionVariables(_ environment: [String: String]) -> [String: String] {
        environment.filter { !$0.key.hasPrefix("ANTHROPIC_") && $0.key != "OPENAI_API_KEY" }
    }

    static func findExecutable(name: String = "claude", environment: [String: String], home: URL,
                               isExecutable: (String) -> Bool = FileManager.default.isExecutableFile(atPath:)) -> URL? {
        let candidates = (environment["PATH"] ?? "").split(separator: ":").map { String($0) + "/" + name }
            + [home.appendingPathComponent(".local/bin/" + name).path, "/opt/homebrew/bin/" + name, "/usr/local/bin/" + name]
        // Relative entries depend on the conversation's cwd and cannot identify an installed CLI.
        return candidates.first { $0.hasPrefix("/") && isExecutable($0) }.map { URL(fileURLWithPath: $0) }
    }

    static func capture(
        shell: String? = loginShell(),
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        appEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        runShell: (String) -> Data? = captureLoginShell,
        isExecutable: (String) -> Bool = FileManager.default.isExecutableFile(atPath:)
    ) -> Self {
        var variables = shell.flatMap(runShell).map(parse) ?? [:]
        if variables["PATH"] == nil {
            variables = sanitized(appEnvironment)
            variables["PATH"] = home.appendingPathComponent(".local/bin").path
                + ":/opt/homebrew/bin:/usr/local/bin:" + (variables["PATH"] ?? "/usr/bin:/bin")
        }
        return Self(variables: variables, executable: findExecutable(environment: variables, home: home, isExecutable: isExecutable))
    }

    static func loginShell() -> String? {
        guard let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell else { return nil }
        return String(cString: shell)
    }

    static func captureLoginShell(_ shell: String) -> Data? {
        let process = Process()
        let output = Pipe()
        let finished = DispatchSemaphore(value: 0)
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-l", "-c", "/usr/bin/env -0"]
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        process.environment = sanitized(ProcessInfo.processInfo.environment)
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { _ in finished.signal() }
        do { try process.run() } catch { return nil }
        try? output.fileHandleForWriting.close()
        defer { try? output.fileHandleForReading.close() }
        let descriptor = output.fileHandleForReading.fileDescriptor
        _ = fcntl(descriptor, F_SETFL, O_NONBLOCK)
        let deadline = ProcessInfo.processInfo.systemUptime + 10
        var data = Data()
        var bytes = [UInt8](repeating: 0, count: 8192)
        var eof = false
        while ProcessInfo.processInfo.systemUptime < deadline {
            var descriptorState = pollfd(fd: descriptor, events: Int16(POLLIN | POLLHUP), revents: 0)
            _ = poll(&descriptorState, 1, 50)
            let count = Darwin.read(descriptor, &bytes, bytes.count)
            if count > 0 { data.append(contentsOf: bytes.prefix(count)) }
            else if count == 0 { eof = true; break }
            else if errno != EAGAIN && errno != EINTR { break }
        }
        let remaining = max(0, deadline - ProcessInfo.processInfo.systemUptime)
        guard eof, finished.wait(timeout: .now() + remaining) == .success, process.terminationStatus == 0 else {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            return nil
        }
        return data
    }
}
