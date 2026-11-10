import Foundation

/// Reads the PostgreSQL catalogs. Every name is a bound parameter.
struct PostgresIntrospector: SchemaIntrospecting {
    let driver: any DatabaseDriver

    /// Separates the column names of an index or constraint in one text value.
    private static let separator: Character = "\u{1F}"

    private static let userSchemas = """
        n.nspname NOT IN ('pg_catalog', 'information_schema') AND n.nspname NOT LIKE 'pg\\_toast%' AND n.nspname NOT LIKE 'pg\\_temp%'
        """

    private static let tableMatch = "n.nspname = COALESCE($1::text, current_schema()) AND c.relname = $2"

    private func parameters(_ table: TableRef) -> [SQLValue] {
        [table.schema.map(SQLValue.text) ?? .null, .text(table.name)]
    }

    private func names(_ value: SQLValue) -> [String] {
        (value.displayText ?? "").split(separator: Self.separator).map(String.init)
    }

    func databases() async throws -> [String] {
        let result = try await driver.query(
            "SELECT datname FROM pg_database WHERE datallowconn AND NOT datistemplate ORDER BY datname", limit: 10_000)
        return result.rows.compactMap { $0.first?.displayText }
    }

    func namespaces() async throws -> [SchemaNamespace] {
        var byName: [String: SchemaNamespace] = [:]
        var order: [String] = []
        func namespace(_ name: String) -> SchemaNamespace {
            if byName[name] == nil { order.append(name) }
            return byName[name] ?? SchemaNamespace(name: name)
        }

        let relations = try await driver.query(
            """
            SELECT n.nspname, c.relname, c.relkind FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE c.relkind IN ('r', 'p', 'v', 'm', 'f') AND \(Self.userSchemas) ORDER BY n.nspname, c.relname
            """, limit: 200_000)
        for row in relations.rows {
            guard let schema = row[0].displayText, let name = row[1].displayText else { continue }
            var entry = namespace(schema)
            if row[2].displayText == "v" || row[2].displayText == "m" { entry.views.append(name) } else { entry.tables.append(name) }
            byName[schema] = entry
        }

        let functions = try await driver.query(
            """
            SELECT DISTINCT n.nspname, p.proname FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
            WHERE \(Self.userSchemas) ORDER BY n.nspname, p.proname
            """, limit: 50_000)
        for row in functions.rows {
            guard let schema = row[0].displayText, let name = row[1].displayText else { continue }
            var entry = namespace(schema)
            entry.functions.append(name)
            byName[schema] = entry
        }

        // `public` first, then the others in alphabetical order.
        return order.sorted { ($0 == "public" ? "" : $0) < ($1 == "public" ? "" : $1) }.compactMap { byName[$0] }
    }

