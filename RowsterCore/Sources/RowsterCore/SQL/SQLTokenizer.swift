import Foundation

public struct SQLToken: Equatable, Sendable {
    public enum Kind: Sendable {
        case whitespace, comment
        /// MySQL `/*! ... */`: a comment whose content the server executes.
        case executableComment
        case word, quotedIdentifier, string, number, parameter, punctuation
    }

    public let kind: Kind
    public let range: Range<String.Index>
    /// False for a string, quoted identifier or block comment that reaches the end of the text unclosed.
    public let isTerminated: Bool

    /// Whitespace and plain comments carry no meaning for the splitter and the classifier.
    public var isSignificant: Bool { kind != .whitespace && kind != .comment }
}

/// Splits SQL text into tokens. It never fails: unknown characters become punctuation, and an unclosed
/// string or comment extends to the end of the text.
public struct SQLTokenizer: Sendable {
    public let syntax: SQLSyntax

    public init(syntax: SQLSyntax) { self.syntax = syntax }

    public func tokenize(_ text: String) -> [SQLToken] {
        let scalars = text.unicodeScalars
        let end = scalars.endIndex
        var tokens: [SQLToken] = []
        var index = scalars.startIndex

        func scalar(_ position: String.Index, offsetBy offset: Int = 0) -> Unicode.Scalar? {
            guard let target = scalars.index(position, offsetBy: offset, limitedBy: end), target < end else { return nil }
            return scalars[target]
        }

        func skipToLineEnd(from position: String.Index) -> String.Index {
            var cursor = position
            while cursor < end, scalars[cursor] != "\n" { cursor = scalars.index(after: cursor) }
            return cursor
        }

        /// Scans a quoted run starting at its opening quote. A doubled quote is an escaped quote.
        func scanQuoted(from position: String.Index, quote: Unicode.Scalar, backslash: Bool) -> (String.Index, Bool) {
            var cursor = scalars.index(after: position)
            while cursor < end {
                let current = scalars[cursor]
                if backslash, current == "\\" {
                    cursor = scalars.index(after: cursor)
                    if cursor < end { cursor = scalars.index(after: cursor) }
                    continue
                }
                if current == quote {
                    let after = scalars.index(after: cursor)
                    if after < end, scalars[after] == quote {
                        cursor = scalars.index(after: after)
                        continue
                    }
                    return (after, true)
                }
                cursor = scalars.index(after: cursor)
            }
            return (end, false)
        }

        while index < end {
            let start = index
            let current = scalars[index]
            let next = scalar(index, offsetBy: 1)
            var kind = SQLToken.Kind.punctuation
            var terminated = true

            if current.properties.isWhitespace {
                while index < end, scalars[index].properties.isWhitespace { index = scalars.index(after: index) }
                kind = .whitespace
            } else if current == "-", next == "-", !syntax.dashCommentNeedsSpace || Self.endsDashComment(scalar(index, offsetBy: 2)) {
                index = skipToLineEnd(from: index)
                kind = .comment
            } else if current == "#", syntax.hashComments {
                index = skipToLineEnd(from: index)
                kind = .comment
            } else if current == "/", next == "*" {
                let third = scalar(index, offsetBy: 2)
                let executable = syntax.executableComments
                    && (third == "!" || (third == "M" && scalar(index, offsetBy: 3) == "!"))
                var depth = 1
                index = scalars.index(index, offsetBy: 2)
                terminated = false
                while index < end {
                    let here = scalars[index]
                    let following = scalar(index, offsetBy: 1)
                    if here == "*", following == "/" {
                        depth -= 1
                        index = scalars.index(index, offsetBy: 2)
                        if depth == 0 { terminated = true; break }
                    } else if syntax.nestedComments, here == "/", following == "*" {
                        depth += 1
                        index = scalars.index(index, offsetBy: 2)
                    } else {
                        index = scalars.index(after: index)
                    }
                }
                kind = executable ? .executableComment : .comment
            } else if current == "'" {
                (index, terminated) = scanQuoted(from: index, quote: "'", backslash: syntax.backslashEscapes)
                kind = .string
            } else if current == "\"" {
                (index, terminated) = scanQuoted(
                    from: index, quote: "\"", backslash: syntax.doubleQuoteIsString && syntax.backslashEscapes)
                kind = syntax.doubleQuoteIsString ? .string : .quotedIdentifier
            } else if current == "`", syntax.backtickIdentifiers {
                (index, terminated) = scanQuoted(from: index, quote: "`", backslash: false)
                kind = .quotedIdentifier
            } else if current == "[", syntax.bracketIdentifiers {
                index = scalars.index(after: index)
                terminated = false
                while index < end {
                    let here = scalars[index]
                    index = scalars.index(after: index)
                    if here == "]" { terminated = true; break }
                }
                kind = .quotedIdentifier
            } else if current == "$", syntax.dollarQuoting, let tagEnd = Self.dollarTagEnd(in: scalars, from: index) {
                let tag = String(scalars[index...tagEnd])
                let bodyStart = scalars.index(after: tagEnd)
                if let closing = text.range(of: tag, range: bodyStart..<end) {
                    index = closing.upperBound
                } else {
                    index = end
                    terminated = false
                }
                kind = .string
            } else if current == "$", let digit = next, Self.isDigit(digit) {
                index = scalars.index(after: index)
                while index < end, Self.isDigit(scalars[index]) { index = scalars.index(after: index) }
                kind = .parameter
            } else if Self.isDigit(current) || (current == "." && next.map(Self.isDigit) == true) {
                index = scalars.index(after: index)
                while index < end {
                    let here = scalars[index]
                    if Self.isDigit(here) || Self.isLetter(here) || here == "." || here == "_" {
                        index = scalars.index(after: index)
                    } else if here == "+" || here == "-", let previous = scalar(index, offsetBy: -1),
                              previous == "e" || previous == "E", scalar(index, offsetBy: 1).map(Self.isDigit) == true {
                        index = scalars.index(after: index)
                    } else {
                        break
                    }
                }
                kind = .number
            } else if Self.isWordStart(current) {
                index = scalars.index(after: index)
                while index < end, Self.isWordPart(scalars[index]) { index = scalars.index(after: index) }
                kind = .word
                // PostgreSQL E'...' strings use backslash escapes.
                if syntax.escapeStringPrefix, index < end, scalars[index] == "'",
                   scalars.distance(from: start, to: index) == 1, current == "E" || current == "e" {
                    (index, terminated) = scanQuoted(from: index, quote: "'", backslash: true)
                    kind = .string
                }
            } else {
                index = scalars.index(after: index)
            }

            tokens.append(SQLToken(kind: kind, range: start..<index, isTerminated: terminated))
        }
        return tokens
    }

