import RowsterCore
import SwiftUI

/// The schema of the connection: schemas, tables and views, with a search field.
struct SidebarView: View {
    @Bindable var model: WorkspaceModel
    @State private var selection: WorkspaceModel.SidebarItem?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.system(size: 11))
                TextField("Filter tables", text: $model.sidebarSearch)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
            }
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(Theme.softFill, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Theme.softStroke))
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            if let error = model.schemaError {
                ContentUnavailableView {
                    Label("Cannot read the schema", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(verbatim: error)
                } actions: {
                    Button("Retry") { Task { await model.reloadSchema() } }
                }
            } else if model.filteredNamespaces.allSatisfy({ $0.tables.isEmpty && $0.views.isEmpty }) {
                if model.isLoadingSchema {
                    ProgressView().controlSize(.small).frame(maxHeight: .infinity)
                } else if model.sidebarSearch.isEmpty {
                    ContentUnavailableView("No tables", systemImage: "tablecells")
                } else {
                    ContentUnavailableView.search(text: model.sidebarSearch)
                }
            } else {
                list
            }
        }
    }

    private var list: some View {
        List(selection: $selection) {
            ForEach(model.filteredNamespaces, id: \.name) { namespace in
                if let name = namespace.name {
                    DisclosureGroup {
                        objects(of: namespace)
                    } label: {
                        Label { Text(verbatim: name) } icon: { Image(systemName: "square.stack.3d.up") }
                    }
                } else {
                    objects(of: namespace)
                }
            }
        }
        .listStyle(.sidebar)
        .onChange(of: selection) { _, item in
            if let item { model.openTable(item, permanent: false) }
        }
        .contextMenu(forSelectionType: WorkspaceModel.SidebarItem.self) { items in
            if let item = items.first {
                Button("Open") { model.openTable(item, permanent: true) }
                Button("Copy Name") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(item.ref.name, forType: .string)
                }
            }
        } primaryAction: { items in
            if let item = items.first { model.openTable(item, permanent: true) }
        }
    }

    @ViewBuilder
    private func objects(of namespace: SchemaNamespace) -> some View {
        if !namespace.tables.isEmpty {
            Section("Tables") {
                ForEach(namespace.tables, id: \.self) { table in
                    Label { Text(verbatim: table).lineLimit(1) } icon: { Image(systemName: "tablecells") }
                        .tag(WorkspaceModel.SidebarItem(ref: TableRef(schema: namespace.name, name: table), kind: .table))
                }
            }
        }
        if !namespace.views.isEmpty {
            Section("Views") {
                ForEach(namespace.views, id: \.self) { view in
                    Label { Text(verbatim: view).lineLimit(1) } icon: { Image(systemName: "eye") }
                        .tag(WorkspaceModel.SidebarItem(ref: TableRef(schema: namespace.name, name: view), kind: .view))
                }
            }
        }
        if !namespace.functions.isEmpty {
            Section("Functions") {
                ForEach(namespace.functions, id: \.self) { function in
                    Label { Text(verbatim: function).lineLimit(1) } icon: { Image(systemName: "function") }
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
