import Foundation

public enum FilterOperator: String, CaseIterable, Codable, Sendable {
    case equals, notEquals, lessThan, lessOrEqual, greaterThan, greaterOrEqual
    case contains, startsWith, endsWith, isIn, between, isNull, isNotNull

    public var needsValue: Bool { self != .isNull && self != .isNotNull }
    public var needsSecondValue: Bool { self == .between }
    var isPattern: Bool { self == .contains || self == .startsWith || self == .endsWith }
}

public enum FilterMatch: String, Codable, Sendable {
    case all, any
}

/// One row of the filter bar.
public struct FilterCondition: Identifiable, Hashable, Sendable {
    public enum Target: Hashable, Sendable {
        case column(String)
        /// Every non-binary column; only with `contains`.
        case anyColumn
        /// A condition the user wrote by hand. It is SQL, shown as such, and sent as written.
        case rawSQL
    }

    public var id: UUID
    public var isEnabled: Bool
    public var target: Target
    public var op: FilterOperator
    public var value: String
    public var secondValue: String

    public init(
        id: UUID = UUID(), isEnabled: Bool = true, target: Target, op: FilterOperator = .equals, value: String = "",
        secondValue: String = ""
    ) {
        self.id = id
        self.isEnabled = isEnabled
        self.target = target
        self.op = op
        self.value = value
        self.secondValue = secondValue
    }
}

public enum FilterError: Error, Equatable, Sendable {
    case unknownColumn(String)
    case missingValue
    /// A hand-written condition that would not stay inside its parentheses.
    case unsafeRawSQL
}

/// Turns the filter bar into the body of a WHERE clause. Column names are quoted by the dialect and
/// every value is a bound parameter; only a raw condition, written by the user, is sent as text.
public struct FilterBuilder: Sendable {
    public let columns: [ColumnDescription]
    public let dialect: any SQLDialect

    public init(columns: [ColumnDescription], dialect: any SQLDialect) {
        self.columns = columns
        self.dialect = dialect
    }

    /// `nil` when no condition is enabled.
    public func build(_ conditions: [FilterCondition], match: FilterMatch = .all) throws -> SQLFragment? {
        var parts: [String] = []
        var parameters: [SQLValue] = []
        for condition in conditions where condition.isEnabled {
            parts.append("(" + (try sql(for: condition, parameters: &parameters)) + ")")
        }
        guard !parts.isEmpty else { return nil }
        return SQLFragment(sql: parts.joined(separator: match == .all ? " AND " : " OR "), parameters: parameters)
    }

    private func sql(for condition: FilterCondition, parameters: inout [SQLValue]) throws -> String {
        switch condition.target {
        case .rawSQL:
            return try checkedRaw(condition.value)
        case .anyColumn:
            guard !condition.value.isEmpty else { throw FilterError.missingValue }
            let searchable = columns.filter { $0.kind != .binary }
            guard !searchable.isEmpty else { throw FilterError.missingValue }
            return searchable.map { pattern($0, op: .contains, value: condition.value, parameters: &parameters) }
                .joined(separator: " OR ")
        case .column(let name):
            guard let column = columns.first(where: { $0.name == name }) else { throw FilterError.unknownColumn(name) }
            return try sql(column: column, condition: condition, parameters: &parameters)
        }
    }