    // MARK: - Character classes

    private static func endsDashComment(_ scalar: Unicode.Scalar?) -> Bool {
        guard let scalar else { return true }
        return scalar.properties.isWhitespace || scalar.value < 0x20
    }

    static func isDigit(_ scalar: Unicode.Scalar) -> Bool { scalar.value >= 0x30 && scalar.value <= 0x39 }

    static func isLetter(_ scalar: Unicode.Scalar) -> Bool {
        (scalar.value >= 0x41 && scalar.value <= 0x5A) || (scalar.value >= 0x61 && scalar.value <= 0x7A)
    }

    static func isWordStart(_ scalar: Unicode.Scalar) -> Bool {
        isLetter(scalar) || scalar == "_" || scalar == "@" || scalar.value >= 0x80
    }

    static func isWordPart(_ scalar: Unicode.Scalar) -> Bool {
        isWordStart(scalar) || isDigit(scalar) || scalar == "$"
    }

    /// Index of the `$` closing a dollar-quote tag (`$$` or `$tag$`) that starts at `start`, if there is one.
    private static func dollarTagEnd(in scalars: String.UnicodeScalarView, from start: String.Index) -> String.Index? {
        var cursor = scalars.index(after: start)
        var isFirst = true
        while cursor < scalars.endIndex {
            let here = scalars[cursor]
            if here == "$" { return cursor }
            guard isLetter(here) || here == "_" || here.value >= 0x80 || (!isFirst && isDigit(here)) else { return nil }
            isFirst = false
            cursor = scalars.index(after: cursor)
        }
        return nil
    }
}

public extension SQLToken {
    /// Uppercased text of a word token, for keyword comparison.
    func keyword(in text: String) -> String? {
        kind == .word ? text[range].uppercased() : nil
    }
}
