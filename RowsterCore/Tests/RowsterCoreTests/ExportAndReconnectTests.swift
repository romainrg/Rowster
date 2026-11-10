import XCTest
@testable import RowsterCore

/// Wraps a SQLite driver and fails the next statement with a closed connection when told to.
final class DroppingDriver: DatabaseDriver, @unchecked Sendable {
    let inner: SQLiteDriver
    let control: Control

    final class Control: @unchecked Sendable {
        private let lock = NSLock()
        private var shouldDrop = false
        private var made = 0
        func dropNext() { lock.withLock { shouldDrop = true } }
        func takeDrop() -> Bool {
            lock.withLock {
                defer { shouldDrop = false }
                return shouldDrop
            }
        }
        func countDriver() { lock.withLock { made += 1 } }
        var drivers: Int { lock.withLock { made } }
    }

    init(configuration: SQLiteConfiguration, control: Control) {
        inner = SQLiteDriver(configuration: configuration)
        self.control = control
    }

    var dialect: any SQLDialect { inner.dialect }
    func connect() async throws { try await inner.connect() }
    func close() async { await inner.close() }
    func execute(_ sql: String, parameters: [SQLValue]) async throws -> any ResultCursor {
        if control.takeDrop() { throw ConnectionError.closed }
        return try await inner.execute(sql, parameters: parameters)
    }
    func cancel() async { await inner.cancel() }
    var transactionState: TransactionState { get async { await inner.transactionState } }
    var serverVersion: String? { get async { await inner.serverVersion } }
    func setReadOnly(_ readOnly: Bool) async throws { try await inner.setReadOnly(readOnly) }
    func makeIntrospector() -> any SchemaIntrospecting { inner.makeIntrospector() }
}

struct DroppingProvider: DriverProviding {
    let name = "rowster-drop-\(UUID().uuidString)"
    let control = DroppingDriver.Control()

    func makeDriver(for profile: ConnectionProfile, password: String?, database: String?, readOnly: Bool) throws -> any DatabaseDriver {
        control.countDriver()
        var configuration = SQLiteConfiguration.sharedMemory(name: name)
        configuration.readOnly = readOnly
        return DroppingDriver(configuration: configuration, control: control)
    }
}