    func describe(_ table: TableRef) async throws -> TableDescription {
        let parameters = parameters(table)
        let relation = try await driver.query(
            """
            SELECT c.relkind, n.nspname, CASE WHEN c.relkind IN ('v', 'm') THEN pg_get_viewdef(c.oid, true) END
            FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE \(Self.tableMatch)
            """, parameters: parameters)
        guard let found = relation.rows.first else {
            throw DatabaseError(message: "relation \"\(table.displayName)\" does not exist", code: "42P01")
        }
        let isView = found[0].displayText == "v" || found[0].displayText == "m"
        let schema = found[1].displayText ?? table.schema

        let attributes = try await driver.query(
            """
            SELECT a.attname, format_type(a.atttypid, a.atttypmod), a.attnotnull, pg_get_expr(d.adbin, d.adrelid),
                   (a.attgenerated <> '' OR a.attidentity = 'a'), a.atttypid::int4
            FROM pg_attribute a JOIN pg_class c ON c.oid = a.attrelid JOIN pg_namespace n ON n.oid = c.relnamespace
            LEFT JOIN pg_attrdef d ON d.adrelid = a.attrelid AND d.adnum = a.attnum
            WHERE \(Self.tableMatch) AND a.attnum > 0 AND NOT a.attisdropped ORDER BY a.attnum
            """, parameters: parameters, limit: 5000)
        var columns = attributes.rows.compactMap { row -> ColumnDescription? in
            guard let name = row[0].displayText else { return nil }
            var type: Int32 = 0
            if case .integer(let oid) = row[5] { type = Int32(truncatingIfNeeded: oid) }
            var kind = PostgresType.kind(type)
            let typeName = row[1].displayText ?? ""
            if kind == .other, typeName.hasPrefix("character") || typeName == "citext" { kind = .text }
            return ColumnDescription(
                name: name, typeName: typeName, kind: kind, isNullable: row[2] != .bool(true),
                defaultValue: row[3].displayText, isGenerated: row[4] == .bool(true))
        }

        let indexRows = try await driver.query(
            """
            SELECT i.relname, ix.indisunique, ix.indisprimary,
                   array_to_string(ARRAY(SELECT a.attname FROM unnest(ix.indkey) WITH ORDINALITY k(attnum, ord)
                     JOIN pg_attribute a ON a.attrelid = ix.indrelid AND a.attnum = k.attnum ORDER BY k.ord), E'\\x1f'),
                   pg_get_indexdef(ix.indexrelid)
            FROM pg_index ix JOIN pg_class i ON i.oid = ix.indexrelid JOIN pg_class c ON c.oid = ix.indrelid
            JOIN pg_namespace n ON n.oid = c.relnamespace WHERE \(Self.tableMatch) ORDER BY ix.indisprimary DESC, i.relname
            """, parameters: parameters, limit: 5000)
        var indexes: [IndexDescription] = []
        var indexDefinitions: [String] = []
        for row in indexRows.rows {
            guard let name = row[0].displayText else { continue }
            let members = names(row[3])
            let isPrimary = row[2] == .bool(true)
            indexes.append(IndexDescription(name: name, columns: members, isUnique: row[1] == .bool(true), isPrimary: isPrimary))
            if isPrimary {
                for (position, member) in members.enumerated() {
                    if let index = columns.firstIndex(where: { $0.name == member }) { columns[index].primaryKeyPosition = position + 1 }
                }
            } else if let definition = row[4].displayText {
                indexDefinitions.append(definition)
            }
        }

        let constraintRows = try await driver.query(
            """
            SELECT con.conname, con.contype, pg_get_constraintdef(con.oid), fn.nspname, fc.relname,
                   array_to_string(ARRAY(SELECT a.attname FROM unnest(con.conkey) WITH ORDINALITY k(attnum, ord)
                     JOIN pg_attribute a ON a.attrelid = con.conrelid AND a.attnum = k.attnum ORDER BY k.ord), E'\\x1f'),
                   array_to_string(ARRAY(SELECT a.attname FROM unnest(con.confkey) WITH ORDINALITY k(attnum, ord)
                     JOIN pg_attribute a ON a.attrelid = con.confrelid AND a.attnum = k.attnum ORDER BY k.ord), E'\\x1f')
            FROM pg_constraint con JOIN pg_class c ON c.oid = con.conrelid JOIN pg_namespace n ON n.oid = c.relnamespace
            LEFT JOIN pg_class fc ON fc.oid = con.confrelid LEFT JOIN pg_namespace fn ON fn.oid = fc.relnamespace
            WHERE \(Self.tableMatch) ORDER BY con.contype DESC, con.conname
            """, parameters: parameters, limit: 5000)
        var foreignKeys: [ForeignKeyDescription] = []
        var checks: [CheckDescription] = []
        var constraintLines: [String] = []
        for row in constraintRows.rows {
            guard let name = row[0].displayText, let definition = row[2].displayText else { continue }
            constraintLines.append("  CONSTRAINT \(driver.dialect.quote(identifier: name)) \(definition)")
            switch row[1].displayText {
            case "f":
                guard let target = row[4].displayText else { continue }
                foreignKeys.append(ForeignKeyDescription(
                    name: name, columns: names(row[5]), referencedTable: TableRef(schema: row[3].displayText, name: target),
                    referencedColumns: names(row[6])))
            case "c":
                checks.append(CheckDescription(name: name, definition: definition))
            default:
                break
            }
        }

        let qualified = driver.dialect.qualified(schema: schema, name: table.name)
        let ddl: String
        if isView {
            ddl = "CREATE VIEW \(qualified) AS\n\(found[2].displayText ?? "")"
        } else {
            let columnLines = columns.map { column -> String in
                var line = "  \(driver.dialect.quote(identifier: column.name)) \(column.typeName)"
                if !column.isNullable { line += " NOT NULL" }
                if let value = column.defaultValue { line += " DEFAULT \(value)" }
                return line
            }
            ddl = (["CREATE TABLE \(qualified) (\n" + (columnLines + constraintLines).joined(separator: ",\n") + "\n)"] + indexDefinitions)
                .joined(separator: ";\n\n") + ";"
        }

        return TableDescription(
            ref: TableRef(schema: schema, name: table.name), kind: isView ? .view : .table, columns: columns, indexes: indexes,
            foreignKeys: foreignKeys, checks: checks, ddl: ddl, ddlIsReconstructed: !isView)
    }

    func estimatedRowCount(_ table: TableRef) async throws -> Int? {
        let result = try await driver.query(
            "SELECT c.reltuples::bigint FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE \(Self.tableMatch)",
            parameters: parameters(table))
        guard case .integer(let estimate)? = result.rows.first?.first, estimate >= 0 else { return nil }
        return Int(estimate)
    }
}
