import XCTest
@testable import RowsterCore

/// Serves SQLite databases held in memory and shared between the connections of one test.
struct MemoryProvider: DriverProviding {
    let name = "rowster-test-\(UUID().uuidString)"
    let requests = Requests()

    final class Requests: @unchecked Sendable {
        private let lock = NSLock()
        private var databases: [String?] = []
        private var socketPaths: [String] = []
        func record(_ database: String?, socket: String) {
            lock.withLock {
                databases.append(database)
                socketPaths.append(socket)
            }
        }
        var all: [String?] { lock.withLock { databases } }
        var sockets: [String] { lock.withLock { socketPaths } }
    }

    func makeDriver(for profile: ConnectionProfile, password: String?, database: String?, readOnly: Bool) throws -> any DatabaseDriver {
        requests.record(database, socket: profile.socketPath)
        var configuration = SQLiteConfiguration.sharedMemory(name: name + (database ?? ""))
        configuration.readOnly = readOnly
        return SQLiteDriver(configuration: configuration)
    }
}

/// A driver that fails where a test tells it to.
final class FailingDriver: DatabaseDriver, @unchecked Sendable {
    let dialect: any SQLDialect = PostgresDialect()
    var failsReadOnly = false
    private(set) var isClosed = false
    private(set) var statements: [String] = []

    func connect() async throws {}
    func close() async { isClosed = true }
    func execute(_ sql: String, parameters: [SQLValue]) async throws -> any ResultCursor {
        statements.append(sql)
        return EmptyCursor()
    }
    func cancel() async {}
    var transactionState: TransactionState { get async { .idle } }
    var serverVersion: String? { get async { "test" } }
    func setReadOnly(_ readOnly: Bool) async throws {
        if readOnly, failsReadOnly { throw DatabaseError(message: "cannot set read-only") }
    }
    func makeIntrospector() -> any SchemaIntrospecting { fatalError("not used") }

    final class EmptyCursor: ResultCursor {
        let columns: [ColumnInfo] = []
        func next(maxRows: Int) async throws -> [Row]? { nil }
        func close() async throws -> CommandSummary { CommandSummary() }
    }
}

struct FixedProvider: DriverProviding {
    let driver: FailingDriver
    func makeDriver(for profile: ConnectionProfile, password: String?, database: String?, readOnly: Bool) throws -> any DatabaseDriver {
        driver
    }
}

final class SessionTests: XCTestCase {
    private func profile(_ label: EnvironmentLabel = .none, bootstrap: String = "") -> ConnectionProfile {
        var profile = ConnectionProfile(name: "test", engine: .sqlite)
        profile.label = label
        profile.bootstrapSQL = bootstrap
        return profile
    }

    /// A read-write session used to prepare data that a second, read-only session then sees.
    private func prepared(_ provider: MemoryProvider, _ statements: [String]) async throws -> Session {
        let session = Session(profile: profile(), password: nil, provider: provider)
        try await session.open()
        for statement in statements { try await session.run(statement) }
        return session
    }

    private func assertThrows(_ expected: SessionError, _ body: () async throws -> Void, line: UInt = #line) async {
        do {
            try await body()
            XCTFail("no error", line: line)
        } catch {
            XCTAssertEqual(error as? SessionError, expected, line: line)
        }
    }

    func testStatementsRunAndReportRowsAffected() async throws {
        let session = try await prepared(MemoryProvider(), ["CREATE TABLE t (a)"])
        let summary = try await session.run("INSERT INTO t VALUES (1), (2), (3)")
        XCTAssertEqual(summary.rowsAffected, 3)
        let result = try await session.query("SELECT a FROM t ORDER BY a", limit: 2)
        XCTAssertEqual(result.rows, [[.integer(1)], [.integer(2)]])
        XCTAssertTrue(result.isTruncated)
        await session.close()
    }

    func testNotOpen() async {
        let session = Session(profile: profile(), password: nil, provider: MemoryProvider())
        await assertThrows(.notOpen) { _ = try await session.query("SELECT 1") }
        await assertThrows(.notOpen) { _ = try await session.namespaces() }
    }

