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
            DataGridView(source: model, revision: model.gridRevision, structureRevision: model.gridStructureRevision)
            Divider()
            footer
        }
        .task { await model.load() }
    }

    private var footer: some View {
        HStack(spacing: 10) {
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
            if model.rows.isEmpty {
                Text(model.isLoading ? "Loading…" : "No rows").foregroundStyle(.secondary)
            } else {
                Text("Rows \(model.firstRowNumber)–\(model.lastRowNumber)").monospacedDigit()
            }
            countView
            if model.isLoading { ProgressView().controlSize(.small) }
            Spacer(minLength: 8)
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
        }
        .font(.system(size: 12))
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(.bar)
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
