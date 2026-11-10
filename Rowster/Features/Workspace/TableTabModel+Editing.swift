import AppKit
import RowsterCore
import SwiftUI

/// Pending changes: edits made in the grid stay here, highlighted, until the user previews and commits
/// them. Nothing in this file sends SQL except `commitChanges`, which runs one transaction.
extension TableTabModel {
    // MARK: - State

    /// Number of rows with a pending change.
    var pendingCount: Int {
        let editedRows = pendingEdits.filter { !$0.value.isEmpty && !deletedRows.contains($0.key) }.count
        return editedRows + deletedRows.count + newRows.count
    }

    var hasPendingChanges: Bool { pendingCount > 0 }

    /// Why the rows of this table cannot be changed, when they cannot.
    var editingObstacle: String? {
        guard let structure else { return nil }
        if structure.kind == .view { return String(localized: "A view cannot be edited.") }
        if structure.rowIdentity == nil {
            return String(localized: "This table has no primary key, so its rows cannot be edited safely.")
        }
        return nil
    }

    private func refuseIfReadOnly() -> Bool {
        guard isReadOnly() else { return false }
        notice = String(localized: "This connection is read-only. Unlock writing to make changes.")
        return true
    }

    // MARK: - Cells

    func gridCanEdit(row: Int, column: Int) -> Bool {
        guard let structure, structure.columns.indices.contains(column), row < gridRowCount else { return false }
        if refuseIfReadOnly() { return false }
        let description = structure.columns[column]
        if description.isGenerated {
            notice = String(localized: "This column is computed by the database.")
            return false
        }
        if description.kind == .binary || gridValue(row: row, column: column).isBinary {
            notice = String(localized: "Binary values cannot be edited.")
            return false
        }
        if gridValue(row: row, column: column).displayText?.contains(where: \.isNewline) == true {
            notice = String(localized: "A value with several lines cannot be edited in the grid.")
            return false
        }
        if row < rows.count {
            if let obstacle = editingObstacle {
                notice = obstacle
                return false
            }
            if deletedRows.contains(row) { return false }
        }
        notice = nil
        return true
    }

    func gridCommit(text: String, row: Int, column: Int) {
        guard let structure, structure.columns.indices.contains(column) else { return }
        let description = structure.columns[column]
        let value: SQLValue = text.isEmpty && description.kind != .text && description.isNullable
            ? .null : .typed(text, as: description.kind)
        setPending(value, row: row, column: column)
    }

    /// Records a new value for a cell, or forgets the edit when the value is the loaded one again.
    private func setPending(_ value: SQLValue, row: Int, column: Int) {
        if row < rows.count {
            let original = rows[row].indices.contains(column) ? rows[row][column] : .null
            if value.isNull == original.isNull, value.displayText == original.displayText {
                pendingEdits[row]?[column] = nil
                if pendingEdits[row]?.isEmpty == true { pendingEdits[row] = nil }
            } else {
                pendingEdits[row, default: [:]][column] = value
            }
        } else if newRows.indices.contains(row - rows.count) {
            newRows[row - rows.count][column] = value
        }
        gridRevision += 1
    }

    func setNull(row: Int, column: Int) {
        guard gridCanEdit(row: row, column: column) else { return }
        setPending(.null, row: row, column: column)
    }

    // MARK: - Rows

    func addRow() {
        guard let structure, !refuseIfReadOnly() else { return }
        guard structure.kind == .table else {
            notice = editingObstacle
            return
        }
        newRows.append([:])
        gridRevision += 1
    }

    /// Adds a copy of the selected row, without its key, its computed columns and its binary values.
    func duplicateSelectedRow() {
        guard let structure, let row = inspectedRow, !refuseIfReadOnly() else { return }
        var copy: [Int: SQLValue] = [:]
        for (index, column) in structure.columns.enumerated() where column.primaryKeyPosition == nil && !column.isGenerated {
            let value = gridValue(row: row, column: index)
            if !value.isBinary { copy[index] = value }
        }
        newRows.append(copy)
        gridRevision += 1
    }

    /// Marks the selected rows for deletion, or restores them when they all already are. New rows are dropped.
    func gridDeleteSelection() {
        guard !selectedRows.isEmpty, !refuseIfReadOnly() else { return }
        let existing = selectedRows.filter { $0 < rows.count }
        if !existing.isEmpty, let obstacle = editingObstacle {
            notice = obstacle
            return
        }
        if !existing.isEmpty, existing.allSatisfy(deletedRows.contains) {
            deletedRows.subtract(existing)
        } else {
            deletedRows.formUnion(existing)
        }
        for row in selectedRows.filter({ $0 >= rows.count }).sorted(by: >) where newRows.indices.contains(row - rows.count) {
            newRows.remove(at: row - rows.count)
        }
        gridRevision += 1
    }

