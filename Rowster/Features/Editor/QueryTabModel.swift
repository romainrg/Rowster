import AppKit
import RowsterCore
import SwiftUI

/// What one statement returned.
struct StatementResult: Identifiable {
    let id = UUID()
    let sql: String
    var columns: [ColumnInfo] = []
    var rows: [Row] = []
    var isTruncated = false
    var rowsAffected: Int?
    var duration: TimeInterval = 0
    var error: String?
    var limit: Int

    var returnsRows: Bool { !columns.isEmpty }
}

/// A SQL editor tab: the text, and the results of the last run.
@MainActor
@Observable
final class QueryTabModel {
    let number: Int
    let session: Session
    let dialect: any SQLDialect
    private let connectionID: UUID
    private let history: any HistoryStoring
    private let activity: Activity

    var text = ""
    var selection = NSRange(location: 0, length: 0)
    private(set) var results: [StatementResult] = []
    var selectedResultID: UUID?
    private(set) var isRunning = false
    private(set) var gridRevision = 0
    private(set) var historyEntries: [HistoryEntry] = []

    /// Set by the window: asks the user to confirm destructive statements.
    var confirmHazards: ([(sql: String, hazard: StatementInfo.Hazard)]) async -> Bool = { _ in false }
    /// Set by the window: called after a statement that may have changed the schema.
    var onSchemaChange: () -> Void = {}

    init(number: Int, session: Session, dialect: any SQLDialect, connectionID: UUID, history: any HistoryStoring, activity: Activity) {
        self.number = number
        self.session = session
        self.dialect = dialect
        self.connectionID = connectionID
        self.history = history
        self.activity = activity
    }

    var title: String { String(localized: "Query \(number)") }
    var isBlank: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var selectedResult: StatementResult? { results.first { $0.id == selectedResultID } ?? results.first }

    private var rowLimit: Int {
        let stored = UserDefaults.standard.integer(forKey: AppSettings.editorRowLimit)
        return stored > 0 ? stored : AppSettings.defaultEditorRowLimit
    }

    // MARK: - Running

    /// Runs the selection when there is one, the statement under the cursor otherwise.
    func runCurrent() async {
        let nsText = text as NSString
        if selection.length > 0, NSMaxRange(selection) <= nsText.length {
            await run(dialect.splitter.split(nsText.substring(with: selection)).map(\.text))
        } else {
            let offset = min(selection.location, text.utf16.count)
            let position = String.Index(utf16Offset: offset, in: text)
            guard let statement = dialect.splitter.statement(at: position, in: text) else { return }
            await run([statement.text])
        }
    }

    func runAll() async {
        await run(dialect.splitter.split(text).map(\.text))
    }

    /// Runs statements in order and stops at the first error. Destructive ones are all shown and
    /// confirmed first: nothing runs before the user has answered.
    private func run(_ statements: [String]) async {
        guard !statements.isEmpty, !isRunning else { return }
        var hazards: [(sql: String, hazard: StatementInfo.Hazard)] = []
        for statement in statements {
            if let hazard = dialect.classifier.classify(statement).hazard { hazards.append((statement, hazard)) }
        }
        if !hazards.isEmpty, !(await confirmHazards(hazards)) { return }

        isRunning = true
        activity.running += 1
        defer {
            isRunning = false
            activity.running -= 1
        }
        results = []
        selectedResultID = nil
        var changedSchema = false
        for statement in statements {
            let result = await execute(statement, limit: rowLimit)
            results.append(result)
            selectedResultID = result.id
            gridRevision += 1
            record(result)
            if ["CREATE", "DROP", "ALTER", "RENAME"].contains(dialect.classifier.classify(statement).verb) { changedSchema = true }
            if result.error != nil { break }
        }
        if changedSchema { onSchemaChange() }
    }

    private func execute(_ sql: String, limit: Int) async -> StatementResult {
        var result = StatementResult(sql: sql, limit: limit)
        let started = Date()
        do {
            let query = try await session.query(sql, limit: limit, confirmed: true)
            result.columns = query.columns
            result.rows = query.rows
            result.isTruncated = query.isTruncated
            result.rowsAffected = query.summary.rowsAffected
        } catch let error as DatabaseError where error.isCancellation {
            result.error = String(localized: "Cancelled.")
        } catch {
            result.error = WorkspaceModel.describe(error)
        }
        result.duration = Date().timeIntervalSince(started)
        return result
    }

