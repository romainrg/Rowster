import Foundation
import SQLite3

public struct SQLiteConfiguration: Sendable, Equatable {
    /// File path, or `:memory:`.
    public var path: String
    public var readOnly: Bool
    public var createIfMissing: Bool

    public init(path: String, readOnly: Bool = false, createIfMissing: Bool = false) {
        self.path = path
        self.readOnly = readOnly
        self.createIfMissing = createIfMissing
    }

    public static func memory() -> SQLiteConfiguration { SQLiteConfiguration(path: ":memory:") }

    /// An in-memory database that every connection opened with the same name shares, for as long as one
    /// of them stays open. Used by demo mode, where a window has several connections.
    public static func sharedMemory(name: String) -> SQLiteConfiguration {
        let safeName = name.filter { $0.isLetter || $0.isNumber || $0 == "-" }
        var configuration = SQLiteConfiguration(path: "file:\(safeName)?mode=memory&cache=shared")
        configuration.isSharedMemory = true
        return configuration
    }

    /// The path is only read as a URI for a shared in-memory database, never for a path the user gave.
    var isSharedMemory = false

    var isMemory: Bool { isSharedMemory || path == ":memory:" || path.isEmpty }
}

/// SQLite through the `libsqlite3` of the SDK. Every call runs on one private serial queue.
public final class SQLiteDriver: DatabaseDriver, @unchecked Sendable {
    public let dialect: any SQLDialect = SQLiteDialect()

    private let queue = DispatchQueue(label: "io.github.romainrg.Rowster.sqlite")
    private let lock = NSLock()
    private var handle: OpaquePointer?
    private var configuration: SQLiteConfiguration
    fileprivate var hasOpenCursor = false

    public init(configuration: SQLiteConfiguration) {
        self.configuration = configuration
    }

    deinit {
        if let handle { sqlite3_close_v2(handle) }
    }