    private func sql(column: ColumnDescription, condition: FilterCondition, parameters: inout [SQLValue]) throws -> String {
        let quoted = dialect.quote(identifier: column.name)
        func bind(_ text: String) -> String {
            parameters.append(typed(text, for: column))
            return dialect.placeholder(parameters.count)
        }

        switch condition.op {
        case .isNull: return "\(quoted) IS NULL"
        case .isNotNull: return "\(quoted) IS NOT NULL"
        case .equals: return "\(quoted) = \(bind(condition.value))"
        case .notEquals: return "\(quoted) <> \(bind(condition.value))"
        case .lessThan: return "\(quoted) < \(bind(condition.value))"
        case .lessOrEqual: return "\(quoted) <= \(bind(condition.value))"
        case .greaterThan: return "\(quoted) > \(bind(condition.value))"
        case .greaterOrEqual: return "\(quoted) >= \(bind(condition.value))"
        case .between:
            guard !condition.value.isEmpty, !condition.secondValue.isEmpty else { throw FilterError.missingValue }
            return "\(quoted) BETWEEN \(bind(condition.value)) AND \(bind(condition.secondValue))"
        case .isIn:
            let items = condition.value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            guard !items.isEmpty else { throw FilterError.missingValue }
            return "\(quoted) IN (\(items.map(bind).joined(separator: ", ")))"
        case .contains, .startsWith, .endsWith:
            guard !condition.value.isEmpty else { throw FilterError.missingValue }
            return pattern(column, op: condition.op, value: condition.value, parameters: &parameters)
        }
    }

    /// A LIKE match in which `%`, `_` and the escape character of the user's text are literal.
    private func pattern(_ column: ColumnDescription, op: FilterOperator, value: String, parameters: inout [SQLValue]) -> String {
        var escaped = ""
        for character in value {
            if character == "!" || character == "%" || character == "_" { escaped.append("!") }
            escaped.append(character)
        }
        switch op {
        case .startsWith: escaped += "%"
        case .endsWith: escaped = "%" + escaped
        default: escaped = "%" + escaped + "%"
        }
        parameters.append(.text(escaped))
        let quoted = dialect.quote(identifier: column.name)
        let operand = column.kind == .text ? quoted : dialect.textCast(quoted)
        return "\(operand) \(dialect.caseInsensitiveLike) \(dialect.placeholder(parameters.count)) ESCAPE '!'"
    }

    private func typed(_ text: String, for column: ColumnDescription) -> SQLValue {
        SQLValue.typed(text, as: column.kind)
    }

    /// A raw condition is refused when it could end the WHERE clause it is placed in: a semicolon,
    /// an unbalanced parenthesis, an unclosed string or comment, or an executable comment.
    private func checkedRaw(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw FilterError.missingValue }
        var depth = 0
        for token in dialect.tokenizer.tokenize(trimmed) {
            guard token.isTerminated, token.kind != .executableComment else { throw FilterError.unsafeRawSQL }
            guard token.kind == .punctuation else { continue }
            switch trimmed[token.range] {
            case ";": throw FilterError.unsafeRawSQL
            case "(": depth += 1
            case ")":
                depth -= 1
                if depth < 0 { throw FilterError.unsafeRawSQL }
            default: break
            }
        }
        guard depth == 0 else { throw FilterError.unsafeRawSQL }
        // The line break keeps a trailing `--` comment from swallowing the closing parenthesis.
        return trimmed + "\n"
    }
}

public extension SQLFragment {
    /// The statement with its values written in place of the placeholders, **for display only**: this is
    /// what "Show SQL" and the change preview print. It is never sent to a server.
    func inlinedForDisplay(dialect: any SQLDialect) -> String {
        let tokens = dialect.tokenizer.tokenize(sql)
        var out = ""
        var next = 0
        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            let text = sql[token.range]
            if token.kind == .parameter, let number = Int(text.dropFirst()), parameters.indices.contains(number - 1) {
                out += dialect.literalForDisplay(parameters[number - 1])
            } else if token.kind == .punctuation, text == "?", dialect.engine != .postgres {
                var position = next
                if index + 1 < tokens.count, tokens[index + 1].kind == .number, let number = Int(sql[tokens[index + 1].range]) {
                    position = number - 1
                    index += 1
                } else {
                    next += 1
                }
                out += parameters.indices.contains(position) ? dialect.literalForDisplay(parameters[position]) : "?"
            } else {
                out += text
            }
            index += 1
        }
        return out
    }
}