final class ExportAndReconnectTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("rowster-export-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Export

    private func session(rows: Int) async throws -> Session {
        let session = Session(profile: ConnectionProfile(name: "t", engine: .sqlite), password: nil, provider: MemoryProvider())
        try await session.open()
        try await session.run("CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT, note TEXT, photo BLOB)")
        try await session.run(
            "INSERT INTO t SELECT x, 'name ' || x, CASE WHEN x % 2 = 0 THEN 'a, \"quoted\"' END, CASE WHEN x = 1 THEN x'0102' END FROM (WITH RECURSIVE n(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM n WHERE x < \(rows)) SELECT x FROM n)")
        return session
    }

    func testExportsEveryRowAsCSVAndJSON() async throws {
        let session = try await session(rows: 2500)
        let table = try await session.describe(TableRef(name: "t"))
        let all = BrowseQuery(table: table, limit: 300).selectAll(dialect: SQLiteDialect())
        XCTAssertEqual(all.sql, #"SELECT "id", "name", "note", "photo" FROM "t" ORDER BY "id" ASC"#)

        let csv = directory.appendingPathComponent("t.csv")
        let progress = Progress()
        let written = try await session.export(all.sql, parameters: all.parameters, to: csv, format: .csv) { progress.set($0) }
        XCTAssertEqual(written, 2500)
        XCTAssertEqual(progress.last, 2500)
        let lines = try String(contentsOf: csv, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false)
        XCTAssertEqual(lines.count, 2502)
        XCTAssertEqual(lines[0], "id,name,note,photo")
        XCTAssertEqual(lines[1], "1,name 1,,AQI=")
        XCTAssertEqual(lines[2], "2,name 2,\"a, \"\"quoted\"\"\",")

        let json = directory.appendingPathComponent("t.json")
        let count = try await session.export(all.sql, to: json, format: .json)
        XCTAssertEqual(count, 2500)
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: json)) as? [[String: Any]])
        XCTAssertEqual(parsed.count, 2500)
        XCTAssertEqual(parsed[1]["note"] as? String, "a, \"quoted\"")
        XCTAssertTrue(parsed[0]["note"] is NSNull)
        XCTAssertEqual(parsed[2499]["id"] as? Int, 2500)

        // The connection is free again after an export.
        let after = try await session.query("SELECT 1")
        XCTAssertEqual(after.rows.count, 1)
        await session.close()
    }

    func testExportOfNothingAndOfAFilter() async throws {
        let session = try await session(rows: 10)
        let table = try await session.describe(TableRef(name: "t"))
        var query = BrowseQuery(table: table)
        query.filter = BrowseQuery.equality(column: "id", value: .integer(999), dialect: SQLiteDialect())
        let none = query.selectAll(dialect: SQLiteDialect())
        let empty = directory.appendingPathComponent("empty.json")
        let written = try await session.export(none.sql, parameters: none.parameters, to: empty, format: .json)
        XCTAssertEqual(written, 0)
        XCTAssertEqual(try String(contentsOf: empty, encoding: .utf8), "[\n\n]\n")
        // An export is a read: a write is refused before anything is created.
        do {
            _ = try await session.export("DELETE FROM t", to: directory.appendingPathComponent("x.csv"), format: .csv)
            XCTFail("exported a DELETE")
        } catch {
            XCTAssertEqual(error as? SessionError, .needsConfirmation(.deleteWithoutWhere))
        }
        await session.close()
    }

    final class Progress: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func set(_ new: Int) { lock.withLock { value = new } }
        var last: Int { lock.withLock { value } }
    }

    // MARK: - Reconnection

    func testAReadIsReplayedAfterTheConnectionDrops() async throws {
        let provider = DroppingProvider()
        // A second session keeps the shared in-memory database alive across the reconnection.
        let keeper = Session(profile: ConnectionProfile(name: "keep", engine: .sqlite), password: nil, provider: provider)
        try await keeper.open()
        try await keeper.run("CREATE TABLE t (a)")
        try await keeper.run("INSERT INTO t VALUES (1)")

        let session = Session(profile: ConnectionProfile(name: "t", engine: .sqlite), password: nil, provider: provider)
        try await session.open()
        provider.control.dropNext()
        let rows = try await session.query("SELECT a FROM t")
        XCTAssertEqual(rows.rows, [[.integer(1)]])
        XCTAssertEqual(provider.control.drivers, 3)
        await session.close()
        await keeper.close()
    }

    func testAWriteIsNeverReplayed() async throws {
        let provider = DroppingProvider()
        let keeper = Session(profile: ConnectionProfile(name: "keep", engine: .sqlite), password: nil, provider: provider)
        try await keeper.open()
        try await keeper.run("CREATE TABLE t (a)")

        let session = Session(profile: ConnectionProfile(name: "t", engine: .sqlite), password: nil, provider: provider)
        try await session.open()
        provider.control.dropNext()
        do {
            try await session.run("INSERT INTO t VALUES (1)")
            XCTFail("the write was replayed")
        } catch {
            XCTAssertEqual(error as? SessionError, .connectionLost(reconnected: true))
        }
        let count = try await session.query("SELECT count(*) FROM t")
        XCTAssertEqual(count.rows, [[.integer(0)]])
        // The session works again: the user can run the statement once more.
        try await session.run("INSERT INTO t VALUES (1)")
        await session.close()
        await keeper.close()
    }

    func testReadOnlyIsAppliedAgainAfterAReconnection() async throws {
        let provider = DroppingProvider()
        let keeper = Session(profile: ConnectionProfile(name: "keep", engine: .sqlite), password: nil, provider: provider)
        try await keeper.open()
        try await keeper.run("CREATE TABLE t (a)")

        var production = ConnectionProfile(name: "prod", engine: .sqlite)
        production.label = .production
        let session = Session(profile: production, password: nil, provider: provider)
        try await session.open()
        provider.control.dropNext()
        _ = try await session.query("SELECT count(*) FROM t")
        let readOnly = await session.isReadOnly
        XCTAssertTrue(readOnly)
        do {
            try await session.run("INSERT INTO t VALUES (1)")
            XCTFail("wrote after a reconnection")
        } catch {
            XCTAssertEqual(error as? SessionError, .readOnly(verb: "INSERT"))
        }
        // Even past the client-side check, the new connection itself is read-only.
        try await session.setReadOnly(false)
        try await session.setReadOnly(true)
        await session.close()
        await keeper.close()
    }
}
