import AppKit
import RowsterCore
import SwiftUI

struct GridColumn: Equatable {
    var title: String
    var typeName: String
    var kind: ColumnKind
    var hasForeignKey = false
}

enum GridCellState {
    case normal, modified, inserted, deleted
}

/// What a grid shows and what it reports back. The rows are held by the source: the grid only asks for
/// the cells it displays.
@MainActor
protocol GridDataSource: AnyObject {
    var gridColumns: [GridColumn] { get }
    var gridRowCount: Int { get }
    func gridValue(row: Int, column: Int) -> SQLValue
    func gridState(row: Int, column: Int) -> GridCellState
    var gridSort: [SortTerm] { get }
    func gridToggleSort(column: Int, additive: Bool)
    func gridWidth(ofColumn column: Int) -> CGFloat?
    func gridSetWidth(_ width: CGFloat, ofColumn column: Int)
    func gridSelectionChanged(rows: IndexSet, column: Int?)
    func gridMenu(row: Int?, column: Int?) -> NSMenu?
    func gridCopy()
    func gridCanEdit(row: Int, column: Int) -> Bool
    func gridCommit(text: String, row: Int, column: Int)
    func gridDeleteSelection()
    func gridFollowForeignKey(row: Int, column: Int)
    func gridForeignKeyPreview(row: Int, column: Int) async -> ForeignKeyPreview?
}

/// The row a foreign key points to, shown when hovering the arrow of the cell.
struct ForeignKeyPreview {
    let table: String
    let fields: [(name: String, text: String, isNull: Bool)]
}

extension GridDataSource {
    func gridForeignKeyPreview(row: Int, column: Int) async -> ForeignKeyPreview? { nil }
    func gridState(row: Int, column: Int) -> GridCellState { .normal }
    var gridSort: [SortTerm] { [] }
    func gridToggleSort(column: Int, additive: Bool) {}
    func gridWidth(ofColumn column: Int) -> CGFloat? { nil }
    func gridSetWidth(_ width: CGFloat, ofColumn column: Int) {}
    func gridSelectionChanged(rows: IndexSet, column: Int?) {}
    func gridMenu(row: Int?, column: Int?) -> NSMenu? { nil }
    func gridCopy() {}
    func gridCanEdit(row: Int, column: Int) -> Bool { false }
    func gridCommit(text: String, row: Int, column: Int) {}
    func gridDeleteSelection() {}
    func gridFollowForeignKey(row: Int, column: Int) {}
}

/// A data grid on `NSTableView`: views are reused, so 100,000 rows cost the same as 30.
struct DataGridView: NSViewRepresentable {
    let source: any GridDataSource
    /// Changes when rows or their state changed.
    let revision: Int
    /// Changes when the columns changed.
    let structureRevision: Int

    func makeCoordinator() -> GridCoordinator { GridCoordinator(source: source) }

    func makeNSView(context: Context) -> NSScrollView {
        let table = GridTableView()
        table.coordinator = context.coordinator
        table.usesAutomaticRowHeights = false
        table.rowHeight = 24
        table.intercellSpacing = .zero
        table.usesAlternatingRowBackgroundColors = false
        table.backgroundColor = Theme.Grid.background
        table.gridColor = Theme.Grid.line
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.allowsMultipleSelection = true
        table.allowsColumnReordering = true
        table.gridStyleMask = [.solidHorizontalGridLineMask, .solidVerticalGridLineMask]
        table.style = .plain
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        table.target = context.coordinator
        table.doubleAction = #selector(GridCoordinator.doubleClicked(_:))
        table.setAccessibilityLabel(String(localized: "Data grid"))

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        context.coordinator.table = table
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.update(source: source, revision: revision, structureRevision: structureRevision)
    }
}

