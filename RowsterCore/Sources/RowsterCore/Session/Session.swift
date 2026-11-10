import Foundation

public enum SessionError: Error, Equatable, Sendable {
    case notOpen
    /// The session is read-only and the statement is not a plain read.
    case readOnly(verb: String)
    /// The statement is destructive and was not confirmed by the user.
    case needsConfirmation(StatementInfo.Hazard)
}

/// The connections of one work window.
///
/// - The **primary** connection runs everything the user runs, one statement at a time, so session state
///   (temporary tables, `SET`) stays consistent.
/// - The **auxiliary** connection is opened on first use, is always read-only, and serves introspection
///   and previews, so a long statement never blocks the sidebar.
///
/// Every statement goes through `check` first: a read-only session refuses anything that is not a plain
/// read, and a destructive statement must have been confirmed.
public actor Session {
    public nonisolated let profile: ConnectionProfile
    private let password: String?
    private let provider: any DriverProviding

    private var primary: (any DatabaseDriver)?
    private var auxiliary: (any DatabaseDriver)?
    public private(set) var isReadOnly: Bool
    /// The database in use when the user switched away from the profile's.
    public private(set) var database: String?

    private var primaryBusy = false
    private var primaryWaiters: [CheckedContinuation<Void, Never>] = []
    private var auxiliaryBusy = false
    private var auxiliaryWaiters: [CheckedContinuation<Void, Never>] = []

    public init(profile: ConnectionProfile, password: String?, provider: any DriverProviding) {
        self.profile = profile
        self.password = password
        self.provider = provider
        isReadOnly = profile.isReadOnlyOnOpen
    }

    // MARK: - Lifecycle

    /// Connects, makes the session read-only when it must be, then runs the user's bootstrap SQL.
    /// Nothing else runs. If any step fails the connection is closed: it never stays half-configured.
    public func open() async throws {
        let driver = try provider.makeDriver(for: profile, password: password, database: database, readOnly: isReadOnly)
        try await driver.connect()
        do {
            if isReadOnly { try await driver.setReadOnly(true) }
            for statement in driver.dialect.splitter.split(profile.bootstrapSQL) {
                // The user wrote the bootstrap SQL, so a destructive statement in it counts as confirmed.
                try Self.check(statement.text, dialect: driver.dialect, readOnly: isReadOnly, confirmed: true)
                try await driver.run(statement.text)
            }
        } catch {
            await driver.close()
            throw error
        }
        primary = driver
    }

    public func close() async {
        await primary?.close()
        await auxiliary?.close()
        primary = nil
        auxiliary = nil
    }

    public var isOpen: Bool { primary != nil }

    public var dialect: any SQLDialect { primary?.dialect ?? profile.engine.dialect }

    public var serverVersion: String? {
        get async { await primary?.serverVersion }
    }

    public var transactionState: TransactionState {
        get async { await primary?.transactionState ?? .idle }
    }

    // MARK: - Guard

    /// What the classifier says about a statement, so the UI can ask for a confirmation before running it.
    public func classify(_ sql: String) -> StatementInfo {
        dialect.classifier.classify(sql)
    }

    private static func check(_ sql: String, dialect: any SQLDialect, readOnly: Bool, confirmed: Bool) throws {
        let info = dialect.classifier.classify(sql)
        if readOnly, !info.isAllowedWhenReadOnly { throw SessionError.readOnly(verb: info.verb) }
        if let hazard = info.hazard, !confirmed { throw SessionError.needsConfirmation(hazard) }
    }

    // MARK: - Primary connection

    /// Runs a statement and collects at most `limit` rows.
    public func query(
        _ sql: String, parameters: [SQLValue] = [], limit: Int = 10_000, confirmed: Bool = false
    ) async throws -> QueryResult {
        var (result, summary) = try await perform(sql, parameters: parameters, confirmed: confirmed) { cursor in
            var rows: [Row] = []
            while rows.count < limit {
                guard let batch = try await cursor.next(maxRows: min(500, limit - rows.count)) else {
                    return QueryResult(columns: cursor.columns, rows: rows, isTruncated: false, summary: CommandSummary())
                }
                rows.append(contentsOf: batch)
            }
            let extra = try await cursor.next(maxRows: 1)
            return QueryResult(
                columns: cursor.columns, rows: rows, isTruncated: extra?.isEmpty == false, summary: CommandSummary())
        }
        result.summary = summary
        summary = CommandSummary()
        return result
    }

    /// Runs a statement whose rows are not needed.
    @discardableResult
    public func run(_ sql: String, parameters: [SQLValue] = [], confirmed: Bool = false) async throws -> CommandSummary {
        try await perform(sql, parameters: parameters, confirmed: confirmed) { _ in }.1
    }

    /// Runs a statement and hands its cursor to `body`. The primary connection is held until `body`
    /// returns, then the cursor is closed.
    public func withCursor<T>(
        _ sql: String, parameters: [SQLValue] = [], confirmed: Bool = false,
        _ body: (any ResultCursor) async throws -> T
    ) async throws -> T {
        try await perform(sql, parameters: parameters, confirmed: confirmed, body).0
    }

    private func perform<T>(
        _ sql: String, parameters: [SQLValue], confirmed: Bool, _ body: (any ResultCursor) async throws -> T
    ) async throws -> (T, CommandSummary) {
        guard let primary else { throw SessionError.notOpen }
        try Self.check(sql, dialect: primary.dialect, readOnly: isReadOnly, confirmed: confirmed)
        await acquirePrimary()
        defer { releasePrimary() }
        let cursor = try await primary.execute(sql, parameters: parameters)
        do {
            let result = try await body(cursor)
            return (result, try await cursor.close())
        } catch {
            _ = try? await cursor.close()
            throw error
        }
    }

    /// Interrupts the statement running on the primary connection. Never waits for it.
    public func cancel() async {
        await primary?.cancel()
    }

    /// Unlocks or re-locks writing. If the server refuses to become read-only again, the session is
    /// closed rather than left writable.
    public func setReadOnly(_ readOnly: Bool) async throws {
        guard let primary else { throw SessionError.notOpen }
        guard readOnly != isReadOnly else { return }
        await acquirePrimary()
        defer { releasePrimary() }
        do {
            try await primary.setReadOnly(readOnly)
            isReadOnly = readOnly
        } catch {
            if readOnly { await close() }
            throw error
        }
    }

    /// Reconnects to another database of the same server.
    public func switchDatabase(_ name: String) async throws {
        await close()
        database = name
        try await open()
    }

    // MARK: - Auxiliary connection

    public func databases() async throws -> [String] {
        try await withAuxiliary { try await $0.makeIntrospector().databases() }
    }

    public func namespaces() async throws -> [SchemaNamespace] {
        try await withAuxiliary { try await $0.makeIntrospector().namespaces() }
    }

    public func describe(_ table: TableRef) async throws -> TableDescription {
        try await withAuxiliary { try await $0.makeIntrospector().describe(table) }
    }

    public func estimatedRowCount(_ table: TableRef) async throws -> Int? {
        try await withAuxiliary { try await $0.makeIntrospector().estimatedRowCount(table) }
    }

    /// A bounded read on the auxiliary connection: previews and counts. Refuses anything but a plain read.
    public func preview(_ sql: String, parameters: [SQLValue] = [], limit: Int = 100) async throws -> QueryResult {
        try await withAuxiliary { driver in
            try Self.check(sql, dialect: driver.dialect, readOnly: true, confirmed: false)
            return try await driver.query(sql, parameters: parameters, limit: limit)
        }
    }

    private func withAuxiliary<T>(_ body: (any DatabaseDriver) async throws -> T) async throws -> T {
        guard primary != nil else { throw SessionError.notOpen }
        await acquireAuxiliary()
        defer { releaseAuxiliary() }
        if auxiliary == nil {
            let driver = try provider.makeDriver(for: profile, password: password, database: database, readOnly: true)
            try await driver.connect()
            do {
                try await driver.setReadOnly(true)
            } catch {
                await driver.close()
                throw error
            }
            auxiliary = driver
        }
        guard let auxiliary else { throw SessionError.notOpen }
        return try await body(auxiliary)
    }

    // MARK: - One statement at a time

    private func acquirePrimary() async {
        if !primaryBusy {
            primaryBusy = true
            return
        }
        await withCheckedContinuation { primaryWaiters.append($0) }
    }

    private func releasePrimary() {
        if primaryWaiters.isEmpty { primaryBusy = false } else { primaryWaiters.removeFirst().resume() }
    }

    private func acquireAuxiliary() async {
        if !auxiliaryBusy {
            auxiliaryBusy = true
            return
        }
        await withCheckedContinuation { auxiliaryWaiters.append($0) }
    }

    private func releaseAuxiliary() {
        if auxiliaryWaiters.isEmpty { auxiliaryBusy = false } else { auxiliaryWaiters.removeFirst().resume() }
    }
}
