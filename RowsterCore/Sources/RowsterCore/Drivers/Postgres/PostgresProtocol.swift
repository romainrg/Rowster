import CommonCrypto
import CryptoKit
import Foundation

/// Messages of the PostgreSQL frontend/backend protocol, version 3.
enum PostgresMessage {
    // MARK: - Frontend

    static func startup(user: String, database: String) -> Data {
        var body = Data()
        body.appendBE(Int32(196_608))
        var parameters = [("user", user), ("client_encoding", "UTF8"), ("application_name", "Rowster")]
        if !database.isEmpty { parameters.append(("database", database)) }
        for (key, value) in parameters {
            body.appendCString(key)
            body.appendCString(value)
        }
        body.append(0)
        var message = Data()
        message.appendBE(Int32(body.count + 4))
        message.append(body)
        return message
    }

    static func cancelRequest(processID: Int32, secret: Int32) -> Data {
        var message = Data()
        message.appendBE(Int32(16))
        message.appendBE(Int32(80_877_102))
        message.appendBE(processID)
        message.appendBE(secret)
        return message
    }

    static func frame(_ type: Character, _ build: (inout Data) -> Void = { _ in }) -> Data {
        var body = Data()
        build(&body)
        var message = Data([type.asciiValue ?? 0])
        message.appendBE(Int32(body.count + 4))
        message.append(body)
        return message
    }

    static func password(_ text: String) -> Data { frame("p") { $0.appendCString(text) } }

    static func saslInitial(mechanism: String, response: String) -> Data {
        frame("p") {
            $0.appendCString(mechanism)
            let bytes = Data(response.utf8)
            $0.appendBE(Int32(bytes.count))
            $0.append(bytes)
        }
    }

    static func saslResponse(_ response: String) -> Data { frame("p") { $0.append(Data(response.utf8)) } }

    static func parse(_ sql: String) -> Data {
        frame("P") {
            $0.appendCString("")
            $0.appendCString(sql)
            $0.appendBE(Int16(0))
        }
    }

    /// Binds the unnamed statement to the unnamed portal, every value in text format.
    static func bind(_ parameters: [SQLValue]) -> Data {
        frame("B") {
            $0.appendCString("")
            $0.appendCString("")
            $0.appendBE(Int16(0))
            $0.appendBE(Int16(truncatingIfNeeded: parameters.count))
            for parameter in parameters {
                if let text = text(of: parameter) {
                    let bytes = Data(text.utf8)
                    $0.appendBE(Int32(bytes.count))
                    $0.append(bytes)
                } else {
                    $0.appendBE(Int32(-1))
                }
            }
            $0.appendBE(Int16(0))
        }
    }

    static let describePortal = frame("D") { $0.append(UInt8(ascii: "P")); $0.appendCString("") }
    static let closePortal = frame("C") { $0.append(UInt8(ascii: "P")); $0.appendCString("") }
    static let flush = frame("H")
    static let sync = frame("S")
    static let terminate = frame("X")

    static func execute(maxRows: Int) -> Data {
        frame("E") {
            $0.appendCString("")
            $0.appendBE(Int32(clamping: maxRows))
        }
    }

    /// The text form of a parameter; `nil` for NULL.
    static func text(of value: SQLValue) -> String? {
        switch value {
        case .null, .deferredBytes: return nil
        case .text(let text): return text
        case .integer(let number): return String(number)
        case .double(let number): return String(number)
        case .bool(let flag): return flag ? "true" : "false"
        case .bytes(let data): return "\\x" + data.hexString
        }
    }

    // MARK: - Backend

    /// The fields of an ErrorResponse or NoticeResponse, by their one-letter code.
    static func fields(_ body: Data) -> [Character: String] {
        var reader = ByteReader(body)
        var fields: [Character: String] = [:]
        while let code = reader.peek, code != 0 {
            _ = reader.byte()
            fields[Character(UnicodeScalar(code))] = reader.cString()
        }
        return fields
    }

    static func error(_ body: Data) -> DatabaseError {
        let fields = fields(body)
        return DatabaseError(
            message: fields["M"] ?? "unknown error", code: fields["C"], detail: fields["D"], hint: fields["H"],
            position: fields["P"].flatMap { Int($0) })
    }

    static func columns(_ body: Data) -> [(info: ColumnInfo, type: Int32)] {
        var reader = ByteReader(body)
        let count = Int(reader.int16BE())
        return (0..<max(0, count)).map { _ in
            let name = reader.cString()
            reader.skip(6)
            let type = reader.int32BE()
            reader.skip(8)
            return (ColumnInfo(name: name, typeName: PostgresType.name(type), kind: PostgresType.kind(type)), type)
        }
    }

    static func row(_ body: Data, types: [Int32]) -> Row {
        var reader = ByteReader(body)
        let count = Int(reader.int16BE())
        return (0..<max(0, count)).map { index in
            let length = reader.int32BE()
            guard length >= 0 else { return .null }
            let text = String(decoding: reader.bytes(Int(length)), as: UTF8.self)
            return PostgresType.value(text, type: index < types.count ? types[index] : 0)
        }
    }

    /// Rows affected, from a CommandComplete tag such as `UPDATE 3` or `INSERT 0 5`. `nil` for a SELECT.
    static func rowsAffected(tag: String) -> Int? {
        let words = tag.split(separator: " ")
        guard let verb = words.first, ["INSERT", "UPDATE", "DELETE", "MERGE", "COPY"].contains(verb), let last = words.last else {
            return nil
        }
        return Int(last)
    }
}

