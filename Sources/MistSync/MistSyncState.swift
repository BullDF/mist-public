import Foundation

struct MistSyncState: Codable {
    var deviceID = UUID().uuidString
    var clock = MistSyncClock()
    var cursor: Int64 = 0
    var versions: [String: String] = [:]
    /// Only sealed records go to disk, so the sync state never contains plaintext passwords.
    var outbox: [String: MistSyncWireRecord] = [:]
    var needsInitialUpload = true
}

struct MistSyncStateStore {
    let directory: URL
    var file: URL { directory.appendingPathComponent("state.json") }

    func load() throws -> MistSyncState {
        guard FileManager.default.fileExists(atPath: file.path) else { return MistSyncState() }
        return try JSONDecoder().decode(MistSyncState.self, from: Data(contentsOf: file))
    }

    func save(_ state: MistSyncState) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(state).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    func delete() throws {
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
    }
}
