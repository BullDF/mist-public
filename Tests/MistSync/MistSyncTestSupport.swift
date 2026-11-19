import Foundation

// The real helper depends on the app. Tests always inject their own vault URL.
enum FileSystemUtils {
    static func applicationSupportDirctory() -> String { fatalError("A test must inject its state directory") }
}

@MainActor
final class MemoryPasswordStore: MistPasswordSyncStorage {
    var data = MistPasswordData()
    var failNextChange = false
    var syncDidCommit: ((MistPasswordData, MistPasswordData) throws -> Void)?
    func load() throws {}
    func change(_ edit: (inout MistPasswordData) -> Void, reportingLocalChanges: Bool = true) throws {
        if failNextChange {
            failNextChange = false
            throw SyncTestFailure(description: "Injected password store failure")
        }
        let old = data
        edit(&data)
        if reportingLocalChanges { try syncDidCommit?(old, data) }
    }
}

struct SyncTestFailure: Error, CustomStringConvertible {
    let description: String
}

func expectSync(_ condition: @autoclosure () throws -> Bool, _ message: String,
                file: StaticString = #filePath, line: UInt = #line) throws {
    if try !condition() { throw SyncTestFailure(description: "\(file):\(line): \(message)") }
}

func expectSyncThrows(_ message: String, _ action: () throws -> Void) throws {
    do { try action() } catch { return }
    throw SyncTestFailure(description: "Expected failure: \(message)")
}

func expectSyncThrowsAsync(_ message: String, _ action: () async throws -> Void) async throws {
    do { try await action() } catch { return }
    throw SyncTestFailure(description: "Expected failure: \(message)")
}

final class MemorySyncKeys: MistSyncKeyStorage {
    var value: MistSyncCredentials?
    func load() throws -> MistSyncCredentials? { value }
    func save(_ credentials: MistSyncCredentials) throws { value = credentials }
    func delete() throws { value = nil }
}

@MainActor
final class MemorySyncSource: MistSyncSource {
    let kinds: Set<String>
    init(kind: String = "example") { kinds = [kind] }
    var onChange: (([MistSyncRecord]) throws -> Void)?
    var records: [String: MistSyncRecord] = [:]
    var applied: [String] = []
    var failID: String?
    var beforeApply: (() async throws -> Void)?
    func snapshot() throws -> [MistSyncRecord] { Array(records.values) }
    func deduplicate(versions: [String: String]) throws {}
    func apply(_ record: MistSyncRecord) async throws {
        try await beforeApply?()
        if failID == record.id { throw SyncTestFailure(description: "Injected source failure") }
        applied.append(record.id)
        if record.deleted { records.removeValue(forKey: record.id) } else { records[record.id] = record }
    }
}

func syncFrame(_ frame: MistSyncFrame) throws -> String {
    String(decoding: try JSONEncoder().encode(frame), as: UTF8.self)
}

func syncTestDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mist-sync-test-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}
