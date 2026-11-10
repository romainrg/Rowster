import Foundation

public enum Engine: String, Codable, CaseIterable, Sendable {
    case postgres, mysql, mariadb, sqlite

    public var dialect: any SQLDialect {
        switch self {
        case .postgres: return PostgresDialect()
        case .mysql, .mariadb: return MySQLDialect(engine: self)
        case .sqlite: return SQLiteDialect()
        }
    }

    public var displayName: String {
        switch self {
        case .postgres: return "PostgreSQL"
        case .mysql: return "MySQL"
        case .mariadb: return "MariaDB"
        case .sqlite: return "SQLite"
        }
    }

    public var defaultPort: Int? {
        switch self {
        case .postgres: return 5432
        case .mysql, .mariadb: return 3306
        case .sqlite: return nil
        }
    }
}

/// Lexical rules that differ between engines.
public struct SQLSyntax: Sendable, Equatable {
    public var backslashEscapes = false
    public var doubleQuoteIsString = false
    public var backtickIdentifiers = false
    public var bracketIdentifiers = false
    public var dollarQuoting = false
    public var escapeStringPrefix = false
    public var hashComments = false
    public var nestedComments = false
    public var dashCommentNeedsSpace = false
    public var executableComments = false
    public var delimiterCommand = false
}

/// Everything engine-specific about writing SQL. A dialect quotes identifiers and names placeholders;
/// it never receives a value: values are always bound.
public protocol SQLDialect: Sendable {
    var engine: Engine { get }
    var syntax: SQLSyntax { get }
    func quote(identifier: String) -> String
    /// Placeholder of the `index`-th bound parameter, starting at 1.
    func placeholder(_ index: Int) -> String
    /// Statements that make the session read-only, run right after connecting.
    var readOnlyStatements: [String] { get }
    var readWriteStatements: [String] { get }
    /// Wraps an expression so that text operators apply to any type.
    func textCast(_ expression: String) -> String
    /// Operator for a case-insensitive pattern match.
    var caseInsensitiveLike: String { get }
    /// Length in bytes of a binary expression, so a grid can show a BLOB's size without loading it.
    func byteLength(_ expression: String) -> String
}

public extension SQLDialect {
    func qualified(schema: String?, name: String) -> String {
        guard let schema, !schema.isEmpty else { return quote(identifier: name) }
        return quote(identifier: schema) + "." + quote(identifier: name)
    }

    func paginated(_ select: String, limit: Int, offset: Int) -> String {
        "\(select) LIMIT \(max(0, limit)) OFFSET \(max(0, offset))"
    }

    var tokenizer: SQLTokenizer { SQLTokenizer(syntax: syntax) }
    var splitter: StatementSplitter { StatementSplitter(syntax: syntax) }
    var classifier: StatementClassifier { StatementClassifier(syntax: syntax) }
}

private func quoted(_ identifier: String, with quote: Character) -> String {
    var out = String(quote)
    for character in identifier where character != "\0" {
        if character == quote { out.append(quote) }
        out.append(character)
    }
    out.append(quote)
    return out
}

public struct PostgresDialect: SQLDialect {
    public init() {}
    public var engine: Engine { .postgres }
    public var syntax: SQLSyntax {
        var syntax = SQLSyntax()
        syntax.dollarQuoting = true
        syntax.escapeStringPrefix = true
        syntax.nestedComments = true
        return syntax
    }
    public func quote(identifier: String) -> String { quoted(identifier, with: "\"") }
    public func placeholder(_ index: Int) -> String { "$\(index)" }
    public var readOnlyStatements: [String] { ["SET SESSION CHARACTERISTICS AS TRANSACTION READ ONLY"] }
    public var readWriteStatements: [String] { ["SET SESSION CHARACTERISTICS AS TRANSACTION READ WRITE"] }
    public func textCast(_ expression: String) -> String { "\(expression)::text" }
    public var caseInsensitiveLike: String { "ILIKE" }
    public func byteLength(_ expression: String) -> String { "octet_length(\(expression))" }
}

public struct MySQLDialect: SQLDialect {
    public let engine: Engine
    public init(engine: Engine = .mysql) { self.engine = engine }
    public var syntax: SQLSyntax {
        var syntax = SQLSyntax()
        syntax.backslashEscapes = true
        syntax.doubleQuoteIsString = true
        syntax.backtickIdentifiers = true
        syntax.hashComments = true
        syntax.dashCommentNeedsSpace = true
        syntax.executableComments = true
        syntax.delimiterCommand = true
        return syntax
    }
    public func quote(identifier: String) -> String { quoted(identifier, with: "`") }
    public func placeholder(_ index: Int) -> String { "?" }
    public var readOnlyStatements: [String] { ["SET SESSION TRANSACTION READ ONLY"] }
    public var readWriteStatements: [String] { ["SET SESSION TRANSACTION READ WRITE"] }
    public func textCast(_ expression: String) -> String { "CAST(\(expression) AS CHAR)" }
    public var caseInsensitiveLike: String { "LIKE" }
    public func byteLength(_ expression: String) -> String { "OCTET_LENGTH(\(expression))" }
}

public struct SQLiteDialect: SQLDialect {
    public init() {}
    public var engine: Engine { .sqlite }
    public var syntax: SQLSyntax {
        var syntax = SQLSyntax()
        syntax.backtickIdentifiers = true
        syntax.bracketIdentifiers = true
        return syntax
    }
    public func quote(identifier: String) -> String { quoted(identifier, with: "\"") }
    public func placeholder(_ index: Int) -> String { "?\(index)" }
    public var readOnlyStatements: [String] { ["PRAGMA query_only = ON"] }
    public var readWriteStatements: [String] { ["PRAGMA query_only = OFF"] }
    public func textCast(_ expression: String) -> String { "CAST(\(expression) AS TEXT)" }
    public var caseInsensitiveLike: String { "LIKE" }
    public func byteLength(_ expression: String) -> String { "length(CAST(\(expression) AS BLOB))" }
}
