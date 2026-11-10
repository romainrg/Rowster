import AppKit
import RowsterCore
import SwiftUI

/// Counts the statements running in a work window, for its activity indicator.
@MainActor
@Observable
final class Activity {
    var running = 0
}

/// A table or view opened in a tab: its structure and one page of its rows.
@MainActor
@Observable
final class TableTabModel: GridDataSource {
    let ref: TableRef
    let kind: SchemaObjectKind
    let session: Session
    let dialect: any SQLDialect
    private let connectionID: UUID
    private let viewState: any ViewStateStoring
    private let activity: Activity

    private(set) var structure: TableDescription?
    private(set) var columns: [GridColumn] = []
    private(set) var rows: [Row] = []
    private(set) var keys: [[SQLValue]] = []
    private(set) var hasMore = false
    private(set) var pageIndex = 0
    private(set) var pageSize = 300
    private(set) var sort: [SortTerm] = []
    private(set) var estimatedCount: Int?
    private(set) var exactCount: Int?
    private(set) var isLoading = false
    private(set) var isCounting = false
    var errorMessage: String?

    private(set) var gridRevision = 0
    private(set) var gridStructureRevision = 0
    private(set) var selectedRows = IndexSet()
    private(set) var activeColumn: Int?
    private var columnWidths: [String: Double] = [:]
    private var generation = 0

    var filters: [FilterCondition] = []
    var filterMatch: FilterMatch = .all
    var isFilterBarVisible = false
    private(set) var appliedFilter: SQLFragment?
    var filterError: String?

    static let pageSizes = [100, 300, 1000, 5000]

    init(
        ref: TableRef, kind: SchemaObjectKind, session: Session, dialect: any SQLDialect, connectionID: UUID,
        viewState: any ViewStateStoring, activity: Activity
    ) {
        self.ref = ref
        self.kind = kind
        self.session = session
        self.dialect = dialect
        self.connectionID = connectionID
        self.viewState = viewState
        self.activity = activity
    }

    // MARK: - Loading

    /// Reads the structure, then the first page. Called when the tab is first displayed.
    func load() async {
        guard structure == nil, !isLoading else { return }
        do {
            let description = try await session.describe(ref)
            let saved = viewState.state(connection: connectionID, table: ref)
            let known = Set(description.columns.map(\.name))
            sort = saved.sort.filter { known.contains($0.column) }
            columnWidths = saved.columnWidths
            columns = description.columns.map { column in
                GridColumn(
                    title: column.name, typeName: column.typeName, kind: column.kind,
                    hasForeignKey: description.foreignKey(for: column.name) != nil)
            }
            structure = description
            gridStructureRevision += 1
        } catch {
            errorMessage = WorkspaceModel.describe(error)
            return
        }
        await fetchPage()
        estimatedCount = try? await session.estimatedRowCount(ref)
    }

    func reload() async {
        exactCount = nil
        await fetchPage()
    }

    private func browseQuery() -> BrowseQuery? {
        guard let structure else { return nil }
        return BrowseQuery(table: structure, filter: appliedFilter, sort: sort, limit: pageSize, offset: pageIndex * pageSize)
    }

    // MARK: - Filters

    func addFilter() {
        let target = columns.first.map { FilterCondition.Target.column($0.title) } ?? .anyColumn
        filters.append(FilterCondition(target: target, op: target == .anyColumn ? .contains : .equals))
        isFilterBarVisible = true
    }

    func removeFilter(_ id: UUID) {
        filters.removeAll { $0.id == id }
    }

    func toggleFilterBar() {
        isFilterBarVisible.toggle()
        if isFilterBarVisible, filters.isEmpty { addFilter() }
    }

    /// Builds the WHERE clause from the enabled rows and reloads from the first page.
    func applyFilters() async {
        guard let structure else { return }
        do {
            appliedFilter = try FilterBuilder(columns: structure.columns, dialect: dialect).build(filters, match: filterMatch)
            filterError = nil
        } catch {
            filterError = Self.describe(error as? FilterError)
            return
        }
        pageIndex = 0
        exactCount = nil
        await fetchPage()
    }

    func clearFilters() async {
        filters = []
        filterError = nil
        guard appliedFilter != nil else { return }
        appliedFilter = nil
        pageIndex = 0
        exactCount = nil
        await fetchPage()
    }

    /// Shows a table filtered on one value, as when following a foreign key.
    func setFilter(column: String, equals value: SQLValue) async {
        filters = [FilterCondition(target: .column(column), op: .equals, value: value.displayText ?? "")]
        isFilterBarVisible = true
        if structure == nil { await load() }
        await applyFilters()
    }

    /// The applied filter with its values written in, for reading only.
    var appliedFilterSQL: String? {
        appliedFilter.map { "WHERE " + $0.inlinedForDisplay(dialect: dialect) }
    }

