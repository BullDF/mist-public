import Foundation
import Darwin
import XCTest
#if !MIST_CODEX_HOSTLESS_TESTS
@testable import Phi
#endif

final class CodexProcessTests: XCTestCase {
    func testPipeReaderReleasesEachRead() throws {
        let pipe = Pipe()
        let consumed = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            readAgentPipe(pipe.fileHandleForReading) { _ in consumed.signal() }
            finished.signal()
        }
        defer { try? pipe.fileHandleForWriting.close() }
        let before = try physicalFootprint()
        for _ in 0..<2_000 {
            try autoreleasepool { try pipe.fileHandleForWriting.write(contentsOf: Data("x\n".utf8)) }
            guard consumed.wait(timeout: .now() + 5) == .success else {
                return XCTFail("Reader did not consume a chunk")
            }
        }
        let after = try physicalFootprint()
        try pipe.fileHandleForWriting.close()
        XCTAssertEqual(finished.wait(timeout: .now() + 5), .success)
        XCTAssertLessThan(Int64(after) - Int64(before), 8 * 1024 * 1024, "Footprint grew from \(before) to \(after) bytes")
    }

    func testConcurrentResponseCorrelationAndServerRequests() async throws {
        let captured = await ClaudeCodeEnvironment.shared.value
        let node = try XCTUnwrap(ClaudeCodeEnvironment.findExecutable(name: "node", environment: captured.variables, home: FileManager.default.homeDirectoryForCurrentUser))
        let code = #"""
        const rl = require('readline').createInterface({input:process.stdin});
        const send = v => process.stdout.write(JSON.stringify(v)+'\n');
        rl.on('line',l=>{const v=JSON.parse(l); if(v.method==='slow'||v.method==='fast')setTimeout(()=>send({id:v.id,result:{method:v.method}}),v.method==='slow'?60:0); else if(v.method==='ask'){send({id:99,method:'mcpServer/elicitation/request',params:{}});send({id:v.id,result:{}});} else if(v.id===99)send({method:'answered',params:v.result});});
        """#
        let process = try CodexProcess(executable: node, arguments: ["-e", code], folder: FileManager.default.temporaryDirectory, environment: captured.variables)
        defer { process.terminateNow() }
        async let slow = process.request("slow", .null)
        async let fast = process.request("fast", .null)
        let values = try await (slow, fast)
        XCTAssertEqual(values.0["method"].string, "slow")
        XCTAssertEqual(values.1["method"].string, "fast")
        _ = try await process.request("ask", .null)
        var iterator = process.output.makeAsyncIterator()
        guard case let .message(request) = await iterator.next() else { return XCTFail() }
        XCTAssertEqual(request["id"], .number(99))
        process.reply(id: request["id"], result: .object(["action": .string("decline")]))
        guard case let .message(answered) = await iterator.next() else { return XCTFail() }
        XCTAssertEqual(answered["params"]["action"].string, "decline")
    }

    func testRequestTimeoutAndExitTail() async throws {
        let process = try CodexProcess(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "echo fixture-stderr >&2; read line; sleep 0.2"],
            folder: FileManager.default.temporaryDirectory, environment: ["PATH": "/usr/bin:/bin"])
        defer { process.terminateNow() }
        do { _ = try await process.request("ignored", .null, timeout: 0.02); XCTFail("Expected timeout") }
        catch CodexProcess.TransportError.timedOut {} catch { XCTFail("Unexpected error") }
        for await output in process.output {
            if case let .exited(_, stderr) = output { XCTAssertTrue(stderr.contains("fixture-stderr")); return }
        }
        XCTFail("No exit event")
    }

    func testPendingResponseFailsOnExit() async throws {
        let process = try CodexProcess(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "echo pending-stderr >&2; read line; exit 1"],
            folder: FileManager.default.temporaryDirectory, environment: [:])
        do { _ = try await process.request("ignored", .null); XCTFail("Expected closed transport") }
        catch let CodexProcess.TransportError.exited(stderr) { XCTAssertTrue(stderr.contains("pending-stderr")) }
        catch { XCTFail("Exit lost its stderr detail") }
    }
}

private func physicalFootprint() throws -> UInt64 {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    guard result == KERN_SUCCESS else { throw NSError(domain: NSMachErrorDomain, code: Int(result)) }
    return info.phys_footprint
}
