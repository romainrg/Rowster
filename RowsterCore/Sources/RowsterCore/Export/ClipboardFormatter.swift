import Foundation

public enum TabularFormat: String, CaseIterable, Sendable {
    case tsv, csv, json, markdown, insert
}

/// Renders rows as text for the clipboard and for exports.
public enum TabularText {
    public static func format(
        columns: [String], rows: [Row], as format: TabularFormat, table: TableRef? = nil, dialect: any SQLDialect
    ) -> String {
        switch format {
        case .tsv:
            return rows.map { row in row.map(tsvField).joined(separator: "\t") }.joined(separator: "\n")
        case .csv:
            return ([csvLine(columns.map(SQLValue.text))] + rows.map(csvLine)).joined(separator: "\n")
        case .json:
            return "[\n" + rows.map { "  " + jsonObject(columns: columns, row: $0) }.joined(separator: ",\n") + "\n]"
        case .markdown:
            let header = "| " + columns.map(markdownField).joined(separator: " | ") + " |"
            let rule = "| " + columns.map { _ in "---" }.joined(separator: " | ") + " |"
            let body = rows.map { row in "| " + row.map { markdownField($0.exportText ?? "") }.joined(separator: " | ") + " |" }
            return ([header, rule] + body).joined(separator: "\n")
        case .insert:
            let target = dialect.qualified(schema: table?.schema, name: table?.name ?? "table")
            let names = columns.map(dialect.quote(identifier:)).joined(separator: ", ")
            return rows.map { row in
                "INSERT INTO \(target) (\(names)) VALUES (\(row.map(dialect.literalForDisplay).joined(separator: ", ")));"
            }.joined(separator: "\n")
        }
    }

    // MARK: - Fields

    private static func tsvField(_ value: SQLValue) -> String {
        (value.exportText ?? "").map { $0 == "\t" || $0.isNewline ? " " : $0 }.reduce(into: "") { $0.append($1) }
    }

    /// One CSV record (RFC 4180). NULL is an empty field; an empty string is `""`, so the two stay distinct.
    public static func csvLine(_ row: Row) -> String {
        row.map { value -> String in
            guard let text = value.exportText else { return "" }
            let needsQuotes = text.isEmpty || text.contains { $0 == "," || $0 == "\"" || $0.isNewline }
                || text.first == " " || text.last == " "
            return needsQuotes ? "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : text
        }.joined(separator: ",")
    }

    /// One JSON object, with keys in column order.
    public static func jsonObject(columns: [String], row: Row) -> String {
        let members = zip(columns, row).map { name, value in "\(jsonString(name)): \(jsonValue(value))" }
        return "{" + members.joined(separator: ", ") + "}"
    }

    static func jsonValue(_ value: SQLValue) -> String {
        switch value {
        case .null, .deferredBytes: return "null"
        case .text(let text): return jsonString(text)
        case .integer(let number): return String(number)
        case .double(let number): return number.isFinite ? String(number) : "null"
        case .bool(let flag): return flag ? "true" : "false"
        case .bytes(let data): return jsonString(data.base64EncodedString())
        }
    }

    static func jsonString(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case _ where scalar.value < 0x20: out += String(format: "\\u%04x", scalar.value)
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }

    private static func markdownField(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "|", with: "\\|")
            .replacingOccurrences(of: "\r\n", with: "<br>")
            .replacingOccurrences(of: "\n", with: "<br>")
    }
}

public extension SQLValue {
    /// The value as text for an export: full text, no byte-count shorthand. `nil` for NULL.
    var exportText: String? {
        switch self {
        case .null: return nil
        case .bytes(let data): return data.base64EncodedString()
        case .deferredBytes: return ""
        default: return displayText
        }
    }
}

public extension SQLDialect {
    /// The SQL literal of a value, **for display and the clipboard only**. Rowster never executes text
    /// built this way: every value it sends to a server is a bound parameter.
    func literalForDisplay(_ value: SQLValue) -> String {
        switch value {
        case .null: return "NULL"
        case .text(let text):
            var escaped = text.replacingOccurrences(of: "'", with: "''")
            if syntax.backslashEscapes { escaped = escaped.replacingOccurrences(of: "\\", with: "\\\\") }
            return "'\(escaped)'"
        case .integer(let number): return String(number)
        case .double(let number): return number.isFinite ? String(number) : "NULL"
        case .bool(let flag):
            if engine == .sqlite { return flag ? "1" : "0" }
            return flag ? "TRUE" : "FALSE"
        case .bytes(let data):
            let hex = data.map { String(format: "%02x", $0) }.joined()
            return engine == .postgres ? "'\\x\(hex)'" : "X'\(hex)'"
        case .deferredBytes: return "NULL /* binary value not loaded */"
        }
    }
}
