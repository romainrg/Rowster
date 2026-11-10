import XCTest
@testable import RowsterCore

final class BrowseQueryTests: XCTestCase {
    private let orders = TableDescription(
        ref: TableRef(schema: "shop", name: "orders"),
        columns: [
            ColumnDescription(name: "id", typeName: "int", kind: .integer, isNullable: false, primaryKeyPosition: 1),
            ColumnDescription(name: "status", typeName: "text", kind: .text),
            ColumnDescription(name: "receipt", typeName: "bytea", kind: .binary)
        ])

    func testSelectPerDialect() {
        let query = BrowseQuery(table: orders, limit: 300, offset: 600)
        XCTAssertEqual(
            query.select(dialect: PostgresDialect()).sql,
            #"SELECT "id", "status", octet_length("receipt") AS "receipt" FROM "shop"."orders" ORDER BY "id" ASC LIMIT 301 OFFSET 600"#)
        XCTAssertEqual(
            query.select(dialect: MySQLDialect()).sql,
            "SELECT `id`, `status`, OCTET_LENGTH(`receipt`) AS `receipt` FROM `shop`.`orders` ORDER BY `id` ASC LIMIT 301 OFFSET 600")
        XCTAssertEqual(
            query.select(dialect: SQLiteDialect()).sql,
            #"SELECT "id", "status", length(CAST("receipt" AS BLOB)) AS "receipt" FROM "shop"."orders" ORDER BY "id" ASC LIMIT 301 OFFSET 600"#)
    }

    func testSortKeepsTheKeyAsATieBreakerAndIgnoresUnknownColumns() {
        var query = BrowseQuery(table: orders)
        query.sort = [SortTerm(column: "status", ascending: false), SortTerm(column: "nope"), SortTerm(column: "status")]
        XCTAssertTrue(query.select(dialect: PostgresDialect()).sql.contains(#"ORDER BY "status" DESC, "id" ASC LIMIT"#))
        query.sort = [SortTerm(column: "id", ascending: false)]
        XCTAssertTrue(query.select(dialect: PostgresDialect()).sql.contains(#"ORDER BY "id" DESC LIMIT"#))
    }

    func testFilterIsParenthesizedAndItsValuesStayParameters() {
        var query = BrowseQuery(table: orders)
        query.filter = SQLFragment(sql: #""status" = $1 OR "status" = $2"#, parameters: [.text("failed"), .text("x' OR 1=1 --")])
        let select = query.select(dialect: PostgresDialect())
        XCTAssertTrue(select.sql.contains(#"WHERE ("status" = $1 OR "status" = $2) ORDER BY"#))
        XCTAssertEqual(select.parameters, [.text("failed"), .text("x' OR 1=1 --")])
        XCTAssertFalse(select.sql.contains("1=1"))
        let count = query.count(dialect: PostgresDialect())
        XCTAssertEqual(count.sql, #"SELECT count(*) FROM "shop"."orders" WHERE ("status" = $1 OR "status" = $2)"#)
        XCTAssertEqual(count.parameters.count, 2)
    }

    func testRowIDIdentity() {
        let log = TableDescription(
            ref: TableRef(name: "log"), columns: [ColumnDescription(name: "line", typeName: "text", kind: .text)], hasRowID: true)
        let query = BrowseQuery(table: log, limit: 2)
        XCTAssertEqual(
            query.select(dialect: SQLiteDialect()).sql,
            #"SELECT rowid AS "__rowster_rowid", "line" FROM "log" ORDER BY rowid ASC LIMIT 3 OFFSET 0"#)
        let result = QueryResult(
            columns: [], rows: [[.integer(7), .text("a")], [.integer(9), .text("b")], [.integer(12), .text("c")]],
            isTruncated: false, summary: CommandSummary())
        let page = query.page(from: result)
        XCTAssertEqual(page.rows, [[.text("a")], [.text("b")]])
        XCTAssertEqual(page.keys, [[.integer(7)], [.integer(9)]])
        XCTAssertTrue(page.hasMore)
        XCTAssertEqual(query.value(of: "line", key: [.integer(7)], dialect: SQLiteDialect())?.sql, #"SELECT "line" FROM "log" WHERE rowid = ?1"#)
    }

    func testPageMarksDeferredBinaryAndExtractsKeys() {
        let query = BrowseQuery(table: orders, limit: 10)
        let result = QueryResult(
            columns: [], rows: [[.integer(1), .text("paid"), .integer(2048)], [.integer(2), .null, .null]],
            isTruncated: false, summary: CommandSummary())
        let page = query.page(from: result)
        XCTAssertEqual(page.rows, [[.integer(1), .text("paid"), .deferredBytes(length: 2048)], [.integer(2), .null, .null]])
        XCTAssertEqual(page.keys, [[.integer(1)], [.integer(2)]])
        XCTAssertFalse(page.hasMore)
    }

    func testNoIdentityMeansNoOrderNoKeysAndNoValueFetch() {
        let view = TableDescription(
            ref: TableRef(name: "v"), kind: .view, columns: [ColumnDescription(name: "a", typeName: "", kind: .other)])
        let query = BrowseQuery(table: view)
        XCTAssertEqual(query.select(dialect: PostgresDialect()).sql, #"SELECT "a" FROM "v" LIMIT 301 OFFSET 0"#)
        XCTAssertNil(query.value(of: "a", key: [], dialect: PostgresDialect()))
        let page = query.page(from: QueryResult(columns: [], rows: [[.integer(1)]], isTruncated: false, summary: CommandSummary()))
        XCTAssertEqual(page.keys, [[]])
    }

    func testValueFetchWithCompositeKey() {
        let items = TableDescription(
            ref: TableRef(name: "items"),
            columns: [
                ColumnDescription(name: "order", typeName: "int", kind: .integer, isNullable: false, primaryKeyPosition: 2),
                ColumnDescription(name: "sku", typeName: "text", kind: .text, isNullable: false, primaryKeyPosition: 1),
                ColumnDescription(name: "photo", typeName: "blob", kind: .binary)
            ])
        let query = BrowseQuery(table: items)
        let fetch = query.value(of: "photo", key: [.text("A-1"), .integer(4)], dialect: MySQLDialect())
        XCTAssertEqual(fetch?.sql, "SELECT `photo` FROM `items` WHERE `sku` = ? AND `order` = ?")
        XCTAssertEqual(fetch?.parameters, [.text("A-1"), .integer(4)])
        XCTAssertNil(query.value(of: "photo", key: [.text("A-1")], dialect: MySQLDialect()))
        // Keys follow the primary key order, not the column order.
        let page = query.page(from: QueryResult(columns: [], rows: [[.integer(4), .text("A-1"), .null]], isTruncated: false, summary: CommandSummary()))
        XCTAssertEqual(page.keys, [[.text("A-1"), .integer(4)]])
    }

    /// The generated SQL runs on a real database, with names that try to break out of their quotes.
    func testRunsOnSQLiteWithHostileNames() async throws {
        let dialect = SQLiteDialect()
        let driver = SQLiteDriver(configuration: .memory())
        try await driver.connect()
        for name in SQLDialectTests.hostileIdentifiers where !name.isEmpty {
            let table = dialect.quote(identifier: name)
            try await driver.run("CREATE TABLE \(table) (\(table) INTEGER PRIMARY KEY, \"blob col\" BLOB, note TEXT)")
            try await driver.run(
                "INSERT INTO \(table) VALUES (?1, ?2, ?3), (?4, NULL, NULL)",
                parameters: [.integer(1), .bytes(Data(repeating: 7, count: 5000)), .text(name), .integer(2)])

            let description = try await driver.makeIntrospector().describe(TableRef(name: name))
            var query = BrowseQuery(table: description, limit: 1)
            query.sort = [SortTerm(column: "note", ascending: false)]
            query.filter = BrowseQuery.equality(column: name, value: .integer(1), dialect: dialect)
            let select = query.select(dialect: dialect)
            let page = query.page(from: try await driver.query(select.sql, parameters: select.parameters))
            XCTAssertEqual(page.rows, [[.integer(1), .deferredBytes(length: 5000), .text(name)]], name)
            XCTAssertEqual(page.keys, [[.integer(1)]], name)
            XCTAssertFalse(page.hasMore, name)

            let fetch = try XCTUnwrap(query.value(of: "blob col", key: page.keys[0], dialect: dialect))
            let value = try await driver.query(fetch.sql, parameters: fetch.parameters)
            XCTAssertEqual(value.rows, [[.bytes(Data(repeating: 7, count: 5000))]], name)

            let count = query.count(dialect: dialect)
            let counted = try await driver.query(count.sql, parameters: count.parameters)
            XCTAssertEqual(counted.rows, [[.integer(1)]], name)
        }
        let tables = try await driver.query("SELECT count(*) FROM sqlite_master WHERE type = 'table'")
        XCTAssertEqual(tables.rows, [[.integer(Int64(SQLDialectTests.hostileIdentifiers.count - 1))]])
    }
}
