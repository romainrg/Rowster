import Foundation

/// An error reported by a database server for a statement.
public struct DatabaseError: Error, Equatable, Sendable, LocalizedError {
    public var message: String
    /// SQLSTATE or the engine's own error code.
    public var code: String?
    public var detail: String?
    public var hint: String?
    /// 1-based character position in the statement, when the server gives one.
    public var position: Int?

    public init(message: String, code: String? = nil, detail: String? = nil, hint: String? = nil, position: Int? = nil) {
        self.message = message
        self.code = code
        self.detail = detail
        self.hint = hint
        self.position = position
    }

    public var errorDescription: String? { message }

    /// The statement was interrupted by `cancel()`.
    public var isCancellation: Bool { code == "57014" || code == "1317" || code == "SQLITE_INTERRUPT" }
}

/// A failure to reach or talk to a server, as opposed to a statement the server rejected.
public enum ConnectionError: Error, Equatable, Sendable {
    case unreachable(String)
    case tlsRequiredButUnavailable
    case tlsFailed(String)
    case authenticationFailed(String)
    case unsupportedAuthentication(String)
    case protocolViolation(String)
    case closed
    /// A statement was sent while the previous result was still open.
    case busy
}

public enum TransactionState: Sendable, Equatable {
    case idle, inTransaction, failed
}

public struct CommandSummary: Equatable, Sendable {
    public var rowsAffected: Int?
    public init(rowsAffected: Int? = nil) { self.rowsAffected = rowsAffected }
}

/// The rows of one statement, pulled in batches so that memory stays bounded and reading can stop at a limit.
public protocol ResultCursor: AnyObject, Sendable {
    /// Empty for a statement that returns no rows.
    var columns: [ColumnInfo] { get }
    /// The next rows, at most `maxRows`; `nil` once the result is exhausted.
    func next(maxRows: Int) async throws -> [Row]?
    /// Stops reading, discards what remains and releases the connection for the next statement.
    func close() async throws -> CommandSummary
}

/// One connection to a database. A driver runs one statement at a time.
public protocol DatabaseDriver: AnyObject, Sendable {
    var dialect: any SQLDialect { get }
    func connect() async throws
    func close() async
    /// Sends one statement. The returned cursor must be closed before the next statement is sent.
    func execute(_ sql: String, parameters: [SQLValue]) async throws -> any ResultCursor
    /// Interrupts the running statement. Safe to call from another task, and when nothing is running.
    func cancel() async
    var transactionState: TransactionState { get async }
    var serverVersion: String? { get async }
    /// Switches the session between read-only and read-write. Throws when the server refuses: the caller
    /// must then treat the connection as unusable rather than leave it writable.
    func setReadOnly(_ readOnly: Bool) async throws
    /// An introspector that reads the catalogs through this connection.
    func makeIntrospector() -> any SchemaIntrospecting
}

public extension DatabaseDriver {
    func setReadOnly(_ readOnly: Bool) async throws {
        for statement in readOnly ? dialect.readOnlyStatements : dialect.readWriteStatements {
            try await run(statement)
        }
    }
}

public struct QueryResult: Equatable, Sendable {
    public var columns: [ColumnInfo]
    public var rows: [Row]
    /// True when reading stopped at the row limit and more rows were available.
    public var isTruncated: Bool
    public var summary: CommandSummary
}

public extension DatabaseDriver {
    /// Runs a statement and collects at most `limit` rows.
    func query(_ sql: String, parameters: [SQLValue] = [], limit: Int = 10_000) async throws -> QueryResult {
        let cursor = try await execute(sql, parameters: parameters)
        var rows: [Row] = []
        var truncated = false
        do {
            while rows.count < limit {
                guard let batch = try await cursor.next(maxRows: min(500, limit - rows.count)) else { break }
                rows.append(contentsOf: batch)
            }
            if rows.count >= limit, let extra = try await cursor.next(maxRows: 1), !extra.isEmpty {
                truncated = true
            }
        } catch {
            _ = try? await cursor.close()
            throw error
        }
        let summary = try await cursor.close()
        return QueryResult(columns: cursor.columns, rows: rows, isTruncated: truncated, summary: summary)
    }

    /// Runs a statement whose rows, if any, are not needed.
    @discardableResult
    func run(_ sql: String, parameters: [SQLValue] = []) async throws -> CommandSummary {
        let cursor = try await execute(sql, parameters: parameters)
        return try await cursor.close()
    }
}
