import AppKit
import RowsterCore
import SwiftUI

/// The selected row as a form: one field per column, with a tree for JSON and a preview for binary values.
struct InspectorView: View {
    @Bindable var model: TableTabModel

    var body: some View {
        Group {
            if let row = model.inspectedRow {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(Array(model.columns.enumerated()), id: \.offset) { index, column in
                            InspectorField(model: model, row: row, column: index, description: column)
                        }
                    }
                    .padding(12)
                }
            } else {
                ContentUnavailableView {
                    Label("No row selected", systemImage: "sidebar.right")
                } description: {
                    Text("Select one row to see all its values.")
                }
            }
        }
        .frame(minWidth: 240, idealWidth: 320, maxWidth: 560, maxHeight: .infinity)
        .background(.background)
    }
}

private struct InspectorField: View {
    let model: TableTabModel
    let row: Int
    let column: Int
    let description: GridColumn

    var body: some View {
        let value = model.gridValue(row: row, column: column)
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(verbatim: description.title).font(.system(size: 11, weight: .semibold))
                Text(verbatim: description.typeName).font(.system(size: 10)).foregroundStyle(.secondary)
                if model.isKeyColumn(column) {
                    Image(systemName: "key.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(Text("Primary key"))
                }
                Spacer(minLength: 0)
            }
            content(value)
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func content(_ value: SQLValue) -> some View {
        switch value {
        case .null:
            Text(verbatim: "NULL").font(.system(size: 12).italic()).foregroundStyle(.tertiary)
        case .bytes, .deferredBytes:
            BinaryField(model: model, row: row, column: column, value: value)
        case .text(let text):
            if description.kind == .json || text.first == "{" || text.first == "[", let json = JSONValue.parse(text) {
                JSONTreeView(label: nil, value: json, depth: 0)
            } else {
                plain(text)
            }
        default:
            plain(value.displayText ?? "")
        }
    }

    private func plain(_ text: String) -> some View {
        Text(verbatim: text.isEmpty ? " " : text)
            .font(.system(size: 12))
            .textSelection(.enabled)
            .lineLimit(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
            .background(Theme.softFill, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Theme.softStroke))
    }
}

/// A binary value: its size, and on demand an image or a hex dump.
private struct BinaryField: View {
    let model: TableTabModel
    let row: Int
    let column: Int
    let value: SQLValue
    @State private var isLoading = false

    var body: some View {
        let data = model.blob(row: row, column: column)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(verbatim: value.displayText ?? "").font(.system(size: 12)).foregroundStyle(.secondary)
                if let data, let type = BinaryPreview.imageType(of: data) {
                    Text(verbatim: type).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                }
                if data == nil {
                    if isLoading {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Load") {
                            isLoading = true
                            Task {
                                await model.loadBlob(row: row, column: column)
                                isLoading = false
                            }
                        }
                        .controlSize(.small)
                    }
                }
            }
            if let data {
                if BinaryPreview.imageType(of: data) != nil, let image = NSImage(data: data) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: min(image.size.width, 280), maxHeight: 200, alignment: .leading)
                        .accessibilityLabel(Text("Image preview"))
                } else {
                    ScrollView(.horizontal) {
                        Text(verbatim: BinaryPreview.hexDump(data, limit: 1024))
                            .font(.system(size: 10.5, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
            }
        }
    }
}

/// A JSON value as a tree that can be folded.
struct JSONTreeView: View {
    let label: String?
    let value: JSONValue
    let depth: Int
    @State private var isExpanded: Bool

    init(label: String?, value: JSONValue, depth: Int) {
        self.label = label
        self.value = value
        self.depth = depth
        _isExpanded = State(initialValue: depth < 2)
    }

    var body: some View {
        switch value {
        case .object(let members):
            DisclosureGroup(isExpanded: $isExpanded) {
                ForEach(Array(members.prefix(500).enumerated()), id: \.offset) { _, member in
                    JSONTreeView(label: member.key, value: member.value, depth: depth + 1)
                }
            } label: {
                row
            }
        case .array(let items):
            DisclosureGroup(isExpanded: $isExpanded) {
                ForEach(Array(items.prefix(500).enumerated()), id: \.offset) { index, item in
                    JSONTreeView(label: String(index), value: item, depth: depth + 1)
                }
            } label: {
                row
            }
        default:
            row.padding(.leading, 14)
        }
    }

    private var row: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if let label {
                Text(verbatim: label).font(.system(size: 11.5, weight: .medium, design: .monospaced)).foregroundStyle(.secondary)
            }
            Text(verbatim: value.summary)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(value == .null || value.isContainer ? .tertiary : .primary)
                .textSelection(.enabled)
                .lineLimit(3)
            Spacer(minLength: 0)
        }
    }
}
