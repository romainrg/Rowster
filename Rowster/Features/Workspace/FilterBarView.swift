import RowsterCore
import SwiftUI

/// The filter bar of a data tab: rows of column, operator and value, combined with AND or OR.
struct FilterBarView: View {
    @Bindable var model: TableTabModel
    @State private var isShowingSQL = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach($model.filters) { $condition in
                FilterRow(
                    condition: $condition, columns: model.columns.map(\.title),
                    remove: { model.removeFilter(condition.id) },
                    submit: { Task { await model.applyFilters() } })
            }
            HStack(spacing: 8) {
                Button {
                    model.addFilter()
                } label: {
                    Label("Add Filter", systemImage: "plus")
                }
                .buttonStyle(.borderless)
                if model.filters.count > 1 {
                    Picker("Match", selection: $model.filterMatch) {
                        Text("All conditions").tag(FilterMatch.all)
                        Text("Any condition").tag(FilterMatch.any)
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                }
                if let error = model.filterError {
                    Label { Text(verbatim: error) } icon: { Image(systemName: "exclamationmark.triangle.fill") }
                        .foregroundStyle(.red)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                if let sql = model.appliedFilterSQL {
                    Button("Show SQL") { isShowingSQL = true }
                        .buttonStyle(.borderless)
                        .popover(isPresented: $isShowingSQL, arrowEdge: .bottom) { SQLPopover(sql: sql) }
                }
                Button("Clear") { Task { await model.clearFilters() } }
                    .buttonStyle(.soft)
                    .controlSize(.small)
                    .disabled(model.filters.isEmpty && model.appliedFilterSQL == nil)
                Button("Apply") { Task { await model.applyFilters() } }
                    .buttonStyle(.gradient)
                    .controlSize(.small)
                    .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .font(.system(size: 12))
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

private struct FilterRow: View {
    @Binding var condition: FilterCondition
    let columns: [String]
    let remove: () -> Void
    let submit: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Toggle("Enabled", isOn: $condition.isEnabled).labelsHidden().toggleStyle(.checkbox)
            Picker("Column", selection: $condition.target) {
                Text("Any column").tag(FilterCondition.Target.anyColumn)
                Text("SQL condition").tag(FilterCondition.Target.rawSQL)
                Divider()
                ForEach(columns, id: \.self) { column in
                    Text(verbatim: column).tag(FilterCondition.Target.column(column))
                }
            }
            .labelsHidden()
            .frame(width: 170)
            .onChange(of: condition.target) { _, target in
                if target == .anyColumn { condition.op = .contains }
            }

            switch condition.target {
            case .rawSQL:
                TextField("SQL condition", text: $condition.value, prompt: Text(verbatim: "total > 100 AND status = 'paid'"))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                    .onSubmit(submit)
            case .anyColumn:
                Text("contains").foregroundStyle(.secondary).frame(width: 120, alignment: .leading)
                valueField
            case .column:
                Picker("Operator", selection: $condition.op) {
                    ForEach(FilterOperator.allCases, id: \.self) { op in
                        Text(op.title).tag(op)
                    }
                }
                .labelsHidden()
                .frame(width: 120)
                if condition.op.needsValue { valueField }
                if condition.op.needsSecondValue {
                    Text("and").foregroundStyle(.secondary)
                    TextField("Second value", text: $condition.secondValue)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(submit)
                }
                if !condition.op.needsValue { Spacer(minLength: 0) }
            }
            Button(action: remove) {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(Text("Remove filter"))
        }
    }

    private var valueField: some View {
        TextField("Value", text: $condition.value, prompt: condition.op == .isIn ? Text("a, b, c") : nil)
            .textFieldStyle(.roundedBorder)
            .onSubmit(submit)
    }
}

/// SQL shown for reading, with a copy button. The text is for display: it is never executed.
struct SQLPopover: View {
    let sql: String

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            ScrollView {
                Text(verbatim: sql)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 220)
            Button("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(sql, forType: .string)
            }
        }
        .padding(12)
        .frame(width: 460)
    }
}

extension FilterOperator {
    var title: LocalizedStringKey {
        switch self {
        case .equals: return "="
        case .notEquals: return "≠"
        case .lessThan: return "<"
        case .lessOrEqual: return "≤"
        case .greaterThan: return ">"
        case .greaterOrEqual: return "≥"
        case .contains: return "contains"
        case .startsWith: return "starts with"
        case .endsWith: return "ends with"
        case .isIn: return "in list"
        case .between: return "between"
        case .isNull: return "is null"
        case .isNotNull: return "is not null"
        }
    }
}
