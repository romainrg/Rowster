import Foundation

/// A value read from or sent to a database. Values are always bound as parameters, never written into SQL text.
public enum SQLValue: Hashable, Sendable {
    case null
    case text(String)
    case integer(Int64)
    case double(Double)
    case bool(Bool)
    case bytes(Data)
    /// A binary value that was not loaded; only its length is known.
    case deferredBytes(length: Int)

    public var isNull: Bool { self == .null }

    /// Text shown in a grid cell. `nil` for NULL, so the view can render it distinctly from an empty string.
    public var displayText: String? {
        switch self {
        case .null: return nil
        case .text(let value): return value
        case .integer(let value): return String(value)
        case .double(let value): return String(value)
        case .bool(let value): return value ? "true" : "false"
        case .bytes(let data): return ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)
        case .deferredBytes(let length): return ByteCountFormatter.string(fromByteCount: Int64(length), countStyle: .file)
        }
    }

    public var isBinary: Bool {
        switch self {
        case .bytes, .deferredBytes: return true
        default: return false
        }
    }
}

public typealias Row = [SQLValue]

/// Broad family of a column type, used to pick an editor, an alignment and filter operators.
public enum ColumnKind: String, Sendable, Codable {
    case text, integer, decimal, boolean, date, json, binary, other

    public var isNumeric: Bool { self == .integer || self == .decimal }
}

public struct ColumnInfo: Hashable, Sendable {
    public var name: String
    /// Type name as the server reports it (`int4`, `varchar(255)`, `TEXT`), empty when unknown.
    public var typeName: String
    public var kind: ColumnKind

    public init(name: String, typeName: String = "", kind: ColumnKind = .text) {
        self.name = name
        self.typeName = typeName
        self.kind = kind
    }
}