@MainActor
final class GridCoordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    var source: any GridDataSource
    weak var table: GridTableView?
    private var revision = -1
    private var structureRevision = -1
    private(set) var activeColumn: Int?
    private var isRebuilding = false
    private var editing: (row: Int, column: Int, original: String?)?
    private var editWasCancelled = false

    init(source: any GridDataSource) { self.source = source }

    func update(source: any GridDataSource, revision: Int, structureRevision: Int) {
        self.source = source
        guard let table else { return }
        if self.structureRevision != structureRevision {
            self.structureRevision = structureRevision
            self.revision = revision
            rebuildColumns()
            table.reloadData()
        } else if self.revision != revision {
            self.revision = revision
            refreshHeaders()
            table.reloadData()
            if let last = table.selectedRowIndexes.last, last >= source.gridRowCount { table.deselectAll(nil) }
        }
    }

    // MARK: - Columns

    private func rebuildColumns() {
        guard let table else { return }
        isRebuilding = true
        defer { isRebuilding = false }
        for column in table.tableColumns { table.removeTableColumn(column) }
        for (index, column) in source.gridColumns.enumerated() {
            let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("c\(index)"))
            tableColumn.title = headerTitle(index)
            tableColumn.headerToolTip = column.typeName.isEmpty ? nil : column.typeName
            tableColumn.minWidth = 40
            tableColumn.maxWidth = 4000
            tableColumn.width = source.gridWidth(ofColumn: index) ?? estimatedWidth(index)
            if column.kind.isNumeric { tableColumn.headerCell.alignment = .right }
            table.addTableColumn(tableColumn)
        }
        activeColumn = nil
    }

    private func refreshHeaders() {
        guard let table else { return }
        for tableColumn in table.tableColumns {
            if let index = modelColumn(tableColumn) { tableColumn.title = headerTitle(index) }
        }
        table.headerView?.needsDisplay = true
    }

    private func headerTitle(_ index: Int) -> String {
        let column = source.gridColumns[index]
        let sort = source.gridSort
        guard let position = sort.firstIndex(where: { $0.column == column.title }) else { return column.title }
        let arrow = sort[position].ascending ? "↑" : "↓"
        return sort.count > 1 ? "\(column.title) \(arrow)\(position + 1)" : "\(column.title) \(arrow)"
    }

    /// A width that fits the title and the first rows, within sensible bounds.
    private func estimatedWidth(_ index: Int) -> CGFloat {
        var longest = source.gridColumns[index].title.count + 2
        for row in 0..<min(source.gridRowCount, 40) {
            longest = max(longest, GridCellView.displayText(source.gridValue(row: row, column: index)).count)
        }
        return min(max(CGFloat(longest) * 7.2 + 20, 64), 340)
    }

    private func modelColumn(_ tableColumn: NSTableColumn?) -> Int? {
        guard let raw = tableColumn?.identifier.rawValue, raw.hasPrefix("c") else { return nil }
        return Int(raw.dropFirst())
    }

    private func modelColumn(viewColumn: Int) -> Int? {
        guard let table, viewColumn >= 0, viewColumn < table.tableColumns.count else { return nil }
        return modelColumn(table.tableColumns[viewColumn])
    }

    // MARK: - Data source

    func numberOfRows(in tableView: NSTableView) -> Int { source.gridRowCount }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let column = modelColumn(tableColumn), row < source.gridRowCount else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("cell")
        let cell: GridCellView
        if let reused = tableView.makeView(withIdentifier: identifier, owner: nil) as? GridCellView {
            cell = reused
        } else {
            cell = GridCellView()
            cell.identifier = identifier
        }
        let description = source.gridColumns[column]
        let value = source.gridValue(row: row, column: column)
        cell.configure(
            value: value, kind: description.kind, state: source.gridState(row: row, column: column),
            isActive: column == activeColumn && tableView.selectedRowIndexes == IndexSet(integer: row),
            showsArrow: description.hasForeignKey && !value.isNull)
        cell.onArrow = { [weak self] in
            self?.hidePreview()
            self?.source.gridFollowForeignKey(row: row, column: column)
        }
        cell.onArrowHover = { [weak self, weak cell] isInside in
            guard let self, let cell else { return }
            if isInside { showPreview(row: row, column: column, anchor: cell.arrowView) } else { hidePreview() }
        }
        return cell
    }

    // MARK: - Foreign key preview

    private var previewTask: Task<Void, Never>?
    private var previewPopover: NSPopover?

    /// Shows the referenced row after a short pause over the arrow, so a passing pointer loads nothing.
    private func showPreview(row: Int, column: Int, anchor: NSView) {
        previewTask?.cancel()
        previewTask = Task { [weak self, weak anchor] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled, let self, let preview = await source.gridForeignKeyPreview(row: row, column: column),
                  !Task.isCancelled, let anchor, anchor.window != nil else { return }
            let popover = NSPopover()
            popover.behavior = .semitransient
            popover.animates = false
            popover.contentViewController = NSHostingController(rootView: ForeignKeyPreviewView(preview: preview))
            popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
            previewPopover = popover
        }
    }

    private func hidePreview() {
        previewTask?.cancel()
        previewTask = nil
        previewPopover?.close()
        previewPopover = nil
    }

    // MARK: - Delegate

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard let table else { return }
        source.gridSelectionChanged(rows: table.selectedRowIndexes, column: activeColumn)
        refreshVisibleRows()
    }

    func tableView(_ tableView: NSTableView, didClick tableColumn: NSTableColumn) {
        guard let column = modelColumn(tableColumn) else { return }
        source.gridToggleSort(column: column, additive: NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false)
    }

    func tableViewColumnDidResize(_ notification: Notification) {
        guard !isRebuilding, let tableColumn = notification.userInfo?["NSTableColumn"] as? NSTableColumn,
              let column = modelColumn(tableColumn) else { return }
        source.gridSetWidth(tableColumn.width, ofColumn: column)
    }

    func setActiveColumn(viewColumn: Int) {
        let column = modelColumn(viewColumn: viewColumn)
        guard column != activeColumn else { return }
        activeColumn = column
        if let table {
            source.gridSelectionChanged(rows: table.selectedRowIndexes, column: activeColumn)
            refreshVisibleRows()
        }
    }

    /// Redraws the cells on screen, to move the active-cell outline.
    private func refreshVisibleRows() {
        guard let table else { return }
        let visible = table.rows(in: table.visibleRect)
        guard visible.length > 0 else { return }
        table.reloadData(
            forRowIndexes: IndexSet(integersIn: visible.location..<(visible.location + visible.length)),
            columnIndexes: IndexSet(integersIn: 0..<table.numberOfColumns))
    }

    func menu(row: Int?, viewColumn: Int?) -> NSMenu? {
        source.gridMenu(row: row, column: viewColumn.flatMap { modelColumn(viewColumn: $0) })
    }

    // MARK: - Editing

    @objc func doubleClicked(_ sender: Any?) {
        guard let table, table.clickedRow >= 0 else { return }
        beginEditing(row: table.clickedRow, viewColumn: table.clickedColumn)
    }

    func beginEditingActiveCell() {
        guard let table, let activeColumn, table.selectedRowIndexes.count == 1, let row = table.selectedRowIndexes.first,
              let viewColumn = table.tableColumns.firstIndex(where: { modelColumn($0) == activeColumn }) else { return }
        beginEditing(row: row, viewColumn: viewColumn)
    }

    private func beginEditing(row: Int, viewColumn: Int) {
        guard let table, let column = modelColumn(viewColumn: viewColumn), source.gridCanEdit(row: row, column: column),
              let cell = table.view(atColumn: viewColumn, row: row, makeIfNecessary: false) as? GridCellView else { return }
        let original = source.gridValue(row: row, column: column).displayText
        editing = (row, column, original)
        editWasCancelled = false
        cell.beginEditing(text: original ?? "", delegate: self)
        table.window?.makeFirstResponder(cell.label)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            editWasCancelled = true
            table?.window?.makeFirstResponder(table)
            return true
        }
        return false
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField, let editing else { return }
        self.editing = nil
        field.isEditable = false
        field.drawsBackground = false
        let text = field.stringValue
        if !editWasCancelled, text != (editing.original ?? "") || editing.original == nil && !text.isEmpty {
            source.gridCommit(text: text, row: editing.row, column: editing.column)
        }
        if let table, editing.row < source.gridRowCount {
            table.reloadData(
                forRowIndexes: IndexSet(integer: editing.row), columnIndexes: IndexSet(integersIn: 0..<table.numberOfColumns))
        }
    }
}

