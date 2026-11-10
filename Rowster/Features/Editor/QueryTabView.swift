import RowsterCore
import SwiftUI

/// A query tab: the editor on top, one result per statement below.
struct QueryTabView: View {
    @Bindable var model: QueryTabModel
    @State private var isShowingHistory = false

    var body: some View {
        VSplitView {
            VStack(spacing: 0) {
                toolbar
                Divider()
                SQLEditorView(text: $model.text, selection: $model.selection, dialect: model.dialect)
            }
            .frame(minHeight: 120, idealHeight: 260)
            results.frame(minHeight: 120, maxHeight: .infinity)
        }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Button {
                Task { await model.runCurrent() }
            } label: {
                Label("Run", systemImage: "play.fill")
            }
            .buttonStyle(.gradient)
            .controlSize(.small)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(model.isRunning || model.isBlank)
            .help(Text("Run the statement under the cursor, or the selection"))
            Button("Run All") { Task { await model.runAll() } }
                .buttonStyle(.soft)
                .controlSize(.small)
                .keyboardShortcut(.return, modifiers: [.command, .shift])
                .disabled(model.isRunning || model.isBlank)
            if model.isRunning { ProgressView().controlSize(.small) }
            Spacer(minLength: 8)
            Button {
                model.loadHistory()
                isShowingHistory = true
            } label: {
                Label("History", systemImage: "clock.arrow.circlepath")
            }
            .buttonStyle(.borderless)
            .popover(isPresented: $isShowingHistory, arrowEdge: .bottom) {
                HistoryView(model: model) { isShowingHistory = false }
            }
        }
        .font(.system(size: 12))
        .padding(.horizontal, 10)
        .frame(height: 36)
        .background(.bar)
    }

    @ViewBuilder private var results: some View {
        if model.results.isEmpty {
            ContentUnavailableView {
                Label("No results yet", systemImage: "play.rectangle")
            } description: {
                Text("⌘↩ runs the statement under the cursor. ⇧⌘↩ runs every statement.")
            }
        } else {
            VStack(spacing: 0) {
                if model.results.count > 1 { resultTabs }
                if let result = model.selectedResult { ResultView(model: model, result: result) }
            }
        }
    }

    private var resultTabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(Array(model.results.enumerated()), id: \.element.id) { index, result in
                    let isSelected = result.id == model.selectedResult?.id
                    Button {
                        model.selectedResultID = result.id
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: result.error == nil ? "checkmark.circle.fill" : "xmark.octagon.fill")
                                .foregroundStyle(result.error == nil ? .green : .red)
                            Text("Statement \(index + 1)")
                        }
                        .font(.system(size: 11.5, weight: isSelected ? .semibold : .regular))
                        .padding(.horizontal, 8)
                        .frame(height: 22)
                        .background(isSelected ? Theme.softFill : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
        }
        .frame(height: 30)
        .background(.bar)
    }
}

/// The result of one statement: a grid, a count of affected rows, or the error.
private struct ResultView: View {
    let model: QueryTabModel
    let result: StatementResult

    var body: some View {
        VStack(spacing: 0) {
            if let error = result.error {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        Label { Text(verbatim: error).textSelection(.enabled) } icon: {
                            Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
                        }
                        Text(verbatim: result.sql)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                }
            } else if result.returnsRows {
                DataGridView(
                    source: ResultGridSource(result: result, dialect: model.dialect), revision: model.gridRevision,
                    structureRevision: result.id.hashValue)
            } else {
                VStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 28)).foregroundStyle(.green)
                    if let affected = result.rowsAffected {
                        Text("\(affected) rows affected").font(.headline)
                    } else {
                        Text("Done").font(.headline)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            HStack(spacing: 10) {
                if result.error == nil, result.returnsRows {
                    Text("\(result.rows.count) rows").monospacedDigit()
                }
                Text(verbatim: Self.format(result.duration)).foregroundStyle(.secondary).monospacedDigit()
                if result.isTruncated {
                    Text("Only the first \(result.limit) rows were fetched.").foregroundStyle(.orange)
                    Button("Load More") { Task { await model.loadMore(result.id) } }
                        .disabled(model.isRunning)
                }
                Spacer()
            }
            .font(.system(size: 12))
            .buttonStyle(.borderless)
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(.bar)
        }
    }

    private static func format(_ duration: TimeInterval) -> String {
        duration < 1 ? String(format: "%.0f ms", duration * 1000) : String(format: "%.2f s", duration)
    }
}

/// The statements run on this connection, most recent first, with a search field.
private struct HistoryView: View {
    let model: QueryTabModel
    let close: () -> Void
    @State private var search = ""

    var body: some View {
        let entries = model.historyEntries.search(search)
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search history", text: $search).textFieldStyle(.plain)
                Button("Clear History") { model.clearHistory() }
                    .buttonStyle(.borderless)
                    .disabled(model.historyEntries.isEmpty)
            }
            .padding(10)
            Divider()
            if entries.isEmpty {
                ContentUnavailableView("No statements", systemImage: "clock")
            } else {
                List(entries) { entry in
                    Button {
                        model.insert(entry)
                        close()
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: entry.sql)
                                .font(.system(size: 11.5, design: .monospaced))
                                .lineLimit(3)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            HStack(spacing: 6) {
                                Image(systemName: entry.succeeded ? "checkmark.circle.fill" : "xmark.octagon.fill")
                                    .foregroundStyle(entry.succeeded ? .green : .red)
                                Text(entry.date, format: .dateTime.day().month().hour().minute())
                                if let rows = entry.rowCount { Text("\(rows) rows") }
                            }
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.plain)
            }
        }
        .frame(width: 520, height: 380)
    }
}
