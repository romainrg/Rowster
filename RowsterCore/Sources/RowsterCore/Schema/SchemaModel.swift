import Foundation

/// A table or view, with its schema when the engine has schemas.
public struct TableRef: Hashable, Sendable, Codable {
    public var schema: String?
    public var name: String

    public init(schema: String? = nil, name: String) {
        self.schema = schema
        self.name = name
    }

    public var displayName: String {
        guard let schema, !schema.isEmpty else { return name }
        return "\(schema).\(name)"
    }
}

public enum SchemaObjectKind: String, Sendable, Codable {
    case table, view
}

/// One schema of a database (PostgreSQL), or the whole database for engines without schemas.
public struct SchemaNamespace: Hashable, Sendable {
    /// `nil` for engines without schemas.
    public var name: String?
    public var tables: [String]
    public var views: [String]
    public var functions: [String]

    public init(name: String?, tables: [String] = [], views: [String] = [], functions: [String] = []) {
        self.name = name
        self.tables = tables
        self.views = views
        self.functions = functions
    }
}

public struct ColumnDescription: Hashable, Sendable {
    public var name: String
    public var typeName: String
    public var kind: ColumnKind
    public var isNullable: Bool
    public var defaultValue: String?
    /// 1-based position in the primary key, `nil` when the column is not part of it.
    public var primaryKeyPosition: Int?
    /// Computed by the server (generated column, identity always): never written by an INSERT or UPDATE.
    public var isGenerated: Bool

    public init(
        name: String, typeName: String, kind: ColumnKind, isNullable: Bool = true, defaultValue: String? = nil,
        primaryKeyPosition: Int? = nil, isGenerated: Bool = false
    ) {
        self.name = name
        self.typeName = typeName
        self.kind = kind
        self.isNullable = isNullable
        self.defaultValue = defaultValue
        self.primaryKeyPosition = primaryKeyPosition
        self.isGenerated = isGenerated
    }
}

public struct IndexDescription: Hashable, Sendable {
    public var name: String
    public var columns: [String]
    public var isUnique: Bool
    public var isPrimary: Bool

    public init(name: String, columns: [String], isUnique: Bool, isPrimary: Bool = false) {
        self.name = name
        self.columns = columns
        self.isUnique = isUnique
        self.isPrimary = isPrimary
    }
}

public struct ForeignKeyDescription: Hashable, Sendable {
    public var name: String?
    public var columns: [String]
    public var referencedTable: TableRef
    public var referencedColumns: [String]
    public var onUpdate: String?
    public var onDelete: String?

    public init(
        name: String? = nil, columns: [String], referencedTable: TableRef, referencedColumns: [String],
        onUpdate: String? = nil, onDelete: String? = nil
    ) {
        self.name = name
        self.columns = columns
        self.referencedTable = referencedTable
        self.referencedColumns = referencedColumns
        self.onUpdate = onUpdate
        self.onDelete = onDelete
    }
}

public struct CheckDescription: Hashable, Sendable {
    public var name: String?
    public var definition: String

    public init(name: String? = nil, definition: String) {
        self.name = name
        self.definition = definition
    }
}

/// How one row of a table is addressed by an UPDATE or DELETE.
public enum RowIdentity: Hashable, Sendable {
    /// Primary key, or a unique index whose columns are all NOT NULL.
    case columns([String])
    /// SQLite's implicit rowid.
    case rowID
}

public struct TableDescription: Hashable, Sendable {
    public var ref: TableRef
    public var kind: SchemaObjectKind
    public var columns: [ColumnDescription]
    public var indexes: [IndexDescription]
    public var foreignKeys: [ForeignKeyDescription]
    public var checks: [CheckDescription]
    public var ddl: String?
    /// True when the DDL was rebuilt from the catalogs rather than returned by the server.
    public var ddlIsReconstructed: Bool
    /// SQLite only: the table has an implicit rowid.
    public var hasRowID: Bool

    public init(
        ref: TableRef, kind: SchemaObjectKind = .table, columns: [ColumnDescription], indexes: [IndexDescription] = [],
        foreignKeys: [ForeignKeyDescription] = [], checks: [CheckDescription] = [], ddl: String? = nil,
        ddlIsReconstructed: Bool = false, hasRowID: Bool = false
    ) {
        self.ref = ref
        self.kind = kind
        self.columns = columns
        self.indexes = indexes
        self.foreignKeys = foreignKeys
        self.checks = checks
        self.ddl = ddl
        self.ddlIsReconstructed = ddlIsReconstructed
        self.hasRowID = hasRowID
    }

    public var primaryKey: [String] {
        columns.filter { $0.primaryKeyPosition != nil }
            .sorted { ($0.primaryKeyPosition ?? 0) < ($1.primaryKeyPosition ?? 0) }
            .map(\.name)
    }

    /// `nil` when no row can be addressed safely: the grid is then read-only for this table.
    public var rowIdentity: RowIdentity? {
        guard kind == .table else { return nil }
        let key = primaryKey
        if !key.isEmpty { return .columns(key) }
        let notNull = Set(columns.filter { !$0.isNullable }.map(\.name))
        if let unique = indexes.first(where: { $0.isUnique && !$0.columns.isEmpty && $0.columns.allSatisfy(notNull.contains) }) {
            return .columns(unique.columns)
        }
        return hasRowID ? .rowID : nil
    }

    public func foreignKey(for column: String) -> ForeignKeyDescription? {
        foreignKeys.first { $0.columns == [column] }
    }
}

/// Reads the structure of a database. Introspection only reads catalogs: it never touches user data.
public protocol SchemaIntrospecting: Sendable {
    /// Other databases on the server the user can switch to. Empty when the engine has none.
    func databases() async throws -> [String]
    func namespaces() async throws -> [SchemaNamespace]
    func describe(_ table: TableRef) async throws -> TableDescription
    /// A cheap estimate from the catalogs, `nil` when the engine has none. Never a `COUNT(*)`.
    func estimatedRowCount(_ table: TableRef) async throws -> Int?
}
