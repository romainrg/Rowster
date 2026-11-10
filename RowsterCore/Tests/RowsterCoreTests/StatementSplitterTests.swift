import XCTest
@testable import RowsterCore

final class StatementSplitterTests: XCTestCase {
    private func split(_ sql: String, _ engine: Engine = .postgres) -> [String] {
        engine.dialect.splitter.split(sql).map(\.text)
    }

    func testSimpleStatements() {
        XCTAssertEqual(split("SELECT 1; SELECT 2;\nSELECT 3"), ["SELECT 1", "SELECT 2", "SELECT 3"])
    }

    func testEmptyStatementsAreDropped() {
        XCTAssertEqual(split(";;  SELECT 1 ;; -- only a comment\n ; /* x */"), ["SELECT 1"])
        XCTAssertEqual(split("   \n"), [])
    }

    func testSemicolonsInsideStringsCommentsAndIdentifiers() {
        XCTAssertEqual(
            split("SELECT 'a;b', \"c;d\" -- e;f\n, /* g;h */ 1; SELECT 2"),
            ["SELECT 'a;b', \"c;d\" -- e;f\n, /* g;h */ 1", "SELECT 2"])
    }

    func testLeadingAndTrailingCommentsAreNotPartOfTheStatement() {
        XCTAssertEqual(split("-- header\nSELECT 1 -- trailing\n;\n-- footer"), ["SELECT 1"])
    }

    func testDollarQuotedBodies() {
        let function = "CREATE FUNCTION f() RETURNS int AS $$ BEGIN RETURN 1; END; $$ LANGUAGE plpgsql"
        XCTAssertEqual(split("\(function); SELECT f();"), [function, "SELECT f()"])
        let tagged = "DO $do$ BEGIN PERFORM 1; PERFORM $$;$$; END $do$"
        XCTAssertEqual(split("\(tagged);SELECT 1"), [tagged, "SELECT 1"])
    }

    func testMySQLBackslashEscape() {
        XCTAssertEqual(split(#"SELECT 'a\';b'; SELECT 2"#, .mysql), [#"SELECT 'a\';b'"#, "SELECT 2"])
    }

    func testDelimiterCommand() {
        let sql = """
        DELIMITER //
        CREATE PROCEDURE p() BEGIN SELECT 1; SELECT 2; END //
        DELIMITER ;
        CALL p();
        """
        XCTAssertEqual(split(sql, .mysql), ["CREATE PROCEDURE p() BEGIN SELECT 1; SELECT 2; END", "CALL p()"])
    }

    func testDelimiterWithDollars() {
        let sql = "delimiter $$\nSELECT 1; SELECT 2 $$\nSELECT 3 $$"
        XCTAssertEqual(split(sql, .mysql), ["SELECT 1; SELECT 2", "SELECT 3"])
    }

    func testDelimiterIsNotACommandOutsideMySQL() {
        XCTAssertEqual(split("DELIMITER //\nSELECT 1;", .postgres), ["DELIMITER //\nSELECT 1"])
    }

    func testTriggerBodyWithoutDelimiter() {
        let trigger = """
        CREATE TRIGGER audit AFTER UPDATE ON t BEGIN
          INSERT INTO log VALUES (CASE WHEN new.a > 1 THEN 'big' ELSE 'small' END);
          UPDATE t SET b = 1 WHERE id = new.id;
        END
        """
        XCTAssertEqual(split("\(trigger);\nSELECT 1;", .sqlite), [trigger, "SELECT 1"])
    }

    func testProcedureBodyWithControlFlow() {
        let procedure = """
        CREATE PROCEDURE p() BEGIN
          IF 1 = 1 THEN SELECT 1; END IF;
          WHILE 0 DO SELECT 2; END WHILE;
          CASE 1 WHEN 1 THEN SELECT 3; END CASE;
        END
        """
        XCTAssertEqual(split("\(procedure); SELECT 4", .mysql), [procedure, "SELECT 4"])
    }

    func testTransactionBlockIsSplit() {
        XCTAssertEqual(split("BEGIN; UPDATE t SET a = 1 WHERE id = 2; END;"), ["BEGIN", "UPDATE t SET a = 1 WHERE id = 2", "END"])
    }

    func testCaseExpressionInAPlainStatement() {
        XCTAssertEqual(split("SELECT CASE WHEN a THEN 1 END; SELECT 2"), ["SELECT CASE WHEN a THEN 1 END", "SELECT 2"])
    }

    func testUnterminatedStringKeepsTheRest() {
        XCTAssertEqual(split("SELECT 1; SELECT 'abc; SELECT 3"), ["SELECT 1", "SELECT 'abc; SELECT 3"])
    }

    func testRangesPointIntoTheSource() {
        let sql = "  SELECT 1 ;\n\tSELECT 'é🙂' ; "
        for statement in Engine.postgres.dialect.splitter.split(sql) {
            XCTAssertEqual(String(sql[statement.range]), statement.text)
        }
    }

    func testStatementAtPosition() {
        let sql = "SELECT 1;\n\nSELECT 2;\nSELECT 3"
        let splitter = Engine.postgres.dialect.splitter
        func at(_ offset: Int) -> String? {
            splitter.statement(at: sql.index(sql.startIndex, offsetBy: offset), in: sql)?.text
        }
        XCTAssertEqual(at(0), "SELECT 1")
        XCTAssertEqual(at(8), "SELECT 1")
        XCTAssertEqual(at(10), "SELECT 1")
        XCTAssertEqual(at(11), "SELECT 2")
        XCTAssertEqual(at(sql.count), "SELECT 3")
        XCTAssertNil(splitter.statement(at: "".startIndex, in: ""))
    }
}