    fileprivate func perform<T>(_ body: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try body() }) }
        }
    }

    // MARK: - Connection

    public func connect() async throws {
        try await perform { try self.open() }
    }

    private func open() throws {
        var flags = SQLITE_OPEN_FULLMUTEX
        if configuration.isSharedMemory { flags |= SQLITE_OPEN_URI }
        if configuration.isMemory {
            flags |= SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
        } else if configuration.readOnly {
            flags |= SQLITE_OPEN_READONLY
        } else {
            flags |= SQLITE_OPEN_READWRITE | (configuration.createIfMissing ? SQLITE_OPEN_CREATE : 0)
        }
        var database: OpaquePointer?
        let code = sqlite3_open_v2(configuration.path, &database, flags, nil)
        guard code == SQLITE_OK, let database else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open the database"
            sqlite3_close_v2(database)
            throw ConnectionError.unreachable(message)
        }
        sqlite3_busy_timeout(database, 5000)
        // Reading the schema fails right away when the file is not a database.
        if sqlite3_exec(database, "SELECT count(*) FROM sqlite_master", nil, nil, nil) != SQLITE_OK {
            let message = String(cString: sqlite3_errmsg(database))
            sqlite3_close_v2(database)
            throw ConnectionError.unreachable(message)
        }
        if configuration.readOnly, sqlite3_exec(database, "PRAGMA query_only = ON", nil, nil, nil) != SQLITE_OK {
            sqlite3_close_v2(database)
            throw ConnectionError.unreachable("cannot make the connection read-only")
        }
        lock.withLock { handle = database }
    }

    private func closeHandle() {
        let database = lock.withLock { () -> OpaquePointer? in
            defer { handle = nil }
            return handle
        }
        if let database { sqlite3_close_v2(database) }
        hasOpenCursor = false
    }

    public func close() async {
        _ = try? await perform { self.closeHandle() }
    }

    public func setReadOnly(_ readOnly: Bool) async throws {
        try await perform {
            guard self.configuration.readOnly != readOnly else { return }
            guard !self.hasOpenCursor else { throw ConnectionError.busy }
            self.configuration.readOnly = readOnly
            if self.configuration.isMemory {
                // An in-memory database cannot be reopened without losing it.
                guard let database = self.handle else { throw ConnectionError.closed }
                let pragma = readOnly ? "PRAGMA query_only = ON" : "PRAGMA query_only = OFF"
                guard sqlite3_exec(database, pragma, nil, nil, nil) == SQLITE_OK else { throw self.error(database) }
            } else {
                self.closeHandle()
                try self.open()
            }
        }
    }

    public func cancel() async {
        lock.withLock {
            if let handle { sqlite3_interrupt(handle) }
        }
    }

    public var transactionState: TransactionState {
        get async {
            (try? await perform { () -> TransactionState in
                guard let database = self.handle else { return .idle }
                return sqlite3_get_autocommit(database) == 0 ? .inTransaction : .idle
            }) ?? .idle
        }
    }

    public var serverVersion: String? {
        get async { String(cString: sqlite3_libversion()) }
    }

    public func makeIntrospector() -> any SchemaIntrospecting { SQLiteIntrospector(driver: self) }

    // MARK: - Statements

    public func execute(_ sql: String, parameters: [SQLValue]) async throws -> any ResultCursor {
        try await perform {
            guard let database = self.handle else { throw ConnectionError.closed }
            guard !self.hasOpenCursor else { throw ConnectionError.busy }

            var statement: OpaquePointer?
            var rest = ""
            let code = sql.withCString { text -> Int32 in
                var tail: UnsafePointer<CChar>?
                let code = sqlite3_prepare_v2(database, text, -1, &statement, &tail)
                if let tail { rest = String(cString: tail) }
                return code
            }
            guard code == SQLITE_OK else { throw self.error(database, sql: sql) }
            guard SQLiteDialect().classifier.classify(rest).kind == .empty else {
                sqlite3_finalize(statement)
                throw DatabaseError(message: "Only one statement can be run at a time", code: "SQLITE_MISUSE")
            }
            guard let statement else {
                return SQLiteCursor(driver: self, database: database, statement: nil)
            }
            if self.configuration.readOnly, sqlite3_stmt_readonly(statement) == 0 {
                sqlite3_finalize(statement)
                throw DatabaseError(message: "attempt to write a readonly database", code: "SQLITE_READONLY")
            }
            do {
                try self.bind(parameters, to: statement, database: database)
            } catch {
                sqlite3_finalize(statement)
                throw error
            }
            self.hasOpenCursor = true
            return SQLiteCursor(driver: self, database: database, statement: statement)
        }
    }

    private func bind(_ parameters: [SQLValue], to statement: OpaquePointer, database: OpaquePointer) throws {
        let expected = Int(sqlite3_bind_parameter_count(statement))
        guard expected == parameters.count else {
            throw DatabaseError(
                message: "The statement has \(expected) parameters but \(parameters.count) values were given",
                code: "SQLITE_RANGE")
        }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (offset, value) in parameters.enumerated() {
            let index = Int32(offset + 1)
            let code: Int32
            switch value {
            case .null: code = sqlite3_bind_null(statement, index)
            case .text(let text): code = sqlite3_bind_text(statement, index, text, -1, transient)
            case .integer(let number): code = sqlite3_bind_int64(statement, index, number)
            case .double(let number): code = sqlite3_bind_double(statement, index, number)
            case .bool(let flag): code = sqlite3_bind_int64(statement, index, flag ? 1 : 0)
            case .bytes(let data):
                code = data.withUnsafeBytes { sqlite3_bind_blob64(statement, index, $0.baseAddress, UInt64(data.count), transient) }
            case .deferredBytes:
                throw DatabaseError(message: "A binary value that was not loaded cannot be written", code: "SQLITE_MISUSE")
            }
            guard code == SQLITE_OK else { throw error(database) }
        }
    }

    fileprivate func error(_ database: OpaquePointer, sql: String? = nil) -> DatabaseError {
        let code = sqlite3_errcode(database)
        var position: Int?
        if let sql {
            let offset = Int(sqlite3_error_offset(database))
            if offset >= 0, let index = sql.utf8.index(sql.utf8.startIndex, offsetBy: offset, limitedBy: sql.utf8.endIndex) {
                position = sql.distance(from: sql.startIndex, to: index) + 1
            }
        }
        return DatabaseError(
            message: String(cString: sqlite3_errmsg(database)), code: Self.codeName(code), position: position)
    }

    private static func codeName(_ code: Int32) -> String {
        switch code {
        case SQLITE_BUSY: return "SQLITE_BUSY"
        case SQLITE_LOCKED: return "SQLITE_LOCKED"
        case SQLITE_READONLY: return "SQLITE_READONLY"
        case SQLITE_INTERRUPT: return "SQLITE_INTERRUPT"
        case SQLITE_CONSTRAINT: return "SQLITE_CONSTRAINT"
        case SQLITE_MISUSE: return "SQLITE_MISUSE"
        case SQLITE_RANGE: return "SQLITE_RANGE"
        default: return "SQLITE_ERROR"
        }
    }

    /// Family of a declared column type, following SQLite's type affinity rules.
    static func kind(forDeclaredType declared: String) -> ColumnKind {
        let type = declared.uppercased()
        if type.isEmpty { return .other }
        if type.contains("BOOL") { return .boolean }
        if type.contains("INT") { return .integer }
        if type.contains("JSON") { return .json }
        if type.contains("CHAR") || type.contains("CLOB") || type.contains("TEXT") { return .text }
        if type.contains("BLOB") || type.contains("BINARY") { return .binary }
        if type.contains("DATE") || type.contains("TIME") { return .date }
        if type.contains("REAL") || type.contains("FLOA") || type.contains("DOUB") || type.contains("NUM") || type.contains("DEC") {
            return .decimal
        }
        return .other
    }
}

