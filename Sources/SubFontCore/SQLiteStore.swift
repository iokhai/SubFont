import Foundation
import CSQLite

enum SQLValue {
    case text(String), integer(Int64), blob(Data), null
    var string: String { if case let .text(v) = self { return v }; return "" }
    var int: Int64 { if case let .integer(v) = self { return v }; return 0 }
    var data: Data { if case let .blob(v) = self { return v }; return Data() }
}

/// Accessed exclusively by FontIndex's actor.
final class SQLiteStore {
    private var db: OpaquePointer?
    private var statements: [String: OpaquePointer] = [:]
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            throw SubFontError.message("无法打开字体索引")
        }
        sqlite3_busy_timeout(db, 3000)
        try execute("PRAGMA foreign_keys=ON")
        try execute("PRAGMA journal_mode=WAL")
        try execute("PRAGMA synchronous=NORMAL")
        let version = try rows("PRAGMA user_version").first?["user_version"]?.int ?? 0
        guard version <= 1 else { throw SubFontError.message("索引由更新版本的 SubFont 创建，请更新应用。") }
        if version == 0 {
            try transaction {
                for sql in Self.schema { try execute(sql) }
                try execute("PRAGMA user_version=1")
            }
        }
    }
    deinit {
        for statement in statements.values { sqlite3_finalize(statement) }
        sqlite3_close(db)
    }
    func execute(_ sql: String, _ values: [SQLValue] = []) throws {
        let statement = try prepare(sql, values)
        defer { sqlite3_reset(statement); sqlite3_clear_bindings(statement) }
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW { result = sqlite3_step(statement) }
        guard result == SQLITE_DONE else { throw failure() }
    }
    func rows(_ sql: String, _ values: [SQLValue] = []) throws -> [[String: SQLValue]] {
        let statement = try prepare(sql, values)
        defer { sqlite3_reset(statement); sqlite3_clear_bindings(statement) }
        var output: [[String: SQLValue]] = []
        var code = sqlite3_step(statement)
        while code == SQLITE_ROW {
            var row: [String: SQLValue] = [:]
            for i in 0..<sqlite3_column_count(statement) {
                let key = String(cString: sqlite3_column_name(statement, i))
                switch sqlite3_column_type(statement, i) {
                case SQLITE_INTEGER: row[key] = .integer(sqlite3_column_int64(statement, i))
                case SQLITE_TEXT:
                    row[key] = .text(String(cString: sqlite3_column_text(statement, i)))
                case SQLITE_BLOB:
                    let count = Int(sqlite3_column_bytes(statement, i))
                    row[key] = .blob(count == 0 ? Data() : Data(bytes: sqlite3_column_blob(statement, i)!, count: count))
                default: row[key] = .null
                }
            }
            output.append(row)
            code = sqlite3_step(statement)
        }
        guard code == SQLITE_DONE else { throw failure() }
        return output
    }
    var lastID: Int64 { sqlite3_last_insert_rowid(db) }
    func transaction(_ body: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE")
        do { try body(); try execute("COMMIT") }
        catch { try? execute("ROLLBACK"); throw error }
    }
    private func prepare(_ sql: String, _ values: [SQLValue]) throws -> OpaquePointer {
        let statement: OpaquePointer
        if let cached = statements[sql] { statement = cached }
        else {
            var value: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &value, nil) == SQLITE_OK, let value else { throw failure() }
            statements[sql] = value; statement = value
        }
        sqlite3_reset(statement)
        sqlite3_clear_bindings(statement)
        for (i, value) in values.enumerated() {
            let position = Int32(i + 1)
            let code: Int32
            switch value {
            case let .integer(v): code = sqlite3_bind_int64(statement, position, v)
            case let .text(v): code = sqlite3_bind_text(statement, position, v, -1, transient)
            case let .blob(v):
                code = v.withUnsafeBytes { sqlite3_bind_blob(statement, position, $0.baseAddress, Int32(v.count), transient) }
            case .null: code = sqlite3_bind_null(statement, position)
            }
            guard code == SQLITE_OK else { throw failure() }
        }
        return statement
    }
    private func failure() -> SubFontError {
        .message("字体索引：\(db.map { String(cString: sqlite3_errmsg($0)) } ?? "数据库不可用")")
    }
    private static let schema = [
        """
        CREATE TABLE roots(id TEXT PRIMARY KEY, path TEXT NOT NULL UNIQUE, bookmark BLOB NOT NULL,
          available INTEGER NOT NULL DEFAULT 1, issue TEXT)
        """,
        """
        CREATE TABLE files(id INTEGER PRIMARY KEY, root_id TEXT NOT NULL REFERENCES roots(id) ON DELETE CASCADE,
          path TEXT NOT NULL, size INTEGER NOT NULL, mtime INTEGER NOT NULL, ctime INTEGER NOT NULL,
          identity TEXT NOT NULL, parser_version INTEGER NOT NULL, error TEXT, UNIQUE(root_id,path))
        """,
        """
        CREATE TABLE faces(id INTEGER PRIMARY KEY, file_id INTEGER NOT NULL REFERENCES files(id) ON DELETE CASCADE,
          face_index INTEGER NOT NULL, ps_name TEXT NOT NULL, family TEXT NOT NULL,
          weight INTEGER NOT NULL, italic INTEGER NOT NULL, revision INTEGER NOT NULL, UNIQUE(file_id,face_index))
        """,
        """
        CREATE TABLE names(face_id INTEGER NOT NULL REFERENCES faces(id) ON DELETE CASCADE,
          kind INTEGER NOT NULL, language INTEGER NOT NULL, original TEXT NOT NULL, key TEXT NOT NULL,
          PRIMARY KEY(face_id,kind,language,original))
        """,
        "CREATE INDEX names_lookup ON names(key,face_id)",
        """
        CREATE TABLE pending(root_id TEXT NOT NULL REFERENCES roots(id) ON DELETE CASCADE,
          scope TEXT NOT NULL, force INTEGER NOT NULL DEFAULT 0, PRIMARY KEY(root_id,scope))
        """
    ]
}
