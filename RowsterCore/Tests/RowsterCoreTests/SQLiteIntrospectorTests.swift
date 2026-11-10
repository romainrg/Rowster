import XCTest
@testable import RowsterCore

final class SQLiteIntrospectorTests: XCTestCase {
    private func database(_ statements: [String]) async throws -> (SQLiteDriver, any SchemaIntrospecting) {
        let driver = SQLiteDriver(configuration: .memory())
        try await driver.connect()
        for statement in statements { try await driver.run(statement) }
        return (driver, driver.makeIntrospector())
    }

    func testListsTablesAndViews() async throws {
        let (_, introspector) = try await database([
            "CREATE TABLE zebra (a)", "CREATE TABLE Apple (a)", "CREATE VIEW fruit AS SELECT * FROM Apple",
            "CREATE INDEX zebra_a ON zebra (a)"
        ])
        let namespaces = try await introspector.namespaces()
        XCTAssertEqual(namespaces.count, 1)
        XCTAssertNil(namespaces[0].name)
        XCTAssertEqual(namespaces[0].tables, ["Apple", "zebra"])
        XCTAssertEqual(namespaces[0].views, ["fruit"])
        let databases = try await introspector.databases()
        XCTAssertTrue(databases.isEmpty)
    }

    func testDescribesColumnsKeysAndIndexes() async throws {
        let (_, introspector) = try await database([
            "CREATE TABLE customer (id INTEGER PRIMARY KEY, email TEXT NOT NULL UNIQUE, name VARCHAR(80) DEFAULT 'x', score REAL, data JSON, photo BLOB, born DATE, vip BOOLEAN NOT NULL DEFAULT 0)",
            "CREATE INDEX customer_name ON customer (name, score)"
        ])
        let table = try await introspector.describe(TableRef(name: "customer"))
        XCTAssertEqual(table.kind, .table)
        XCTAssertEqual(table.columns.map(\.name), ["id", "email", "name", "score", "data", "photo", "born", "vip"])
        XCTAssertEqual(table.columns.map(\.kind), [.integer, .text, .text, .decimal, .json, .binary, .date, .boolean])
        XCTAssertEqual(table.columns.map(\.isNullable), [false, false, true, true, true, true, true, false])
        XCTAssertEqual(table.columns[2].defaultValue, "'x'")
        XCTAssertEqual(table.primaryKey, ["id"])
        XCTAssertEqual(table.rowIdentity, .columns(["id"]))
        XCTAssertTrue(table.hasRowID)

        let named = table.indexes.first { $0.name == "customer_name" }
        XCTAssertEqual(named?.columns, ["name", "score"])
        XCTAssertEqual(named?.isUnique, false)
        XCTAssertTrue(table.indexes.contains { $0.isUnique && $0.columns == ["email"] })
        XCTAssertTrue(table.ddl?.contains("CREATE TABLE customer") == true)
        XCTAssertTrue(table.ddl?.contains("CREATE INDEX customer_name") == true)
    }

    func testCompositePrimaryKeyKeepsItsOrder() async throws {
        let (_, introspector) = try await database(["CREATE TABLE line (b INT, a INT, qty INT, PRIMARY KEY (a, b)) WITHOUT ROWID"])
        let table = try await introspector.describe(TableRef(name: "line"))
        XCTAssertEqual(table.primaryKey, ["a", "b"])
        XCTAssertFalse(table.hasRowID)
        XCTAssertEqual(table.rowIdentity, .columns(["a", "b"]))
    }

