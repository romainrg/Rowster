import Foundation

public struct SQLStatement: Equatable, Sendable {
    /// The statement without its delimiter and without surrounding whitespace or comments.
    public let text: String
    public let range: Range<String.Index>
}

/// Cuts a script into statements. It knows comments, strings, dollar-quoting, the `DELIMITER` command of
/// the MySQL client, and the `BEGIN ... END` bodies of triggers and routines.
public struct StatementSplitter: Sendable {
    public let syntax: SQLSyntax

    public init(syntax: SQLSyntax) { self.syntax = syntax }

    private static let routineKinds: Set<String> = ["TRIGGER", "PROCEDURE", "FUNCTION", "EVENT"]
    private static let unbalancedEnds: Set<String> = ["IF", "LOOP", "WHILE", "REPEAT"]

    public func split(_ source: String) -> [SQLStatement] {
        let tokens = SQLTokenizer(syntax: syntax).tokenize(source)
        var statements: [SQLStatement] = []
        var delimiter = ";"
        var start: String.Index?
        var lastEnd = source.startIndex
        var headWords: [String] = []
        var isRoutine = false
        var depth = 0
        var previousWord: String?
        var skipUntil = source.startIndex

        func flush() {
            if let begin = start {
                statements.append(SQLStatement(text: String(source[begin..<lastEnd]), range: begin..<lastEnd))
            }
            start = nil
            headWords = []
            isRoutine = false
            depth = 0
            previousWord = nil
        }

        for (position, token) in tokens.enumerated() {
            guard token.range.lowerBound >= skipUntil, token.isSignificant else { continue }
            let word = token.keyword(in: source)

            if syntax.delimiterCommand, start == nil, word == "DELIMITER" {
                var lineEnd = token.range.upperBound
                while lineEnd < source.endIndex, source[lineEnd] != "\n" { lineEnd = source.index(after: lineEnd) }
                let value = source[token.range.upperBound..<lineEnd].trimmingCharacters(in: .whitespaces)
                if !value.isEmpty { delimiter = value }
                skipUntil = lineEnd
                continue
            }

            let isCodeToken = token.kind == .punctuation || token.kind == .word
            if isCodeToken, depth == 0, source[token.range.lowerBound...].hasPrefix(delimiter) {
                flush()
                skipUntil = source.index(token.range.lowerBound, offsetBy: delimiter.count)
                continue
            }

            if start == nil { start = token.range.lowerBound }
            lastEnd = token.range.upperBound

            guard let word else { continue }
            if headWords.count < 8 {
                headWords.append(word)
                if headWords.first == "CREATE", Self.routineKinds.contains(word) { isRoutine = true }
            }
            guard isRoutine, delimiter == ";" else { continue }
            defer { previousWord = word }
            switch word {
            case "CASE" where previousWord == "END":
                break
            case "BEGIN", "CASE":
                depth += 1
            case "END":
                let following = tokens[(position + 1)...].first { $0.isSignificant }?.keyword(in: source)
                if following.map(Self.unbalancedEnds.contains) != true { depth = max(0, depth - 1) }
            default:
                break
            }
        }
        flush()
        return statements
    }

    /// The statement containing `position`, or the one just before it when the position is between two statements.
    public func statement(at position: String.Index, in source: String) -> SQLStatement? {
        let statements = split(source)
        return statements.last { $0.range.lowerBound <= position } ?? statements.first
    }
}