    /// Fetches more rows of a truncated result by running the statement again with a higher limit.
    func loadMore(_ id: UUID) async {
        guard !isRunning, let index = results.firstIndex(where: { $0.id == id }), results[index].isTruncated,
              dialect.classifier.classify(results[index].sql).kind == .read else { return }
        isRunning = true
        activity.running += 1
        defer {
            isRunning = false
            activity.running -= 1
        }
        let result = await execute(results[index].sql, limit: min(results[index].limit * 5, 200_000))
        results[index] = result
        selectedResultID = result.id
        gridRevision += 1
    }

    // MARK: - History

    private func record(_ result: StatementResult) {
        let enabled = UserDefaults.standard.object(forKey: AppSettings.historyEnabled) as? Bool ?? true
        guard enabled else { return }
        history.add(
            HistoryEntry(
                sql: HistoryRedactor.redact(result.sql, dialect: dialect), duration: result.duration,
                succeeded: result.error == nil, rowCount: result.returnsRows ? result.rows.count : result.rowsAffected),
            connection: connectionID)
    }

    func loadHistory() {
        historyEntries = history.entries(connection: connectionID)
    }

    func clearHistory() {
        history.clear(connection: connectionID)
        historyEntries = []
    }

    /// Puts a statement from the history into the editor, after what is already there.
    func insert(_ entry: HistoryEntry) {
        if isBlank {
            text = entry.sql
        } else {
            text = text.trimmingCharacters(in: .newlines) + "\n\n" + entry.sql
        }
        selection = NSRange(location: text.utf16.count, length: 0)
    }
}

/// Shows the rows of one statement in a grid. Read-only.
@MainActor
final class ResultGridSource: GridDataSource {
    let result: StatementResult
    let dialect: any SQLDialect
    private var selectedRows = IndexSet()
    private var activeColumn: Int?

    init(result: StatementResult, dialect: any SQLDialect) {
        self.result = result
        self.dialect = dialect
    }

    var gridColumns: [GridColumn] {
        result.columns.map { GridColumn(title: $0.name, typeName: $0.typeName, kind: $0.kind) }
    }

    var gridRowCount: Int { result.rows.count }

    func gridValue(row: Int, column: Int) -> SQLValue {
        guard result.rows.indices.contains(row), result.rows[row].indices.contains(column) else { return .null }
        return result.rows[row][column]
    }

    func gridSelectionChanged(rows: IndexSet, column: Int?) {
        selectedRows = rows
        activeColumn = column
    }

    func gridCopy() {
        if selectedRows.count == 1, let row = selectedRows.first, let column = activeColumn {
            setClipboard(gridValue(row: row, column: column).exportText ?? "")
        } else {
            copyRows(as: .tsv)
        }
    }

    private func copyRows(as format: TabularFormat) {
        let rows = selectedRows.filter { result.rows.indices.contains($0) }.map { result.rows[$0] }
        guard !rows.isEmpty else { return }
        setClipboard(TabularText.format(columns: result.columns.map(\.name), rows: rows, as: format, dialect: dialect))
    }

    private func setClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func gridMenu(row: Int?, column: Int?) -> NSMenu? {
        guard let row else { return nil }
        let menu = NSMenu()
        if let column {
            menu.addItem(ClosureMenuItem(String(localized: "Copy Cell")) { [weak self] in
                guard let self else { return }
                setClipboard(gridValue(row: row, column: column).exportText ?? "")
            })
        }
        let copyAs = NSMenuItem(title: String(localized: "Copy Rows As"), action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        let formats: [(String, TabularFormat)] = [
            (String(localized: "Tab-separated"), .tsv), ("CSV", .csv), ("JSON", .json), ("Markdown", .markdown),
            (String(localized: "SQL INSERT"), .insert)
        ]
        for (title, format) in formats {
            submenu.addItem(ClosureMenuItem(title) { [weak self] in self?.copyRows(as: format) })
        }
        copyAs.submenu = submenu
        menu.addItem(copyAs)
        return menu
    }
}
