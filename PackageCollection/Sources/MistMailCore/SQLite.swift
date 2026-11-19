import Foundation
import SQLite3

enum SQLValue {
    case text(String), integer(Int64), real(Double), blob(Data), null
    var string: String? { if case .text(let value) = self { return value }; return nil }
    var int: Int64? { if case .integer(let value) = self { return value }; return nil }
    var data: Data? { if case .blob(let value) = self { return value }; return nil }
}

/// Confined to MailEngine's actor after initialization; never shared with LocalStore.
final class MailSQLite {
    private var handle: OpaquePointer?
    init(url: URL) throws {
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            let error = failure(); sqlite3_close(handle); handle = nil; throw error
        }
        do {
            sqlite3_busy_timeout(handle, 5_000)
            try execute("PRAGMA foreign_keys=ON")
            try execute("PRAGMA journal_mode=WAL")
            // Creating the actual virtual table checks the loaded SQLite, not a build-time option.
            try execute("CREATE VIRTUAL TABLE IF NOT EXISTS mail_fts_probe USING fts5(value)")
            try execute("DROP TABLE mail_fts_probe")
        } catch { sqlite3_close(handle); handle = nil; throw error }
    }
    deinit { sqlite3_close(handle) }
    func execute(_ sql: String, _ bindings: [SQLValue] = []) throws { _ = try rows(sql, bindings) }
    func rows(_ sql: String, _ bindings: [SQLValue] = []) throws -> [[String: SQLValue]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { throw failure() }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, value) in bindings.enumerated() {
            let position = Int32(index + 1)
            let result: Int32
            switch value {
            case .text(let text): result = sqlite3_bind_text(statement, position, text, -1, transient)
            case .integer(let number): result = sqlite3_bind_int64(statement, position, number)
            case .real(let number): result = sqlite3_bind_double(statement, position, number)
            case .blob(let data): result = data.withUnsafeBytes { sqlite3_bind_blob(statement, position, $0.baseAddress, Int32($0.count), transient) }
            case .null: result = sqlite3_bind_null(statement, position)
            }
            guard result == SQLITE_OK else { throw failure() }
        }
        var output: [[String: SQLValue]] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return output }
            guard result == SQLITE_ROW else { throw failure() }
            var row: [String: SQLValue] = [:]
            for index in 0..<sqlite3_column_count(statement) {
                let key = String(cString: sqlite3_column_name(statement, index))
                switch sqlite3_column_type(statement, index) {
                case SQLITE_INTEGER: row[key] = .integer(sqlite3_column_int64(statement, index))
                case SQLITE_FLOAT: row[key] = .real(sqlite3_column_double(statement, index))
                case SQLITE_TEXT: row[key] = .text(String(cString: sqlite3_column_text(statement, index)))
                case SQLITE_BLOB:
                    let count = Int(sqlite3_column_bytes(statement, index))
                    row[key] = .blob(count == 0 ? Data() : Data(bytes: sqlite3_column_blob(statement, index)!, count: count))
                default: row[key] = .null
                }
            }
            output.append(row)
        }
    }
    func transaction<T>(_ work: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do { let result = try work(); try execute("COMMIT"); return result }
        catch { try? execute("ROLLBACK"); throw error }
    }
    private func failure() -> MailError {
        .storage(handle.map { String(cString: sqlite3_errmsg($0)) } ?? "Cannot open mail database")
    }
}
