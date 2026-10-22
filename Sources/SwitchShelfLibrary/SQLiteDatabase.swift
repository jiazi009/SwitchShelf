import Foundation
import CSQLite

public enum SQLiteError: Error, LocalizedError, Equatable {
    case openFailed(String)
    case prepareFailed(String, code: Int32)
    case executionFailed(String, code: Int32)
    case stepFailed(String, code: Int32)
    case migrationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .openFailed(let msg): return "SQLite open failed: \(msg)"
        case .prepareFailed(let msg, let code): return "SQLite prepare failed (code \(code)): \(msg)"
        case .executionFailed(let msg, let code): return "SQLite execution failed (code \(code)): \(msg)"
        case .stepFailed(let msg, let code): return "SQLite step failed (code \(code)): \(msg)"
        case .migrationFailed(let msg): return "SQLite migration failed: \(msg)"
        }
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

final class SQLiteDatabase {
    private var db: OpaquePointer?

    init(databaseURL: URL) throws {
        let fileManager = FileManager.default
        let directoryURL = databaseURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        let path = databaseURL.path
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(path, &handle, flags, nil)
        guard rc == SQLITE_OK, let handle else {
            let msg = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "Unknown error"
            if let handle { sqlite3_close_v2(handle) }
            throw SQLiteError.openFailed(msg)
        }
        self.db = handle

        try execute("PRAGMA journal_mode = WAL;")
        try execute("PRAGMA foreign_keys = ON;")
        try runMigrations()
    }

    deinit {
        if let db {
            sqlite3_close_v2(db)
        }
    }

    func execute(_ sql: String) throws {
        guard let db else { throw SQLiteError.executionFailed("Database closed", code: -1) }
        var errmsg: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &errmsg)
        if rc != SQLITE_OK {
            let msg = errmsg.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(db))
            sqlite3_free(errmsg)
            throw SQLiteError.executionFailed(msg, code: rc)
        }
    }

    func beginTransaction() throws {
        try execute("BEGIN IMMEDIATE TRANSACTION;")
    }

    func commit() throws {
        try execute("COMMIT;")
    }

    func rollback() throws {
        try execute("ROLLBACK;")
    }

    func prepare(_ sql: String) throws -> SQLiteStatement {
        guard let db else { throw SQLiteError.prepareFailed("Database closed", code: -1) }
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK, let stmt else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw SQLiteError.prepareFailed("\(msg) for query: \(sql)", code: rc)
        }
        return SQLiteStatement(stmt: stmt)
    }

    private func currentSchemaVersion() throws -> Int32 {
        let stmt = try prepare("PRAGMA user_version;")
        defer { stmt.finalize() }
        if try stmt.step() {
            return stmt.columnInt32(0)
        }
        return 0
    }

    private func runMigrations() throws {
        let version = try currentSchemaVersion()
        if version < 1 {
            try migrateToV1()
            try execute("PRAGMA user_version = 1;")
        }
    }

    private func migrateToV1() throws {
        let schema = """
        CREATE TABLE IF NOT EXISTS sources (
            id TEXT PRIMARY KEY,
            url TEXT NOT NULL,
            name TEXT NOT NULL,
            availability TEXT NOT NULL,
            bookmark BLOB
        );

        CREATE TABLE IF NOT EXISTS games (
            id TEXT PRIMARY KEY,
            title TEXT NOT NULL,
            original_title TEXT,
            cover_url TEXT,
            identification TEXT NOT NULL
        );

        CREATE TABLE IF NOT EXISTS contents (
            id TEXT PRIMARY KEY,
            game_id TEXT NOT NULL,
            title_id TEXT,
            kind TEXT NOT NULL,
            raw_version INTEGER,
            display_version TEXT,
            file_url TEXT NOT NULL,
            byte_count INTEGER NOT NULL,
            format TEXT NOT NULL,
            availability TEXT NOT NULL,
            FOREIGN KEY(game_id) REFERENCES games(id) ON DELETE CASCADE
        );

        CREATE TABLE IF NOT EXISTS snapshot_meta (
            key TEXT PRIMARY KEY,
            value TEXT
        );

        CREATE TABLE IF NOT EXISTS snapshot_issues (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            issue TEXT NOT NULL
        );

        CREATE INDEX IF NOT EXISTS idx_contents_game_id ON contents(game_id);
        CREATE INDEX IF NOT EXISTS idx_contents_title_id ON contents(title_id);
        """
        try execute(schema)
    }
}

final class SQLiteStatement {
    private var stmt: OpaquePointer?

    init(stmt: OpaquePointer) {
        self.stmt = stmt
    }

    func finalize() {
        if let s = stmt {
            sqlite3_finalize(s)
            self.stmt = nil
        }
    }

    func reset() {
        guard let stmt else { return }
        sqlite3_reset(stmt)
        sqlite3_clear_bindings(stmt)
    }

    func bindText(_ index: Int32, _ value: String?) throws {
        guard let stmt else { return }
        if let value {
            let rc = value.withCString { cStr in
                sqlite3_bind_text(stmt, index, cStr, -1, SQLITE_TRANSIENT)
            }
            if rc != SQLITE_OK {
                throw SQLiteError.executionFailed("Bind text failed at index \(index)", code: rc)
            }
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }

    func bindInt64(_ index: Int32, _ value: Int64?) throws {
        guard let stmt else { return }
        if let value {
            let rc = sqlite3_bind_int64(stmt, index, value)
            if rc != SQLITE_OK {
                throw SQLiteError.executionFailed("Bind int64 failed at index \(index)", code: rc)
            }
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }

    func bindBlob(_ index: Int32, _ value: Data?) throws {
        guard let stmt else { return }
        if let value, !value.isEmpty {
            let rc = value.withUnsafeBytes { buffer in
                sqlite3_bind_blob(stmt, index, buffer.baseAddress, Int32(value.count), SQLITE_TRANSIENT)
            }
            if rc != SQLITE_OK {
                throw SQLiteError.executionFailed("Bind blob failed at index \(index)", code: rc)
            }
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }

    func step() throws -> Bool {
        guard let stmt else { return false }
        let rc = sqlite3_step(stmt)
        if rc == SQLITE_ROW {
            return true
        } else if rc == SQLITE_DONE {
            return false
        } else {
            throw SQLiteError.stepFailed("Step failed", code: rc)
        }
    }

    func columnText(_ index: Int32) -> String? {
        guard let stmt else { return nil }
        guard let cStr = sqlite3_column_text(stmt, index) else { return nil }
        return String(cString: cStr)
    }

    func columnInt32(_ index: Int32) -> Int32 {
        guard let stmt else { return 0 }
        return sqlite3_column_int(stmt, index)
    }

    func columnInt64(_ index: Int32) -> Int64? {
        guard let stmt else { return nil }
        if sqlite3_column_type(stmt, index) == SQLITE_NULL {
            return nil
        }
        return sqlite3_column_int64(stmt, index)
    }

    func columnBlob(_ index: Int32) -> Data? {
        guard let stmt else { return nil }
        if sqlite3_column_type(stmt, index) == SQLITE_NULL {
            return nil
        }
        guard let bytes = sqlite3_column_blob(stmt, index) else { return nil }
        let count = Int(sqlite3_column_bytes(stmt, index))
        return Data(bytes: bytes, count: count)
    }
}
