import XCTest
@testable import RowsterCore

final class FilterBuilderTests: XCTestCase {
    private let columns = [
        ColumnDescription(name: "id", typeName: "int", kind: .integer),
        ColumnDescription(name: "name", typeName: "text", kind: .text),
        ColumnDescription(name: "price", typeName: "numeric", kind: .decimal),
        ColumnDescription(name: "active", typeName: "bool", kind: .boolean),
        ColumnDescription(name: "photo", typeName: "bytea", kind: .binary),
        ColumnDescription(name: "we\"ird`", typeName: "date", kind: .date)
    ]

    private func build(
        _ conditions: [FilterCondition], _ dialect: any SQLDialect = PostgresDialect(), match: FilterMatch = .all
    ) throws -> SQLFragment? {
        try FilterBuilder(columns: columns, dialect: dialect).build(conditions, match: match)
    }

    private func one(_ column: String, _ op: FilterOperator, _ value: String = "", _ second: String = "") -> FilterCondition {
        FilterCondition(target: .column(column), op: op, value: value, secondValue: second)
    }

    func testComparisonOperators() throws {
        let cases: [(FilterOperator, String)] = [
            (.equals, "="), (.notEquals, "<>"), (.lessThan, "<"), (.lessOrEqual, "<="), (.greaterThan, ">"), (.greaterOrEqual, ">=")
        ]
        for (op, symbol) in cases {
            let fragment = try XCTUnwrap(build([one("id", op, "42")]))
            XCTAssertEqual(fragment.sql, "(\"id\" \(symbol) $1)")
            XCTAssertEqual(fragment.parameters, [.integer(42)])
        }
    }

