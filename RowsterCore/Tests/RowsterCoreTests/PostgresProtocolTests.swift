import XCTest
@testable import RowsterCore

final class PostgresProtocolTests: XCTestCase {
    private func hex(_ text: String) -> Data {
        Data(hex: Substring(text.filter { !$0.isWhitespace })) ?? Data()
    }

    // MARK: - Authentication

    /// The example exchange of RFC 7677, section 3.
    func testScramSHA256VectorsOfRFC7677() {
        var client = ScramSHA256(user: "user", password: "pencil", nonce: "rOprNGfwEbeRWgbNEkqO")
        XCTAssertEqual(client.clientFirst, "n,,n=user,r=rOprNGfwEbeRWgbNEkqO")
        let final = client.clientFinal(
            serverFirst: "r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096")
        XCTAssertEqual(
            final, "c=biws,r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,p=dHzbZapWIk4jUhN+Ute9ytag9zjfMHgsqmmiz7AndVQ=")
        XCTAssertTrue(client.verify(serverFinal: "v=6rriTRBi23WpRR/wtup+mMhUZUn/dB5nLTJRsjl95G4="))
        XCTAssertFalse(client.verify(serverFinal: "v=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="))
    }

    func testScramRefusesAForgedServerFirstMessage() {
        var client = ScramSHA256(password: "pencil", nonce: "abc")
        // The server nonce must extend the client nonce.
        XCTAssertNil(client.clientFinal(serverFirst: "r=other,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096"))
        XCTAssertNil(client.clientFinal(serverFirst: "r=abc,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096"))
        XCTAssertNil(client.clientFinal(serverFirst: "r=abcdef,s=!!!,i=4096"))
        XCTAssertNil(client.clientFinal(serverFirst: "r=abcdef,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=0"))
        XCTAssertFalse(client.verify(serverFinal: "v="))
        XCTAssertEqual(ScramSHA256(password: "x", nonce: "n").clientFirst, "n,,n=,r=n")
        XCTAssertNotEqual(ScramSHA256.makeNonce(), ScramSHA256.makeNonce())
    }

    func testMD5Response() {
        // "md5" + md5(md5("secret" + "app") + 01 02 03 04), computed independently with Python's hashlib.
        XCTAssertEqual(
            PostgresMD5.response(user: "app", password: "secret", salt: Data([0x01, 0x02, 0x03, 0x04])),
            "md5911f527656472583a006e7727877b33e")
    }

    // MARK: - Frontend messages

    func testStartupMessage() {
        let message = PostgresMessage.startup(user: "app", database: "shop")
        var reader = ByteReader(message)
        XCTAssertEqual(Int(reader.int32BE()), message.count)
        XCTAssertEqual(reader.int32BE(), 196_608)
        var pairs: [String: String] = [:]
        while let next = reader.peek, next != 0 {
            let key = reader.cString()
            pairs[key] = reader.cString()
        }
        XCTAssertEqual(pairs, ["user": "app", "client_encoding": "UTF8", "application_name": "Rowster", "database": "shop"])
        XCTAssertNil(String(decoding: PostgresMessage.startup(user: "app", database: ""), as: UTF8.self).range(of: "database"))
    }

    func testBindSendsValuesAsTextAndNullAsMinusOne() {
        let message = PostgresMessage.bind([.text("O'Brien"), .null, .integer(-7), .bool(true), .bytes(Data([0xDE, 0xAD])), .double(1.5)])
        var expected = hex("42 0000003a 00 00 0000 0006")
        expected.append(hex("00000007"))
        expected.append(Data("O'Brien".utf8))
        expected.append(hex("ffffffff"))
        expected.append(hex("00000002"))
        expected.append(Data("-7".utf8))
        expected.append(hex("00000004"))
        expected.append(Data("true".utf8))
        expected.append(hex("00000006"))
        expected.append(Data("\\xdead".utf8))
        expected.append(hex("00000003"))
        expected.append(Data("1.5".utf8))
        expected.append(hex("0000"))
        XCTAssertEqual(message, expected)
    }

