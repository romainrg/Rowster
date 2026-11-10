import Foundation

/// SQL text with placeholders, and the values bound to them.
public struct SQLFragment: Equatable, Sendable {
    public var sql: String
    public var parameters: [SQLValue]

    public init(sql: String, parameters: [SQLValue] = []) {
        self.sql = sql
        self.parameters = parameters
    }
}

public struct SortTerm: Hashable, Codable, Sendable {
    public var column: String
    public var ascending: Bool

    public init(column: String, ascending: Bool = true) {
        self.column = column
        self.ascending = ascending
    }
}

/// One page of a table, as shown in the grid.
public struct BrowsePage: Equatable, Sendable {
    public var rows: [Row]
    /// For each row, the values that identify it (primary key values, or the rowid). Empty when the
    /// table has no row identity.
    public var keys: [[SQLValue]]
    public var hasMore: Bool
}

/// Builds the statements that read a table for the grid. Identifiers are quoted by the dialect and every
/// value is a bound parameter.
public struct BrowseQuery: Sendable {
    public static let rowIDAlias = "__rowster_rowid"

    public var table: TableDescription
    /// The body of a WHERE clause, with placeholders numbered from 1.
    public var filter: SQLFragment?
    public var sort: [SortTerm]
    public var limit: Int
    public var offset: Int
    /// Binary columns are read as their length; the bytes are fetched on demand.
    public var defersBinary = true

    public init(table: TableDescription, filter: SQLFragment? = nil, sort: [SortTerm] = [], limit: Int = 300, offset: Int = 0) {
        self.table = table
        self.filter = filter
        self.sort = sort
        self.limit = limit
        self.offset = offset
    }

    private var usesRowID: Bool { table.rowIdentity == .rowID }

    private func isDeferred(_ column: ColumnDescription) -> Bool { defersBinary && column.kind == .binary }

    private func source(_ dialect: any SQLDialect) -> String {
        dialect.qualified(schema: table.ref.schema, name: table.ref.name)
    }

    private func whereClause() -> String {
        guard let filter, !filter.sql.isEmpty else { return "" }
        return " WHERE (\(filter.sql))"
    }

    /// Reads one page, plus one row to know whether another page follows.
    public func select(dialect: any SQLDialect) -> SQLFragment {
        var projection = table.columns.map { column -> String in
            let quoted = dialect.quote(identifier: column.name)
            return isDeferred(column) ? "\(dialect.byteLength(quoted)) AS \(quoted)" : quoted
        }
        if usesRowID { projection.insert("rowid AS \(dialect.quote(identifier: Self.rowIDAlias))", at: 0) }

        var sql = "SELECT \(projection.joined(separator: ", ")) FROM \(source(dialect))\(whereClause())"
        let order = orderTerms(dialect)
        if !order.isEmpty { sql += " ORDER BY " + order.joined(separator: ", ") }
        return SQLFragment(
            sql: dialect.paginated(sql, limit: limit + 1, offset: offset), parameters: filter?.parameters ?? [])
    }

    /// The user's sort, then the row identity as a tie-breaker so that paging is stable.
    private func orderTerms(_ dialect: any SQLDialect) -> [String] {
        let known = Set(table.columns.map(\.name))
        var terms: [String] = []
        var used = Set<String>()
        for term in sort where known.contains(term.column) && used.insert(term.column).inserted {
            terms.append("\(dialect.quote(identifier: term.column)) \(term.ascending ? "ASC" : "DESC")")
        }
        switch table.rowIdentity {
        case .columns(let columns):
            for column in columns where used.insert(column).inserted {
                terms.append("\(dialect.quote(identifier: column)) ASC")
            }
        case .rowID:
            terms.append("rowid ASC")
        case nil:
            break
        }
        return terms
    }

    /// Counts the rows matching the filter. Only run when the user asks for an exact count.
    public func count(dialect: any SQLDialect) -> SQLFragment {
        SQLFragment(sql: "SELECT count(*) FROM \(source(dialect))\(whereClause())", parameters: filter?.parameters ?? [])
    }

    /// Reads the full value of one column of one row, addressed by its identity. `nil` when the table
    /// has no row identity.
    public func value(of column: String, key: [SQLValue], dialect: any SQLDialect) -> SQLFragment? {
        guard let predicate = Self.identityPredicate(table.rowIdentity, firstPlaceholder: 1, dialect: dialect),
              predicate.count == key.count else { return nil }
        return SQLFragment(
            sql: "SELECT \(dialect.quote(identifier: column)) FROM \(source(dialect)) WHERE \(predicate.sql)",
            parameters: key)
    }

    /// `"id" = $1 AND "variant" = $2`, or `rowid = $1`.
    static func identityPredicate(
        _ identity: RowIdentity?, firstPlaceholder: Int, dialect: any SQLDialect
    ) -> (sql: String, count: Int)? {
        switch identity {
        case .columns(let columns):
            let terms = columns.enumerated().map { offset, column in
                "\(dialect.quote(identifier: column)) = \(dialect.placeholder(firstPlaceholder + offset))"
            }
            return (terms.joined(separator: " AND "), columns.count)
        case .rowID:
            return ("rowid = \(dialect.placeholder(firstPlaceholder))", 1)
        case nil:
            return nil
        }
    }

    /// `"column" = $1`, for following a foreign key.
    public static func equality(column: String, value: SQLValue, dialect: any SQLDialect) -> SQLFragment {
        SQLFragment(sql: "\(dialect.quote(identifier: column)) = \(dialect.placeholder(1))", parameters: [value])
    }

    /// Turns the rows of `select` into a page: drops the extra row and the rowid column, marks deferred
    /// binary values and extracts each row's key.
    public func page(from result: QueryResult) -> BrowsePage {
        let hasMore = result.rows.count > limit
        let deferred = table.columns.enumerated().filter { isDeferred($0.element) }.map(\.offset)
        let keyIndexes: [Int]
        if case .columns(let columns) = table.rowIdentity {
            keyIndexes = columns.compactMap { name in table.columns.firstIndex { $0.name == name } }
        } else {
            keyIndexes = []
        }

        var rows: [Row] = []
        var keys: [[SQLValue]] = []
        for raw in result.rows.prefix(limit) {
            var row = raw
            var key: [SQLValue] = []
            if usesRowID, !row.isEmpty { key = [row.removeFirst()] }
            for index in deferred where index < row.count {
                if case .integer(let length) = row[index] { row[index] = .deferredBytes(length: Int(length)) }
            }
            if !keyIndexes.isEmpty { key = keyIndexes.map { $0 < row.count ? row[$0] : .null } }
            rows.append(row)
            keys.append(key)
        }
        return BrowsePage(rows: rows, keys: keys, hasMore: hasMore)
    }
}
