import CryptoKit
import Foundation

enum MistSyncBase64 {
    static func encode(_ bytes: Data) -> String {
        bytes.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    static func decode(_ value: String) throws -> Data {
        guard !value.isEmpty, value.utf8.allSatisfy({
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95
        }), value.count % 4 != 1 else { throw MistSyncError.invalidConfiguration }
        let padded = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            + String(repeating: "=", count: (4 - value.count % 4) % 4)
        guard let bytes = Data(base64Encoded: padded), encode(bytes) == value else {
            throw MistSyncError.invalidConfiguration
        }
        return bytes
    }
}

struct MistSyncCrypto {
    private let encryption: SymmetricKey
    private let identity: SymmetricKey
    let token: String

    init(groupKey: Data) throws {
        guard groupKey.count == 32 else { throw MistSyncError.invalidConfiguration }
        func derive(_ info: String) -> SymmetricKey {
            HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: groupKey),
                                  salt: Data("mist-sync-v1".utf8), info: Data(info.utf8), outputByteCount: 32)
        }
        encryption = derive("enc")
        identity = derive("id")
        token = MistSyncBase64.encode(derive("auth").withUnsafeBytes { Data($0) })
    }

    func serverID(kind: String, id: String) -> String {
        MistSyncBase64.encode(Data(HMAC<SHA256>.authenticationCode(for: Data("\(kind)/\(id)".utf8), using: identity)))
    }

    func seal(_ record: MistSyncRecord) throws -> MistSyncWireRecord {
        guard let bytes = try AES.GCM.seal(JSONEncoder().encode(record), using: encryption).combined,
              bytes.base64EncodedString().utf8.count <= 65_536 else { throw MistSyncError.invalidRecord }
        return MistSyncWireRecord(id: serverID(kind: record.kind, id: record.id), hlc: record.hlc,
                                 blob: bytes.base64EncodedString())
    }

    func open(_ wire: MistSyncWireRecord) throws -> MistSyncRecord {
        guard wire.blob.utf8.count <= 65_536, let bytes = Data(base64Encoded: wire.blob) else {
            throw MistSyncError.invalidRecord
        }
        let plain = try AES.GCM.open(AES.GCM.SealedBox(combined: bytes), using: encryption)
        let record = try JSONDecoder().decode(MistSyncRecord.self, from: plain)
        guard !record.kind.isEmpty, record.kind.utf8.allSatisfy({ (97...122).contains($0) || $0 == 45 }),
              !record.id.isEmpty, wire.id == serverID(kind: record.kind, id: record.id) else {
            throw MistSyncError.invalidRecord
        }
        _ = try MistSyncClock.parts(record.hlc)
        return record
    }
}
