import Foundation

/// JSON values keep record payloads extensible without adding data kinds to the engine.
enum MistSyncValue: Codable, Equatable {
    case string(String), number(Double), bool(Bool), object([String: MistSyncValue]), array([MistSyncValue]), null

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let bool = try? value.decode(Bool.self) { self = .bool(bool) }
        else if let string = try? value.decode(String.self) { self = .string(string) }
        else if let number = try? value.decode(Double.self) { self = .number(number) }
        else if let object = try? value.decode([String: MistSyncValue].self) { self = .object(object) }
        else { self = .array(try value.decode([MistSyncValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .string(let item): try value.encode(item)
        case .number(let item): try value.encode(item)
        case .bool(let item): try value.encode(item)
        case .object(let item): try value.encode(item)
        case .array(let item): try value.encode(item)
        case .null: try value.encodeNil()
        }
    }

    var string: String? { if case .string(let value) = self { return value }; return nil }
}

struct MistSyncRecord: Codable, Equatable {
    var kind: String
    var id: String
    var hlc = ""
    var deleted = false
    var payload: [String: MistSyncValue] = [:]
    var versionKey: String { "\(kind)/\(id)" }
}

struct MistSyncWireRecord: Codable, Equatable {
    var seq: Int64?
    var id: String
    var hlc: String
    var blob: String
}

struct MistSyncFrame: Codable {
    var t: String
    var after: Int64?
    var ref: Int?
    var items: [MistSyncWireRecord]?
    var seq: Int64?
    var message: String?
}

@MainActor
protocol MistSyncSource: AnyObject {
    var kinds: Set<String> { get }
    var onChange: (([MistSyncRecord]) throws -> Void)? { get set }
    func snapshot() throws -> [MistSyncRecord]
    func prepare(versions: [String: String])
    func prepareIncoming(_ records: [MistSyncRecord])
    func flushPendingChanges() throws
    func apply(_ record: MistSyncRecord) async throws
    func deduplicate(versions: [String: String]) throws
}

extension MistSyncSource {
    func prepare(versions: [String: String]) {}
    func prepareIncoming(_ records: [MistSyncRecord]) {}
    func flushPendingChanges() throws {}
}

enum MistSyncError: LocalizedError {
    case invalidConfiguration, invalidRecord, invalidFrame, unknownKind, missedPong, server(String)

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration: return MistSyncStrings.errorConfiguration
        case .invalidRecord: return MistSyncStrings.errorRecord
        case .invalidFrame: return MistSyncStrings.errorFrame
        case .unknownKind: return MistSyncStrings.errorKind
        case .missedPong: return MistSyncStrings.errorHeartbeat
        case .server(let message): return String(format: MistSyncStrings.errorServer, message)
        }
    }
}
