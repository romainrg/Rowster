import XCTest
@testable import RowsterCore

final class MySQLProtocolTests: XCTestCase {
    private let salt = Data(1...20)

    // MARK: - Authentication

    /// Both vectors were computed independently with Python's hashlib.
    func testScrambles() {
        XCTAssertEqual(
            MySQLAuth.scramble(plugin: "mysql_native_password", password: "rowster-test", salt: salt)?.hexString,
            "35b86039927c94daf02eec9f8616bcc50995fcd8")
        XCTAssertEqual(
            MySQLAuth.scramble(plugin: "caching_sha2_password", password: "rowster-test", salt: salt)?.hexString,
            "4c531e21b4ef723ae5b25e8b22af7650ed319deca7e6ad21e17521a0b0f736a0")
        XCTAssertEqual(MySQLAuth.scramble(plugin: "caching_sha2_password", password: "", salt: salt), Data())
        XCTAssertNil(MySQLAuth.scramble(plugin: "sha256_password", password: "x", salt: salt))
        XCTAssertNil(MySQLAuth.encrypt(password: "x", salt: salt, publicKeyPEM: "not a key"))
    }

    // MARK: - Handshake

    private func greeting(capabilities: UInt32, plugin: String = "caching_sha2_password") -> Data {
        var data = Data([10])
        data.appendCString("8.4.3")
        data.appendLE(77, bytes: 4)
        data.append(Data(1...8))
        data.append(0)
        data.appendLE(UInt64(capabilities & 0xFFFF), bytes: 2)
        data.append(255)
        data.appendLE(2, bytes: 2)
        data.appendLE(UInt64(capabilities >> 16), bytes: 2)
        data.append(21)
        data.append(Data(count: 10))
        data.append(Data(9...20))
        data.append(0)
        data.appendCString(plugin)
        return data
    }

    func testParsesTheGreeting() throws {
        let all: UInt32 = 0xFFFF_FFFF
        let handshake = try XCTUnwrap(MySQLHandshake(greeting(capabilities: all)))
        XCTAssertEqual(handshake.version, "8.4.3")
        XCTAssertEqual(handshake.threadID, 77)
        XCTAssertEqual(handshake.salt, salt)
        XCTAssertEqual(handshake.capabilities, all)
        XCTAssertEqual(handshake.plugin, "caching_sha2_password")
        XCTAssertTrue(handshake.supportsTLS)
        XCTAssertFalse(try XCTUnwrap(MySQLHandshake(greeting(capabilities: all & ~MySQLCapability.ssl))).supportsTLS)
        XCTAssertNil(MySQLHandshake(Data([9, 0])))
        XCTAssertNil(MySQLHandshake(Data()))
    }

    func testClientCapabilitiesNeverExceedTheServer() {
        let server: UInt32 = MySQLCapability.protocol41 | MySQLCapability.secureConnection | MySQLCapability.pluginAuth
        let client = MySQLCapability.client(server: server, hasDatabase: true, tls: true)
        XCTAssertEqual(client & ~server, 0)
        XCTAssertEqual(client & MySQLCapability.ssl, 0)
        let full = MySQLCapability.client(server: 0xFFFF_FFFF, hasDatabase: false, tls: true)
        XCTAssertNotEqual(full & MySQLCapability.ssl, 0)
        XCTAssertNotEqual(full & MySQLCapability.foundRows, 0)
        XCTAssertEqual(full & MySQLCapability.connectWithDB, 0)
    }

    func testHandshakeResponse() {
        let capabilities = MySQLCapability.client(server: 0xFFFF_FFFF, hasDatabase: true, tls: false)
        let response = MySQLPacket.handshakeResponse(
            capabilities: capabilities, user: "app", authResponse: Data([1, 2, 3]), database: "shop", plugin: "caching_sha2_password")
        var reader = ByteReader(response)
        XCTAssertEqual(UInt32(reader.uintLE(4)), capabilities)
        reader.skip(4 + 1 + 23)
        XCTAssertEqual(reader.cString(), "app")
        XCTAssertEqual(reader.lengthEncodedBytes(), Data([1, 2, 3]))
        XCTAssertEqual(reader.cString(), "shop")
        XCTAssertEqual(reader.cString(), "caching_sha2_password")
        XCTAssertTrue(reader.isAtEnd)
    }

    // MARK: - Packets

