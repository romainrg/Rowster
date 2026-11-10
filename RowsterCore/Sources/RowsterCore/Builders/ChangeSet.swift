import Foundation

public enum ChangeSetError: Error, Equatable, Sendable {
    /// The table has no primary key, unique NOT NULL index or rowid: a row cannot be addressed safely.
    case noRowIdentity
    case unknownColumn(String)
    /// The server computes this column; it cannot be written.
    case generatedColumn(String)
    case keyMismatch
    /// A binary value that was never loaded cannot be written back.
    case valueNotLoaded(String)
    case emptyUpdate
}

/// The changes made in a grid and not sent yet. It turns them into statements whose values are all
/// bound parameters; nothing is executed here.
public struct ChangeSet: Sendable {
    public enum Change: Equatable, Sendable {
        /// New values for some columns of the row identified by `key`.
        case update(key: [SQLValue], values: [String: SQLValue])
        case delete(key: [SQLValue])
        /// A new row. Columns that are not listed keep their default.
        case insert(values: [String: SQLValue])
    }

    public var table: TableDescription
    public var changes: [Change]

    public init(table: TableDescription, changes: [Change] = []) {
        self.table = table
        self.changes = changes
    }

    public var isEmpty: Bool { changes.isEmpty }

    /// One statement per change, in the order they run: deletes, then updates, then inserts.
    /// Each statement is expected to affect exactly one row.
    public func statements(dialect: any SQLDialect) throws -> [SQLFragment] {
        let target = dialect.qualified(schema: table.ref.schema, name: table.ref.name)
        var deletes: [SQLFragment] = []
        var updates: [SQLFragment] = []
        var inserts: [SQLFragment] = []

        for change in changes {
            switch change {
            case .delete(let key):
                let predicate = try identity(key: key, firstPlaceholder: 1, dialect: dialect)
                deletes.append(SQLFragment(sql: "DELETE FROM \(target) WHERE \(predicate)", parameters: key))

            case .update(let key, let values):
                let columns = try ordered(values)
                guard !columns.isEmpty else { throw ChangeSetError.emptyUpdate }
                let assignments = columns.enumerated().map { offset, column in
                    "\(dialect.quote(identifier: column.name)) = \(dialect.placeholder(offset + 1))"
                }
                let predicate = try identity(key: key, firstPlaceholder: columns.count + 1, dialect: dialect)
                updates.append(SQLFragment(
                    sql: "UPDATE \(target) SET \(assignments.joined(separator: ", ")) WHERE \(predicate)",
                    parameters: columns.map(\.value) + key))

            case .insert(let values):
                let columns = try ordered(values)
                if columns.isEmpty {
                    let sql = dialect.engine == .mysql || dialect.engine == .mariadb
                        ? "INSERT INTO \(target) () VALUES ()" : "INSERT INTO \(target) DEFAULT VALUES"
                    inserts.append(SQLFragment(sql: sql))
                } else {
                    let names = columns.map { dialect.quote(identifier: $0.name) }.joined(separator: ", ")
                    let placeholders = columns.indices.map { dialect.placeholder($0 + 1) }.joined(separator: ", ")
                    inserts.append(SQLFragment(
                        sql: "INSERT INTO \(target) (\(names)) VALUES (\(placeholders))", parameters: columns.map(\.value)))
                }
            }
        }
        return deletes + updates + inserts
    }

    /// The written columns in table order, after checking each one can be written.
    private func ordered(_ values: [String: SQLValue]) throws -> [(name: String, value: SQLValue)] {
        let known = Dictionary(uniqueKeysWithValues: table.columns.map { ($0.name, $0) })
        for (name, value) in values {
            guard let column = known[name] else { throw ChangeSetError.unknownColumn(name) }
            if column.isGenerated { throw ChangeSetError.generatedColumn(name) }
            if case .deferredBytes = value { throw ChangeSetError.valueNotLoaded(name) }
        }
        return table.columns.compactMap { column in values[column.name].map { (column.name, $0) } }
    }

    private func identity(key: [SQLValue], firstPlaceholder: Int, dialect: any SQLDialect) throws -> String {
        guard let predicate = BrowseQuery.identityPredicate(table.rowIdentity, firstPlaceholder: firstPlaceholder, dialect: dialect) else {
            throw ChangeSetError.noRowIdentity
        }
        guard predicate.count == key.count, !key.contains(.null) else { throw ChangeSetError.keyMismatch }
        return predicate.sql
    }
}

public extension SQLValue {
    /// The value a user typed for a column. Numbers and booleans are bound with their own type when the
    /// text reads as one; anything else is bound as text and left to the server to convert or reject.
    static func typed(_ text: String, as kind: ColumnKind) -> SQLValue {
        switch kind {
        case .integer:
            if let number = Int64(text) { return .integer(number) }
        case .decimal:
            if let number = Double(text), number.isFinite { return .double(number) }
        case .boolean:
            switch text.lowercased() {
            case "true", "t", "yes", "1": return .bool(true)
            case "false", "f", "no", "0": return .bool(false)
            default: break
            }
        default:
            break
        }
        return .text(text)
    }
}
