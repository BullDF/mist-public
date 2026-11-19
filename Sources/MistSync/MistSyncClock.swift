import Foundation

struct MistSyncClock: Codable, Equatable {
    private(set) var milliseconds: Int64 = 0
    private(set) var counter = 0

    static func parts(_ value: String) throws -> (Int64, Int) {
        let fields = value.split(separator: "-", maxSplits: 2, omittingEmptySubsequences: false)
        guard fields.count == 3, fields[0].count == 15, fields[1].count == 6,
              fields[0].allSatisfy({ $0.isASCII && $0.isNumber }),
              fields[1].allSatisfy({ $0.isASCII && $0.isNumber }),
              !fields[2].isEmpty, fields[2].count <= 64,
              fields[2].allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }),
              let ms = Int64(fields[0]), let count = Int(fields[1]) else { throw MistSyncError.invalidRecord }
        return (ms, count)
    }

    /// Advance on both edits and receives, even when the wall clock moves backward.
    @discardableResult
    mutating func tick(deviceID: String, receiving: String? = nil,
                       now: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) throws -> String {
        let remote = try receiving.map(Self.parts)
        let next = max(milliseconds, remote?.0 ?? 0, now)
        var count = next == milliseconds ? counter + 1 : 0
        if let remote, next == remote.0 { count = max(count, remote.1 + 1) }
        milliseconds = next
        if count > 999_999 { milliseconds += 1; count = 0 }
        guard milliseconds >= 0, milliseconds < 1_000_000_000_000_000 else { throw MistSyncError.invalidRecord }
        counter = count
        return String(format: "%015lld-%06d-%@", milliseconds, counter, deviceID)
    }
}
