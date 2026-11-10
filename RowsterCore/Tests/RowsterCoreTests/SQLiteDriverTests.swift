import XCTest
@testable import RowsterCore

final class SQLiteDriverTests: XCTestCase {
    private var temporaryFiles: [URL] = []

    override func tearDown() {
        for url in temporaryFiles { try? FileManager.default.removeItem(at: url) }
        temporaryFiles = []
    }

    private func memory() async throws -> SQLiteDriver {
        let driver = SQLiteDriver(configuration: .memory())
        try await driver.connect()
        return driver
    }

    private func temporaryPath() -> String {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rowster-\(UUID().uuidString).sqlite")
        temporaryFiles.append(url)
        return url.path
    }

    func testTypesRoundTripThroughParameters() async throws {
        let driver = try await memory()
        try await driver.run("CREATE TABLE t (i INTEGER, r REAL, s TEXT, b BLOB, n TEXT, flag BOOLEAN)")
        let blob = Data([0, 1, 2, 255])
        let hostile = "Robert'); DROP TABLE t; -- \"quoted\" \\ é🙂\n"
        let summary = try await driver.run(
            "INSERT INTO t VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
            parameters: [.integer(-42), .double(1.5), .text(hostile), .bytes(blob), .null, .bool(true)])
        XCTAssertEqual(summary.rowsAffected, 1)

        let result = try await driver.query("SELECT * FROM t")
        XCTAssertEqual(result.columns.map(\.name), ["i", "r", "s", "b", "n", "flag"])
        XCTAssertEqual(result.columns.map(\.kind), [.integer, .decimal, .text, .binary, .text, .boolean])
        XCTAssertEqual(result.rows, [[.integer(-42), .double(1.5), .text(hostile), .bytes(blob), .null, .integer(1)]])
        XCTAssertFalse(result.isTruncated)
    }

    func testCursorReadsInBatchesAndStopsAtTheLimit() async throws {
        let driver = try await memory()
        let numbers = "WITH RECURSIVE n(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM n WHERE x < 1000) SELECT x FROM n"
        let cursor = try await driver.execute(numbers, parameters: [])
        let first = try await cursor.next(maxRows: 300)
        XCTAssertEqual(first?.count, 300)
        let second = try await cursor.next(maxRows: 300)
        XCTAssertEqual(second?.first, [.integer(301)])
        _ = try await cursor.close()

        let limited = try await driver.query(numbers, limit: 250)
        XCTAssertEqual(limited.rows.count, 250)
        XCTAssertTrue(limited.isTruncated)
        let exact = try await driver.query(numbers, limit: 1000)
        XCTAssertEqual(exact.rows.count, 1000)
        XCTAssertFalse(exact.isTruncated)
    }

    func testExhaustedCursorReturnsNil() async throws {
        let driver = try await memory()
        let cursor = try await driver.execute("SELECT 1 UNION ALL SELECT 2", parameters: [])
        let rows = try await cursor.next(maxRows: 10)
        XCTAssertEqual(rows?.count, 2)
        let end = try await cursor.next(maxRows: 10)
        XCTAssertNil(end)
        _ = try await cursor.close()
    }

    func testOneStatementAtATime() async throws {
        let driver = try await memory()
        let cursor = try await driver.execute("SELECT 1", parameters: [])
        do {
            _ = try await driver.execute("SELECT 2", parameters: [])
            XCTFail("a second statement ran while a cursor was open")
        } catch {
            XCTAssertEqual(error as? ConnectionError, .busy)
        }
        _ = try await cursor.close()
        let after = try await driver.query("SELECT 2")
        XCTAssertEqual(after.rows, [[.integer(2)]])
    }

    func testSeveralStatementsAreRefused() async throws {
        let driver = try await memory()
        try await driver.run("CREATE TABLE t (a)")
        do {
            try await driver.run("INSERT INTO t VALUES (1); DROP TABLE t")
            XCTFail("two statements ran")
        } catch let error as DatabaseError {
            XCTAssertEqual(error.code, "SQLITE_MISUSE")
        }
        let count = try await driver.query("SELECT count(*) FROM t")
        XCTAssertEqual(count.rows, [[.integer(0)]])
        // A trailing comment is not a second statement.
        try await driver.run("INSERT INTO t VALUES (1); -- done")
    }

    func testClosingAnUnreadCursorStillRunsTheStatement() async throws {
        let driver = try await memory()
        try await driver.run("CREATE TABLE t (a)")
        let cursor = try await driver.execute("INSERT INTO t VALUES (1), (2) RETURNING a", parameters: [])
        let summary = try await cursor.close()
        XCTAssertEqual(summary.rowsAffected, 2)
        let count = try await driver.query("SELECT count(*) FROM t")
        XCTAssertEqual(count.rows, [[.integer(2)]])
    }

    func testErrorsCarryAMessageAndAPosition() async throws {
        let driver = try await memory()
        do {
            try await driver.run("SELECT * FROM missing_table")
            XCTFail("no error")
        } catch let error as DatabaseError {
            XCTAssertTrue(error.message.contains("missing_table"))
            XCTAssertEqual(error.code, "SQLITE_ERROR")
        }
        do {
            try await driver.run("SELECT 1 +* 2")
            XCTFail("no error")
        } catch let error as DatabaseError {
            XCTAssertEqual(error.position, 11)
        }
        let again = try await driver.query("SELECT 1")
        XCTAssertEqual(again.rows.count, 1)
    }