final class GridTableView: NSTableView {
    weak var coordinator: GridCoordinator?

    override func mouseDown(with event: NSEvent) {
        coordinator?.setActiveColumn(viewColumn: column(at: convert(event.locationInWindow, from: nil)))
        super.mouseDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let row = row(at: point)
        let column = column(at: point)
        if row >= 0, !selectedRowIndexes.contains(row) {
            selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        coordinator?.setActiveColumn(viewColumn: column)
        return coordinator?.menu(row: row >= 0 ? row : nil, viewColumn: column >= 0 ? column : nil)
    }

    @objc func copy(_ sender: Any?) {
        coordinator?.source.gridCopy()
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 51, 117:
            coordinator?.source.gridDeleteSelection()
        case 36, 76:
            coordinator?.beginEditingActiveCell()
        default:
            super.keyDown(with: event)
        }
    }
}

/// One cell: a single-line label, laid out by frame, with an optional arrow for a foreign key.
final class GridCellView: NSView {
    let label = NSTextField(labelWithString: "")
    private let arrow = HoverButton()
    var onArrow: (() -> Void)?
    var onArrowHover: ((Bool) -> Void)?
    var arrowView: NSView { arrow }

    private static let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    private static let numberFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    private static let nullFont = NSFontManager.shared.convert(
        NSFont.monospacedSystemFont(ofSize: 11, weight: .regular), toHaveTrait: .italicFontMask)

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        label.lineBreakMode = .byTruncatingTail
        label.cell?.usesSingleLineMode = true
        label.cell?.isScrollable = true
        addSubview(label)
        arrow.image = NSImage(systemSymbolName: "arrow.right.circle.fill", accessibilityDescription: nil)
        arrow.isBordered = false
        arrow.imagePosition = .imageOnly
        arrow.contentTintColor = .tertiaryLabelColor
        arrow.target = self
        arrow.action = #selector(arrowClicked)
        arrow.isHidden = true
        arrow.setAccessibilityLabel(String(localized: "Open the referenced row"))
        arrow.onHover = { [weak self] isInside in self?.onArrowHover?(isInside) }
        addSubview(arrow)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func layout() {
        super.layout()
        let arrowWidth: CGFloat = arrow.isHidden ? 0 : 18
        label.frame = NSRect(x: 6, y: (bounds.height - 16) / 2, width: max(0, bounds.width - 12 - arrowWidth), height: 16)
        arrow.frame = NSRect(x: bounds.width - 20, y: (bounds.height - 16) / 2, width: 16, height: 16)
    }