    func discardChanges() {
        pendingEdits = [:]
        deletedRows = []
        newRows = []
        notice = nil
        isPreviewingChanges = false
        gridRevision += 1
    }

    // MARK: - Preview and commit

    private func changeSet() -> ChangeSet? {
        guard let structure else { return nil }
        var changes: [ChangeSet.Change] = []
        func named(_ values: [Int: SQLValue]) -> [String: SQLValue] {
            var out: [String: SQLValue] = [:]
            for (column, value) in values where structure.columns.indices.contains(column) {
                out[structure.columns[column].name] = value
            }
            return out
        }
        for row in deletedRows.sorted() where keys.indices.contains(row) {
            changes.append(.delete(key: keys[row]))
        }
        for row in pendingEdits.keys.sorted() where !deletedRows.contains(row) && keys.indices.contains(row) {
            let values = named(pendingEdits[row] ?? [:])
            if !values.isEmpty { changes.append(.update(key: keys[row], values: values)) }
        }
        for row in newRows { changes.append(.insert(values: named(row))) }
        return ChangeSet(table: structure, changes: changes)
    }

    /// The exact statements a commit would run, with their values written in for reading.
    var previewSQL: String {
        guard let changeSet = changeSet() else { return "" }
        do {
            let statements = try changeSet.statements(dialect: dialect)
            return (["BEGIN;"] + statements.map { $0.inlinedForDisplay(dialect: dialect) + ";" } + ["COMMIT;"])
                .joined(separator: "\n")
        } catch {
            return "-- " + Self.describe(error)
        }
    }

    /// Sends the pending changes in one transaction. On any error nothing is changed and they stay pending.
    func commitChanges() async {
        guard hasPendingChanges, !isCommitting, let changeSet = changeSet() else { return }
        isCommitting = true
        activity.running += 1
        defer {
            isCommitting = false
            activity.running -= 1
        }
        do {
            try await session.commit(changeSet.statements(dialect: dialect))
        } catch {
            errorMessage = Self.describe(error)
            return
        }
        isPreviewingChanges = false
        notice = nil
        exactCount = nil
        await fetchPage()
    }

    private static func describe(_ error: Error) -> String {
        switch error {
        case SessionError.unexpectedRowCount(let statement, let affected):
            return String(localized: "Statement \(statement + 1) changed \(affected ?? 0) rows instead of 1. The row may have been modified or deleted by someone else. Nothing was changed.")
        case SessionError.transactionInProgress:
            return String(localized: "A transaction is open in this window. Commit or roll it back before committing these changes.")
        case let error as ChangeSetError:
            switch error {
            case .noRowIdentity: return String(localized: "This table has no primary key, so its rows cannot be edited safely.")
            case .unknownColumn(let name): return String(localized: "Unknown column: \(name)")
            case .generatedColumn(let name): return String(localized: "The column \(name) is computed by the database.")
            case .keyMismatch: return String(localized: "A row has no usable key and cannot be changed.")
            case .valueNotLoaded(let name): return String(localized: "The value of \(name) was not loaded and cannot be written back.")
            case .emptyUpdate: return String(localized: "There is nothing to change.")
            }
        default:
            return WorkspaceModel.describe(error) + "\n" + String(localized: "Nothing was changed.")
        }
    }

    // MARK: - Menu

    func addEditingItems(to menu: NSMenu, row: Int?, column: Int?) {
        guard let structure, structure.kind == .table, let row else { return }
        menu.addItem(.separator())
        if let column, structure.columns.indices.contains(column), structure.columns[column].isNullable,
           !gridValue(row: row, column: column).isNull {
            menu.addItem(ClosureMenuItem(String(localized: "Set NULL")) { [weak self] in self?.setNull(row: row, column: column) })
        }
        menu.addItem(ClosureMenuItem(String(localized: "Duplicate Row")) { [weak self] in self?.duplicateSelectedRow() })
        let allDeleted = !selectedRows.isEmpty && selectedRows.allSatisfy { deletedRows.contains($0) }
        let title = allDeleted ? String(localized: "Restore Rows") : String(localized: "Delete Rows")
        menu.addItem(ClosureMenuItem(title) { [weak self] in self?.gridDeleteSelection() })
    }
}