    func testParameterCountMismatch() async throws {
        let driver = try await memory()
        do {
            try await driver.run("SELECT ?1, ?2", parameters: [.integer(1)])
            XCTFail("no error")
        } catch let error as DatabaseError {
            XCTAssertEqual(error.code, "SQLITE_RANGE")
        }
    }

    func testCancelInterruptsARunningStatement() async throws {
        let driver = try await memory()
        let endless = "WITH RECURSIVE n(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM n) SELECT count(*) FROM n"
        let started = Date()
        Task {
            try? await Task.sleep(for: .milliseconds(200))
            await driver.cancel()
        }
        do {
            _ = try await driver.query(endless)
            XCTFail("the statement was not interrupted")
        } catch let error as DatabaseError {
            XCTAssertTrue(error.isCancellation)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
        let after = try await driver.query("SELECT 1")
        XCTAssertEqual(after.rows, [[.integer(1)]])
    }

    func testCancelWithNothingRunningIsHarmless() async throws {
        let driver = try await memory()
        await driver.cancel()
        let result = try await driver.query("SELECT 1")
        XCTAssertEqual(result.rows.count, 1)
    }

    func testTransactionState() async throws {
        let driver = try await memory()
        var state = await driver.transactionState
        XCTAssertEqual(state, .idle)
        try await driver.run("BEGIN")
        state = await driver.transactionState
        XCTAssertEqual(state, .inTransaction)
        try await driver.run("ROLLBACK")
        state = await driver.transactionState
        XCTAssertEqual(state, .idle)
    }

    func testReadOnlyFileRefusesWrites() async throws {
        let path = temporaryPath()
        let writer = SQLiteDriver(configuration: SQLiteConfiguration(path: path, createIfMissing: true))
        try await writer.connect()
        try await writer.run("CREATE TABLE t (a)")
        try await writer.run("INSERT INTO t VALUES (1)")
        await writer.close()

        let reader = SQLiteDriver(configuration: SQLiteConfiguration(path: path, readOnly: true))
        try await reader.connect()
        let rows = try await reader.query("SELECT a FROM t")
        XCTAssertEqual(rows.rows, [[.integer(1)]])
        for sql in ["INSERT INTO t VALUES (2)", "DELETE FROM t", "DROP TABLE t", "CREATE TABLE u (a)", "PRAGMA user_version = 5"] {
            do {
                try await reader.run(sql)
                XCTFail("\(sql) ran on a read-only connection")
            } catch let error as DatabaseError {
                XCTAssertEqual(error.code, "SQLITE_READONLY", sql)
            }
        }
        // Lifting query_only by hand does not make the file writable.
        _ = try? await reader.run("PRAGMA query_only = OFF")
        do {
            try await reader.run("INSERT INTO t VALUES (3)")
            XCTFail("write after PRAGMA query_only = OFF")
        } catch {}

        try await reader.setReadOnly(false)
        try await reader.run("INSERT INTO t VALUES (4)")
        try await reader.setReadOnly(true)
        do {
            try await reader.run("INSERT INTO t VALUES (5)")
            XCTFail("write after re-locking")
        } catch {}
        let final = try await reader.query("SELECT a FROM t ORDER BY a")
        XCTAssertEqual(final.rows, [[.integer(1)], [.integer(4)]])
        await reader.close()
    }

    func testReadOnlyInMemory() async throws {
        let driver = try await memory()
        try await driver.run("CREATE TABLE t (a)")
        try await driver.setReadOnly(true)
        do {
            try await driver.run("INSERT INTO t VALUES (1)")
            XCTFail("write on a read-only connection")
        } catch {}
        try await driver.setReadOnly(false)
        try await driver.run("INSERT INTO t VALUES (1)")
    }

    func testOpeningAMissingOrInvalidFileFails() async throws {
        let missing = SQLiteDriver(configuration: SQLiteConfiguration(path: temporaryPath()))
        do {
            try await missing.connect()
            XCTFail("opened a missing file")
        } catch let error as ConnectionError {
            guard case .unreachable = error else { return XCTFail("\(error)") }
        }
        let path = temporaryPath()
        try Data(repeating: 0x41, count: 4096).write(to: URL(fileURLWithPath: path))
        let invalid = SQLiteDriver(configuration: SQLiteConfiguration(path: path))
        do {
            try await invalid.connect()
            XCTFail("opened a file that is not a database")
        } catch let error as ConnectionError {
            guard case .unreachable = error else { return XCTFail("\(error)") }
        }
    }

    func testUseAfterCloseFails() async throws {
        let driver = try await memory()
        await driver.close()
        do {
            try await driver.run("SELECT 1")
            XCTFail("ran on a closed connection")
        } catch {
            XCTAssertEqual(error as? ConnectionError, .closed)
        }
    }

    func testEmptyStatement() async throws {
        let driver = try await memory()
        let result = try await driver.query("  -- nothing here\n")
        XCTAssertTrue(result.columns.isEmpty)
        XCTAssertTrue(result.rows.isEmpty)
    }
}
