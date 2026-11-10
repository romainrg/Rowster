import Foundation

/// Reads fields from the bytes a server sent. It never traps on short or malformed input: a read past
/// the end returns zero or an empty value and leaves the reader at the end.
struct ByteReader {
    private let bytes: [UInt8]
    private(set) var offset = 0

    init(_ data: Data) { bytes = [UInt8](data) }

    var isAtEnd: Bool { offset >= bytes.count }
    var remainingCount: Int { max(0, bytes.count - offset) }
    var peek: UInt8? { offset < bytes.count ? bytes[offset] : nil }

    mutating func byte() -> UInt8 {
        guard offset < bytes.count else { return 0 }
        defer { offset += 1 }
        return bytes[offset]
    }

    mutating func bytes(_ count: Int) -> Data {
        let end = min(bytes.count, offset + max(0, count))
        defer { offset = end }
        return Data(bytes[offset..<end])
    }

    mutating func remaining() -> Data { bytes(remainingCount) }

    mutating func skip(_ count: Int) { offset = min(bytes.count, offset + max(0, count)) }

    /// Big-endian, as PostgreSQL sends integers.
    mutating func uintBE(_ count: Int) -> UInt64 {
        var value: UInt64 = 0
        for _ in 0..<count { value = value << 8 | UInt64(byte()) }
        return value
    }

    mutating func int32BE() -> Int32 { Int32(truncatingIfNeeded: uintBE(4)) }
    mutating func int16BE() -> Int16 { Int16(truncatingIfNeeded: uintBE(2)) }

    /// Little-endian, as MySQL sends integers.
    mutating func uintLE(_ count: Int) -> UInt64 {
        var value: UInt64 = 0
        for index in 0..<count { value |= UInt64(byte()) << (8 * UInt64(index)) }
        return value
    }

    /// Bytes up to the next NUL, which is consumed.
    mutating func cString() -> String {
        var end = offset
        while end < bytes.count, bytes[end] != 0 { end += 1 }
        defer { offset = min(bytes.count, end + 1) }
        return String(decoding: bytes[offset..<end], as: UTF8.self)
    }
}

extension Data {
    mutating func appendBE(_ value: Int32) { Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) } }
    mutating func appendBE(_ value: Int16) { Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) } }
    mutating func appendCString(_ value: String) {
        append(contentsOf: value.utf8.filter { $0 != 0 })
        append(0)
    }
    mutating func appendLE(_ value: UInt64, bytes count: Int) {
        for index in 0..<count { append(UInt8(truncatingIfNeeded: value >> (8 * UInt64(index)))) }
    }

    var hexString: String { map { String(format: "%02x", $0) }.joined() }

    init?(hex: Substring) {
        guard hex.count % 2 == 0 else { return nil }
        var out = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            out.append(byte)
            index = next
        }
        self = out
    }
}

/// What a network driver needs to reach its server.
public struct ServerConfiguration: Sendable, Equatable {
    public var endpoint: TransportEndpoint
    public var tls: TLSSettings
    public var user: String
    public var password: String?
    public var database: String

    public init(endpoint: TransportEndpoint, tls: TLSSettings, user: String, password: String?, database: String) {
        self.endpoint = endpoint
        self.tls = tls
        self.user = user
        self.password = password
        self.database = database
    }

    /// A Unix socket never leaves the machine, so a clear-text password is acceptable on it.
    var isLocalSocket: Bool {
        if case .unix = endpoint { return true }
        return false
    }
}