    func testProductionOpensReadOnlyAndRefusesWritesBeforeTheyAreSent() async throws {
        let provider = MemoryProvider()
        let writer = try await prepared(provider, ["CREATE TABLE t (a)", "INSERT INTO t VALUES (1)"])
        let session = Session(profile: profile(.production), password: nil, provider: provider)
        try await session.open()
        let readOnly = await session.isReadOnly
        XCTAssertTrue(readOnly)

        let rows = try await session.query("SELECT a FROM t")
        XCTAssertEqual(rows.rows, [[.integer(1)]])
        await assertThrows(.readOnly(verb: "INSERT")) { try await session.run("INSERT INTO t VALUES (2)") }
        await assertThrows(.readOnly(verb: "DROP")) { try await session.run("DROP TABLE t", confirmed: true) }
        await assertThrows(.readOnly(verb: "PRAGMA")) { try await session.run("PRAGMA query_only = OFF") }
        await assertThrows(.readOnly(verb: "FROBNICATE")) { try await session.run("FROBNICATE") }
        await assertThrows(.readOnly(verb: "WITH")) {
            try await session.run("WITH x AS (SELECT 1) DELETE FROM t WHERE a IN (SELECT * FROM x)")
        }

        try await session.setReadOnly(false)
        try await session.run("INSERT INTO t VALUES (2)")
        try await session.setReadOnly(true)
        await assertThrows(.readOnly(verb: "INSERT")) { try await session.run("INSERT INTO t VALUES (3)") }
        let count = try await session.query("SELECT count(*) FROM t")
        XCTAssertEqual(count.rows, [[.integer(2)]])
        await session.close()
        await writer.close()
    }

    func testDestructiveStatementsNeedAConfirmation() async throws {
        let session = try await prepared(MemoryProvider(), ["CREATE TABLE t (a)", "INSERT INTO t VALUES (1), (2)"])
        await assertThrows(.needsConfirmation(.deleteWithoutWhere)) { try await session.run("DELETE FROM t") }
        await assertThrows(.needsConfirmation(.updateWithoutWhere)) { try await session.run("UPDATE t SET a = 0") }
        await assertThrows(.needsConfirmation(.drop)) { try await session.run("DROP TABLE t") }
        let untouched = try await session.query("SELECT count(*) FROM t")
        XCTAssertEqual(untouched.rows, [[.integer(2)]])

        try await session.run("DELETE FROM t WHERE a = 1")
        let summary = try await session.run("DELETE FROM t", confirmed: true)
        XCTAssertEqual(summary.rowsAffected, 1)
        await session.close()
    }

    func testClassify() async throws {
        let session = try await prepared(MemoryProvider(), [])
        let info = await session.classify("TRUNCATE t")
        XCTAssertEqual(info.hazard, .truncate)
        await session.close()
    }

    func testBootstrapSQLRunsOnOpen() async throws {
        let provider = MemoryProvider()
        let session = Session(
            profile: profile(bootstrap: "CREATE TABLE boot (a); -- then\nINSERT INTO boot VALUES (7);"), password: nil, provider: provider)
        try await session.open()
        let rows = try await session.query("SELECT a FROM boot")
        XCTAssertEqual(rows.rows, [[.integer(7)]])
        await session.close()
    }

    func testFailingBootstrapClosesTheConnection() async throws {
        let session = Session(profile: profile(bootstrap: "SELECT * FROM missing"), password: nil, provider: MemoryProvider())
        do {
            try await session.open()
            XCTFail("opened")
        } catch is DatabaseError {}
        let isOpen = await session.isOpen
        XCTAssertFalse(isOpen)
    }

    func testBootstrapCannotWriteOnAReadOnlySession() async throws {
        let session = Session(
            profile: profile(.production, bootstrap: "CREATE TABLE sneaky (a)"), password: nil, provider: MemoryProvider())
        await assertThrows(.readOnly(verb: "CREATE")) { try await session.open() }
        let isOpen = await session.isOpen
        XCTAssertFalse(isOpen)
    }