    func testRowIdentityFallsBackToUniqueIndexThenRowID() async throws {
        let (_, introspector) = try await database([
            "CREATE TABLE u (code TEXT NOT NULL, label TEXT)", "CREATE UNIQUE INDEX u_code ON u (code)",
            "CREATE TABLE nullable_unique (code TEXT, label TEXT)", "CREATE UNIQUE INDEX nu_code ON nullable_unique (code)",
            "CREATE TABLE bare (a, b)", "CREATE VIEW v AS SELECT * FROM bare"
        ])
        let unique = try await introspector.describe(TableRef(name: "u"))
        XCTAssertEqual(unique.rowIdentity, .columns(["code"]))
        // A unique index over a nullable column does not identify a row: NULLs are not unique.
        let nullable = try await introspector.describe(TableRef(name: "nullable_unique"))
        XCTAssertEqual(nullable.rowIdentity, .rowID)
        let bare = try await introspector.describe(TableRef(name: "bare"))
        XCTAssertEqual(bare.rowIdentity, .rowID)
        let view = try await introspector.describe(TableRef(name: "v"))
        XCTAssertEqual(view.kind, .view)
        XCTAssertNil(view.rowIdentity)
    }

    func testForeignKeys() async throws {
        let (_, introspector) = try await database([
            "CREATE TABLE customer (id INTEGER PRIMARY KEY)",
            "CREATE TABLE product (sku TEXT, variant TEXT, PRIMARY KEY (sku, variant))",
            "CREATE TABLE orders (id INTEGER PRIMARY KEY, customer_id INT REFERENCES customer (id) ON DELETE CASCADE, sku TEXT, variant TEXT, FOREIGN KEY (sku, variant) REFERENCES product (sku, variant))"
        ])
        let table = try await introspector.describe(TableRef(name: "orders"))
        XCTAssertEqual(table.foreignKeys.count, 2)
        let single = table.foreignKey(for: "customer_id")
        XCTAssertEqual(single?.referencedTable, TableRef(name: "customer"))
        XCTAssertEqual(single?.referencedColumns, ["id"])
        XCTAssertEqual(single?.onDelete, "CASCADE")
        let composite = table.foreignKeys.first { $0.columns.count == 2 }
        XCTAssertEqual(composite?.columns, ["sku", "variant"])
        XCTAssertEqual(composite?.referencedColumns, ["sku", "variant"])
        XCTAssertNil(table.foreignKey(for: "sku"))
    }

    func testGeneratedColumns() async throws {
        let (_, introspector) = try await database(["CREATE TABLE g (a INT, b INT GENERATED ALWAYS AS (a * 2) STORED)"])
        let table = try await introspector.describe(TableRef(name: "g"))
        XCTAssertEqual(table.columns.map(\.isGenerated), [false, true])
    }

    func testHostileNamesAreData() async throws {
        let dialect = SQLiteDialect()
        var statements: [String] = []
        let names = SQLDialectTests.hostileIdentifiers.filter { !$0.isEmpty }
        for name in names {
            statements.append("CREATE TABLE \(dialect.quote(identifier: name)) (\(dialect.quote(identifier: name)) INTEGER PRIMARY KEY)")
        }
        let (driver, introspector) = try await database(statements)
        let listed = try await introspector.namespaces()[0].tables
        XCTAssertEqual(Set(listed), Set(names))
        for name in names {
            let table = try await introspector.describe(TableRef(name: name))
            XCTAssertEqual(table.columns.map(\.name), [name], name)
            XCTAssertEqual(table.primaryKey, [name], name)
        }
        // Nothing was dropped along the way.
        let count = try await driver.query("SELECT count(*) FROM sqlite_master WHERE type = 'table'")
        XCTAssertEqual(count.rows, [[.integer(Int64(names.count))]])
    }

    func testUnknownTable() async throws {
        let (_, introspector) = try await database([])
        do {
            _ = try await introspector.describe(TableRef(name: "nope"))
            XCTFail("described a missing table")
        } catch let error as DatabaseError {
            XCTAssertTrue(error.message.contains("nope"))
        }
    }

    func testNoEstimate() async throws {
        let (_, introspector) = try await database(["CREATE TABLE t (a)"])
        let estimate = try await introspector.estimatedRowCount(TableRef(name: "t"))
        XCTAssertNil(estimate)
    }
}
