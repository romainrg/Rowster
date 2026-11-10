import Foundation

/// What a statement would do, decided from its text before it is sent.
public struct StatementInfo: Equatable, Sendable {
    public enum Kind: Sendable {
        /// Only whitespace and comments.
        case empty
        case read, write, transaction, session
        /// Not recognised. Refused on a read-only connection.
        case unknown
    }

    public enum Hazard: Sendable {
        case drop, truncate, deleteWithoutWhere, updateWithoutWhere
    }

    public var kind: Kind
    /// Set when the statement must be confirmed before it runs.
    public var hazard: Hazard?
    /// True when the statement would make a read-only session writable again.
    public var liftsReadOnly: Bool
    /// First keyword, uppercased.
    public var verb: String

    public init(kind: Kind, hazard: Hazard? = nil, liftsReadOnly: Bool = false, verb: String = "") {
        self.kind = kind
        self.hazard = hazard
        self.liftsReadOnly = liftsReadOnly
        self.verb = verb
    }

    /// Whether a read-only connection may send this statement. The server-side read-only session is the
    /// first layer; this is the second, and it fails closed on anything it does not recognise.
    public var isAllowedWhenReadOnly: Bool {
        guard !liftsReadOnly else { return false }
        switch kind {
        case .empty, .read, .transaction, .session: return true
        case .write, .unknown: return false
        }
    }
}

/// Classifies one statement. It guards against accidents; it is not a security boundary.
public struct StatementClassifier: Sendable {
    public let syntax: SQLSyntax

    public init(syntax: SQLSyntax) { self.syntax = syntax }

    private struct Item {
        let word: String?
        let symbol: Character?
        let depth: Int
    }

    private static let readVerbs: Set<String> = ["SHOW", "DESCRIBE", "DESC"]
    private static let writeVerbs: Set<String> = [
        "INSERT", "UPDATE", "DELETE", "MERGE", "REPLACE", "UPSERT", "CREATE", "ALTER", "DROP", "TRUNCATE", "RENAME",
        "GRANT", "REVOKE", "COMMENT", "COPY", "VACUUM", "ANALYZE", "ANALYSE", "REINDEX", "CLUSTER", "REFRESH", "CALL",
        "DO", "EXECUTE", "LOCK", "UNLOCK", "LOAD", "IMPORT", "OPTIMIZE", "REPAIR", "INSTALL", "UNINSTALL", "FLUSH",
        "KILL", "ATTACH", "DETACH", "NOTIFY", "HANDLER", "CHECKPOINT", "REASSIGN", "PURGE", "CHANGE", "SECURITY"
    ]
    private static let transactionVerbs: Set<String> = [
        "BEGIN", "START", "COMMIT", "END", "ROLLBACK", "ABORT", "SAVEPOINT", "RELEASE"
    ]
    private static let dataChangingWords: Set<String> = ["INSERT", "UPDATE", "DELETE", "MERGE"]
    private static let mainVerbs: Set<String> = ["SELECT", "VALUES", "TABLE", "INSERT", "UPDATE", "DELETE", "MERGE"]
    private static let readOnlyPragmas: Set<String> = [
        "TABLE_INFO", "TABLE_XINFO", "TABLE_LIST", "INDEX_LIST", "INDEX_INFO", "INDEX_XINFO", "FOREIGN_KEY_LIST",
        "DATABASE_LIST", "COLLATION_LIST", "FUNCTION_LIST", "COMPILE_OPTIONS", "INTEGRITY_CHECK", "QUICK_CHECK",
        "FOREIGN_KEY_CHECK", "PAGE_COUNT", "PAGE_SIZE", "FREELIST_COUNT", "ENCODING"
    ]

    public func classify(_ sql: String) -> StatementInfo {
        let tokens = SQLTokenizer(syntax: syntax).tokenize(sql).filter(\.isSignificant)
        guard !tokens.isEmpty else { return StatementInfo(kind: .empty) }

        var items: [Item] = []
        var depth = 0
        var hasExecutableComment = false
        for token in tokens {
            switch token.kind {
            case .executableComment:
                hasExecutableComment = true
            case .word:
                items.append(Item(word: sql[token.range].uppercased(), symbol: nil, depth: depth))
            case .punctuation:
                let symbol = sql[token.range].first
                if symbol == ")" { depth = max(0, depth - 1) }
                items.append(Item(word: nil, symbol: symbol, depth: depth))
                if symbol == "(" { depth += 1 }
            default:
                break
            }
        }

        guard let firstWord = items.firstIndex(where: { $0.word != nil }) else {
            return StatementInfo(kind: .unknown)
        }
        var info = classify(Array(items[firstWord...]))
        if hasExecutableComment {
            info = StatementInfo(kind: .unknown, hazard: info.hazard, liftsReadOnly: info.liftsReadOnly, verb: info.verb)
        }
        if items.contains(where: { $0.word == "SET_CONFIG" }) {
            info.liftsReadOnly = true
        }
        return info
    }