    func testOpenFailsClosedWhenReadOnlyCannotBeSet() async throws {
        let driver = FailingDriver()
        driver.failsReadOnly = true
        let session = Session(profile: profile(.production), password: nil, provider: FixedProvider(driver: driver))
        do {
            try await session.open()
            XCTFail("opened a production connection that is not read-only")
        } catch is DatabaseError {}
        XCTAssertTrue(driver.isClosed)
        XCTAssertTrue(driver.statements.isEmpty)
        let isOpen = await session.isOpen
        XCTAssertFalse(isOpen)
    }

    func testRelockFailureClosesTheSession() async throws {
        let driver = FailingDriver()
        let session = Session(profile: profile(.production), password: nil, provider: FixedProvider(driver: driver))
        try await session.open()
        try await session.setReadOnly(false)
        driver.failsReadOnly = true
        do {
            try await session.setReadOnly(true)
            XCTFail("re-locked")
        } catch is DatabaseError {}
        XCTAssertTrue(driver.isClosed)
        await assertThrows(.notOpen) { try await session.run("INSERT INTO t VALUES (1)") }
    }

    func testConcurrentStatementsAreSerialized() async throws {
        let session = try await prepared(MemoryProvider(), ["CREATE TABLE t (a)"])
        try await withThrowingTaskGroup(of: Void.self) { group in
            for value in 0..<40 {
                group.addTask {
                    try await session.run("INSERT INTO t VALUES (?1)", parameters: [.integer(Int64(value))])
                    _ = try await session.query("SELECT count(*) FROM t")
                }
            }
            try await group.waitForAll()
        }
        let count = try await session.query("SELECT count(*) FROM t")
        XCTAssertEqual(count.rows, [[.integer(40)]])
        await session.close()
    }

    func testIntrospectionAndPreviewsUseTheAuxiliaryConnection() async throws {
        let provider = MemoryProvider()
        let session = try await prepared(provider, ["CREATE TABLE customer (id INTEGER PRIMARY KEY, name TEXT)", "INSERT INTO customer VALUES (1, 'Ada')"])
        let namespaces = try await session.namespaces()
        XCTAssertEqual(namespaces.first?.tables, ["customer"])
        let table = try await session.describe(TableRef(name: "customer"))
        XCTAssertEqual(table.primaryKey, ["id"])
        let preview = try await session.preview("SELECT name FROM customer WHERE id = ?1", parameters: [.integer(1)])
        XCTAssertEqual(preview.rows, [[.text("Ada")]])
        XCTAssertEqual(provider.requests.all.count, 2)

        // The auxiliary connection is read-only even when the window is not.
        await assertThrows(.readOnly(verb: "DELETE")) { _ = try await session.preview("DELETE FROM customer WHERE id = 1") }
        let databases = try await session.databases()
        XCTAssertTrue(databases.isEmpty)
        await session.close()
    }

    func testWithCursorHoldsTheConnectionAndClosesTheCursor() async throws {
        let session = try await prepared(MemoryProvider(), ["CREATE TABLE t (a)", "INSERT INTO t VALUES (1), (2), (3)"])
        let firstBatch = try await session.withCursor("SELECT a FROM t ORDER BY a") { cursor in
            try await cursor.next(maxRows: 2)
        }
        XCTAssertEqual(firstBatch?.count, 2)
        // The cursor was closed: the connection is free again.
        let after = try await session.query("SELECT count(*) FROM t")
        XCTAssertEqual(after.rows, [[.integer(3)]])
        await session.close()
    }

    func testSwitchDatabaseReconnects() async throws {
        let provider = MemoryProvider()
        let session = try await prepared(provider, ["CREATE TABLE in_first (a)"])
        try await session.switchDatabase("second")
        let database = await session.database
        XCTAssertEqual(database, "second")
        XCTAssertEqual(provider.requests.all, [nil, "second"])
        let namespaces = try await session.namespaces()
        XCTAssertEqual(namespaces.first?.tables, [])
        await session.close()
    }

    func testVersionAndTransactionState() async throws {
        let session = try await prepared(MemoryProvider(), [])
        let version = await session.serverVersion
        XCTAssertNotNil(version)
        try await session.run("BEGIN")
        var state = await session.transactionState
        XCTAssertEqual(state, .inTransaction)
        try await session.run("COMMIT")
        state = await session.transactionState
        XCTAssertEqual(state, .idle)
        await session.close()
    }
}
