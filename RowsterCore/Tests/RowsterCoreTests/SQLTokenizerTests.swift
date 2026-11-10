import XCTest
@testable import RowsterCore

final class SQLTokenizerTests: XCTestCase {
    private func tokens(_ sql: String, _ engine: Engine) -> [(SQLToken.Kind, String)] {
        engine.dialect.tokenizer.tokenize(sql).filter { $0.kind != .whitespace }.map { ($0.kind, String(sql[$0.range])) }
    }

    private func texts(_ sql: String, _ engine: Engine, of kind: SQLToken.Kind) -> [String] {
        tokens(sql, engine).filter { $0.0 == kind }.map(\.1)
    }

    func testTokensCoverTheWholeText() {
        let sql = "SELECT \"a b\", 'it''s', 1.5e-3 FROM t -- tail\n/* block */ WHERE x >= $1;"
        for engine in Engine.allCases {
            let all = engine.dialect.tokenizer.tokenize(sql)
            XCTAssertEqual(all.map { String(sql[$0.range]) }.joined(), sql, "\(engine)")
        }
    }

    func testStringsWithDoubledQuotes() {
        XCTAssertEqual(texts("SELECT 'it''s; here', 'b'", .postgres, of: .string), ["'it''s; here'", "'b'"])
    }

    func testBackslashEscapesOnlyInMySQL() {
        XCTAssertEqual(texts(#"SELECT 'a\'b; c'"#, .mysql, of: .string), [#"'a\'b; c'"#])
        // In PostgreSQL and SQLite the backslash is an ordinary character, so the string ends at the second quote.
        XCTAssertEqual(texts(#"SELECT 'a\' AS b"#, .postgres, of: .string), [#"'a\'"#])
        XCTAssertEqual(texts(#"SELECT 'a\' AS b"#, .sqlite, of: .string), [#"'a\'"#])
    }

    func testPostgresEscapeStringPrefix() {
        XCTAssertEqual(texts(#"SELECT E'a\'b; c', e'x'"#, .postgres, of: .string), [#"E'a\'b; c'"#, "e'x'"])
    }

    func testDollarQuoting() {
        let sql = "DO $body$ BEGIN; 'x' $$ nested $$ END $body$; SELECT $1, $$a;b$$"
        XCTAssertEqual(
            texts(sql, .postgres, of: .string),
            ["$body$ BEGIN; 'x' $$ nested $$ END $body$", "$$a;b$$"])
        XCTAssertEqual(texts(sql, .postgres, of: .parameter), ["$1"])
    }

    func testDollarIsNotAQuoteOutsidePostgres() {
        XCTAssertTrue(texts("SELECT $$a$$", .mysql, of: .string).isEmpty)
    }

    func testQuotedIdentifiersPerDialect() {
        XCTAssertEqual(texts("SELECT \"a\"\"b\" FROM \"t;\"", .postgres, of: .quotedIdentifier), ["\"a\"\"b\"", "\"t;\""])
        XCTAssertEqual(texts("SELECT `a``b` FROM `t;`", .mysql, of: .quotedIdentifier), ["`a``b`", "`t;`"])
        XCTAssertEqual(texts("SELECT [a;b] FROM `t`", .sqlite, of: .quotedIdentifier), ["[a;b]", "`t`"])
        // MySQL reads double quotes as a string by default.
        XCTAssertEqual(texts("SELECT \"a;b\"", .mysql, of: .string), ["\"a;b\""])
    }

    func testComments() {
        XCTAssertEqual(texts("SELECT 1 -- a; b\n# not a comment", .postgres, of: .comment), ["-- a; b"])
        XCTAssertEqual(texts("SELECT 1 # a; b\nFROM t", .mysql, of: .comment), ["# a; b"])
        XCTAssertEqual(texts("SELECT /* a; /* nested */ still */ 1", .postgres, of: .comment), ["/* a; /* nested */ still */"])
        XCTAssertEqual(texts("SELECT /* a; /* nested */ 1", .mysql, of: .comment), ["/* a; /* nested */"])
    }

    func testMySQLDashCommentNeedsWhitespace() {
        XCTAssertTrue(texts("SELECT 5--3", .mysql, of: .comment).isEmpty)
        XCTAssertEqual(texts("SELECT 5 -- 3", .mysql, of: .comment), ["-- 3"])
        XCTAssertEqual(texts("SELECT 5--3", .postgres, of: .comment), ["--3"])
    }

    func testExecutableComments() {
        XCTAssertEqual(texts("SELECT 1 /*!50000 , 2 */ /*M! x */", .mysql, of: .executableComment), ["/*!50000 , 2 */", "/*M! x */"])
        XCTAssertTrue(texts("SELECT 1 /*! x */", .postgres, of: .executableComment).isEmpty)
    }

    func testUnterminatedTokensReachTheEnd() {
        for sql in ["SELECT 'abc; SELECT 2", "SELECT /* abc; SELECT 2", "SELECT $x$ abc; SELECT 2", "SELECT \"abc; x"] {
            let last = Engine.postgres.dialect.tokenizer.tokenize(sql).last
            XCTAssertEqual(last?.isTerminated, false, sql)
            XCTAssertEqual(last?.range.upperBound, sql.endIndex, sql)
        }
    }

    func testNumbersAndWords() {
        XCTAssertEqual(texts("SELECT 1, 2.5, .5, 1e10, 3E-2, 0x1F", .postgres, of: .number), ["1", "2.5", ".5", "1e10", "3E-2", "0x1F"])
        XCTAssertEqual(texts("SELECT café, _x1, @v FROM tâble", .mysql, of: .word), ["SELECT", "café", "_x1", "@v", "FROM", "tâble"])
    }

    func testEmoji() {
        let sql = "SELECT '🙂;' AS \"🙂\""
        XCTAssertEqual(texts(sql, .postgres, of: .string), ["'🙂;'"])
        XCTAssertEqual(texts(sql, .postgres, of: .quotedIdentifier), ["\"🙂\""])
    }
}