    private func classify(_ items: [Item]) -> StatementInfo {
        guard let verb = items.first?.word else { return StatementInfo(kind: .unknown) }
        let words = items.compactMap(\.word)
        let baseDepth = items[0].depth

        func topLevel(_ word: String, after index: Int = 0) -> Bool {
            items[index...].contains { $0.word == word && $0.depth == baseDepth }
        }

        switch verb {
        case "EXPLAIN":
            // EXPLAIN ANALYZE runs the statement, so it is classified as that statement.
            guard let inner = items.dropFirst().firstIndex(where: { item in
                item.depth == baseDepth && item.word.map { Self.mainVerbs.contains($0) || $0 == "WITH" } == true
            }) else { return StatementInfo(kind: .read, verb: verb) }
            let analyzes = items[..<inner].contains { $0.word == "ANALYZE" || $0.word == "ANALYSE" }
            guard analyzes else { return StatementInfo(kind: .read, verb: verb) }
            var info = classify(Array(items[inner...]))
            info.verb = verb
            return info

        case "SELECT", "VALUES", "TABLE", "WITH":
            let mainIndex = verb == "WITH"
                ? items.dropFirst().firstIndex { $0.depth == baseDepth && $0.word.map(Self.mainVerbs.contains) == true }
                : 0
            let changesData = words.contains(where: Self.dataChangingWords.contains)
            let selectsInto = topLevel("INTO")
            var info = StatementInfo(kind: changesData || selectsInto ? .write : .read, verb: verb)
            if let mainIndex, let main = items[mainIndex].word {
                info.hazard = hazard(of: main, items: items, from: mainIndex, baseDepth: baseDepth)
            }
            return info

        case _ where Self.readVerbs.contains(verb):
            return StatementInfo(kind: .read, verb: verb)

        case "PRAGMA":
            let assigns = items.contains { $0.symbol == "=" }
            let isKnownRead = words.dropFirst().contains(where: Self.readOnlyPragmas.contains)
            return StatementInfo(
                kind: isKnownRead && !assigns ? .read : .unknown,
                liftsReadOnly: words.contains("QUERY_ONLY"), verb: verb)

        case _ where Self.transactionVerbs.contains(verb):
            return StatementInfo(kind: .transaction, liftsReadOnly: words.contains("WRITE"), verb: verb)

        case "SET":
            let lifts = words.contains("WRITE") || words.contains { $0.contains("READ_ONLY") || $0.contains("QUERY_ONLY") }
            return StatementInfo(kind: .session, liftsReadOnly: lifts, verb: verb)

        case "RESET", "DISCARD":
            let lifts = words.contains("ALL") || words.contains { $0.contains("READ_ONLY") }
            return StatementInfo(kind: .session, liftsReadOnly: lifts, verb: verb)

        case "USE":
            return StatementInfo(kind: .session, verb: verb)

        case _ where Self.writeVerbs.contains(verb):
            return StatementInfo(
                kind: .write, hazard: hazard(of: verb, items: items, from: 0, baseDepth: baseDepth), verb: verb)

        default:
            return StatementInfo(kind: .unknown, verb: verb)
        }
    }

    private func hazard(of verb: String, items: [Item], from index: Int, baseDepth: Int) -> StatementInfo.Hazard? {
        func topLevel(_ word: String) -> Bool {
            items[index...].contains { $0.word == word && $0.depth == baseDepth }
        }
        switch verb {
        case "DROP": return .drop
        case "TRUNCATE": return .truncate
        case "ALTER": return topLevel("DROP") ? .drop : nil
        case "DELETE": return topLevel("WHERE") ? nil : .deleteWithoutWhere
        case "UPDATE": return topLevel("WHERE") ? nil : .updateWithoutWhere
        default: return nil
        }
    }
}
