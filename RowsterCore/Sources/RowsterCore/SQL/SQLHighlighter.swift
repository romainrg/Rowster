import Foundation

public enum SyntaxClass: Sendable, Equatable {
    case keyword, string, number, comment, quotedIdentifier, parameter
}

public struct SyntaxSpan: Equatable, Sendable {
    public let range: Range<String.Index>
    public let kind: SyntaxClass
}

/// Finds what to color in SQL text. It uses the tokenizer of the dialect, so a keyword inside a string
/// or a comment is never colored as a keyword.
public struct SQLHighlighter: Sendable {
    public let dialect: any SQLDialect
    private let keywords: Set<String>

    public init(dialect: any SQLDialect) {
        self.dialect = dialect
        keywords = SQLKeywords.keywords(for: dialect.engine)
    }

    public func spans(in text: String) -> [SyntaxSpan] {
        dialect.tokenizer.tokenize(text).compactMap { token in
            switch token.kind {
            case .comment, .executableComment: return SyntaxSpan(range: token.range, kind: .comment)
            case .string: return SyntaxSpan(range: token.range, kind: .string)
            case .number: return SyntaxSpan(range: token.range, kind: .number)
            case .quotedIdentifier: return SyntaxSpan(range: token.range, kind: .quotedIdentifier)
            case .parameter: return SyntaxSpan(range: token.range, kind: .parameter)
            case .word:
                return keywords.contains(text[token.range].uppercased()) ? SyntaxSpan(range: token.range, kind: .keyword) : nil
            case .whitespace, .punctuation: return nil
            }
        }
    }
}

public enum SQLKeywords {
    public static func keywords(for engine: Engine) -> Set<String> {
        switch engine {
        case .postgres: return common.union(postgres)
        case .mysql, .mariadb: return common.union(mysql)
        case .sqlite: return common.union(sqlite)
        }
    }

    static let common: Set<String> = [
        "ADD", "ALL", "ALTER", "AND", "ANY", "AS", "ASC", "BEGIN", "BETWEEN", "BY", "CASCADE", "CASE", "CAST", "CHECK",
        "COLUMN", "COMMIT", "CONSTRAINT", "CREATE", "CROSS", "CURRENT_DATE", "CURRENT_TIME", "CURRENT_TIMESTAMP",
        "DATABASE", "DEFAULT", "DELETE", "DESC", "DISTINCT", "DROP", "ELSE", "END", "EXCEPT", "EXISTS", "EXPLAIN",
        "FALSE", "FOREIGN", "FROM", "FULL", "FUNCTION", "GRANT", "GROUP", "HAVING", "IF", "IN", "INDEX", "INNER",
        "INSERT", "INTERSECT", "INTO", "IS", "JOIN", "KEY", "LEFT", "LIKE", "LIMIT", "NOT", "NULL", "OFFSET", "ON",
        "OR", "ORDER", "OUTER", "OVER", "PARTITION", "PRIMARY", "PROCEDURE", "RECURSIVE", "REFERENCES", "RELEASE",
        "RENAME", "REVOKE", "RIGHT", "ROLLBACK", "SAVEPOINT", "SCHEMA", "SELECT", "SET", "TABLE", "THEN", "TO",
        "TRANSACTION", "TRIGGER", "TRUE", "TRUNCATE", "UNION", "UNIQUE", "UPDATE", "USING", "VALUES", "VIEW", "WHEN",
        "WHERE", "WINDOW", "WITH"
    ]

    static let postgres: Set<String> = [
        "ANALYZE", "ARRAY", "CONCURRENTLY", "COPY", "DO", "FETCH", "FILTER", "ILIKE", "LANGUAGE", "LATERAL", "MATERIALIZED",
        "NULLS", "ONLY", "RETURNING", "RETURNS", "SEQUENCE", "SERIAL", "SIMILAR", "TABLESPACE", "VACUUM", "VERBOSE"
    ]

    static let mysql: Set<String> = [
        "AUTO_INCREMENT", "CALL", "CHANGE", "CHARSET", "COLLATE", "DELIMITER", "DESCRIBE", "DUPLICATE", "ENGINE", "IGNORE",
        "KILL", "LOCK", "MODIFY", "REGEXP", "REPLACE", "SHOW", "STRAIGHT_JOIN", "UNLOCK", "UNSIGNED", "USE", "ZEROFILL"
    ]

    static let sqlite: Set<String> = [
        "ABORT", "ATTACH", "AUTOINCREMENT", "CONFLICT", "DETACH", "FAIL", "GLOB", "IGNORE", "INDEXED", "PRAGMA", "REPLACE",
        "RETURNING", "ROWID", "STRICT", "TEMP", "TEMPORARY", "VACUUM", "VIRTUAL", "WITHOUT"
    ]
}
