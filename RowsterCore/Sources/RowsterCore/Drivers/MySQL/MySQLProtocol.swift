import CryptoKit
import Foundation
import Security

/// Capability flags of the MySQL client/server protocol.
enum MySQLCapability {
    static let longPassword: UInt32 = 0x1
    /// Report matched rows, not changed rows: an UPDATE that sets the same value still counts its row.
    static let foundRows: UInt32 = 0x2
    static let longFlag: UInt32 = 0x4
    static let connectWithDB: UInt32 = 0x8
    static let protocol41: UInt32 = 0x200
    static let ssl: UInt32 = 0x800
    static let transactions: UInt32 = 0x2000
    static let secureConnection: UInt32 = 0x8000
    static let multiResults: UInt32 = 0x20000
    static let pluginAuth: UInt32 = 0x80000
    static let pluginAuthLenencData: UInt32 = 0x200000
    static let deprecateEOF: UInt32 = 0x1000000

    /// What Rowster asks for, limited to what the server offers.
    static func client(server: UInt32, hasDatabase: Bool, tls: Bool) -> UInt32 {
        var wanted = longPassword | foundRows | longFlag | protocol41 | transactions | secureConnection | multiResults
            | pluginAuth | pluginAuthLenencData | deprecateEOF
        if hasDatabase { wanted |= connectWithDB }
        if tls { wanted |= ssl }
        return wanted & server
    }
}

/// The greeting a server sends first (protocol version 10).
struct MySQLHandshake: Equatable {
    var version = ""
    var threadID: UInt32 = 0
    var salt = Data()
    var capabilities: UInt32 = 0
    var plugin = ""

    init?(_ payload: Data) {
        var reader = ByteReader(payload)
        guard reader.byte() == 10 else { return nil }
        version = reader.cString()
        threadID = UInt32(truncatingIfNeeded: reader.uintLE(4))
        salt = reader.bytes(8)
        reader.skip(1)
        capabilities = UInt32(truncatingIfNeeded: reader.uintLE(2))
        reader.skip(3)
        capabilities |= UInt32(truncatingIfNeeded: reader.uintLE(2)) << 16
        let saltLength = Int(reader.byte())
        reader.skip(10)
        salt.append(reader.bytes(max(13, saltLength - 8)).prefix(12))
        plugin = reader.cString()
    }

    var supportsTLS: Bool { capabilities & MySQLCapability.ssl != 0 }
}

enum MySQLPacket {
    static let maxPayload = 0xFF_FFFF

    /// Frames a payload, splitting it when it does not fit one packet. Returns the next sequence number.
    static func frame(_ payload: Data, sequence: UInt8) -> (data: Data, next: UInt8) {
        var out = Data()
        var sequence = sequence
        var offset = 0
        repeat {
            let size = min(maxPayload, payload.count - offset)
            out.appendLE(UInt64(size), bytes: 3)
            out.append(sequence)
            out.append(payload.subdata(in: payload.startIndex + offset..<payload.startIndex + offset + size))
            sequence &+= 1
            offset += size
            if size < maxPayload { break }
        } while true
        return (out, sequence)
    }

    static func sslRequest(capabilities: UInt32) -> Data {
        var body = Data()
        body.appendLE(UInt64(capabilities), bytes: 4)
        body.appendLE(UInt64(maxPayload + 1), bytes: 4)
        body.append(45)
        body.append(Data(count: 23))
        return body
    }

    static func handshakeResponse(
        capabilities: UInt32, user: String, authResponse: Data, database: String, plugin: String
    ) -> Data {
        var body = sslRequest(capabilities: capabilities)
        body.appendCString(user)
        appendLengthEncoded(authResponse, to: &body)
        if capabilities & MySQLCapability.connectWithDB != 0 { body.appendCString(database) }
        body.appendCString(plugin)
        return body
    }

