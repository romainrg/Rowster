import XCTest
@testable import RowsterCore

final class SQLDialectTests: XCTestCase {
    /// Identifiers that try to break out of their quotes.
    static let hostileIdentifiers = [
        "plain", "with space", "select", "a\"b", "a`b", "a]b", "a[b", "x\"; DROP TABLE t; --", "x`; DROP TABLE t; --",
        "é🙂", "a'b", "a\\b", "", "semi;colon", "new\nline"
    ]

    func testQuotedIdentifierIsAlwaysOneToken() {
        for engine in Engine.allCases {
            let dialect = engine.dialect
            for identifier in Self.hostileIdentifiers {
                let quoted = dialect.quote(identifier: identifier)
                let tokens = dialect.tokenizer.tokenize(quoted)
                XCTAssertEqual(tokens.count, 1, "\(engine) \(identifier)")
                XCTAssertEqual(tokens.first?.kind, .quotedIdentifier, "\(engine) \(identifier)")
                XCTAssertEqual(tokens.first?.isTerminated, true, "\(engine) \(identifier)")
            }
        }
    }

    func testQuoting() {
        XCTAssertEqual(PostgresDialect().quote(identifier: "a\"b"), "\"a\"\"b\"")
        XCTAssertEqual(MySQLDialect().quote(identifier: "a`b"), "`a``b`")
        XCTAssertEqual(SQLiteDialect().quote(identifier: "a\"b"), "\"a\"\"b\"")
        XCTAssertEqual(PostgresDialect().quote(identifier: "a\0b"), "\"ab\"")
    }

    func testQualifiedNames() {
        XCTAssertEqual(PostgresDialect().qualified(schema: "my schema", name: "t"), "\"my schema\".\"t\"")
        XCTAssertEqual(MySQLDialect().qualified(schema: "db", name: "t`x"), "`db`.`t``x`")
        XCTAssertEqual(SQLiteDialect().qualified(schema: nil, name: "t"), "\"t\"")
        XCTAssertEqual(SQLiteDialect().qualified(schema: "", name: "t"), "\"t\"")
    }

    func testPlaceholders() {
        XCTAssertEqual(PostgresDialect().placeholder(3), "$3")
        XCTAssertEqual(MySQLDialect().placeholder(3), "?")
        XCTAssertEqual(SQLiteDialect().placeholder(3), "?3")
    }

    func testPagination() {
        XCTAssertEqual(PostgresDialect().paginated("SELECT 1", limit: 300, offset: 600), "SELECT 1 LIMIT 300 OFFSET 600")
        XCTAssertEqual(MySQLDialect().paginated("SELECT 1", limit: -5, offset: -1), "SELECT 1 LIMIT 0 OFFSET 0")
    }

    func testReadOnlyStatementsAreRecognisedByTheClassifier() {
        for engine in Engine.allCases {
            let dialect = engine.dialect
            XCTAssertFalse(dialect.readOnlyStatements.isEmpty, "\(engine)")
            for statement in dialect.readWriteStatements {
                XCTAssertTrue(dialect.classifier.classify(statement).liftsReadOnly, "\(engine): \(statement)")
            }
        }
    }

    func testMariaDBSharesTheMySQLDialect() {
        XCTAssertEqual(Engine.mariadb.dialect.engine, .mariadb)
        XCTAssertEqual(Engine.mariadb.dialect.syntax, Engine.mysql.dialect.syntax)
    }
}
