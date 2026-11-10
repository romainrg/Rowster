import Foundation

/// Reads the schema of a SQLite database. Names are passed as bound values to the `pragma_*` table
/// functions, never written into the SQL text.
struct SQLiteIntrospector: SchemaIntrospecting {
    let driver: any DatabaseDriver

    func databases() async throws -> [String] { [] }

    func namespaces() async throws -> [SchemaNamespace] {
        let result = try await driver.query(
            "SELECT name, type FROM sqlite_master WHERE type IN ('table', 'view') AND name NOT LIKE 'sqlite\\_%' ESCAPE '\\' ORDER BY name COLLATE NOCASE",
            limit: 100_000)
        var namespace = SchemaNamespace(name: nil)
        for row in result.rows {
            guard case .text(let name) = row[0], case .text(let type) = row[1] else { continue }
            if type == "view" { namespace.views.append(name) } else { namespace.tables.append(name) }
        }
        return [namespace]
    }

    func describe(_ table: TableRef) async throws -> TableDescription {
        let name = SQLValue.text(table.name)
        let master = try await driver.query(
            "SELECT type, sql FROM sqlite_master WHERE name = ?1 AND type IN ('table', 'view')", parameters: [name])
        guard let entry = master.rows.first else {
            throw DatabaseError(message: "no such table: \(table.name)", code: "SQLITE_ERROR")
        }
        let kind: SchemaObjectKind = entry[0] == .text("view") ? .view : .table
        var ddl = entry[1].displayText

        let info = try await driver.query(
            "SELECT name, type, \"notnull\", dflt_value, pk, hidden FROM pragma_table_xinfo(?1) ORDER BY cid", parameters: [name])
        let columns = info.rows.compactMap { row -> ColumnDescription? in
            guard case .text(let column) = row[0] else { return nil }
            let type = row[1].displayText ?? ""
            let position = Self.int(row[4])
            let hidden = Self.int(row[5])
            // hidden: 1 is a virtual-table hidden column, 2 and 3 are generated columns.
            guard hidden != 1 else { return nil }
            return ColumnDescription(
                name: column, typeName: type, kind: SQLiteDriver.kind(forDeclaredType: type),
                isNullable: Self.int(row[2]) == 0 && position == 0, defaultValue: row[3].displayText,
                primaryKeyPosition: position > 0 ? position : nil, isGenerated: hidden >= 2)
        }

        var indexes: [IndexDescription] = []
        let indexList = try await driver.query(
            "SELECT name, \"unique\", origin FROM pragma_index_list(?1) ORDER BY seq", parameters: [name])
        for row in indexList.rows {
            guard case .text(let indexName) = row[0] else { continue }
            let members = try await driver.query(
                "SELECT name FROM pragma_index_info(?1) ORDER BY seqno", parameters: [.text(indexName)])
            indexes.append(IndexDescription(
                name: indexName, columns: members.rows.compactMap { $0[0].displayText },
                isUnique: Self.int(row[1]) == 1, isPrimary: row[2] == .text("pk")))
            let indexSQL = try await driver.query(
                "SELECT sql FROM sqlite_master WHERE type = 'index' AND name = ?1", parameters: [.text(indexName)])
            if let sql = indexSQL.rows.first?[0].displayText {
                ddl = (ddl ?? "") + ";\n\n" + sql
            }
        }

        var foreignKeys: [Int: ForeignKeyDescription] = [:]
        let keyList = try await driver.query(
            "SELECT id, \"table\", \"from\", \"to\", on_update, on_delete FROM pragma_foreign_key_list(?1) ORDER BY id, seq",
            parameters: [name])
        for row in keyList.rows {
            let id = Self.int(row[0])
            guard case .text(let target) = row[1], case .text(let from) = row[2] else { continue }
            var key = foreignKeys[id] ?? ForeignKeyDescription(
                columns: [], referencedTable: TableRef(name: target), referencedColumns: [],
                onUpdate: row[4].displayText, onDelete: row[5].displayText)
            key.columns.append(from)
            if let to = row[3].displayText { key.referencedColumns.append(to) }
            foreignKeys[id] = key
        }

        let withoutRowID = ddl?.uppercased().contains("WITHOUT ROWID") ?? false
        return TableDescription(
            ref: table, kind: kind, columns: columns, indexes: indexes,
            foreignKeys: foreignKeys.sorted { $0.key < $1.key }.map(\.value), ddl: ddl,
            hasRowID: kind == .table && !withoutRowID)
    }

    func estimatedRowCount(_ table: TableRef) async throws -> Int? { nil }

    private static func int(_ value: SQLValue) -> Int {
        if case .integer(let number) = value { return Int(number) }
        return 0
    }
}
