import Foundation
import SQLite3

/// En værdi der kan bindes til eller læses fra SQLite.
public enum SQLValue: Equatable {
    case int(Int64)
    case double(Double)
    case text(String)
    case null

    public var int: Int64? {
        switch self {
        case .int(let v): return v
        // Int64(v) crasher ved NaN/uendelig eller værdier uden for Int64's område.
        case .double(let v): return (v.isFinite && v >= -9.2e18 && v <= 9.2e18) ? Int64(v) : nil
        case .text(let s): return Int64(s)
        case .null: return nil
        }
    }

    public var double: Double? {
        switch self {
        case .int(let v): return Double(v)
        case .double(let v): return v
        case .text(let s): return Double(s)
        case .null: return nil
        }
    }

    public var text: String? {
        switch self {
        case .text(let s): return s
        case .int(let v): return String(v)
        case .double(let v): return String(v)
        case .null: return nil
        }
    }
}

public protocol SQLConvertible { var sqlValue: SQLValue { get } }
extension Int: SQLConvertible { public var sqlValue: SQLValue { .int(Int64(self)) } }
extension Int64: SQLConvertible { public var sqlValue: SQLValue { .int(self) } }
extension Double: SQLConvertible { public var sqlValue: SQLValue { .double(self) } }
extension String: SQLConvertible { public var sqlValue: SQLValue { .text(self) } }
extension Bool: SQLConvertible { public var sqlValue: SQLValue { .int(self ? 1 : 0) } }
extension Optional: SQLConvertible where Wrapped: SQLConvertible {
    public var sqlValue: SQLValue { self?.sqlValue ?? .null }
}

public typealias SQLRow = [String: SQLValue]

public struct SQLiteError: Error, CustomStringConvertible, LocalizedError {
    public let message: String
    /// true når `message` er skrevet til brugeren (fx "Sektionen er ikke tom …").
    /// Ellers er det SQLites egen, tekniske besked, som kun hører hjemme i logs.
    public var userFacing = false

    public init(message: String, userFacing: Bool = false) {
        self.message = message
        self.userFacing = userFacing
    }

    public var description: String { "SQLite: \(message)" }

    /// Det, appen viser via `localizedDescription`: altid almindeligt dansk.
    public var errorDescription: String? {
        userFacing ? message : "Der opstod en fejl i databasen. Prøv igen."
    }
}

/// Minimal, synkron SQLite-wrapper. Bruges kun fra main actor.
public final class SQLiteDatabase {
    private var handle: OpaquePointer?
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    /// Filen, databasen ligger i (bruges af eksport, import og nulstilling).
    public let path: String

    public init(path: String) throws {
        self.path = path
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK else {
            let msg = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "kan ikke åbne database"
            sqlite3_close(handle)
            // deinit kører også, når init kaster – undgå at lukke det samme handle to gange.
            handle = nil
            throw SQLiteError(message: msg)
        }
        try execute("PRAGMA journal_mode=WAL;")
        try execute("PRAGMA foreign_keys=ON;")
    }

    deinit { sqlite3_close(handle) }

    private var errorMessage: String { String(cString: sqlite3_errmsg(handle)) }

    public func execute(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(handle, sql, nil, nil, &err) != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? errorMessage
            sqlite3_free(err)
            throw SQLiteError(message: msg)
        }
    }

    private func prepare(_ sql: String, _ params: [SQLConvertible]) throws -> OpaquePointer? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw SQLiteError(message: "\(errorMessage) i: \(sql)")
        }
        for (i, p) in params.enumerated() {
            let idx = Int32(i + 1)
            switch p.sqlValue {
            case .int(let v): sqlite3_bind_int64(stmt, idx, v)
            case .double(let v): sqlite3_bind_double(stmt, idx, v)
            case .text(let s): sqlite3_bind_text(stmt, idx, s, -1, Self.transient)
            case .null: sqlite3_bind_null(stmt, idx)
            }
        }
        return stmt
    }

    @discardableResult
    public func run(_ sql: String, _ params: SQLConvertible...) throws -> Int64 {
        try run(sql, params: params)
    }

    @discardableResult
    public func run(_ sql: String, params: [SQLConvertible]) throws -> Int64 {
        let stmt = try prepare(sql, params)
        defer { sqlite3_finalize(stmt) }
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else {
            throw SQLiteError(message: "\(errorMessage) i: \(sql)")
        }
        return sqlite3_last_insert_rowid(handle)
    }

    public func query(_ sql: String, _ params: SQLConvertible...) throws -> [SQLRow] {
        try query(sql, params: params)
    }

    public func query(_ sql: String, params: [SQLConvertible]) throws -> [SQLRow] {
        let stmt = try prepare(sql, params)
        defer { sqlite3_finalize(stmt) }
        var rows: [SQLRow] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw SQLiteError(message: "\(errorMessage) i: \(sql)") }
            var row: SQLRow = [:]
            for c in 0..<sqlite3_column_count(stmt) {
                let name = String(cString: sqlite3_column_name(stmt, c))
                switch sqlite3_column_type(stmt, c) {
                case SQLITE_INTEGER: row[name] = .int(sqlite3_column_int64(stmt, c))
                case SQLITE_FLOAT: row[name] = .double(sqlite3_column_double(stmt, c))
                case SQLITE_TEXT: row[name] = .text(String(cString: sqlite3_column_text(stmt, c)))
                default: row[name] = .null
                }
            }
            rows.append(row)
        }
        return rows
    }

    public var userVersion: Int {
        get { Int((try? query("PRAGMA user_version").first?["user_version"]?.int) ?? 0) }
        set { try? execute("PRAGMA user_version = \(newValue)") }
    }

    /// Kører `body` i en transaktion. Ruller tilbage ved fejl.
    public func transaction<T>(_ body: () throws -> T) throws -> T {
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
}
