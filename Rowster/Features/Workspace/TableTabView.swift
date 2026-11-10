import RowsterCore
import SwiftUI

/// The data of a table: the grid, and a footer with the position, the count and the paging controls.
struct TableTabView: View {
    @Bindable var model: TableTabModel

    var body: some View {
        VStack(spacing: 0) {
            if model.isFilterBarVisible {
                FilterBarView(model: model)
                Divider()
            }
            if let error = model.errorMessage {
                ErrorBanner(message: error) { model.errorMessage = nil }
            }
            if model.isShowingStructure, let structure = model.structure {
                StructureView(table: structure).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HSplitView {
                    DataGridView(source: model, revision: model.gridRevision, structureRevision: model.gridStructureRevision)
                        .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
                        .layoutPriority(1)
                    if model.isInspectorVisible { InspectorView(model: model) }
                }
            }
            Divider()
            footer
        }
        .task { await model.load() }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Picker("View", selection: $model.isShowingStructure) {
                Text("Data").tag(false)
                Text("Structure").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Button {
                model.toggleFilterBar()
            } label: {
                Image(systemName: model.appliedFilter == nil
                    ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
            }
            .foregroundStyle(model.appliedFilter == nil ? Color.secondary : Color.accentColor)
            .keyboardShortcut("f")
            .help(Text("Filters"))
            .accessibilityLabel(Text("Filters"))
            if model.kind == .table {
                Button {
                    model.addRow()
                } label: {
                    Image(systemName: "plus")
                }
                .help(Text("Add a row"))
                .accessibilityLabel(Text("Add a row"))
            }
            if model.hasPendingChanges {
                pendingControls
            } else if let notice = model.notice {
                Label { Text(verbatim: notice) } icon: { Image(systemName: "info.circle") }
                    .foregroundStyle(.orange)
                    .lineLimit(1)
            }
            if model.rows.isEmpty {
                Text(model.isLoading ? "Loading…" : "No rows").foregroundStyle(.secondary)
            } else {
                Text("Rows \(model.firstRowNumber)–\(model.lastRowNumber)").monospacedDigit()
            }
            countView
            if model.isLoading { ProgressView().controlSize(.small) }
            Spacer(minLength: 8)
            if let exported = model.exportedRows {
                Text("Exporting… \(exported) rows").foregroundStyle(.secondary).monospacedDigit()
                Button("Cancel") { model.cancelExport() }
            } else {
                Menu {
                    Button("CSV…") { chooseExportFile(.csv) }
                    Button("JSON…") { chooseExportFile(.json) }
                } label: {
                    Text("Export")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help(Text("Export every row matching the filter"))
            }
            Menu {
                ForEach(TableTabModel.pageSizes, id: \.self) { size in
                    Button {
                        Task { await model.setPageSize(size) }
                    } label: {
                        if size == model.pageSize { Label("\(size) rows", systemImage: "checkmark") } else { Text("\(size) rows") }
                    }
                }
            } label: {
                Text("\(model.pageSize) per page")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            Button {
                Task { await model.previousPage() }
            } label: {
                Image(systemName: "chevron.left")
            }
            .disabled(!model.canGoBack || model.isLoading)
            .help(Text("Previous page"))
            .accessibilityLabel(Text("Previous page"))
            Button {
                Task { await model.nextPage() }
            } label: {
                Image(systemName: "chevron.right")
            }
            .disabled(!model.hasMore || model.isLoading)
            .help(Text("Next page"))
            .accessibilityLabel(Text("Next page"))
            Button {
                Task { await model.reload() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .disabled(model.isLoading)
            .help(Text("Reload rows"))
            .accessibilityLabel(Text("Reload rows"))
            Button {
                model.isInspectorVisible.toggle()
            } label: {
                Image(systemName: "sidebar.right")
            }
            .foregroundStyle(model.isInspectorVisible ? Color.accentColor : Color.secondary)
            .keyboardShortcut("i", modifiers: [.command, .option])
            .help(Text("Row inspector"))
            .accessibilityLabel(Text("Row inspector"))
        }
        .font(.system(size: 12))
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(.bar)
    }

    private func chooseExportFile(_ format: ExportFormat) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(model.ref.name).\(format.fileExtension)"
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url { model.export(to: url, format: format) }
    }

    /// Shown while changes are pending: how many, and the only three things that can be done with them.
    private var pendingControls: some View {
        HStack(spacing: 8) {
            Text("\(model.pendingCount) pending changes")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.orange)
            Button("Preview SQL") { model.isPreviewingChanges = true }
                .keyboardShortcut("p", modifiers: [.command, .shift])
            Button("Commit") { Task { await model.commitChanges() } }
                .keyboardShortcut("s")
                .disabled(model.isCommitting)
            Button("Discard") { model.discardChanges() }
            if let notice = model.notice {
                Text(verbatim: notice).foregroundStyle(.orange).lineLimit(1)
            }
        }
        .sheet(isPresented: $model.isPreviewingChanges) {
            ChangePreviewSheet(model: model)
        }
    }

    @ViewBuilder private var countView: some View {
        if let exact = model.exactCount {
            Text("of \(exact)").foregroundStyle(.secondary).monospacedDigit()
        } else {
            if let estimate = model.estimatedCount {
                Text("of about \(estimate)").foregroundStyle(.secondary).monospacedDigit()
            }
            if model.isCounting {
                ProgressView().controlSize(.small)
            } else if model.hasMore || model.pageIndex > 0 {
                Button("Count rows") { Task { await model.countRows() } }
                    .help(Text("Runs an exact count, which can be slow on a large table"))
            }
        }
    }
}

/// The statements a commit would run, shown before they run.
struct ChangePreviewSheet: View {
    @Environment(\.dismiss) private var dismiss
    let model: TableTabModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(model.pendingCount) pending changes on \(model.ref.displayName)").font(.headline)
            Text("These statements run in one transaction. If one fails, none is applied.")
                .font(.callout)
                .foregroundStyle(.secondary)
            ScrollView {
                Text(verbatim: model.previewSQL)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .frame(minHeight: 140, maxHeight: 320)
            .background(Theme.softFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.softStroke))
            HStack {
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(model.previewSQL, forType: .string)
                }
                .buttonStyle(.soft)
                Spacer()
                Button("Close", role: .cancel) { dismiss() }
                    .buttonStyle(.soft)
                    .keyboardShortcut(.cancelAction)
                Button("Commit") { Task { await model.commitChanges() } }
                    .buttonStyle(.gradient)
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.isCommitting)
            }
        }
        .padding(20)
        .frame(width: 620)
    }
}

/// A dismissible error shown above the content it concerns.
struct ErrorBanner: View {
    let message: String
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
            Text(verbatim: message)
                .font(.system(size: 12))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: dismiss) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(Text("Dismiss"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.red.opacity(0.12))
    }
}
