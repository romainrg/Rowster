import XCTest
@testable import RowsterCore

final class ValuePreviewTests: XCTestCase {
    // MARK: - JSON

    func testParsesAndKeepsKeyOrderAndNumberText() {
        let parsed = JSONValue.parse(#" {"z": 1.50, "a": [true, false, null, -0.5e+3], "nested": {"é🙂": "x\ny"}, "empty": {}, "none": []} "#)
        XCTAssertEqual(
            parsed,
            .object([
                .init(key: "z", value: .number("1.50")),
                .init(key: "a", value: .array([.bool(true), .bool(false), .null, .number("-0.5e+3")])),
                .init(key: "nested", value: .object([.init(key: "é🙂", value: .string("x\ny"))])),
                .init(key: "empty", value: .object([])),
                .init(key: "none", value: .array([]))
            ]))
    }

    func testEscapes() {
        XCTAssertEqual(JSONValue.parse(#""a\"b\\c\/d\n\té🙂""#), .string("a\"b\\c/d\n\té🙂"))
        XCTAssertNil(JSONValue.parse(#""\ud83d""#))
        XCTAssertNil(JSONValue.parse(#""\x""#))
        XCTAssertNil(JSONValue.parse("\"line\nbreak\""))
    }

    func testScalars() {
        XCTAssertEqual(JSONValue.parse("42"), .number("42"))
        XCTAssertEqual(JSONValue.parse(" null "), .null)
        XCTAssertEqual(JSONValue.parse("\"\""), .string(""))
    }

    func testRejectsWhatIsNotJSON() {
        for text in ["", "hello", "{", "{\"a\": }", "[1, 2,]", "{\"a\": 1,}", "{'a': 1}", "01", "1.", "1e", "tru", "{} {}", "[1] x", "{\"a\" 1}", "-"] {
            XCTAssertNil(JSONValue.parse(text), text)
        }
        XCTAssertNil(JSONValue.parse(String(repeating: "[", count: 500) + String(repeating: "]", count: 500)))
    }

    func testSummary() {
        XCTAssertEqual(JSONValue.parse(#"{"a": 1, "b": 2}"#)?.summary, "{2}")
        XCTAssertEqual(JSONValue.parse("[1, 2, 3]")?.summary, "[3]")
        XCTAssertEqual(JSONValue.string("x").summary, "\"x\"")
        XCTAssertEqual(JSONValue.null.summary, "null")
        XCTAssertTrue(JSONValue.array([]).isContainer)
        XCTAssertFalse(JSONValue.number("1").isContainer)
    }

    // MARK: - Binary

    func testImageTypes() {
        XCTAssertEqual(BinaryPreview.imageType(of: Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0])), "PNG")
        XCTAssertEqual(BinaryPreview.imageType(of: Data([0xFF, 0xD8, 0xFF, 0xE0])), "JPEG")
        XCTAssertEqual(BinaryPreview.imageType(of: Data("GIF89a".utf8)), "GIF")
        XCTAssertEqual(BinaryPreview.imageType(of: Data("RIFF\u{01}\u{02}\u{03}\u{04}WEBPVP8 ".utf8)), "WebP")
        XCTAssertEqual(BinaryPreview.imageType(of: Data([0, 0, 0, 0x18] + Array("ftypheic".utf8))), "HEIC")
        XCTAssertNil(BinaryPreview.imageType(of: Data("hello world, not an image".utf8)))
        XCTAssertNil(BinaryPreview.imageType(of: Data()))
        XCTAssertNil(BinaryPreview.imageType(of: Data([0x89])))
    }

    func testHexDump() {
        let data = Data("Rowster!".utf8) + Data([0x00, 0xFF]) + Data("0123456789".utf8)
        XCTAssertEqual(
            BinaryPreview.hexDump(data),
            """
            00000000  52 6f 77 73 74 65 72 21  00 ff 30 31 32 33 34 35  |Rowster!..012345|
            00000010  36 37 38 39                                       |6789|
            """)
        XCTAssertEqual(BinaryPreview.hexDump(Data()), "")
        let truncated = BinaryPreview.hexDump(Data(repeating: 0x41, count: 40), limit: 16)
        XCTAssertEqual(truncated.components(separatedBy: "\n").count, 2)
        XCTAssertTrue(truncated.hasSuffix("…"))
    }
}