    private static func describe(_ error: FilterError?) -> String {
        switch error {
        case .unknownColumn(let name): return String(localized: "Unknown column: \(name)")
        case .missingValue: return String(localized: "A filter has no value.")
        case .unsafeRawSQL: return String(localized: "The SQL condition must be a single expression, without a semicolon.")
        case nil: return String(localized: "The filter is not valid.")
        }
    }

    private func fetchPage() async {
        guard let query = browseQuery() else { return }
        generation += 1
        let current = generation
        isLoading = true
        activity.running += 1
        defer {
            activity.running -= 1
            if current == generation { isLoading = false }
        }
        let select = query.select(dialect: dialect)
        do {
            let result = try await session.query(select.sql, parameters: select.parameters, limit: pageSize + 1)
            guard current == generation else { return }
            let page = query.page(from: result)
            rows = page.rows
            keys = page.keys
            hasMore = page.hasMore
            errorMessage = nil
        } catch {
            guard current == generation else { return }
            errorMessage = WorkspaceModel.describe(error)
        }
        selectedRows = []
        gridRevision += 1
    }

    // MARK: - Paging

    var firstRowNumber: Int { pageIndex * pageSize + 1 }
    var lastRowNumber: Int { pageIndex * pageSize + rows.count }
    var canGoBack: Bool { pageIndex > 0 }

    func nextPage() async {
        guard hasMore else { return }
        pageIndex += 1
        await fetchPage()
    }

    func previousPage() async {
        guard pageIndex > 0 else { return }
        pageIndex -= 1
        await fetchPage()
    }

    func setPageSize(_ size: Int) async {
        guard size != pageSize else { return }
        pageSize = size
        pageIndex = 0
        await fetchPage()
    }

    /// An exact count, only when the user asks: it runs on the auxiliary connection and can be slow.
    func countRows() async {
        guard let query = browseQuery(), !isCounting else { return }
        isCounting = true
        defer { isCounting = false }
        let count = query.count(dialect: dialect)
        if let result = try? await session.preview(count.sql, parameters: count.parameters, limit: 1),
           case .integer(let total)? = result.rows.first?.first {
            exactCount = Int(total)
        }
    }

    // MARK: - Grid

    var gridColumns: [GridColumn] { columns }
    var gridRowCount: Int { rows.count }
    var gridSort: [SortTerm] { sort }

    func gridValue(row: Int, column: Int) -> SQLValue {
        guard rows.indices.contains(row), rows[row].indices.contains(column) else { return .null }
        return rows[row][column]
    }

    /// A click sorts by one column (ascending, descending, then none); a shift-click adds a column.
    func gridToggleSort(column: Int, additive: Bool) {
        guard columns.indices.contains(column) else { return }
        let name = columns[column].title
        let existing = sort.firstIndex { $0.column == name }
        if additive {
            if let existing {
                if sort[existing].ascending { sort[existing].ascending = false } else { sort.remove(at: existing) }
            } else {
                sort.append(SortTerm(column: name))
            }
        } else if sort.count == 1, let existing {
            sort = sort[existing].ascending ? [SortTerm(column: name, ascending: false)] : []
        } else {
            sort = [SortTerm(column: name)]
        }
        saveViewState()
        pageIndex = 0
        Task { await fetchPage() }
    }

    func gridWidth(ofColumn column: Int) -> CGFloat? {
        guard columns.indices.contains(column) else { return nil }
        return columnWidths[columns[column].title].map { CGFloat($0) }
    }

    func gridSetWidth(_ width: CGFloat, ofColumn column: Int) {
        guard columns.indices.contains(column) else { return }
        columnWidths[columns[column].title] = Double(width)
        saveViewState()
    }

    private func saveViewState() {
        viewState.save(TableViewState(sort: sort, columnWidths: columnWidths), connection: connectionID, table: ref)
    }

    func gridSelectionChanged(rows: IndexSet, column: Int?) {
        selectedRows = rows
        activeColumn = column
    }

    // MARK: - Copy

    /// Copies the active cell when one row is selected, the selected rows otherwise.
    func gridCopy() {
        if selectedRows.count == 1, let row = selectedRows.first, let column = activeColumn {
            setClipboard(gridValue(row: row, column: column).exportText ?? "")
        } else {
            copyRows(as: .tsv)
        }
    }

    func copyRows(as format: TabularFormat) {
        let selected = selectedRows.filter { rows.indices.contains($0) }.map { rows[$0] }
        guard !selected.isEmpty else { return }
        setClipboard(TabularText.format(columns: columns.map(\.title), rows: selected, as: format, table: ref, dialect: dialect))
    }

    private func setClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func gridMenu(row: Int?, column: Int?) -> NSMenu? {
        guard row != nil else { return nil }
        let menu = NSMenu()
        if let row, let column {
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
