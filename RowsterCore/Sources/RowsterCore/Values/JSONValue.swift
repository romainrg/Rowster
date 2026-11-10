import Foundation

/// A parsed JSON document that keeps the order of its keys and the exact text of its numbers,
/// so the inspector shows what is stored rather than a reformatted copy.
public indirect enum JSONValue: Equatable, Sendable {
    case object([Member])
    case array([JSONValue])
    case string(String)
    case number(String)
    case bool(Bool)
    case null

    public struct Member: Equatable, Sendable {
        public let key: String
        public let value: JSONValue
    }

    public var isContainer: Bool {
        switch self {
        case .object, .array: return true
        default: return false
        }
    }

    /// One-line description: the literal of a scalar, or the size of a container.
    public var summary: String {
        switch self {
        case .object(let members): return "{\(members.count)}"
        case .array(let items): return "[\(items.count)]"
        case .string(let text): return "\"\(text)\""
        case .number(let text): return text
        case .bool(let flag): return flag ? "true" : "false"
        case .null: return "null"
        }
    }

    /// `nil` when the text is not exactly one JSON value.
    public static func parse(_ text: String) -> JSONValue? {
        var parser = Parser(scalars: Array(text.unicodeScalars))
        parser.skipWhitespace()
        guard let value = parser.value(depth: 0) else { return nil }
        parser.skipWhitespace()
        return parser.isAtEnd ? value : nil
    }

    private struct Parser {
        let scalars: [Unicode.Scalar]
        var index = 0

        var isAtEnd: Bool { index >= scalars.count }
        var current: Unicode.Scalar? { index < scalars.count ? scalars[index] : nil }

        mutating func skipWhitespace() {
            while let scalar = current, scalar == " " || scalar == "\n" || scalar == "\t" || scalar == "\r" { index += 1 }
        }

        mutating func consume(_ literal: String) -> Bool {
            let expected = Array(literal.unicodeScalars)
            guard index + expected.count <= scalars.count, Array(scalars[index..<index + expected.count]) == expected else {
                return false
            }
            index += expected.count
            return true
        }

        mutating func value(depth: Int) -> JSONValue? {
            guard depth < 200, let scalar = current else { return nil }
            switch scalar {
            case "{": return object(depth: depth)
            case "[": return array(depth: depth)
            case "\"": return string().map(JSONValue.string)
            case "t": return consume("true") ? .bool(true) : nil
            case "f": return consume("false") ? .bool(false) : nil
            case "n": return consume("null") ? .null : nil
            default: return number()
            }
        }

        mutating func object(depth: Int) -> JSONValue? {
            index += 1
            var members: [Member] = []
            skipWhitespace()
            if current == "}" { index += 1; return .object(members) }
            while true {
                skipWhitespace()
                guard current == "\"", let key = string() else { return nil }
                skipWhitespace()
                guard current == ":" else { return nil }
                index += 1
                skipWhitespace()
                guard let value = value(depth: depth + 1) else { return nil }
                members.append(Member(key: key, value: value))
                skipWhitespace()
                if current == "," { index += 1; continue }
                if current == "}" { index += 1; return .object(members) }
                return nil
            }
        }

        mutating func array(depth: Int) -> JSONValue? {
            index += 1
            var items: [JSONValue] = []
            skipWhitespace()
            if current == "]" { index += 1; return .array(items) }
            while true {
                skipWhitespace()
                guard let value = value(depth: depth + 1) else { return nil }
                items.append(value)
                skipWhitespace()
                if current == "," { index += 1; continue }
                if current == "]" { index += 1; return .array(items) }
                return nil
            }
        }

        mutating func string() -> String? {
            index += 1
            var out = String.UnicodeScalarView()
            while let scalar = current {
                index += 1
                if scalar == "\"" { return String(out) }
                if scalar.value < 0x20 { return nil }
                guard scalar == "\\" else { out.append(scalar); continue }
                guard let escape = current else { return nil }
                index += 1
                switch escape {
                case "\"", "\\", "/": out.append(escape)
                case "n": out.append("\n")
                case "t": out.append("\t")
                case "r": out.append("\r")
                case "b": out.append("\u{08}")
                case "f": out.append("\u{0C}")
                case "u":
                    guard let unit = hexUnit() else { return nil }
                    if (0xD800...0xDBFF).contains(unit) {
                        guard consume("\\u"), let low = hexUnit(), (0xDC00...0xDFFF).contains(low),
                              let scalar = Unicode.Scalar(0x10000 + ((unit - 0xD800) << 10) + (low - 0xDC00)) else { return nil }
                        out.append(scalar)
                    } else if let scalar = Unicode.Scalar(unit) {
                        out.append(scalar)
                    } else {
                        return nil
                    }
                default: return nil
                }
            }
            return nil
        }

        mutating func hexUnit() -> UInt32? {
            guard index + 4 <= scalars.count else { return nil }
            var unit: UInt32 = 0
            for scalar in scalars[index..<index + 4] {
                guard let digit = Int(String(scalar), radix: 16) else { return nil }
                unit = unit << 4 | UInt32(digit)
            }
            index += 4
            return unit
        }

        mutating func number() -> JSONValue? {
            let start = index
            func isDigit(_ scalar: Unicode.Scalar?) -> Bool { scalar.map { $0.value >= 0x30 && $0.value <= 0x39 } ?? false }
            if current == "-" { index += 1 }
            guard isDigit(current) else { return nil }
            if current == "0" { index += 1 } else { while isDigit(current) { index += 1 } }
            if current == "." {
                index += 1
                guard isDigit(current) else { return nil }
                while isDigit(current) { index += 1 }
            }
            if current == "e" || current == "E" {
                index += 1
                if current == "+" || current == "-" { index += 1 }
                guard isDigit(current) else { return nil }
                while isDigit(current) { index += 1 }
            }
            var text = String.UnicodeScalarView()
            text.append(contentsOf: scalars[start..<index])
            return .number(String(text))
        }
    }
}
