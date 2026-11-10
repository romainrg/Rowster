import XCTest
@testable import RowsterCore

final class ClipboardFormatterTests: XCTestCase {
    private let columns = ["id", "name", "note"]
    private let rows: [Row] = [
        [.integer(1), .text("Ada"), .null],
        [.integer(2), .text("O'Brien, \"Bob\""), .text("line one\nline two")],
        [.integer(3), .text(""), .text(" padded ")]
    ]

    private func format(_ format: TabularFormat, _ dialect: any SQLDialect = PostgresDialect()) -> String {
        TabularText.format(columns: columns, rows: rows, as: format, table: TableRef(schema: "shop", name: "people"), dialect: dialect)
    }

    func testTSVHasNoHeaderAndFlattensWhitespace() {
        XCTAssertEqual(format(.tsv), "1\tAda\t\n2\tO'Brien, \"Bob\"\tline one line two\n3\t\t padded ")
        XCTAssertEqual(
            TabularText.format(columns: ["a"], rows: [[.text("x\ty")]], as: .tsv, dialect: PostgresDialect()), "x y")
    }

    func testCSVQuotingAndNullVersusEmpty() {
        XCTAssertEqual(
            format(.csv),
            """
            id,name,note
            1,Ada,
            2,"O'Brien, ""Bob\""","line one
            line two"
            3,""," padded "
            """)
    }

    func testJSONKeepsColumnOrderAndTypes() throws {
        let text = TabularText.format(
            columns: ["z", "a", "flag", "ratio", "bad", "blob", "lazy", "ctl"],
            rows: [[.integer(1), .null, .bool(true), .double(1.5), .double(.nan), .bytes(Data([1, 2])), .deferredBytes(length: 9), .text("a\"b\\c\u{01}\n")]],
            as: .json, dialect: PostgresDialect())
        XCTAssertEqual(
            text,
            "[\n  {\"z\": 1, \"a\": null, \"flag\": true, \"ratio\": 1.5, \"bad\": null, \"blob\": \"AQI=\", \"lazy\": null, \"ctl\": \"a\\\"b\\\\c\\u0001\\n\"}\n]")
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [[String: Any]])
        XCTAssertEqual(parsed[0]["ctl"] as? String, "a\"b\\c\u{01}\n")
    }

    func testMarkdownEscapesPipesAndNewlines() {
        let text = TabularText.format(
            columns: ["a|b", "c"], rows: [[.text("x|y"), .text("1\n2")], [.null, .integer(3)]], as: .markdown,
            dialect: PostgresDialect())
        XCTAssertEqual(text, "| a\\|b | c |\n| --- | --- |\n| x\\|y | 1<br>2 |\n|  | 3 |")
    }

    func testInsertStatementsPerDialect() {
        XCTAssertEqual(
            format(.insert),
            """
            INSERT INTO "shop"."people" ("id", "name", "note") VALUES (1, 'Ada', NULL);
            INSERT INTO "shop"."people" ("id", "name", "note") VALUES (2, 'O''Brien, "Bob"', 'line one
            line two');
            INSERT INTO "shop"."people" ("id", "name", "note") VALUES (3, '', ' padded ');
            """)
        XCTAssertTrue(format(.insert, MySQLDialect()).hasPrefix("INSERT INTO `shop`.`people` (`id`, `name`, `note`) VALUES (1, 'Ada', NULL);"))
    }

    func testLiteralsForDisplay() {
        let postgres = PostgresDialect(), mysql = MySQLDialect(), sqlite = SQLiteDialect()
        XCTAssertEqual(postgres.literalForDisplay(.text(#"it's a \ path"#)), #"'it''s a \ path'"#)
        XCTAssertEqual(mysql.literalForDisplay(.text(#"it's a \ path"#)), #"'it''s a \\ path'"#)
        XCTAssertEqual(postgres.literalForDisplay(.bytes(Data([0xDE, 0xAD]))), #"'\xdead'"#)
        XCTAssertEqual(mysql.literalForDisplay(.bytes(Data([0xDE, 0xAD]))), "X'dead'")
        XCTAssertEqual(sqlite.literalForDisplay(.bool(true)), "1")
        XCTAssertEqual(postgres.literalForDisplay(.bool(false)), "FALSE")
        XCTAssertEqual(postgres.literalForDisplay(.null), "NULL")
        XCTAssertEqual(postgres.literalForDisplay(.double(.infinity)), "NULL")
        XCTAssertEqual(postgres.literalForDisplay(.integer(-7)), "-7")
        // A rendered literal is always a single string token: it cannot end early.
        for dialect in [postgres, mysql, sqlite] as [any SQLDialect] {
            for text in ["'; DROP TABLE t; --", "\\'; DROP TABLE t; --", "a\\", "''", "\""] {
                let tokens = dialect.tokenizer.tokenize(dialect.literalForDisplay(.text(text)))
                XCTAssertEqual(tokens.count, 1, "\(dialect.engine) \(text)")
                XCTAssertEqual(tokens.first?.kind, .string, "\(dialect.engine) \(text)")
                XCTAssertEqual(tokens.first?.isTerminated, true, "\(dialect.engine) \(text)")
            }
        }
    }
}