    func testPlaceholdersPerDialect() throws {
        let conditions = [one("id", .equals, "1"), one("name", .equals, "Ada")]
        XCTAssertEqual(try build(conditions, PostgresDialect())?.sql, #"("id" = $1) AND ("name" = $2)"#)
        XCTAssertEqual(try build(conditions, MySQLDialect())?.sql, "(`id` = ?) AND (`name` = ?)")
        XCTAssertEqual(try build(conditions, SQLiteDialect())?.sql, #"("id" = ?1) AND ("name" = ?2)"#)
        XCTAssertEqual(try build(conditions, match: .any)?.sql, #"("id" = $1) OR ("name" = $2)"#)
    }

    func testValuesAreAlwaysParameters() throws {
        let hostile = "x' OR 1=1; DROP TABLE t; --"
        let fragment = try XCTUnwrap(build([one("name", .equals, hostile), one("id", .equals, "1 OR 1=1")]))
        XCTAssertEqual(fragment.sql, #"("name" = $1) AND ("id" = $2)"#)
        XCTAssertEqual(fragment.parameters, [.text(hostile), .text("1 OR 1=1")])
    }

    func testTypedBinding() throws {
        XCTAssertEqual(try build([one("price", .greaterThan, "12.5")])?.parameters, [.double(12.5)])
        XCTAssertEqual(try build([one("price", .greaterThan, "abc")])?.parameters, [.text("abc")])
        XCTAssertEqual(try build([one("active", .equals, "TRUE")])?.parameters, [.bool(true)])
        XCTAssertEqual(try build([one("active", .equals, "0")])?.parameters, [.bool(false)])
        XCTAssertEqual(try build([one("name", .equals, "42")])?.parameters, [.text("42")])
    }

    func testNullInAndBetween() throws {
        XCTAssertEqual(try build([one("name", .isNull)])?.sql, #"("name" IS NULL)"#)
        XCTAssertEqual(try build([one("name", .isNotNull, "ignored")])?.parameters, [])
        let list = try XCTUnwrap(build([one("id", .isIn, " 1, 2 ,,x ")]))
        XCTAssertEqual(list.sql, #"("id" IN ($1, $2, $3))"#)
        XCTAssertEqual(list.parameters, [.integer(1), .integer(2), .text("x")])
        let range = try XCTUnwrap(build([one("price", .between, "1", "9.5")]))
        XCTAssertEqual(range.sql, #"("price" BETWEEN $1 AND $2)"#)
        XCTAssertEqual(range.parameters, [.double(1), .double(9.5)])
    }

    func testPatternsEscapeWildcards() throws {
        let contains = try XCTUnwrap(build([one("name", .contains, "50%_off!")]))
        XCTAssertEqual(contains.sql, #"("name" ILIKE $1 ESCAPE '!')"#)
        XCTAssertEqual(contains.parameters, [.text("%50!%!_off!!%")])
        XCTAssertEqual(try build([one("name", .startsWith, "A")])?.parameters, [.text("A%")])
        XCTAssertEqual(try build([one("name", .endsWith, "a")])?.parameters, [.text("%a")])
        // Non-text columns are cast, each dialect its own way.
        XCTAssertEqual(try build([one("id", .contains, "4")], PostgresDialect())?.sql, #"("id"::text ILIKE $1 ESCAPE '!')"#)
        XCTAssertEqual(try build([one("id", .contains, "4")], MySQLDialect())?.sql, "(CAST(`id` AS CHAR) LIKE ? ESCAPE '!')")
        XCTAssertEqual(try build([one("id", .contains, "4")], SQLiteDialect())?.sql, #"(CAST("id" AS TEXT) LIKE ?1 ESCAPE '!')"#)
    }

    func testAnyColumnSkipsBinaryColumns() throws {
        let fragment = try XCTUnwrap(build([FilterCondition(target: .anyColumn, op: .contains, value: "ada")], MySQLDialect()))
        XCTAssertEqual(fragment.parameters, Array(repeating: .text("%ada%"), count: 5))
        XCTAssertFalse(fragment.sql.contains("photo"))
        XCTAssertTrue(fragment.sql.contains("`we\"ird```"))
        XCTAssertEqual(fragment.sql.components(separatedBy: " OR ").count, 5)
    }

    func testDisabledAndEmpty() throws {
        var disabled = one("id", .equals, "1")
        disabled.isEnabled = false
        XCTAssertNil(try build([disabled]))
        XCTAssertNil(try build([]))
        XCTAssertEqual(try build([disabled, one("name", .isNull)])?.sql, #"("name" IS NULL)"#)
    }

    func testErrors() {
        XCTAssertThrowsError(try build([one("nope", .equals, "1")])) { XCTAssertEqual($0 as? FilterError, .unknownColumn("nope")) }
        XCTAssertThrowsError(try build([one("name", .contains, "")])) { XCTAssertEqual($0 as? FilterError, .missingValue) }
        XCTAssertThrowsError(try build([one("id", .isIn, " , ")])) { XCTAssertEqual($0 as? FilterError, .missingValue) }
        XCTAssertThrowsError(try build([one("id", .between, "1", "")])) { XCTAssertEqual($0 as? FilterError, .missingValue) }
    }

    func testRawSQLStaysInsideItsParentheses() throws {
        func raw(_ sql: String, _ dialect: any SQLDialect = PostgresDialect()) throws -> SQLFragment? {
            try build([FilterCondition(target: .rawSQL, value: sql)], dialect)
        }
        XCTAssertEqual(try raw("  total > 100 AND (status = 'paid' OR vip) ")?.sql, "(total > 100 AND (status = 'paid' OR vip)\n)")
        XCTAssertEqual(try raw("a = 1 -- note")?.sql, "(a = 1 -- note\n)")
        XCTAssertEqual(try raw("note = 'a;b)'")?.parameters, [])
        for unsafe in ["1=1); DROP TABLE t; --", "a = 1;", "a = (1", "a = 1)", "a = 'unterminated", "a = 1 /* open", ""] {
            XCTAssertThrowsError(try raw(unsafe), unsafe)
        }
        XCTAssertThrowsError(try raw("1 /*! OR 1 */", MySQLDialect()))
    }

    func testInlinedForDisplay() {
        let fragment = SQLFragment(sql: #"("name" = $1) AND ("id" = $2) AND note = '$1 ?'"#, parameters: [.text("O'Brien"), .integer(7)])
        XCTAssertEqual(fragment.inlinedForDisplay(dialect: PostgresDialect()), #"("name" = 'O''Brien') AND ("id" = 7) AND note = '$1 ?'"#)
        let mysql = SQLFragment(sql: "(`a` = ?) AND (`b` = ?) AND c = '?'", parameters: [.text("x"), .null])
        XCTAssertEqual(mysql.inlinedForDisplay(dialect: MySQLDialect()), "(`a` = 'x') AND (`b` = NULL) AND c = '?'")
        let sqlite = SQLFragment(sql: #""a" = ?2 AND "b" = ?1"#, parameters: [.integer(1), .text("two")])
        XCTAssertEqual(sqlite.inlinedForDisplay(dialect: SQLiteDialect()), #""a" = 'two' AND "b" = 1"#)
    }

    /// The filters behave as intended on a real database.
    func testRunsOnSQLite() async throws {
        let driver = SQLiteDriver(configuration: .memory())
        try await driver.connect()
        try await driver.run("CREATE TABLE p (id INTEGER PRIMARY KEY, name TEXT, price REAL, active BOOLEAN, photo BLOB, \"we\"\"ird`\" DATE)")
        let names = ["Ada", "100% cotton", "under_score", "plain", "a!b", "O'Brien"]
        for (index, name) in names.enumerated() {
            try await driver.run(
                "INSERT INTO p (id, name, price, active) VALUES (?1, ?2, ?3, ?4)",
                parameters: [.integer(Int64(index + 1)), .text(name), .double(Double(index) * 10), .integer(Int64(index % 2))])
        }
        let builder = FilterBuilder(columns: columns, dialect: SQLiteDialect())
        func ids(_ conditions: [FilterCondition], match: FilterMatch = .all) async throws -> [Int64] {
            let fragment = try XCTUnwrap(builder.build(conditions, match: match))
            let result = try await driver.query("SELECT id FROM p WHERE \(fragment.sql) ORDER BY id", parameters: fragment.parameters)
            return result.rows.compactMap { if case .integer(let id) = $0[0] { return id } else { return nil } }
        }

        var found = try await ids([one("name", .contains, "%")])
        XCTAssertEqual(found, [2])
        found = try await ids([one("name", .contains, "_")])
        XCTAssertEqual(found, [3])
        found = try await ids([one("name", .contains, "!")])
        XCTAssertEqual(found, [5])
        found = try await ids([one("name", .startsWith, "a")])
        XCTAssertEqual(found, [1, 5])
        found = try await ids([one("name", .equals, "O'Brien")])
        XCTAssertEqual(found, [6])
        found = try await ids([one("price", .between, "10", "30"), one("active", .equals, "true")])
        XCTAssertEqual(found, [2, 4])
        found = try await ids([one("id", .isIn, "1, 6"), one("price", .greaterOrEqual, "40")], match: .any)
        XCTAssertEqual(found, [1, 5, 6])
        found = try await ids([FilterCondition(target: .anyColumn, op: .contains, value: "cotton")])
        XCTAssertEqual(found, [2])
        found = try await ids([FilterCondition(target: .rawSQL, value: "price > 20 AND name <> 'plain' -- cheap ones out")])
        XCTAssertEqual(found, [5, 6])
        found = try await ids([one("name", .equals, "x' OR 1=1 --")])
        XCTAssertEqual(found, [])
    }
}
