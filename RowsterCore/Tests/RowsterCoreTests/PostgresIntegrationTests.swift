import XCTest
@testable import RowsterCore

/// Runs against the PostgreSQL server of `scripts/integration-servers.sh`. Only with `make integration`.
final class PostgresIntegrationTests: XCTestCase {
    static let password = "rowster-test"

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["ROWSTER_INTEGRATION"] == "1", "run with make integration")
    }

    static func configuration(user: String = "rowster", tls: TLSMode = .preferred, password: String? = password) -> ServerConfiguration {
        ServerConfiguration(
            endpoint: .tcp(host: "127.0.0.1", port: 54329), tls: TLSSettings(mode: tls, serverName: "localhost"),
            user: user, password: password, database: "rowster_test")
    }

    private func connect(user: String = "rowster", tls: TLSMode = .preferred) async throws -> PostgresDriver {
        let driver = PostgresDriver(configuration: Self.configuration(user: user, tls: tls))
        try await driver.connect()
        return driver
    }

    func testAuthenticationMethodsAndTLSModes() async throws {
        for (user, mode) in [("rowster", TLSMode.disabled), ("rowster", .preferred), ("rowster_md5", .disabled), ("rowster_tls", .required)] {
            let driver = try await connect(user: user, tls: mode)
            let result = try await driver.query("SELECT current_user, (SELECT ssl FROM pg_stat_ssl WHERE pid = pg_backend_pid())")
            XCTAssertEqual(result.rows.first?[0], .text(user))
            XCTAssertEqual(result.rows.first?[1], .bool(mode != .disabled), "\(user) \(mode)")
            let version = await driver.serverVersion
            XCTAssertTrue(version?.hasPrefix("PostgreSQL ") == true)
            await driver.close()
        }
    }

    func testFailuresAreReportedAsConnectionErrors() async throws {
        let wrongPassword = PostgresDriver(configuration: Self.configuration(password: "nope"))
        do {
            try await wrongPassword.connect()
            XCTFail("connected with a wrong password")
        } catch let error as ConnectionError {
            guard case .authenticationFailed = error else { return XCTFail("\(error)") }
        }
        // This user is only allowed over TLS.
        let noTLS = PostgresDriver(configuration: Self.configuration(user: "rowster_tls", tls: .disabled))
        do {
            try await noTLS.connect()
            XCTFail("connected without TLS")
        } catch is ConnectionError {}
        // The server certificate is self-signed: verification must refuse it.
        let verified = PostgresDriver(configuration: Self.configuration(tls: .verifyIdentity))
        do {
            try await verified.connect()
            XCTFail("accepted a self-signed certificate")
        } catch is ConnectionError {}
    }

    func testTypesParametersAndRowsAffected() async throws {
        let driver = try await connect()
        try await driver.run("DROP TABLE IF EXISTS it_types")
        try await driver.run("CREATE TABLE it_types (id serial PRIMARY KEY, n numeric(10,2), t text, b boolean, d bytea, j jsonb, ts timestamptz, big int8)")
        let hostile = "x'); DROP TABLE it_types; -- \"é🙂\"\n"
        let blob = Data([0, 1, 254, 255])
        let values: [SQLValue] = [
            .double(12.5), .text(hostile), .bool(true), .bytes(blob), .text("{\"a\": [1, 2]}"),
            .text("2026-11-10 10:00:00+00"), .integer(9_000_000_000)
        ]
        let summary = try await driver.run(
            "INSERT INTO it_types (n, t, b, d, j, ts, big) VALUES ($1, $2, $3, $4, $5, $6, $7), ($1, NULL, NULL, NULL, NULL, NULL, NULL)",
            parameters: values)
        XCTAssertEqual(summary.rowsAffected, 2)

        let result = try await driver.query("SELECT id, n, t, b, d, j, big FROM it_types ORDER BY id")
        let kinds: [ColumnKind] = [.integer, .decimal, .text, .boolean, .binary, .json, .integer]
        XCTAssertEqual(result.columns.map(\.kind), kinds)
        let first: Row = [.integer(1), .text("12.50"), .text(hostile), .bool(true), .bytes(blob), .text("{\"a\": [1, 2]}"), .integer(9_000_000_000)]
        let second: Row = [.integer(2), .text("12.50"), .null, .null, .null, .null, .null]
        XCTAssertEqual(result.rows[0], first)
        XCTAssertEqual(result.rows[1], second)

        let updated = try await driver.run("UPDATE it_types SET t = $1 WHERE id = $2", parameters: [.text("same"), .integer(1)])
        XCTAssertEqual(updated.rowsAffected, 1)
        try await driver.run("DROP TABLE it_types")
        await driver.close()
    }

    func testPortalReadsInBatchesAndStopsAtTheLimit() async throws {
        let driver = try await connect()
        let cursor = try await driver.execute("SELECT g FROM generate_series(1, 1000000) g", parameters: [])
        let first = try await cursor.next(maxRows: 300)
        XCTAssertEqual(first?.count, 300)
        let second = try await cursor.next(maxRows: 300)
        XCTAssertEqual(second?.first, [.integer(301)])
        _ = try await cursor.close()

        let limited = try await driver.query("SELECT g FROM generate_series(1, 1000000) g", limit: 250)
        XCTAssertEqual(limited.rows.count, 250)
        XCTAssertTrue(limited.isTruncated)
        let small = try await driver.query("SELECT g FROM generate_series(1, 3) g", limit: 250)
        XCTAssertEqual(small.rows.count, 3)
        XCTAssertFalse(small.isTruncated)
        await driver.close()
    }

    func testErrorsLeaveTheConnectionUsable() async throws {
        let driver = try await connect()
        do {
            try await driver.run("SELECT * FROM no_such_table")
            XCTFail("no error")
        } catch let error as DatabaseError {
            XCTAssertEqual(error.code, "42P01")
            XCTAssertEqual(error.position, 15)
        }
        do {
            _ = try await driver.query("SELECT 1 / (g - 2) FROM generate_series(1, 3) g")
            XCTFail("no error")
        } catch let error as DatabaseError {
            XCTAssertEqual(error.code, "22012")
        }
        let after = try await driver.query("SELECT 1")
        XCTAssertEqual(after.rows, [[.integer(1)]])
        await driver.close()
    }

    func testCancelInterruptsAStatement() async throws {
        let driver = try await connect(user: "rowster_tls", tls: .required)
        let started = Date()
        Task {
            try? await Task.sleep(for: .milliseconds(400))
            await driver.cancel()
        }
        do {
            try await driver.run("SELECT pg_sleep(30)")
            XCTFail("not interrupted")
        } catch let error as DatabaseError {
            XCTAssertTrue(error.isCancellation)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
        let after = try await driver.query("SELECT 1")
        XCTAssertEqual(after.rows.count, 1)
        await driver.close()
    }

    func testTransactionsAndReadOnly() async throws {
        let driver = try await connect()
        try await driver.run("DROP TABLE IF EXISTS it_ro")
        try await driver.run("CREATE TABLE it_ro (a int)")
        try await driver.run("BEGIN")
        var state = await driver.transactionState
        XCTAssertEqual(state, .inTransaction)
        try await driver.run("INSERT INTO it_ro VALUES (1)")
        try await driver.run("ROLLBACK")
        state = await driver.transactionState
        XCTAssertEqual(state, .idle)

        try await driver.setReadOnly(true)
        do {
            try await driver.run("INSERT INTO it_ro VALUES (2)")
            XCTFail("wrote on a read-only session")
        } catch let error as DatabaseError {
            XCTAssertEqual(error.code, "25006")
        }
        try await driver.setReadOnly(false)
        try await driver.run("INSERT INTO it_ro VALUES (3)")
        let rows = try await driver.query("SELECT a FROM it_ro")
        XCTAssertEqual(rows.rows, [[.integer(3)]])
        try await driver.run("DROP TABLE it_ro")
        await driver.close()
    }

    func testIntrospection() async throws {
        let driver = try await connect()
        for statement in [
            "DROP SCHEMA IF EXISTS it_shop CASCADE", "CREATE SCHEMA it_shop",
            "CREATE TABLE it_shop.customer (id serial PRIMARY KEY, email text NOT NULL UNIQUE, name varchar(80) DEFAULT 'x', data jsonb, photo bytea)",
            "CREATE TABLE it_shop.\"order line\" (order_id int, line int, customer_id int NOT NULL REFERENCES it_shop.customer (id), qty int CHECK (qty > 0), total numeric GENERATED ALWAYS AS (qty * 2) STORED, PRIMARY KEY (order_id, line))",
            "CREATE INDEX line_customer ON it_shop.\"order line\" (customer_id, qty)",
            "CREATE VIEW it_shop.big AS SELECT * FROM it_shop.customer WHERE id > 10"
        ] { try await driver.run(statement) }

        let introspector = driver.makeIntrospector()
        let databases = try await introspector.databases()
        XCTAssertTrue(databases.contains("rowster_test"))
        let namespaces = try await introspector.namespaces()
        let namespace = try XCTUnwrap(namespaces.first { $0.name == "it_shop" })
        XCTAssertEqual(namespace.tables, ["customer", "order line"])
        XCTAssertEqual(namespace.views, ["big"])

        let customer = try await introspector.describe(TableRef(schema: "it_shop", name: "customer"))
        XCTAssertEqual(customer.columns.map(\.name), ["id", "email", "name", "data", "photo"])
        XCTAssertEqual(customer.columns.map(\.kind), [.integer, .text, .text, .json, .binary])
        XCTAssertEqual(customer.columns.map(\.isNullable), [false, false, true, true, true])
        XCTAssertEqual(customer.primaryKey, ["id"])
        XCTAssertEqual(customer.rowIdentity, .columns(["id"]))
        XCTAssertTrue(customer.ddl?.contains("CREATE TABLE \"it_shop\".\"customer\"") == true)
        XCTAssertTrue(customer.ddlIsReconstructed)

        let line = try await introspector.describe(TableRef(schema: "it_shop", name: "order line"))
        XCTAssertEqual(line.primaryKey, ["order_id", "line"])
        XCTAssertEqual(line.columns.last?.isGenerated, true)
        XCTAssertEqual(line.foreignKey(for: "customer_id")?.referencedTable, TableRef(schema: "it_shop", name: "customer"))
        XCTAssertEqual(line.foreignKey(for: "customer_id")?.referencedColumns, ["id"])
        XCTAssertEqual(line.checks.count, 1)
        XCTAssertEqual(line.indexes.first { $0.name == "line_customer" }?.columns, ["customer_id", "qty"])

        let view = try await introspector.describe(TableRef(schema: "it_shop", name: "big"))
        XCTAssertEqual(view.kind, .view)
        XCTAssertNil(view.rowIdentity)

        // The browse query, the filter and a commit work end to end on this engine.
        let provider = FixedPostgresProvider()
        let session = Session(profile: ConnectionProfile(name: "it", engine: .postgres), password: nil, provider: provider)
        try await session.open()
        let changes = ChangeSet(table: customer, changes: [
            .insert(values: ["email": .text("a@example.com"), "photo": .bytes(Data(repeating: 9, count: 3000))]),
            .insert(values: ["email": .text("o'b@example.com"), "name": .text("O'Brien")])
        ])
        try await session.commit(changes.statements(dialect: PostgresDialect()))
        var query = BrowseQuery(table: customer, limit: 10)
        query.filter = try FilterBuilder(columns: customer.columns, dialect: PostgresDialect())
            .build([FilterCondition(target: .column("email"), op: .contains, value: "'B")])
        let select = query.select(dialect: PostgresDialect())
        let page = query.page(from: try await session.query(select.sql, parameters: select.parameters))
        XCTAssertEqual(page.rows.count, 1)
        XCTAssertEqual(page.rows.first?[2], .text("O'Brien"))
        let all = BrowseQuery(table: customer, limit: 10)
        let allPage = all.page(from: try await session.query(all.select(dialect: PostgresDialect()).sql))
        XCTAssertEqual(allPage.rows.first?[4], .deferredBytes(length: 3000))
        let duplicate = ChangeSet(table: customer, changes: [
            .update(key: allPage.keys[0], values: ["name": .text("changed")]), .insert(values: ["email": .text("a@example.com")])
        ])
        do {
            try await session.commit(duplicate.statements(dialect: PostgresDialect()))
            XCTFail("the unique violation was not reported")
        } catch let error as DatabaseError {
            XCTAssertEqual(error.code, "23505")
        }
        let unchanged = try await session.query("SELECT name FROM it_shop.customer ORDER BY id")
        XCTAssertEqual(unchanged.rows.first, [.text("x")])
        await session.close()

        try await driver.run("DROP SCHEMA it_shop CASCADE")
        await driver.close()
    }
}

struct FixedPostgresProvider: DriverProviding {
    func makeDriver(for profile: ConnectionProfile, password: String?, database: String?, readOnly: Bool) throws -> any DatabaseDriver {
        PostgresDriver(configuration: PostgresIntegrationTests.configuration())
    }
}