    static func appendLengthEncoded(_ value: UInt64, to data: inout Data) {
        switch value {
        case 0..<251: data.append(UInt8(value))
        case 251..<0x1_0000:
            data.append(0xFC)
            data.appendLE(value, bytes: 2)
        case 0x1_0000..<0x100_0000:
            data.append(0xFD)
            data.appendLE(value, bytes: 3)
        default:
            data.append(0xFE)
            data.appendLE(value, bytes: 8)
        }
    }

    static func appendLengthEncoded(_ bytes: Data, to data: inout Data) {
        appendLengthEncoded(UInt64(bytes.count), to: &data)
        data.append(bytes)
    }

    /// OK packet: affected rows and status flags.
    static func ok(_ payload: Data) -> (affectedRows: Int, status: UInt16) {
        var reader = ByteReader(payload)
        reader.skip(1)
        let affected = reader.lengthEncoded()
        _ = reader.lengthEncoded()
        return (Int(clamping: affected ?? 0), UInt16(truncatingIfNeeded: reader.uintLE(2)))
    }

    static func error(_ payload: Data) -> DatabaseError {
        var reader = ByteReader(payload)
        reader.skip(1)
        let code = reader.uintLE(2)
        if reader.peek == UInt8(ascii: "#") { reader.skip(6) }
        return DatabaseError(message: String(decoding: reader.remaining(), as: UTF8.self), code: String(code))
    }

    /// Whether a packet ends a result set: an EOF packet, or an OK packet with the 0xFE header.
    static func isTerminator(_ payload: Data, deprecateEOF: Bool) -> Bool {
        payload.first == 0xFE && (deprecateEOF ? payload.count < maxPayload : payload.count < 9)
    }

    /// Status flags of a result-set terminator.
    static func terminatorStatus(_ payload: Data, deprecateEOF: Bool) -> UInt16 {
        if deprecateEOF { return ok(payload).status }
        var reader = ByteReader(payload)
        reader.skip(3)
        return UInt16(truncatingIfNeeded: reader.uintLE(2))
    }
}

extension ByteReader {
    /// A length-encoded integer; `nil` for the NULL marker (0xFB).
    mutating func lengthEncoded() -> UInt64? {
        switch byte() {
        case 0xFB: return nil
        case 0xFC: return uintLE(2)
        case 0xFD: return uintLE(3)
        case 0xFE: return uintLE(8)
        case let small: return UInt64(small)
        }
    }

    mutating func lengthEncodedBytes() -> Data? {
        guard let length = lengthEncoded() else { return nil }
        return bytes(Int(clamping: length))
    }
}

/// A column of a result set.
struct MySQLColumn: Equatable {
    var name: String
    var type: UInt8
    var charset: UInt16
    var flags: UInt16

    init(_ payload: Data) {
        var reader = ByteReader(payload)
        for _ in 0..<4 { _ = reader.lengthEncodedBytes() }
        name = String(decoding: reader.lengthEncodedBytes() ?? Data(), as: UTF8.self)
        _ = reader.lengthEncodedBytes()
        _ = reader.lengthEncoded()
        charset = UInt16(truncatingIfNeeded: reader.uintLE(2))
        reader.skip(4)
        type = reader.byte()
        flags = UInt16(truncatingIfNeeded: reader.uintLE(2))
    }

    private var isBinaryCharset: Bool { charset == 63 }
    private var isUnsigned: Bool { flags & 0x20 != 0 }

    var kind: ColumnKind {
        switch type {
        case 1, 2, 3, 8, 9, 13: return .integer
        case 0, 4, 5, 246: return .decimal
        case 7, 10, 11, 12, 14: return .date
        case 245: return .json
        case 249, 250, 251, 252, 15, 253, 254: return isBinaryCharset ? .binary : .text
        case 255: return .binary
        default: return .other
        }
    }