    func testFraming() {
        let framed = MySQLPacket.frame(Data("abc".utf8), sequence: 2)
        XCTAssertEqual(framed.data, Data([3, 0, 0, 2]) + Data("abc".utf8))
        XCTAssertEqual(framed.next, 3)
        XCTAssertEqual(MySQLPacket.frame(Data(), sequence: 0).data, Data([0, 0, 0, 0]))
        // A payload of exactly the maximum size is followed by an empty packet.
        let large = MySQLPacket.frame(Data(count: MySQLPacket.maxPayload), sequence: 0)
        XCTAssertEqual(large.data.count, MySQLPacket.maxPayload + 8)
        XCTAssertEqual(large.next, 2)
    }

    func testLengthEncodedIntegers() {
        for value: UInt64 in [0, 250, 251, 65_535, 65_536, 16_777_215, 16_777_216, 1 << 40] {
            var data = Data()
            MySQLPacket.appendLengthEncoded(value, to: &data)
            var reader = ByteReader(data)
            XCTAssertEqual(reader.lengthEncoded(), value)
            XCTAssertTrue(reader.isAtEnd)
        }
        var null = ByteReader(Data([0xFB]))
        XCTAssertNil(null.lengthEncoded())
    }

    func testOKErrorAndTerminator() {
        let ok = MySQLPacket.ok(Data([0x00, 0x03, 0x00, 0x03, 0x00, 0x00, 0x00]))
        XCTAssertEqual(ok.affectedRows, 3)
        XCTAssertEqual(ok.status, 3)
        let error = MySQLPacket.error(Data([0xFF, 0x48, 0x04]) + Data("#42S02Table 'shop.nope' doesn't exist".utf8))
        XCTAssertEqual(error.code, "1096")
        XCTAssertEqual(error.message, "Table 'shop.nope' doesn't exist")
        XCTAssertTrue(MySQLPacket.error(Data([0xFF, 0x25, 0x05]) + Data("#70100Query execution was interrupted".utf8)).isCancellation)
        XCTAssertTrue(MySQLPacket.isTerminator(Data([0xFE, 0, 0, 2, 0]), deprecateEOF: false))
        XCTAssertFalse(MySQLPacket.isTerminator(Data([0xFE]) + Data(count: 12), deprecateEOF: false))
        XCTAssertTrue(MySQLPacket.isTerminator(Data([0xFE, 0, 0, 0x0A, 0, 0, 0]), deprecateEOF: true))
        XCTAssertEqual(MySQLPacket.terminatorStatus(Data([0xFE, 0, 0, 0x0A, 0, 0, 0]), deprecateEOF: true), 0x0A)
        XCTAssertEqual(MySQLPacket.terminatorStatus(Data([0xFE, 0, 0, 2, 0]), deprecateEOF: false), 2)
    }

    // MARK: - Rows

    private func column(_ name: String, type: UInt8, charset: UInt16 = 255, flags: UInt16 = 0) -> MySQLColumn {
        var data = Data()
        for text in ["def", "shop", "t", "t", name, name] { MySQLPacket.appendLengthEncoded(Data(text.utf8), to: &data) }
        data.append(0x0C)
        data.appendLE(UInt64(charset), bytes: 2)
        data.appendLE(255, bytes: 4)
        data.append(type)
        data.appendLE(UInt64(flags), bytes: 2)
        data.append(contentsOf: [0, 0, 0])
        return MySQLColumn(data)
    }

    func testColumnDefinitions() {
        let id = column("id", type: 8, charset: 63, flags: 0x20)
        XCTAssertEqual(id.name, "id")
        XCTAssertEqual(id.kind, .integer)
        XCTAssertEqual(id.typeName, "bigint unsigned")
        XCTAssertEqual(column("b", type: 252, charset: 63).kind, .binary)
        XCTAssertEqual(column("t", type: 252, charset: 255).kind, .text)
        XCTAssertEqual(column("t", type: 252, charset: 255).typeName, "text")
        XCTAssertEqual(column("j", type: 245).kind, .json)
        XCTAssertEqual(column("d", type: 12).kind, .date)
        XCTAssertEqual(column("n", type: 246).kind, .decimal)
        XCTAssertEqual(column("v", type: 253, charset: 63).typeName, "varbinary")
    }

