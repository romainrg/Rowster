import Foundation

/// Reads `information_schema`. Names are bound parameters, sent through prepared statements.
struct MySQLIntrospector: SchemaIntrospecting {
    let driver: any DatabaseDriver

    private static let tableMatch = "table_schema = COALESCE(?, DATABASE()) AND table_name = ?"

    private func parameters(_ table: TableRef) -> [SQLValue] {
        [table.schema.map(SQLValue.text) ?? .null, .text(table.name)]
    }

    func databases() async throws -> [String] {
        let result = try await driver.query(
            """
            SELECT schema_name FROM information_schema.schemata
            WHERE schema_name NOT IN ('information_schema', 'performance_schema', 'mysql', 'sys') ORDER BY schema_name
            """, limit: 10_000)
        return result.rows.compactMap { $0.first?.displayText }
    }

    func namespaces() async throws -> [SchemaNamespace] {
        var namespace = SchemaNamespace(name: nil)
        let tables = try await driver.query(
            "SELECT table_name, table_type FROM information_schema.tables WHERE table_schema = DATABASE() ORDER BY table_name",
            limit: 200_000)
        for row in tables.rows {
            guard let name = row[0].displayText else { continue }
            if row[1].displayText == "VIEW" { namespace.views.append(name) } else { namespace.tables.append(name) }
        }
        let routines = try await driver.query(
            "SELECT DISTINCT routine_name FROM information_schema.routines WHERE routine_schema = DATABASE() ORDER BY routine_name",
            limit: 50_000)
        namespace.functions = routines.rows.compactMap { $0.first?.displayText }
        return [namespace]
    }

    func describe(_ table: TableRef) async throws -> TableDescription {
        let parameters = parameters(table)
        let found = try await driver.query(
            "SELECT table_type FROM information_schema.tables WHERE \(Self.tableMatch)", parameters: parameters)
        guard let type = found.rows.first?.first?.displayText else {
            throw DatabaseError(message: "Table '\(table.displayName)' doesn't exist", code: "1146")
        }
        let isView = type == "VIEW"

        let columnRows = try await driver.query(
            """
            SELECT column_name, column_type, is_nullable, column_default, extra, data_type
            FROM information_schema.columns WHERE \(Self.tableMatch) ORDER BY ordinal_position
            """, parameters: parameters, limit: 5000)
        var columns = columnRows.rows.compactMap { row -> ColumnDescription? in
            guard let name = row[0].displayText else { return nil }
            let extra = (row[4].displayText ?? "").uppercased()
            return ColumnDescription(
                name: name, typeName: row[1].displayText ?? "", kind: Self.kind(dataType: row[5].displayText ?? "", columnType: row[1].displayText ?? ""),
                isNullable: row[2].displayText == "YES", defaultValue: row[3].displayText,
                isGenerated: extra.contains("GENERATED") || extra.contains("VIRTUAL") || extra.contains("PERSISTENT"))
        }

        let indexRows = try await driver.query(
            """
            SELECT index_name, non_unique, column_name FROM information_schema.statistics
            WHERE \(Self.tableMatch) ORDER BY index_name, seq_in_index
            """, parameters: parameters, limit: 5000)
        var indexes: [IndexDescription] = []
        for row in indexRows.rows {
            guard let name = row[0].displayText, let column = row[2].displayText else { continue }
            if let last = indexes.indices.last, indexes[last].name == name {
                indexes[last].columns.append(column)
            } else {
                indexes.append(IndexDescription(
                    name: name, columns: [column], isUnique: row[1].displayText == "0", isPrimary: name == "PRIMARY"))
            }
        }
        if let primary = indexes.first(where: \.isPrimary) {
            for (position, member) in primary.columns.enumerated() {
                if let index = columns.firstIndex(where: { $0.name == member }) { columns[index].primaryKeyPosition = position + 1 }
            }
        }
        indexes.sort { $0.isPrimary && !$1.isPrimary }

        let keyRows = try await driver.query(
            """
            SELECT constraint_name, column_name, referenced_table_schema, referenced_table_name, referenced_column_name
            FROM information_schema.key_column_usage
            WHERE \(Self.tableMatch) AND referenced_table_name IS NOT NULL ORDER BY constraint_name, ordinal_position
            """, parameters: parameters, limit: 5000)
        var foreignKeys: [ForeignKeyDescription] = []
        for row in keyRows.rows {
            guard let name = row[0].displayText, let column = row[1].displayText, let target = row[3].displayText else { continue }
            if let last = foreignKeys.indices.last, foreignKeys[last].name == name {
                foreignKeys[last].columns.append(column)
                if let referenced = row[4].displayText { foreignKeys[last].referencedColumns.append(referenced) }
            } else {
                // A reference into the same database keeps no schema, so that it follows a database switch.
                let schema = row[2].displayText == table.schema ? table.schema : nil
                foreignKeys.append(ForeignKeyDescription(
                    name: name, columns: [column], referencedTable: TableRef(schema: schema, name: target),
                    referencedColumns: row[4].displayText.map { [$0] } ?? []))
            }
        }

        let create = try? await driver.query("SHOW CREATE TABLE \(driver.dialect.qualified(schema: table.schema, name: table.name))")
        let ddl = create?.rows.first.flatMap { $0.count > 1 ? $0[1].displayText : nil }

        return TableDescription(
            ref: table, kind: isView ? .view : .table, columns: columns, indexes: indexes, foreignKeys: foreignKeys, ddl: ddl)
    }

    func estimatedRowCount(_ table: TableRef) async throws -> Int? {
        let result = try await driver.query(
            "SELECT table_rows FROM information_schema.tables WHERE \(Self.tableMatch) AND table_type = 'BASE TABLE'",
            parameters: parameters(table))
        switch result.rows.first?.first {
        case .integer(let rows)?: return Int(rows)
        case .text(let text)?: return Int(text)
        default: return nil
        }
    }

    static func kind(dataType: String, columnType: String) -> ColumnKind {
        let type = dataType.lowercased()
        if columnType.lowercased() == "tinyint(1)" { return .boolean }
        switch type {
        case "tinyint", "smallint", "mediumint", "int", "integer", "bigint", "year": return .integer
        case "decimal", "numeric", "float", "double", "real": return .decimal
        case "date", "datetime", "timestamp", "time": return .date
        case "json": return .json
        case "binary", "varbinary", "tinyblob", "blob", "mediumblob", "longblob", "geometry": return .binary
        case "char", "varchar", "tinytext", "text", "mediumtext", "longtext", "enum", "set": return .text
        case "bool", "boolean": return .boolean
        default: return .other
        }
    }
}
