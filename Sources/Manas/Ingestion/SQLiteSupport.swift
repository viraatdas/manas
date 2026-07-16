import Foundation
import SQLite3

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

enum SQLiteValue: Sendable {
    case integer(Int64)
    case double(Double)
    case text(String)
}

enum SQLiteCell: Sendable {
    case integer(Int64)
    case double(Double)
    case text(String)
    case blob(Data)
    case null

    var int64: Int64? {
        switch self {
        case .integer(let value): value
        case .double(let value): Int64(value)
        case .text(let value): Int64(value)
        case .blob, .null: nil
        }
    }

    var double: Double? {
        switch self {
        case .integer(let value): Double(value)
        case .double(let value): value
        case .text(let value): Double(value)
        case .blob, .null: nil
        }
    }

    var string: String? {
        switch self {
        case .integer(let value): String(value)
        case .double(let value): String(value)
        case .text(let value): value
        case .blob, .null: nil
        }
    }

    var data: Data? {
        if case .blob(let value) = self { value } else { nil }
    }
}

struct SQLiteRow: Sendable {
    private var cells: [String: SQLiteCell]

    init(cells: [String: SQLiteCell]) {
        self.cells = cells
    }

    subscript(_ column: String) -> SQLiteCell {
        cells[column] ?? .null
    }
}

struct SQLiteReadError: Error, LocalizedError, Sendable {
    var code: Int32
    var message: String

    var errorDescription: String? { message }

    var isAccessFailure: Bool {
        code == SQLITE_CANTOPEN || code == SQLITE_PERM || code == SQLITE_AUTH
    }
}

/// Minimal, parameterized, read-only SQLite access. Source databases are
/// never opened with CREATE or READWRITE, and raw rows never leave memory.
enum ReadOnlySQLiteDatabase {
    static func query(
        _ url: URL,
        sql: String,
        bindings: [SQLiteValue] = []
    ) throws -> [SQLiteRow] {
        var database: OpaquePointer?
        let openCode = sqlite3_open_v2(
            url.path,
            &database,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard openCode == SQLITE_OK, let database else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) }
                ?? "The database could not be opened."
            if let database { sqlite3_close(database) }
            throw SQLiteReadError(code: openCode, message: message)
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 1_500)

        var statement: OpaquePointer?
        let prepareCode = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard prepareCode == SQLITE_OK, let statement else {
            throw SQLiteReadError(code: prepareCode, message: String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }

        for (offset, value) in bindings.enumerated() {
            let index = Int32(offset + 1)
            let code: Int32
            switch value {
            case .integer(let value): code = sqlite3_bind_int64(statement, index, value)
            case .double(let value): code = sqlite3_bind_double(statement, index, value)
            case .text(let value):
                code = sqlite3_bind_text(statement, index, value, -1, sqliteTransient)
            }
            guard code == SQLITE_OK else {
                throw SQLiteReadError(code: code, message: String(cString: sqlite3_errmsg(database)))
            }
        }

        var rows: [SQLiteRow] = []
        while true {
            let stepCode = sqlite3_step(statement)
            if stepCode == SQLITE_DONE { break }
            guard stepCode == SQLITE_ROW else {
                throw SQLiteReadError(code: stepCode, message: String(cString: sqlite3_errmsg(database)))
            }
            var cells: [String: SQLiteCell] = [:]
            for column in 0..<sqlite3_column_count(statement) {
                let name = String(cString: sqlite3_column_name(statement, column))
                switch sqlite3_column_type(statement, column) {
                case SQLITE_INTEGER:
                    cells[name] = .integer(sqlite3_column_int64(statement, column))
                case SQLITE_FLOAT:
                    cells[name] = .double(sqlite3_column_double(statement, column))
                case SQLITE_TEXT:
                    cells[name] = .text(String(cString: sqlite3_column_text(statement, column)))
                case SQLITE_BLOB:
                    let count = Int(sqlite3_column_bytes(statement, column))
                    if count > 0, let bytes = sqlite3_column_blob(statement, column) {
                        cells[name] = .blob(Data(bytes: bytes, count: count))
                    } else {
                        cells[name] = .blob(Data())
                    }
                default:
                    cells[name] = .null
                }
            }
            rows.append(SQLiteRow(cells: cells))
        }
        return rows
    }
}

/// Arc keeps Chromium History databases live. Copying the main file and WAL
/// into a private temporary directory gives SQLite a coherent read target
/// without modifying the browser profile or requiring Arc to quit.
enum SQLiteSnapshot {
    struct Snapshot {
        var databaseURL: URL
        var directoryURL: URL
    }

    static func make(of source: URL) throws -> Snapshot {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("ManasSQLite-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        do {
            let destination = directory.appendingPathComponent("snapshot.sqlite")
            try fileManager.copyItem(at: source, to: destination)
            let sourceWAL = URL(fileURLWithPath: source.path + "-wal")
            if fileManager.fileExists(atPath: sourceWAL.path) {
                try fileManager.copyItem(
                    at: sourceWAL,
                    to: URL(fileURLWithPath: destination.path + "-wal")
                )
            }
            return Snapshot(databaseURL: destination, directoryURL: directory)
        } catch {
            try? fileManager.removeItem(at: directory)
            throw error
        }
    }
}

/// Caps and cleans external text before it becomes judge evidence. Activity
/// text is data, not instructions; the prompt reinforces that boundary.
enum ActivityPrivacySanitizer {
    static func text(_ raw: String, limit: Int = 240) -> String? {
        let collapsed = raw
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !collapsed.isEmpty else { return nil }
        let redacted = collapsed
            .replacingOccurrences(
                of: #"(?i)\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b"#,
                with: "[email]",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"(?<!\w)(?:\+?\d[\d(). -]{7,}\d)(?!\w)"#,
                with: "[phone]",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"https?://\S+"#,
                with: "[link]",
                options: [.regularExpression, .caseInsensitive]
            )
        guard redacted.count > limit else { return redacted }
        let end = redacted.index(redacted.startIndex, offsetBy: limit)
        return String(redacted[..<end]).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }
}