    func testTextRow() {
        let columns = [column("id", type: 3), column("name", type: 253), column("blob", type: 252, charset: 63), column("f", type: 5), column("n", type: 246)]
        var payload = Data()
        MySQLPacket.appendLengthEncoded(Data("42".utf8), to: &payload)
        payload.append(0xFB)
        MySQLPacket.appendLengthEncoded(Data([0, 255]), to: &payload)
        MySQLPacket.appendLengthEncoded(Data("1.5".utf8), to: &payload)
        MySQLPacket.appendLengthEncoded(Data("12.50".utf8), to: &payload)
        XCTAssertEqual(MySQLRow.text(payload, columns: columns), [.integer(42), .null, .bytes(Data([0, 255])), .double(1.5), .text("12.50")])
    }

    func testBinaryRow() {
        let columns = [
            column("tiny", type: 1), column("big", type: 8), column("s", type: 253), column("missing", type: 3), column("d", type: 5),
            column("at", type: 12), column("u", type: 8, flags: 0x20)
        ]
        var payload = Data([0x00, 0b0010_0000, 0x00])
        payload.append(0xFF)
        payload.appendLE(UInt64(bitPattern: -9), bytes: 8)
        MySQLPacket.appendLengthEncoded(Data("é🙂".utf8), to: &payload)
        payload.appendLE((1.5).bitPattern, bytes: 8)
        payload.append(contentsOf: [11, 0xEA, 0x07, 11, 10, 10, 20, 30])
        payload.appendLE(123_456, bytes: 4)
        payload.appendLE(UInt64.max, bytes: 8)
        XCTAssertEqual(
            MySQLRow.binary(payload, columns: columns),
            [.integer(-1), .integer(-9), .text("é🙂"), .null, .double(1.5), .text("2026-11-10 10:20:30.123456"), .text("18446744073709551615")])
    }

    func testExecutePayload() {
        let payload = MySQLRow.execute(statement: 7, parameters: [.text("a'b"), .null, .integer(-2), .bool(true), .double(0.5), .bytes(Data([9]))])
        var reader = ByteReader(payload)
        XCTAssertEqual(reader.byte(), 0x17)
        XCTAssertEqual(reader.uintLE(4), 7)
        XCTAssertEqual(reader.byte(), 0)
        XCTAssertEqual(reader.uintLE(4), 1)
        XCTAssertEqual(reader.byte(), 0b0000_0010)
        XCTAssertEqual(reader.byte(), 1)
        XCTAssertEqual(reader.bytes(12), Data([0xFD, 0, 0x06, 0, 0x08, 0, 0x01, 0, 0x05, 0, 0xFC, 0]))
        XCTAssertEqual(reader.lengthEncodedBytes(), Data("a'b".utf8))
        XCTAssertEqual(Int64(bitPattern: reader.uintLE(8)), -2)
        XCTAssertEqual(reader.byte(), 1)
        XCTAssertEqual(Double(bitPattern: reader.uintLE(8)), 0.5)
        XCTAssertEqual(reader.lengthEncodedBytes(), Data([9]))
        XCTAssertTrue(reader.isAtEnd)
        XCTAssertEqual(MySQLRow.execute(statement: 1, parameters: []).count, 10)
    }

    func testMalformedInputNeverTraps() {
        XCTAssertEqual(MySQLRow.text(Data([0x05, 0x41]), columns: [column("a", type: 253), column("b", type: 3)]).count, 2)
        XCTAssertEqual(MySQLRow.binary(Data(), columns: [column("a", type: 8)]).count, 1)
        XCTAssertEqual(MySQLColumn(Data()).name, "")
        XCTAssertEqual(MySQLPacket.ok(Data()).affectedRows, 0)
    }

    func testIntrospectorKinds() {
        XCTAssertEqual(MySQLIntrospector.kind(dataType: "tinyint", columnType: "tinyint(1)"), .boolean)
        XCTAssertEqual(MySQLIntrospector.kind(dataType: "tinyint", columnType: "tinyint(4)"), .integer)
        XCTAssertEqual(MySQLIntrospector.kind(dataType: "VARCHAR", columnType: "varchar(80)"), .text)
        XCTAssertEqual(MySQLIntrospector.kind(dataType: "longblob", columnType: "longblob"), .binary)
        XCTAssertEqual(MySQLIntrospector.kind(dataType: "json", columnType: "json"), .json)
        XCTAssertEqual(MySQLIntrospector.kind(dataType: "point", columnType: "point"), .other)
    }
}
