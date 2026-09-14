import Foundation
import SQLite3

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Minimal SQLite wrapper: one connection, serialized through a lock.
final class SQLiteDatabase: @unchecked Sendable {
    private var db: OpaquePointer?
    private let lock = NSLock()
    let path: String

    init(path: String) throws {
        self.path = path
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK, let handle else {
            let msg = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            throw HealthDataError.internalError("sqlite open failed: \(msg)")
        }
        db = handle
        try exec("PRAGMA journal_mode = WAL")
        try exec("PRAGMA synchronous = NORMAL")
        try exec("PRAGMA temp_store = MEMORY")
    }

    deinit {
        if let db { sqlite3_close_v2(db) }
    }

    func exec(_ sql: String) throws {
        lock.lock(); defer { lock.unlock() }
        var err: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &err) == SQLITE_OK else {
            let msg = err.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(err)
            throw HealthDataError.internalError("sqlite exec failed: \(msg) [\(sql.prefix(80))]")
        }
    }

    final class Statement {
        fileprivate var stmt: OpaquePointer?
        fileprivate init(stmt: OpaquePointer) { self.stmt = stmt }
        deinit { sqlite3_finalize(stmt) }

        func bind(_ index: Int32, _ value: String?) {
            if let value { sqlite3_bind_text(stmt, index, value, -1, sqliteTransient) } else { sqlite3_bind_null(stmt, index) }
        }
        func bind(_ index: Int32, _ value: Double?) {
            if let value { sqlite3_bind_double(stmt, index, value) } else { sqlite3_bind_null(stmt, index) }
        }
        func bind(_ index: Int32, _ value: Int?) {
            if let value { sqlite3_bind_int64(stmt, index, Int64(value)) } else { sqlite3_bind_null(stmt, index) }
        }
        func step() -> Bool { sqlite3_step(stmt) == SQLITE_ROW }
        /// For callers that need raw sqlite3 binding (tests write blobs).
        var rawHandle: OpaquePointer? { stmt }
        func reset() { sqlite3_reset(stmt); sqlite3_clear_bindings(stmt) }

        func string(_ col: Int32) -> String? {
            guard let c = sqlite3_column_text(stmt, col) else { return nil }
            return String(cString: c)
        }
        func double(_ col: Int32) -> Double? {
            sqlite3_column_type(stmt, col) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, col)
        }
        func int(_ col: Int32) -> Int? {
            sqlite3_column_type(stmt, col) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(stmt, col))
        }
        func blob(_ col: Int32) -> Data? {
            guard sqlite3_column_type(stmt, col) == SQLITE_BLOB, let p = sqlite3_column_blob(stmt, col) else { return nil }
            return Data(bytes: p, count: Int(sqlite3_column_bytes(stmt, col)))
        }
    }

    func prepare(_ sql: String) throws -> Statement {
        lock.lock(); defer { lock.unlock() }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw HealthDataError.internalError("sqlite prepare failed: \(String(cString: sqlite3_errmsg(db))) [\(sql.prefix(80))]")
        }
        return Statement(stmt: stmt)
    }

    /// Runs `body` with the connection lock held; use for read queries.
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }
        return try body()
    }

    func query<T>(_ sql: String, bind: (Statement) -> Void = { _ in }, row: (Statement) -> T) throws -> [T] {
        let stmt = try prepare(sql)
        return withLock {
            bind(stmt)
            var out: [T] = []
            while stmt.step() { out.append(row(stmt)) }
            return out
        }
    }

    func scalar(_ sql: String, bind: (Statement) -> Void = { _ in }) throws -> Double? {
        try query(sql, bind: bind) { $0.double(0) }.first ?? nil
    }
}
