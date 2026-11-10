import XCTest
@testable import RowsterCore

/// Runs against the MySQL and MariaDB servers of `scripts/integration-servers.sh`. Only with `make integration`.
final class MySQLIntegrationTests: XCTestCase {
    private static let servers: [(engine: Engine, port: Int)] = [(.mysql, 33069), (.mariadb, 33079)]

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["ROWSTER_INTEGRATION"] == "1", "run with make integration")
    }

    static func configuration(port: Int, user: String = "rowster", tls: TLSMode = .preferred, password: String? = "rowster-test") -> ServerConfiguration {
        ServerConfiguration(
            endpoint: .tcp(host: "127.0.0.1", port: port), tls: TLSSettings(mode: tls, serverName: "localhost"),
            user: user, password: password, database: "rowster_test")
    }

    /// Runs the body once per server that is up; a server that is not installed is skipped.
    private func eachServer(_ body: (MySQLDriver, Engine, Int) async throws -> Void) async throws {
        var ran = 0
        for server in Self.servers {
            let driver = MySQLDriver(configuration: Self.configuration(port: server.port), engine: server.engine)
            do {
                try await driver.connect()
            } catch ConnectionError.unreachable {
                continue
            }
            ran += 1
            try await body(driver, server.engine, server.port)
            await driver.close()
        }
        try XCTSkipIf(ran == 0, "no MySQL or MariaDB server is running")
    }

    func testAuthenticationAndTLS() async throws {
        try await eachServer { driver, engine, port in
            let version = await driver.serverVersion
            XCTAssertTrue(version?.hasPrefix(engine == .mariadb ? "MariaDB " : "MySQL ") == true, version ?? "")

            for mode in [TLSMode.disabled, .preferred, .required] {
                let other = MySQLDriver(configuration: Self.configuration(port: port, tls: mode), engine: engine)
                try await other.connect()
                let cipher = try await other.query("SHOW STATUS LIKE 'Ssl_cipher'")
                let isEncrypted = cipher.rows.first?[1].displayText?.isEmpty == false
                XCTAssertEqual(isEncrypted, mode != .disabled, "\(engine) \(mode)")
                await other.close()
            }

            let wrong = MySQLDriver(configuration: Self.configuration(port: port, password: "nope"), engine: engine)
            do {
                try await wrong.connect()
                XCTFail("connected with a wrong password")
            } catch let error as ConnectionError {
                guard case .authenticationFailed = error else { return XCTFail("\(error)") }
            }
            let verified = MySQLDriver(configuration: Self.configuration(port: port, tls: .verifyIdentity), engine: engine)
            do {
                try await verified.connect()
                XCTFail("accepted a self-signed certificate")
            } catch is ConnectionError {}
        }
    }

    func testTextAndPreparedStatements() async throws {
        try await eachServer { driver, engine, _ in
            try await driver.run("DROP TABLE IF EXISTS it_types")
            try await driver.run(
                "CREATE TABLE it_types (id INT AUTO_INCREMENT PRIMARY KEY, n DECIMAL(10,2), t TEXT, b TINYINT(1), d BLOB, j JSON, ts DATETIME(6), big BIGINT UNSIGNED)")
            let hostile = "x'); DROP TABLE it_types; -- \"é🙂\" \\\n"
            let blob = Data([0, 1, 254, 255])
            let values: [SQLValue] = [
                .double(12.5), .text(hostile), .bool(true), .bytes(blob), .text("{\"a\": [1, 2]}"), .text("2026-11-10 10:20:30.123456"),
                .integer(9_000_000_000)
            ]
            let inserted = try await driver.run("INSERT INTO it_types (n, t, b, d, j, ts, big) VALUES (?, ?, ?, ?, ?, ?, ?)", parameters: values)
            XCTAssertEqual(inserted.rowsAffected, 1)
            try await driver.run("INSERT INTO it_types (n) VALUES (NULL)")

            for parameters in [[SQLValue](), [.integer(0)]] {
                let sql = parameters.isEmpty ? "SELECT id, n, t, b, d, ts, big FROM it_types ORDER BY id"
                    : "SELECT id, n, t, b, d, ts, big FROM it_types WHERE id > ? ORDER BY id"
                let result = try await driver.query(sql, parameters: parameters)
                let label = "\(engine) \(parameters.isEmpty ? "text" : "binary")"
                let kinds: [ColumnKind] = [.integer, .decimal, .text, .integer, .binary, .date, .integer]
                XCTAssertEqual(result.columns.map(\.kind), kinds, label)
                let first: Row = [
                    .integer(1), .text("12.50"), .text(hostile), .integer(1), .bytes(blob), .text("2026-11-10 10:20:30.123456"),
                    .integer(9_000_000_000)
                ]
                XCTAssertEqual(result.rows.first, first, label)
                let second: Row = [.integer(2), .null, .null, .null, .null, .null, .null]
                XCTAssertEqual(result.rows.last, second, label)
            }

            // The same value again still counts its row: matched rows are reported, not changed rows.
            let unchanged = try await driver.run("UPDATE it_types SET t = ? WHERE id = ?", parameters: [.text(hostile), .integer(1)])
            XCTAssertEqual(unchanged.rowsAffected, 1)
            try await driver.run("DROP TABLE it_types")
        }
    }

    func testLimitStopsALargeResultAndTheConnectionStaysUsable() async throws {
        try await eachServer { driver, engine, _ in
            let numbers = "WITH RECURSIVE s(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM s WHERE n < 400000) SELECT n, CONCAT('row-', n) FROM s"
            try await driver.run(engine == .mariadb ? "SET SESSION max_recursive_iterations = 1000000" : "SET SESSION cte_max_recursion_depth = 1000000")
            let started = Date()
            let limited = try await driver.query(numbers, limit: 250)
            XCTAssertEqual(limited.rows.count, 250)
            XCTAssertTrue(limited.isTruncated)
            XCTAssertLessThan(Date().timeIntervalSince(started), 20)
            let after = try await driver.query("SELECT 1")
            XCTAssertEqual(after.rows, [[.integer(1)]])
            let again = try await driver.query("SELECT 2")
            XCTAssertEqual(again.rows, [[.integer(2)]])
        }
    }

    func testErrorsCancelAndReadOnly() async throws {
        try await eachServer { driver, engine, _ in
            do {
                try await driver.run("SELECT * FROM no_such_table")
                XCTFail("no error")
            } catch let error as DatabaseError {
                XCTAssertEqual(error.code, "1146", "\(engine)")
            }
            do {
                try await driver.run("SELECT ?", parameters: [.integer(1), .integer(2)])
                XCTFail("no error")
            } catch let error as DatabaseError {
                XCTAssertEqual(error.code, "PARAMETERS")
            }

            let started = Date()
            Task {
                try? await Task.sleep(for: .milliseconds(400))
                await driver.cancel()
            }
            do {
                try await driver.run("SELECT SLEEP(30)")
                // MySQL ends an interrupted SLEEP without an error: it returns 1.
            } catch let error as DatabaseError {
                XCTAssertTrue(error.isCancellation, "\(engine) \(error)")
            }
            XCTAssertLessThan(Date().timeIntervalSince(started), 10, "\(engine)")

            try await driver.run("DROP TABLE IF EXISTS it_ro")
            try await driver.run("CREATE TABLE it_ro (a INT)")
            try await driver.run("BEGIN")
            var state = await driver.transactionState
            XCTAssertEqual(state, .inTransaction)
            try await driver.run("ROLLBACK")
            state = await driver.transactionState
            XCTAssertEqual(state, .idle)

            try await driver.setReadOnly(true)
            do {
                try await driver.run("INSERT INTO it_ro VALUES (1)")
                XCTFail("wrote on a read-only session")
            } catch let error as DatabaseError {
                XCTAssertEqual(error.code, "1792", "\(engine)")
            }
            try await driver.setReadOnly(false)
            try await driver.run("INSERT INTO it_ro VALUES (2)")
            try await driver.run("DROP TABLE it_ro")
        }
    }

    func testIntrospectionBrowseAndCommit() async throws {
        try await eachServer { driver, engine, port in
            for statement in [
                "DROP TABLE IF EXISTS `it order line`", "DROP VIEW IF EXISTS it_big", "DROP TABLE IF EXISTS it_customer",
                "CREATE TABLE it_customer (id INT AUTO_INCREMENT PRIMARY KEY, email VARCHAR(120) NOT NULL UNIQUE, name VARCHAR(80) DEFAULT 'x', data JSON, photo BLOB)",
                "CREATE TABLE `it order line` (order_id INT, line INT, customer_id INT NOT NULL, qty INT, total INT AS (qty * 2) STORED, PRIMARY KEY (order_id, line), KEY line_customer (customer_id, qty), CONSTRAINT line_fk FOREIGN KEY (customer_id) REFERENCES it_customer (id))",
                "CREATE VIEW it_big AS SELECT * FROM it_customer WHERE id > 10"
            ] { try await driver.run(statement) }

            let introspector = driver.makeIntrospector()
            let databases = try await introspector.databases()
            XCTAssertTrue(databases.contains("rowster_test"))
            let namespace = try await introspector.namespaces()[0]
            XCTAssertNil(namespace.name)
            XCTAssertTrue(namespace.tables.contains("it_customer") && namespace.tables.contains("it order line"))
            XCTAssertTrue(namespace.views.contains("it_big"))

            let customer = try await introspector.describe(TableRef(name: "it_customer"))
            XCTAssertEqual(customer.columns.map(\.name), ["id", "email", "name", "data", "photo"])
            XCTAssertEqual(customer.columns.map(\.isNullable), [false, false, true, true, true])
            XCTAssertEqual(customer.columns.last?.kind, .binary)
            XCTAssertEqual(customer.primaryKey, ["id"])
            XCTAssertTrue(customer.ddl?.contains("CREATE TABLE `it_customer`") == true, "\(engine)")

            let line = try await introspector.describe(TableRef(name: "it order line"))
            XCTAssertEqual(line.primaryKey, ["order_id", "line"])
            XCTAssertEqual(line.columns.last?.isGenerated, true, "\(engine)")
            XCTAssertEqual(line.foreignKey(for: "customer_id")?.referencedTable.name, "it_customer")
            XCTAssertEqual(line.indexes.first { $0.name == "line_customer" }?.columns, ["customer_id", "qty"])
            let view = try await introspector.describe(TableRef(name: "it_big"))
            XCTAssertEqual(view.kind, .view)

            let dialect = MySQLDialect(engine: engine)
            let session = Session(
                profile: ConnectionProfile(name: "it", engine: engine), password: nil, provider: FixedMySQLProvider(port: port, engine: engine))
            try await session.open()
            let changes = ChangeSet(table: customer, changes: [
                .insert(values: ["email": .text("a@example.com"), "photo": .bytes(Data(repeating: 9, count: 3000))]),
                .insert(values: ["email": .text("o'b@example.com"), "name": .text("O'Brien")])
            ])
            try await session.commit(changes.statements(dialect: dialect))

            var query = BrowseQuery(table: customer, limit: 10)
            query.filter = try FilterBuilder(columns: customer.columns, dialect: dialect)
                .build([FilterCondition(target: .column("email"), op: .contains, value: "'B")])
            let select = query.select(dialect: dialect)
            let page = query.page(from: try await session.query(select.sql, parameters: select.parameters))
            XCTAssertEqual(page.rows.count, 1, "\(engine)")
            XCTAssertEqual(page.rows.first?[2], .text("O'Brien"))

            let all = BrowseQuery(table: customer, limit: 10)
            let allPage = all.page(from: try await session.query(all.select(dialect: dialect).sql))
            XCTAssertEqual(allPage.rows.first?[4], .deferredBytes(length: 3000), "\(engine)")

            let failing = ChangeSet(table: customer, changes: [
                .update(key: allPage.keys[0], values: ["name": .text("changed")]), .insert(values: ["email": .text("a@example.com")])
            ])
            do {
                try await session.commit(failing.statements(dialect: dialect))
                XCTFail("the unique violation was not reported")
            } catch let error as DatabaseError {
                XCTAssertEqual(error.code, "1062", "\(engine)")
            }
            let unchanged = try await session.query("SELECT name FROM it_customer ORDER BY id")
            XCTAssertEqual(unchanged.rows.first, [.text("x")], "\(engine)")
            await session.close()

            for statement in ["DROP VIEW it_big", "DROP TABLE `it order line`", "DROP TABLE it_customer"] { try await driver.run(statement) }
        }
    }
}

struct FixedMySQLProvider: DriverProviding {
    let port: Int
    let engine: Engine
    func makeDriver(for profile: ConnectionProfile, password: String?, database: String?, readOnly: Bool) throws -> any DatabaseDriver {
        MySQLDriver(configuration: MySQLIntegrationTests.configuration(port: port), engine: engine)
    }
}
