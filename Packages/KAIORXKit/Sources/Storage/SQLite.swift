import Foundation
import SQLite3

public struct SQLiteError: Error, Equatable, Sendable, CustomStringConvertible {
    public let code: Int32
    public let message: String

    public var description: String { "SQLite error \(code): \(message)" }

    /// Primary result code without extended bits.
    public var primaryCode: Int32 { code & 0xFF }
}

enum SQLValue: Equatable {
    case null
    case integer(Int64)
    case text(String)
    case blob(Data)

    static func optional(_ value: String?) -> SQLValue { value.map(SQLValue.text) ?? .null }
    static func optional(_ value: Int64?) -> SQLValue { value.map(SQLValue.integer) ?? .null }
    static func optional(_ value: Int?) -> SQLValue { value.map { .integer(Int64($0)) } ?? .null }
}

private let transientDestructor = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Read access to the current result row. Valid only inside the `query` callback.
struct SQLRow {
    fileprivate let statement: OpaquePointer

    func isNull(_ column: Int32) -> Bool {
        sqlite3_column_type(statement, column) == SQLITE_NULL
    }

    func int(_ column: Int32) -> Int64 {
        sqlite3_column_int64(statement, column)
    }

    func optionalInt(_ column: Int32) -> Int64? {
        isNull(column) ? nil : int(column)
    }

    /// Reads the full byte length, so text with embedded NUL characters survives.
    func text(_ column: Int32) -> String? {
        guard let pointer = sqlite3_column_text(statement, column) else { return nil }
        let count = Int(sqlite3_column_bytes(statement, column))
        return String(decoding: UnsafeRawBufferPointer(start: pointer, count: count), as: UTF8.self)
    }

    func requiredText(_ column: Int32) throws -> String {
        guard let value = text(column) else {
            throw SQLiteError(code: SQLITE_MISMATCH, message: "Unexpected NULL in column \(column)")
        }
        return value
    }

    func blob(_ column: Int32) -> Data? {
        if isNull(column) { return nil }
        let count = Int(sqlite3_column_bytes(statement, column))
        guard count > 0, let pointer = sqlite3_column_blob(statement, column) else { return Data() }
        return Data(bytes: pointer, count: count)
    }
}

/// Thin wrapper around one SQLite connection. Not thread-safe by itself; the owning `Store` actor
/// serialises all access, so there is exactly one writer.
final class SQLiteConnection {
    private var handle: OpaquePointer?

    init(path: String) throws {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(path, &db, flags, nil)
        guard rc == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "Cannot open database"
            sqlite3_close_v2(db)
            throw SQLiteError(code: rc, message: message)
        }
        sqlite3_extended_result_codes(db, 1)
        handle = db
    }

    deinit { close() }

    var isOpen: Bool { handle != nil }

    func close() {
        guard let handle else { return }
        sqlite3_close_v2(handle)
        self.handle = nil
    }

    private func db() throws -> OpaquePointer {
        guard let handle else { throw SQLiteError(code: SQLITE_MISUSE, message: "Connection is closed") }
        return handle
    }

    private func error(_ code: Int32) -> SQLiteError {
        let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "Connection is closed"
        return SQLiteError(code: code, message: message)
    }

    /// Connection settings from the runtime contract: foreign keys on every connection, WAL on a
    /// local disk, durable commits and a busy timeout.
    func configure(busyTimeoutMillis: Int32 = 5_000) throws {
        // First, so the pragmas below wait for another connection instead of failing.
        sqlite3_busy_timeout(try db(), busyTimeoutMillis)
        try execute("PRAGMA foreign_keys = ON")
        let mode = try query("PRAGMA journal_mode = WAL") { try $0.requiredText(0) }.first
        guard mode?.lowercased() == "wal" else {
            throw SQLiteError(code: SQLITE_ERROR, message: "WAL journal mode unavailable (got \(mode ?? "nil"))")
        }
        try execute("PRAGMA synchronous = FULL")
    }

    /// Runs one or more statements without parameters.
    func execute(_ sql: String) throws {
        var message: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(try db(), sql, nil, nil, &message)
        if rc != SQLITE_OK {
            let text = message.map { String(cString: $0) } ?? "Unknown error"
            sqlite3_free(message)
            throw SQLiteError(code: rc, message: text)
        }
    }

    func run(_ sql: String, _ values: [SQLValue] = []) throws {
        let statement = try prepare(sql, values)
        defer { sqlite3_finalize(statement) }
        let rc = sqlite3_step(statement)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else { throw error(rc) }
    }

    func query<T>(_ sql: String, _ values: [SQLValue] = [], _ map: (SQLRow) throws -> T) throws -> [T] {
        let statement = try prepare(sql, values)
        defer { sqlite3_finalize(statement) }
        var rows: [T] = []
        while true {
            let rc = sqlite3_step(statement)
            if rc == SQLITE_DONE { return rows }
            guard rc == SQLITE_ROW else { throw error(rc) }
            rows.append(try map(SQLRow(statement: statement)))
        }
    }

    var changes: Int {
        handle.map { Int(sqlite3_changes($0)) } ?? 0
    }

    var lastInsertRowID: Int64 {
        handle.map { sqlite3_last_insert_rowid($0) } ?? 0
    }

    /// `BEGIN IMMEDIATE` takes the write lock up front, so validation and commit see the same data.
    func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    /// Online backup of the main database into a new, owner-only file.
    func backup(to path: String) throws {
        let fd = open(path, O_CREAT | O_EXCL | O_WRONLY, 0o600)
        guard fd >= 0 else {
            throw SQLiteError(code: SQLITE_CANTOPEN, message: "Cannot create backup \(path): errno \(errno)")
        }
        Darwin.close(fd)
        let destination = try SQLiteConnection(path: path)
        defer { destination.close() }
        guard let backup = sqlite3_backup_init(try destination.db(), "main", try db(), "main") else {
            throw destination.error(sqlite3_errcode(try destination.db()))
        }
        let rc = sqlite3_backup_step(backup, -1)
        let finish = sqlite3_backup_finish(backup)
        guard rc == SQLITE_DONE else { throw SQLiteError(code: rc, message: "Backup step failed") }
        guard finish == SQLITE_OK else { throw destination.error(finish) }
    }

    private func prepare(_ sql: String, _ values: [SQLValue]) throws -> OpaquePointer {
        var statement: OpaquePointer?
        let rc = sqlite3_prepare_v2(try db(), sql, -1, &statement, nil)
        guard rc == SQLITE_OK, let statement else { throw error(rc) }
        do {
            for (offset, value) in values.enumerated() {
                try bind(value, at: Int32(offset + 1), in: statement)
            }
        } catch {
            sqlite3_finalize(statement)
            throw error
        }
        return statement
    }

    private func bind(_ value: SQLValue, at index: Int32, in statement: OpaquePointer) throws {
        let rc: Int32
        switch value {
        case .null:
            rc = sqlite3_bind_null(statement, index)
        case .integer(let number):
            rc = sqlite3_bind_int64(statement, index, number)
        case .text(let text):
            // Explicit byte length: `-1` would stop at an embedded NUL.
            rc = sqlite3_bind_text(statement, index, text, Int32(text.utf8.count), transientDestructor)
        case .blob(let data):
            if data.isEmpty {
                rc = sqlite3_bind_zeroblob(statement, index, 0)
            } else {
                rc = data.withUnsafeBytes { buffer in
                    sqlite3_bind_blob(statement, index, buffer.baseAddress, Int32(buffer.count), transientDestructor)
                }
            }
        }
        guard rc == SQLITE_OK else { throw error(rc) }
    }
}