/// The few type OIDs Rowster treats specially. Everything else is shown as the text the server sent.
enum PostgresType {
    private static let names: [Int32: String] = [
        16: "bool", 17: "bytea", 18: "char", 19: "name", 20: "int8", 21: "int2", 23: "int4", 25: "text", 26: "oid",
        114: "json", 142: "xml", 700: "float4", 701: "float8", 790: "money", 829: "macaddr", 869: "inet", 650: "cidr",
        1042: "bpchar", 1043: "varchar", 1082: "date", 1083: "time", 1114: "timestamp", 1184: "timestamptz",
        1186: "interval", 1266: "timetz", 1700: "numeric", 2950: "uuid", 3802: "jsonb", 1000: "bool[]", 1005: "int2[]",
        1007: "int4[]", 1009: "text[]", 1015: "varchar[]", 1016: "int8[]", 1021: "float4[]", 1022: "float8[]",
        2951: "uuid[]", 3807: "jsonb[]"
    ]

    static func name(_ type: Int32) -> String { names[type] ?? "" }

    static func kind(_ type: Int32) -> ColumnKind {
        switch type {
        case 16: return .boolean
        case 17: return .binary
        case 20, 21, 23, 26: return .integer
        case 700, 701, 790, 1700: return .decimal
        case 114, 3802: return .json
        case 1082, 1083, 1114, 1184, 1186, 1266: return .date
        case 18, 19, 25, 1042, 1043, 2950: return .text
        default: return .other
        }
    }

    static func value(_ text: String, type: Int32) -> SQLValue {
        switch type {
        case 16: return .bool(text == "t")
        case 20, 21, 23, 26: return Int64(text).map(SQLValue.integer) ?? .text(text)
        case 700, 701:
            if let number = Double(text), number.isFinite { return .double(number) }
            return .text(text)
        case 17:
            if text.hasPrefix("\\x"), let data = Data(hex: text.dropFirst(2)) { return .bytes(data) }
            return .text(text)
        default: return .text(text)
        }
    }
}

/// The client side of SCRAM-SHA-256 (RFC 5802 and 7677), without channel binding.
struct ScramSHA256 {
    let user: String
    let password: String
    let nonce: String
    private(set) var serverSignature = Data()

    init(user: String = "", password: String, nonce: String = ScramSHA256.makeNonce()) {
        self.user = user
        self.password = password
        self.nonce = nonce
    }

    static func makeNonce() -> String {
        Data((0..<18).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
    }

    var clientFirstBare: String { "n=\(user),r=\(nonce)" }
    var clientFirst: String { "n,," + clientFirstBare }

    /// The client-final message for the server's first message, or `nil` when that message is not acceptable.
    mutating func clientFinal(serverFirst: String) -> String? {
        var attributes: [Substring: Substring] = [:]
        for part in serverFirst.split(separator: ",") where part.count >= 2 {
            attributes[part.prefix(1)] = part.dropFirst(2)
        }
        guard let combined = attributes["r"], combined.hasPrefix(nonce), combined.count > nonce.count,
              let salt = attributes["s"].flatMap({ Data(base64Encoded: String($0)) }),
              let iterations = attributes["i"].flatMap({ Int($0) }), iterations > 0 else { return nil }

        let salted = Self.pbkdf2(password, salt: salt, iterations: iterations)
        let clientKey = Self.hmac(salted, "Client Key")
        let storedKey = Data(SHA256.hash(data: clientKey))
        let withoutProof = "c=biws,r=\(combined)"
        let authMessage = "\(clientFirstBare),\(serverFirst),\(withoutProof)"
        let signature = Self.hmac(storedKey, authMessage)
        let proof = Data(zip(clientKey, signature).map { $0 ^ $1 })
        serverSignature = Self.hmac(Self.hmac(salted, "Server Key"), authMessage)
        return "\(withoutProof),p=\(proof.base64EncodedString())"
    }

    /// Whether the server proved it knows the password too.
    func verify(serverFinal: String) -> Bool {
        !serverSignature.isEmpty && serverFinal == "v=\(serverSignature.base64EncodedString())"
    }

    private static func hmac(_ key: Data, _ message: String) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: SymmetricKey(data: key)))
    }

    private static func pbkdf2(_ password: String, salt: Data, iterations: Int) -> Data {
        var derived = [UInt8](repeating: 0, count: 32)
        let passwordBytes = Array(password.utf8CString.dropLast())
        let saltBytes = [UInt8](salt)
        CCKeyDerivationPBKDF(
            CCPBKDFAlgorithm(kCCPBKDF2), passwordBytes, passwordBytes.count, saltBytes, saltBytes.count,
            CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(clamping: iterations), &derived, derived.count)
        return Data(derived)
    }
}

enum PostgresMD5 {
    /// `md5` + md5(md5(password + user) + salt), as the MD5 authentication method expects.
    static func response(user: String, password: String, salt: Data) -> String {
        func hex(_ data: Data) -> String { Data(Insecure.MD5.hash(data: data)).hexString }
        return "md5" + hex(Data(hex(Data((password + user).utf8)).utf8) + salt)
    }
}
