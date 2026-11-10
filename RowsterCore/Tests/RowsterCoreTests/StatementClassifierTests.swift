import XCTest
@testable import RowsterCore

final class StatementClassifierTests: XCTestCase {
    private func info(_ sql: String, _ engine: Engine = .postgres) -> StatementInfo {
        engine.dialect.classifier.classify(sql)
    }

    // MARK: - Kinds

    func testReads() {
        for sql in [
            "SELECT 1", "select * from t where a = 'DELETE FROM x'", "  -- c\n SELECT 1", "(SELECT 1) UNION (SELECT 2)",
            "WITH a AS (SELECT 1) SELECT * FROM a", "VALUES (1)", "TABLE t", "SHOW search_path", "EXPLAIN SELECT 1",
            "EXPLAIN DELETE FROM t", "EXPLAIN (FORMAT JSON) UPDATE t SET a = 1"
        ] {
            XCTAssertEqual(info(sql).kind, .read, sql)
            XCTAssertTrue(info(sql).isAllowedWhenReadOnly, sql)
        }
    }

    func testWrites() {
        for sql in [
            "INSERT INTO t VALUES (1)", "UPDATE t SET a = 1 WHERE id = 2", "DELETE FROM t WHERE id = 1",
            "CREATE TABLE t (a int)", "ALTER TABLE t ADD COLUMN b int", "DROP TABLE t", "TRUNCATE t", "GRANT ALL ON t TO u",
            "COPY t FROM STDIN", "VACUUM", "CALL p()", "DO $$ BEGIN DELETE FROM t; END $$", "MERGE INTO t USING s ON true WHEN MATCHED THEN DELETE",
            "WITH gone AS (DELETE FROM t RETURNING *) SELECT * FROM gone", "WITH a AS (SELECT 1) INSERT INTO t SELECT * FROM a",
            "SELECT * INTO copy FROM t", "SELECT * FROM t FOR UPDATE", "EXPLAIN ANALYZE DELETE FROM t WHERE id = 1",
            "EXPLAIN (ANALYZE, BUFFERS) UPDATE t SET a = 1 WHERE id = 1"
        ] {
            XCTAssertEqual(info(sql).kind, .write, sql)
            XCTAssertFalse(info(sql).isAllowedWhenReadOnly, sql)
        }
    }

    func testExplainAnalyzeOfAReadIsARead() {
        XCTAssertEqual(info("EXPLAIN ANALYZE SELECT * FROM t").kind, .read)
    }

    func testUnknownStatementsAreRefusedWhenReadOnly() {
        for sql in ["FROBNICATE t", "PRAGMA journal_mode = WAL", "PRAGMA optimize", "PREPARE p AS SELECT 1", "?"] {
            XCTAssertEqual(info(sql, .sqlite).kind, .unknown, sql)
            XCTAssertFalse(info(sql, .sqlite).isAllowedWhenReadOnly, sql)
        }
    }

    func testReadOnlyPragmas() {
        XCTAssertEqual(info("PRAGMA table_info(\"t\")", .sqlite).kind, .read)
        XCTAssertEqual(info("PRAGMA main.index_list('t')", .sqlite).kind, .read)
        XCTAssertFalse(info("PRAGMA query_only = OFF", .sqlite).isAllowedWhenReadOnly)
    }

    func testEmpty() {
        XCTAssertEqual(info("").kind, .empty)
        XCTAssertEqual(info("  -- nothing\n /* at all */ ").kind, .empty)
    }

    func testTransactionsAndSessionSettingsAreAllowedWhenReadOnly() {
        for sql in ["BEGIN", "START TRANSACTION READ ONLY", "COMMIT", "ROLLBACK", "SAVEPOINT a", "SET search_path = public", "USE other", "SET NAMES utf8mb4"] {
            XCTAssertTrue(info(sql).isAllowedWhenReadOnly, sql)
        }
    }

    // MARK: - Lifting read-only

    func testStatementsThatLiftReadOnlyAreRefused() {
        for sql in [
            "SET SESSION CHARACTERISTICS AS TRANSACTION READ WRITE", "SET TRANSACTION READ WRITE", "BEGIN READ WRITE",
            "START TRANSACTION READ WRITE", "SET default_transaction_read_only = off", "set transaction_read_only to off",
            "SET SESSION TRANSACTION READ WRITE", "SET @@session.transaction_read_only = 0", "SET tx_read_only = 0",
            "RESET ALL", "RESET default_transaction_read_only", "DISCARD ALL",
            "SELECT set_config('transaction_read_only', 'off', false)", "PRAGMA query_only = 0"
        ] {
            XCTAssertTrue(info(sql).liftsReadOnly, sql)
            XCTAssertFalse(info(sql).isAllowedWhenReadOnly, sql)
        }
    }

    func testMySQLExecutableCommentIsNeverTrusted() {
        let hidden = info("SELECT 1 /*!50000 ; DROP TABLE t */", .mysql)
        XCTAssertEqual(hidden.kind, .unknown)
        XCTAssertFalse(hidden.isAllowedWhenReadOnly)
        // The same text is an ordinary comment for PostgreSQL.
        XCTAssertEqual(info("SELECT 1 /*!50000 ; DROP TABLE t */", .postgres).kind, .read)
    }

    // MARK: - Hazards

    func testDestructiveStatements() {
        XCTAssertEqual(info("DROP TABLE t").hazard, .drop)
        XCTAssertEqual(info("drop database prod").hazard, .drop)
        XCTAssertEqual(info("ALTER TABLE t DROP COLUMN a").hazard, .drop)
        XCTAssertEqual(info("TRUNCATE TABLE t").hazard, .truncate)
        XCTAssertEqual(info("DELETE FROM t").hazard, .deleteWithoutWhere)
        XCTAssertEqual(info("UPDATE t SET a = 1").hazard, .updateWithoutWhere)
        XCTAssertEqual(info("/* c */ DELETE FROM t -- WHERE id = 1").hazard, .deleteWithoutWhere)
        XCTAssertEqual(info("DELETE FROM t RETURNING 'WHERE'").hazard, .deleteWithoutWhere)
        XCTAssertEqual(info("WITH x AS (SELECT 1 WHERE true) DELETE FROM t").hazard, .deleteWithoutWhere)
        XCTAssertEqual(info("UPDATE t SET a = (SELECT b FROM u WHERE u.id = 1)").hazard, .updateWithoutWhere)
        XCTAssertEqual(info("EXPLAIN ANALYZE DELETE FROM t").hazard, .deleteWithoutWhere)
        XCTAssertEqual(info("DELETE FROM `t`", .mysql).hazard, .deleteWithoutWhere)
    }

    func testStatementsThatNeedNoConfirmation() {
        for sql in [
            "DELETE FROM t WHERE id = 1", "UPDATE t SET a = 1 WHERE id = 2", "ALTER TABLE t ADD COLUMN drop_me int",
            "WITH x AS (SELECT 1) DELETE FROM t WHERE id IN (SELECT * FROM x)", "SELECT 'DROP TABLE t'",
            "INSERT INTO t VALUES ('DELETE FROM t')", "EXPLAIN DELETE FROM t", "CREATE TABLE t (a int)"
        ] {
            XCTAssertNil(info(sql).hazard, sql)
        }
    }

    func testVerb() {
        XCTAssertEqual(info("  select 1").verb, "SELECT")
        XCTAssertEqual(info("explain analyze select 1").verb, "EXPLAIN")
        XCTAssertEqual(info("WITH a AS (SELECT 1) SELECT 1").verb, "WITH")
    }
}