    var typeName: String {
        let names: [UInt8: String] = [
            0: "decimal", 1: "tinyint", 2: "smallint", 3: "int", 4: "float", 5: "double", 7: "timestamp", 8: "bigint",
            9: "mediumint", 10: "date", 11: "time", 12: "datetime", 13: "year", 15: "varchar", 16: "bit", 245: "json",
            246: "decimal", 249: "tinyblob", 250: "mediumblob", 251: "longblob", 252: "blob", 253: "varchar", 254: "char",
            255: "geometry"
        ]
        let name = names[type] ?? ""
        if isBinaryCharset, type == 253 || type == 15 { return "varbinary" }
        if isBinaryCharset, type == 254 { return "binary" }
        if !isBinaryCharset, type == 252 { return "text" }
        return isUnsigned && kind == .integer ? name + " unsigned" : name
    }

    var info: ColumnInfo { ColumnInfo(name: name, typeName: typeName, kind: kind) }

    /// A value of the text protocol, where everything arrives as text.
    func value(text bytes: Data) -> SQLValue {
        switch kind {
        case .integer:
            let text = String(decoding: bytes, as: UTF8.self)
            return Int64(text).map(SQLValue.integer) ?? .text(text)
        case .binary:
            return .bytes(bytes)
        default:
            let text = String(decoding: bytes, as: UTF8.self)
            if type == 4 || type == 5, let number = Double(text), number.isFinite { return .double(number) }
            return .text(text)
        }
    }

    /// A value of the binary protocol, used by prepared statements.
    func value(binary reader: inout ByteReader) -> SQLValue {
        switch type {
        case 1:
            let raw = reader.byte()
            return .integer(isUnsigned ? Int64(raw) : Int64(Int8(bitPattern: raw)))
        case 2, 13:
            let raw = UInt16(truncatingIfNeeded: reader.uintLE(2))
            return .integer(isUnsigned ? Int64(raw) : Int64(Int16(bitPattern: raw)))
        case 3, 9:
            let raw = UInt32(truncatingIfNeeded: reader.uintLE(4))
            return .integer(isUnsigned ? Int64(raw) : Int64(Int32(bitPattern: raw)))
        case 8:
            let raw = reader.uintLE(8)
            if isUnsigned, raw > UInt64(Int64.max) { return .text(String(raw)) }
            return .integer(Int64(bitPattern: raw))
        case 4:
            return .double(Double(Float(bitPattern: UInt32(truncatingIfNeeded: reader.uintLE(4)))))
        case 5:
            return .double(Double(bitPattern: reader.uintLE(8)))
        case 7, 10, 12:
            var parts = ByteReader(reader.bytes(Int(reader.byte())))
            let count = parts.remainingCount
            guard count >= 4 else { return .text(type == 10 ? "0000-00-00" : "0000-00-00 00:00:00") }
            var text = String(format: "%04d-%02d-%02d", Int(parts.uintLE(2)), Int(parts.byte()), Int(parts.byte()))
            if type != 10 {
                text += count >= 7
                    ? String(format: " %02d:%02d:%02d", Int(parts.byte()), Int(parts.byte()), Int(parts.byte())) : " 00:00:00"
                if count >= 11 { text += String(format: ".%06d", Int(parts.uintLE(4))) }
            }
            return .text(text)
        case 11:
            var parts = ByteReader(reader.bytes(Int(reader.byte())))
            let count = parts.remainingCount
            guard count >= 8 else { return .text("00:00:00") }
            let negative = parts.byte() == 1
            let hours = Int(parts.uintLE(4)) * 24 + Int(parts.byte())
            var text = String(format: "%@%02d:%02d:%02d", negative ? "-" : "", hours, Int(parts.byte()), Int(parts.byte()))
            if count >= 12 { text += String(format: ".%06d", Int(parts.uintLE(4))) }
            return .text(text)
        default:
            return value(text: reader.lengthEncodedBytes() ?? Data())
        }
    }
}

enum MySQLRow {
    static func text(_ payload: Data, columns: [MySQLColumn]) -> Row {
        var reader = ByteReader(payload)
        return columns.map { column in
            guard let bytes = reader.lengthEncodedBytes() else { return .null }
            return column.value(text: bytes)
        }
    }