    @objc private func arrowClicked() { onArrow?() }

    private var stateColor: NSColor?
    private var isActiveCell = false

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateLayerColors()
    }

    /// Layer colors are resolved for one appearance, so they are set again when it changes.
    private func updateLayerColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = stateColor?.cgColor
            layer?.borderColor = isActiveCell ? Theme.Grid.focus.cgColor : nil
        }
        layer?.borderWidth = isActiveCell ? 1.5 : 0
    }

    /// What a cell shows: one line, bounded in length, with line breaks made visible.
    static func displayText(_ value: SQLValue) -> String {
        guard let text = value.displayText else { return "NULL" }
        let head = text.count > 400 ? String(text.prefix(400)) + "…" : text
        return head.contains(where: \.isNewline) ? head.split(whereSeparator: \.isNewline).joined(separator: " ⏎ ") : head
    }

    func configure(value: SQLValue, kind: ColumnKind, state: GridCellState, isActive: Bool, showsArrow: Bool) {
        label.stringValue = Self.displayText(value)
        let isNumber: Bool
        switch value {
        case .integer, .double: isNumber = true
        default: isNumber = false
        }
        label.alignment = isNumber || (value.isNull && kind.isNumeric) ? .right : .left
        if value.isNull {
            label.font = Self.nullFont
            label.textColor = .tertiaryLabelColor
        } else {
            label.font = isNumber ? Self.numberFont : Self.font
            label.textColor =
                state == .deleted ? Theme.Grid.deletedText : (value.isBinary ? .secondaryLabelColor : .labelColor)
        }
        switch state {
        case .normal: stateColor = nil
        case .modified: stateColor = Theme.Grid.modified
        case .inserted: stateColor = Theme.Grid.inserted
        case .deleted: stateColor = Theme.Grid.deleted
        }
        isActiveCell = isActive
        updateLayerColors()
        arrow.isHidden = !showsArrow
        needsLayout = true
    }

    func beginEditing(text: String, delegate: NSTextFieldDelegate) {
        label.stringValue = text
        label.font = Self.font
        label.textColor = .labelColor
        label.alignment = .left
        label.isEditable = true
        label.drawsBackground = true
        label.backgroundColor = .textBackgroundColor
        label.delegate = delegate
    }
}

/// A button that reports when the pointer enters and leaves it.
final class HoverButton: NSButton {
    var onHover: ((Bool) -> Void)?
    private var tracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
}

/// The referenced row, as a compact list of its values.
struct ForeignKeyPreviewView: View {
    let preview: ForeignKeyPreview

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label { Text(verbatim: preview.table) } icon: { Image(systemName: "tablecells") }
                .font(.system(size: 12, weight: .semibold))
            Divider()
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 3) {
                ForEach(Array(preview.fields.prefix(14).enumerated()), id: \.offset) { _, field in
                    GridRow {
                        Text(verbatim: field.name).foregroundStyle(.secondary)
                        Text(verbatim: field.text)
                            .italic(field.isNull)
                            .foregroundStyle(field.isNull ? .tertiary : .primary)
                            .lineLimit(2)
                    }
                }
            }
            .font(.system(size: 11.5))
        }
        .padding(12)
        .frame(minWidth: 220, maxWidth: 380, alignment: .leading)
    }
}

/// A menu item that runs a closure.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("not used") }

    @objc private func run() { handler() }
}