    func testFixedMessages() {
        XCTAssertEqual(PostgresMessage.parse("SELECT 1"), hex("50 00000010 00") + Data("SELECT 1".utf8) + hex("00 0000"))
        XCTAssertEqual(PostgresMessage.execute(maxRows: 300), hex("45 00000009 00 0000012c"))
        XCTAssertEqual(PostgresMessage.sync, hex("53 00000004"))
        XCTAssertEqual(PostgresMessage.flush, hex("48 00000004"))
        XCTAssertEqual(PostgresMessage.describePortal, hex("44 00000006 50 00"))
        XCTAssertEqual(PostgresMessage.closePortal, hex("43 00000006 50 00"))
        XCTAssertEqual(PostgresMessage.cancelRequest(processID: 1234, secret: 5678), hex("00000010 04d2162e 000004d2 0000162e"))
        XCTAssertEqual(PostgresMessage.password("pw"), hex("70 00000007") + Data("pw".utf8) + hex("00"))
    }

    // MARK: - Backend messages

    func testRowDescriptionAndDataRow() {
        // Two columns: "id" int4 and "name" text.
        let description = hex("0002") + Data("id".utf8) + hex("00 00004001 0001 00000017 0004 ffffffff 0000")
            + Data("name".utf8) + hex("00 00004001 0002 00000019 ffff ffffffff 0000")
        let columns = PostgresMessage.columns(description)
        XCTAssertEqual(columns.map(\.info.name), ["id", "name"])
        XCTAssertEqual(columns.map(\.info.typeName), ["int4", "text"])
        XCTAssertEqual(columns.map(\.info.kind), [.integer, .text])
        XCTAssertEqual(columns.map(\.type), [23, 25])

        let row = hex("0002 00000002") + Data("42".utf8) + hex("ffffffff")
        XCTAssertEqual(PostgresMessage.row(row, types: columns.map(\.type)), [.integer(42), .null])
    }

    func testValueDecoding() {
        XCTAssertEqual(PostgresType.value("t", type: 16), .bool(true))
        XCTAssertEqual(PostgresType.value("f", type: 16), .bool(false))
        XCTAssertEqual(PostgresType.value("-9000000000", type: 20), .integer(-9_000_000_000))
        XCTAssertEqual(PostgresType.value("1.5", type: 701), .double(1.5))
        XCTAssertEqual(PostgresType.value("NaN", type: 701), .text("NaN"))
        XCTAssertEqual(PostgresType.value("12.50", type: 1700), .text("12.50"))
        XCTAssertEqual(PostgresType.value("\\xdead", type: 17), .bytes(Data([0xDE, 0xAD])))
        XCTAssertEqual(PostgresType.value("{\"a\": 1}", type: 3802), .text("{\"a\": 1}"))
        XCTAssertEqual(PostgresType.kind(3802), .json)
        XCTAssertEqual(PostgresType.kind(1184), .date)
        XCTAssertEqual(PostgresType.kind(999_999), .other)
    }

    func testErrorResponse() {
        let body = Data("SERROR\0C42P01\0Mrelation \"nope\" does not exist\0P15\0Hcheck the name\0\0".utf8)
        let error = PostgresMessage.error(body)
        XCTAssertEqual(error.message, "relation \"nope\" does not exist")
        XCTAssertEqual(error.code, "42P01")
        XCTAssertEqual(error.position, 15)
        XCTAssertEqual(error.hint, "check the name")
        XCTAssertNil(error.detail)
        XCTAssertTrue(PostgresMessage.error(Data("C57014\0Mcanceling statement\0\0".utf8)).isCancellation)
    }

    func testRowsAffected() {
        XCTAssertEqual(PostgresMessage.rowsAffected(tag: "INSERT 0 5"), 5)
        XCTAssertEqual(PostgresMessage.rowsAffected(tag: "UPDATE 3"), 3)
        XCTAssertEqual(PostgresMessage.rowsAffected(tag: "DELETE 0"), 0)
        XCTAssertNil(PostgresMessage.rowsAffected(tag: "SELECT 10"))
        XCTAssertNil(PostgresMessage.rowsAffected(tag: "CREATE TABLE"))
        XCTAssertNil(PostgresMessage.rowsAffected(tag: ""))
    }

    func testMalformedInputNeverTraps() {
        XCTAssertTrue(PostgresMessage.columns(hex("0005 6964")).count <= 5)
        XCTAssertEqual(PostgresMessage.row(hex("0003 00000009 41"), types: [25]).count, 3)
        XCTAssertEqual(PostgresMessage.row(Data(), types: []), [])
        XCTAssertEqual(PostgresMessage.fields(Data([0x4D])).count, 1)
    }
}