    static func binary(_ payload: Data, columns: [MySQLColumn]) -> Row {
        var reader = ByteReader(payload)
        reader.skip(1)
        let bitmap = [UInt8](reader.bytes((columns.count + 9) / 8))
        return columns.enumerated().map { index, column in
            let bit = index + 2
            if bit / 8 < bitmap.count, bitmap[bit / 8] & (1 << UInt8(bit % 8)) != 0 { return .null }
            return column.value(binary: &reader)
        }
    }

    /// The payload of COM_STMT_EXECUTE: every parameter is sent with its own type.
    static func execute(statement: UInt32, parameters: [SQLValue]) -> Data {
        var body = Data([0x17])
        body.appendLE(UInt64(statement), bytes: 4)
        body.append(0)
        body.appendLE(1, bytes: 4)
        guard !parameters.isEmpty else { return body }
        var nulls = [UInt8](repeating: 0, count: (parameters.count + 7) / 8)
        var types = Data()
        var values = Data()
        for (index, parameter) in parameters.enumerated() {
            switch parameter {
            case .null, .deferredBytes:
                nulls[index / 8] |= 1 << UInt8(index % 8)
                types.append(contentsOf: [0x06, 0x00])
            case .integer(let number):
                types.append(contentsOf: [0x08, 0x00])
                values.appendLE(UInt64(bitPattern: number), bytes: 8)
            case .double(let number):
                types.append(contentsOf: [0x05, 0x00])
                values.appendLE(number.bitPattern, bytes: 8)
            case .bool(let flag):
                types.append(contentsOf: [0x01, 0x00])
                values.append(flag ? 1 : 0)
            case .text(let text):
                types.append(contentsOf: [0xFD, 0x00])
                MySQLPacket.appendLengthEncoded(Data(text.utf8), to: &values)
            case .bytes(let data):
                types.append(contentsOf: [0xFC, 0x00])
                MySQLPacket.appendLengthEncoded(data, to: &values)
            }
        }
        body.append(contentsOf: nulls)
        body.append(1)
        body.append(types)
        body.append(values)
        return body
    }
}

enum MySQLAuth {
    static func scramble(plugin: String, password: String, salt: Data) -> Data? {
        guard !password.isEmpty else { return Data() }
        let bytes = Data(password.utf8)
        switch plugin {
        case "caching_sha2_password":
            let first = Data(SHA256.hash(data: bytes))
            let second = Data(SHA256.hash(data: Data(SHA256.hash(data: first)) + salt))
            return Data(zip(first, second).map { $0 ^ $1 })
        case "mysql_native_password":
            let first = Data(Insecure.SHA1.hash(data: bytes))
            let second = Data(Insecure.SHA1.hash(data: salt + Data(Insecure.SHA1.hash(data: first))))
            return Data(zip(first, second).map { $0 ^ $1 })
        default:
            return nil
        }
    }

    /// The password, XORed with the salt and encrypted with the server's RSA key: the full
    /// `caching_sha2_password` exchange on a connection without TLS.
    static func encrypt(password: String, salt: Data, publicKeyPEM: String) -> Data? {
        let base64 = publicKeyPEM.split(whereSeparator: \.isNewline).filter { !$0.hasPrefix("-----") }.joined()
        guard !salt.isEmpty, let der = Data(base64Encoded: base64) else { return nil }
        let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPublic]
        guard let key = SecKeyCreateWithData(der as CFData, attributes as CFDictionary, nil) else { return nil }
        let plain = Data(password.utf8) + [0]
        let masked = Data(plain.enumerated().map { $0.element ^ salt[salt.startIndex + $0.offset % salt.count] })
        return SecKeyCreateEncryptedData(key, .rsaEncryptionOAEPSHA1, masked as CFData, nil) as Data?
    }
}