private final class SQLiteCursor: ResultCursor, @unchecked Sendable {
    let columns: [ColumnInfo]
    private let driver: SQLiteDriver
    private let database: OpaquePointer
    private var statement: OpaquePointer?
    private var hasStepped = false
    private var isFinished: Bool
    private let changesBefore: Int32
    private let isReadOnly: Bool

    init(driver: SQLiteDriver, database: OpaquePointer, statement: OpaquePointer?) {
        self.driver = driver
        self.database = database
        self.statement = statement
        isFinished = statement == nil
        changesBefore = sqlite3_total_changes(database)
        isReadOnly = statement.map { sqlite3_stmt_readonly($0) != 0 } ?? true
        columns = statement.map { statement in
            (0..<sqlite3_column_count(statement)).map { index in
                let declared = sqlite3_column_decltype(statement, index).map { String(cString: $0) } ?? ""
                return ColumnInfo(
                    name: String(cString: sqlite3_column_name(statement, index)), typeName: declared,
                    kind: SQLiteDriver.kind(forDeclaredType: declared))
            }
        } ?? []
    }

    func next(maxRows: Int) async throws -> [Row]? {
        try await driver.perform {
            guard !self.isFinished, let statement = self.statement else { return nil }
            var rows: [Row] = []
            while rows.count < maxRows {
                self.hasStepped = true
                let code = sqlite3_step(statement)
                if code == SQLITE_ROW {
                    rows.append(self.readRow(statement))
                } else if code == SQLITE_DONE {
                    self.isFinished = true
                    break
                } else {
                    let error = self.driver.error(self.database)
                    self.finalize()
                    throw error
                }
            }
            return rows.isEmpty && self.isFinished ? nil : rows
        }
    }

    func close() async throws -> CommandSummary {
        try await driver.perform {
            // A statement that was never stepped has not run yet: closing it must still execute it.
            if let statement = self.statement, !self.hasStepped {
                let code = sqlite3_step(statement)
                if code != SQLITE_ROW, code != SQLITE_DONE {
                    let error = self.driver.error(self.database)
                    self.finalize()
                    throw error
                }
            }
            self.finalize()
            guard !self.isReadOnly else { return CommandSummary() }
            return CommandSummary(rowsAffected: Int(sqlite3_total_changes(self.database) - self.changesBefore))
        }
    }

    private func finalize() {
        if let statement {
            sqlite3_finalize(statement)
            self.statement = nil
            driver.hasOpenCursor = false
        }
        isFinished = true
    }

    private func readRow(_ statement: OpaquePointer) -> Row {
        (0..<Int32(columns.count)).map { index in
            switch sqlite3_column_type(statement, index) {
            case SQLITE_INTEGER: return .integer(sqlite3_column_int64(statement, index))
            case SQLITE_FLOAT: return .double(sqlite3_column_double(statement, index))
            case SQLITE_TEXT: return .text(String(cString: sqlite3_column_text(statement, index)))
            case SQLITE_BLOB:
                let count = Int(sqlite3_column_bytes(statement, index))
                guard count > 0, let bytes = sqlite3_column_blob(statement, index) else { return .bytes(Data()) }
                return .bytes(Data(bytes: bytes, count: count))
            default: return .null
            }
        }
    }
}
