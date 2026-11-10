import XCTest
@testable import RowsterCore

final class ChangeSetTests: XCTestCase {
    private let people = TableDescription(
        ref: TableRef(schema: "hr", name: "people"),
        columns: [
            ColumnDescription(name: "id", typeName: "int", kind: .integer, isNullable: false, primaryKeyPosition: 1),
            ColumnDescription(name: "name", typeName: "text", kind: .text),
            ColumnDescription(name: "age", typeName: "int", kind: .integer),
            ColumnDescription(name: "initials", typeName: "text", kind: .text, isGenerated: true),
            ColumnDescription(name: "photo", typeName: "bytea", kind: .binary)
        ])

    private func statements(_ changes: [ChangeSet.Change], _ dialect: any SQLDialect = PostgresDialect(), table: TableDescription? = nil) throws -> [SQLFragment] {
        try ChangeSet(table: table ?? people, changes: changes).statements(dialect: dialect)
    }

    func testUpdate() throws {
        let change = ChangeSet.Change.update(key: [.integer(7)], values: ["age": .integer(41), "name": .text("O'Brien")])
        XCTAssertEqual(
            try statements([change]),
            [SQLFragment(sql: #"UPDATE "hr"."people" SET "name" = $1, "age" = $2 WHERE "id" = $3"#, parameters: [.text("O'Brien"), .integer(41), .integer(7)])])
        XCTAssertEqual(try statements([change], MySQLDialect()).first?.sql, "UPDATE `hr`.`people` SET `name` = ?, `age` = ? WHERE `id` = ?")
        XCTAssertEqual(try statements([change], SQLiteDialect()).first?.sql, #"UPDATE "hr"."people" SET "name" = ?1, "age" = ?2 WHERE "id" = ?3"#)
    }

    func testUpdatingTheKeyStillAddressesTheOriginalRow() throws {
        let fragment = try XCTUnwrap(statements([.update(key: [.integer(7)], values: ["id": .integer(8)])]).first)
        XCTAssertEqual(fragment.sql, #"UPDATE "hr"."people" SET "id" = $1 WHERE "id" = $2"#)
        XCTAssertEqual(fragment.parameters, [.integer(8), .integer(7)])
    }

    func testDelete() throws {
        XCTAssertEqual(
            try statements([.delete(key: [.integer(7)])]),
            [SQLFragment(sql: #"DELETE FROM "hr"."people" WHERE "id" = $1"#, parameters: [.integer(7)])])
    }

    func testInsert() throws {
        XCTAssertEqual(
            try statements([.insert(values: ["name": .text("Ada"), "id": .integer(1), "age": .null])]),
            [SQLFragment(sql: #"INSERT INTO "hr"."people" ("id", "name", "age") VALUES ($1, $2, $3)"#, parameters: [.integer(1), .text("Ada"), .null])])
        XCTAssertEqual(try statements([.insert(values: [:])]).first?.sql, #"INSERT INTO "hr"."people" DEFAULT VALUES"#)
        XCTAssertEqual(try statements([.insert(values: [:])], MySQLDialect()).first?.sql, "INSERT INTO `hr`.`people` () VALUES ()")
    }

    func testOrderIsDeletesThenUpdatesThenInserts() throws {
        let fragments = try statements([
            .insert(values: ["id": .integer(9)]), .update(key: [.integer(1)], values: ["age": .integer(2)]),
            .delete(key: [.integer(3)]), .update(key: [.integer(4)], values: ["age": .integer(5)]), .delete(key: [.integer(6)])
        ])
        XCTAssertEqual(fragments.map { String($0.sql.prefix(6)) }, ["DELETE", "DELETE", "UPDATE", "UPDATE", "INSERT"])
    }

    func testValuesNeverReachTheSQLText() throws {
        let hostile = "x'); DROP TABLE people; --"
        let fragments = try statements([
            .update(key: [.text("1 OR 1=1")], values: ["name": .text(hostile)]), .insert(values: ["name": .text(hostile)]),
            .delete(key: [.text("1; DROP TABLE people")])
        ])
        for fragment in fragments {
            XCTAssertFalse(fragment.sql.contains("DROP"), fragment.sql)
            XCTAssertFalse(fragment.sql.contains("1=1"), fragment.sql)
        }
    }

    func testCompositeKeyAndRowID() throws {
        let items = TableDescription(
            ref: TableRef(name: "items"),
            columns: [
                ColumnDescription(name: "qty", typeName: "int", kind: .integer),
                ColumnDescription(name: "order", typeName: "int", kind: .integer, isNullable: false, primaryKeyPosition: 1),
                ColumnDescription(name: "sku", typeName: "text", kind: .text, isNullable: false, primaryKeyPosition: 2)
            ])
        let update = try XCTUnwrap(statements([.update(key: [.integer(4), .text("A")], values: ["qty": .integer(2)])], table: items).first)
        XCTAssertEqual(update.sql, #"UPDATE "items" SET "qty" = $1 WHERE "order" = $2 AND "sku" = $3"#)
        XCTAssertEqual(update.parameters, [.integer(2), .integer(4), .text("A")])

        let log = TableDescription(ref: TableRef(name: "log"), columns: [ColumnDescription(name: "line", typeName: "text", kind: .text)], hasRowID: true)
        XCTAssertEqual(
            try statements([.delete(key: [.integer(12)])], SQLiteDialect(), table: log).first?.sql, #"DELETE FROM "log" WHERE rowid = ?1"#)
    }

    func testErrors() {
        let view = TableDescription(ref: TableRef(name: "v"), kind: .view, columns: [ColumnDescription(name: "a", typeName: "", kind: .other)])
        XCTAssertThrowsError(try statements([.delete(key: [.integer(1)])], table: view)) { XCTAssertEqual($0 as? ChangeSetError, .noRowIdentity) }
        XCTAssertThrowsError(try statements([.update(key: [.integer(1)], values: ["a": .integer(2)])], table: view)) {
            XCTAssertEqual($0 as? ChangeSetError, .noRowIdentity)
        }
        XCTAssertThrowsError(try statements([.update(key: [.integer(1)], values: ["nope": .integer(2)])])) {
            XCTAssertEqual($0 as? ChangeSetError, .unknownColumn("nope"))
        }
        XCTAssertThrowsError(try statements([.insert(values: ["initials": .text("AB")])])) {
            XCTAssertEqual($0 as? ChangeSetError, .generatedColumn("initials"))
        }
        XCTAssertThrowsError(try statements([.update(key: [.integer(1)], values: ["photo": .deferredBytes(length: 9)])])) {
            XCTAssertEqual($0 as? ChangeSetError, .valueNotLoaded("photo"))
        }
        XCTAssertThrowsError(try statements([.update(key: [.integer(1)], values: [:])])) { XCTAssertEqual($0 as? ChangeSetError, .emptyUpdate) }
        XCTAssertThrowsError(try statements([.delete(key: [])])) { XCTAssertEqual($0 as? ChangeSetError, .keyMismatch) }
        XCTAssertThrowsError(try statements([.delete(key: [.null])])) { XCTAssertEqual($0 as? ChangeSetError, .keyMismatch) }
        XCTAssertThrowsError(try statements([.delete(key: [.integer(1), .integer(2)])])) { XCTAssertEqual($0 as? ChangeSetError, .keyMismatch) }
    }

    func testTypedValues() {
        XCTAssertEqual(SQLValue.typed("42", as: .integer), .integer(42))
        XCTAssertEqual(SQLValue.typed("4.5", as: .integer), .text("4.5"))
        XCTAssertEqual(SQLValue.typed("4.5", as: .decimal), .double(4.5))
        XCTAssertEqual(SQLValue.typed("yes", as: .boolean), .bool(true))
        XCTAssertEqual(SQLValue.typed("maybe", as: .boolean), .text("maybe"))
        XCTAssertEqual(SQLValue.typed("42", as: .text), .text("42"))
    }

    // MARK: - Commit on a real database

    private func shop() async throws -> (Session, TableDescription) {
        let session = Session(profile: ConnectionProfile(name: "t", engine: .sqlite), password: nil, provider: MemoryProvider())
        try await session.open()
        try await session.run("CREATE TABLE p (id INTEGER PRIMARY KEY, name TEXT NOT NULL UNIQUE, qty INTEGER NOT NULL DEFAULT 1)")
        try await session.run("INSERT INTO p VALUES (1, 'pen', 10), (2, 'ink', 20), (3, 'pad', 30)")
        return (session, try await session.describe(TableRef(name: "p")))
    }

    private func rows(_ session: Session) async throws -> [Row] {
        try await session.query("SELECT id, name, qty FROM p ORDER BY id").rows
    }

    func testCommitAppliesEverythingInOneTransaction() async throws {
        let (session, table) = try await shop()
        let changes = ChangeSet(table: table, changes: [
            .update(key: [.integer(1)], values: ["qty": .integer(11), "name": .text("O'pen")]),
            .delete(key: [.integer(2)]), .insert(values: ["name": .text("x'); DROP TABLE p; --")])
        ])
        try await session.commit(changes.statements(dialect: SQLiteDialect()))
        let after = try await rows(session)
        XCTAssertEqual(after, [
            [.integer(1), .text("O'pen"), .integer(11)], [.integer(3), .text("pad"), .integer(30)],
            [.integer(4), .text("x'); DROP TABLE p; --"), .integer(1)]
        ])
        let state = await session.transactionState
        XCTAssertEqual(state, .idle)
        await session.close()
    }

    func testAnErrorRollsEverythingBack() async throws {
        let (session, table) = try await shop()
        let before = try await rows(session)
        let changes = ChangeSet(table: table, changes: [
            .delete(key: [.integer(1)]), .update(key: [.integer(2)], values: ["qty": .integer(99)]),
            .insert(values: ["name": .text("pad")])
        ])
        do {
            try await session.commit(changes.statements(dialect: SQLiteDialect()))
            XCTFail("the unique violation was not reported")
        } catch let error as DatabaseError {
            XCTAssertEqual(error.code, "SQLITE_CONSTRAINT")
        }
        let after = try await rows(session)
        XCTAssertEqual(after, before)
        let state = await session.transactionState
        XCTAssertEqual(state, .idle)
        await session.close()
    }

    func testARowThatIsGoneRollsEverythingBack() async throws {
        let (session, table) = try await shop()
        let before = try await rows(session)
        let changes = ChangeSet(table: table, changes: [
            .update(key: [.integer(1)], values: ["qty": .integer(5)]), .update(key: [.integer(404)], values: ["qty": .integer(5)])
        ])
        do {
            try await session.commit(changes.statements(dialect: SQLiteDialect()))
            XCTFail("an update that matched no row was accepted")
        } catch {
            XCTAssertEqual(error as? SessionError, .unexpectedRowCount(statement: 1, affected: 0))
        }
        let after = try await rows(session)
        XCTAssertEqual(after, before)
        await session.close()
    }

    func testCommitIsRefusedOnAReadOnlySessionAndInsideATransaction() async throws {
        let (session, table) = try await shop()
        let statements = try ChangeSet(table: table, changes: [.delete(key: [.integer(1)])]).statements(dialect: SQLiteDialect())

        try await session.run("BEGIN")
        do {
            try await session.commit(statements)
            XCTFail("committed inside the user's transaction")
        } catch {
            XCTAssertEqual(error as? SessionError, .transactionInProgress)
        }
        try await session.run("ROLLBACK")

        try await session.setReadOnly(true)
        do {
            try await session.commit(statements)
            XCTFail("committed on a read-only session")
        } catch {
            XCTAssertEqual(error as? SessionError, .readOnly(verb: "DELETE"))
        }
        let count = try await session.query("SELECT count(*) FROM p")
        XCTAssertEqual(count.rows, [[.integer(3)]])
        await session.close()
    }
}
