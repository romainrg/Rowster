import XCTest
@testable import RowsterCore

final class EditorSupportTests: XCTestCase {
    // MARK: - Highlighting

    private func spans(_ sql: String, _ engine: Engine = .postgres) -> [(SyntaxClass, String)] {
        SQLHighlighter(dialect: engine.dialect).spans(in: sql).map { ($0.kind, String(sql[$0.range])) }
    }

    func testHighlightsKeywordsStringsNumbersAndComments() {
        let found = spans("select id, 'select' FROM \"from\" WHERE n > 1.5 -- where\n AND x = $1")
        XCTAssertEqual(found.map(\.1), ["select", "'select'", "FROM", "\"from\"", "WHERE", "1.5", "-- where", "AND", "$1"])
        XCTAssertEqual(found.map(\.0), [.keyword, .string, .keyword, .quotedIdentifier, .keyword, .number, .comment, .keyword, .parameter])
    }

    func testKeywordsDependOnTheDialect() {
        XCTAssertTrue(spans("SELECT 1 RETURNING x", .postgres).contains { $0.1 == "RETURNING" })
        XCTAssertFalse(spans("SELECT 1 RETURNING x", .mysql).contains { $0.1 == "RETURNING" })
        XCTAssertTrue(spans("PRAGMA table_info(t)", .sqlite).contains { $0.1 == "PRAGMA" })
        XCTAssertTrue(spans("SHOW TABLES", .mysql).contains { $0.1 == "SHOW" })
        XCTAssertTrue(spans("SELECT /*! x */ 1", .mysql).contains { $0.0 == .comment })
    }

    func testIdentifiersAreNotColored() {
        XCTAssertEqual(spans("customers.name").count, 0)
        XCTAssertEqual(spans("selection").count, 0)
    }

    // MARK: - History

    func testSearch() {
        let old = HistoryEntry(sql: "SELECT * FROM orders WHERE status = 'failed'", date: Date(timeIntervalSince1970: 100), duration: 0.1, succeeded: true)
        let recent = HistoryEntry(sql: "select count(*) from ORDERS", date: Date(timeIntervalSince1970: 200), duration: 0.2, succeeded: true)
        let other = HistoryEntry(sql: "UPDATE customers SET vip = 1", date: Date(timeIntervalSince1970: 300), duration: 0.3, succeeded: false)
        let all = [old, recent, other]
        XCTAssertEqual(all.search("").map(\.id), [other.id, recent.id, old.id])
        XCTAssertEqual(all.search("orders").map(\.id), [recent.id, old.id])
        XCTAssertEqual(all.search(" ORDERS  failed ").map(\.id), [old.id])
        XCTAssertTrue(all.search("nothing").isEmpty)
    }

    func testFileStoreKeepsTheMostRecentEntriesAcrossInstances() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rowster-history-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let connection = UUID()
        let store = FileHistoryStore(directory: directory)
        XCTAssertTrue(store.entries(connection: connection).isEmpty)
        for index in 0..<(FileHistoryStore.limit + 5) {
            store.add(HistoryEntry(sql: "SELECT \(index)", duration: 0.01, succeeded: true, rowCount: 1), connection: connection)
        }
        let reopened = FileHistoryStore(directory: directory)
        let entries = reopened.entries(connection: connection)
        XCTAssertEqual(entries.count, FileHistoryStore.limit)
        XCTAssertEqual(entries.first?.sql, "SELECT 5")
        XCTAssertEqual(entries.last?.sql, "SELECT \(FileHistoryStore.limit + 4)")
        XCTAssertTrue(reopened.entries(connection: UUID()).isEmpty)

        let file = directory.appendingPathComponent("\(connection.uuidString).json")
        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600)

        reopened.clear(connection: connection)
        XCTAssertTrue(FileHistoryStore(directory: directory).entries(connection: connection).isEmpty)
    }

    func testMemoryStore() {
        let store = MemoryHistoryStore()
        let connection = UUID()
        store.add(HistoryEntry(sql: "SELECT 1", duration: 0, succeeded: true), connection: connection)
        XCTAssertEqual(store.entries(connection: connection).count, 1)
        store.clear(connection: connection)
        XCTAssertTrue(store.entries(connection: connection).isEmpty)
    }

    func testRedactsPasswords() {
        let postgres = PostgresDialect(), mysql = MySQLDialect()
        XCTAssertEqual(HistoryRedactor.redact("ALTER USER app PASSWORD 's3cret'", dialect: postgres), "ALTER USER app PASSWORD '***'")
        XCTAssertEqual(
            HistoryRedactor.redact("CREATE ROLE app LOGIN ENCRYPTED PASSWORD 'it''s' VALID UNTIL 'infinity'", dialect: postgres),
            "CREATE ROLE app LOGIN ENCRYPTED PASSWORD '***' VALID UNTIL 'infinity'")
        XCTAssertEqual(
            HistoryRedactor.redact("CREATE USER 'app'@'%' IDENTIFIED BY 'p@ss'", dialect: mysql), "CREATE USER 'app'@'%' IDENTIFIED BY '***'")
        XCTAssertEqual(
            HistoryRedactor.redact("ALTER USER app IDENTIFIED WITH caching_sha2_password BY 'p@ss'", dialect: mysql),
            "ALTER USER app IDENTIFIED WITH caching_sha2_password BY '***'")
        XCTAssertEqual(HistoryRedactor.redact("SET PASSWORD = 'x'", dialect: mysql), "SET PASSWORD = '***'")
        XCTAssertEqual(HistoryRedactor.redact("SET PASSWORD = PASSWORD('x')", dialect: mysql), "SET PASSWORD = PASSWORD('***')")
    }

    func testLeavesOrdinaryStatementsAlone() {
        for sql in [
            "SELECT * FROM users WHERE password = 'x' ORDER BY 'name'", "SELECT 'PASSWORD', 'secret'",
            "SELECT * FROM t GROUP BY 'a'", "-- PASSWORD 'x'\nSELECT 1"
        ] {
            let redacted = HistoryRedactor.redact(sql, dialect: PostgresDialect())
            if sql.contains("password = 'x'") {
                // A comparison with a column named password is hidden too: better too much than too little.
                XCTAssertEqual(redacted, "SELECT * FROM users WHERE password = '***' ORDER BY 'name'")
            } else {
                XCTAssertEqual(redacted, sql)
            }
        }
    }
}
