import RowsterCore
import SwiftUI

/// A work window: one connection, its schema on the left and its tabs on the right.
struct WorkspaceView: View {
    @Bindable var model: WorkspaceModel
    @State private var typedPassword = ""
    @State private var isChoosingDatabase = false

    private var tint: Color { model.profile.effectiveColor.color }

    var body: some View {
        NavigationSplitView {
            SidebarView(model: model)
                .navigationSplitViewColumnWidth(min: 180, ideal: 230, max: 360)
        } detail: {
            detail
        }
        .navigationTitle(Text(verbatim: model.profile.displayName))
        .navigationSubtitle(Text(verbatim: subtitle))
        .toolbar { toolbar }
        .toolbarBackground(tint.opacity(model.profile.label == .none ? 0.10 : 0.30), for: .windowToolbar)
        .toolbarBackground(.visible, for: .windowToolbar)
        .background(Theme.ground)
        // A strip in the connection color, so the environment stays visible whatever the toolbar shows.
        .overlay(alignment: .top) {
            if model.profile.label != .none { tint.frame(height: 3).accessibilityHidden(true) }
        }
        .focusedSceneValue(\.workspace, model)
    }

    private var subtitle: String {
        [model.serverVersion, model.currentDatabase.isEmpty ? nil : model.currentDatabase]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    // MARK: - Detail

    @ViewBuilder private var detail: some View {
        switch model.phase {
        case .needsPassword:
            passwordPrompt
        case .connecting:
            VStack(spacing: 10) {
                ProgressView()
                Text("Connecting…").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            ContentUnavailableView {
                Label("Connection failed", systemImage: "bolt.horizontal.circle")
            } description: {
                Text(verbatim: message).textSelection(.enabled)
            } actions: {
                Button("Retry") { Task { await model.start() } }.buttonStyle(.gradient)
            }
        case .ready:
            VStack(spacing: 0) {
                TabBarView(model: model)
                Divider()
                tabContent.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    @ViewBuilder private var tabContent: some View {
        if let tab = model.selectedTab {
            switch tab.content {
            case .table(let table):
                TableTabView(model: table).id(tab.id)
            case .query(let query):
                QueryTabView(model: query).id(tab.id)
            }
        } else {
            ContentUnavailableView {
                Label("Nothing open", systemImage: "rectangle.dashed")
            } description: {
                Text("Select a table in the sidebar, or press ⌘T for a new query.")
            }
        }
    }

    private var passwordPrompt: some View {
        VStack(spacing: 12) {
            EngineIcon(engine: model.profile.engine, size: 44)
            Text("Password for \(model.profile.displayName)").font(.headline)
            SecureField("Password", text: $typedPassword)
                .textFieldStyle(.roundedBorder)
                .frame(width: 260)
                .onSubmit(connectWithTypedPassword)
            Button("Connect", action: connectWithTypedPassword)
                .buttonStyle(.gradient)
                .keyboardShortcut(.defaultAction)
            Text("The password is used for this window only and is not saved.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func connectWithTypedPassword() {
        let password = typedPassword
        typedPassword = ""
        Task { await model.connect(password: password) }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            EnvironmentBadge(label: model.profile.label, color: model.profile.effectiveColor, prominent: true)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            if model.runningStatements > 0 {
                ProgressView().controlSize(.small)
                Button {
                    Task { await model.cancelRunningStatement() }
                } label: {
                    Label("Cancel", systemImage: "stop.fill")
                }
                .help(Text("Cancel the running statement"))
            }
            if !model.databases.isEmpty {
                Button {
                    isChoosingDatabase = true
                } label: {
                    Label { Text(verbatim: model.currentDatabase) } icon: { Image(systemName: "cylinder.split.1x2") }
                        .labelStyle(.titleAndIcon)
                }
                .keyboardShortcut("k")
                .help(Text("Switch database"))
                .popover(isPresented: $isChoosingDatabase, arrowEdge: .bottom) {
                    DatabasePicker(databases: model.databases, current: model.currentDatabase) { name in
                        isChoosingDatabase = false
                        Task { await model.switchDatabase(name) }
                    }
                }
            }
            if model.isReadOnly {
                Label("Read-only", systemImage: "lock.fill")
                    .labelStyle(.titleAndIcon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(tint)
                    .help(Text("This connection is read-only"))
            }
            Button {
                Task { await model.reloadSchema() }
            } label: {
                Label("Reload schema", systemImage: "arrow.clockwise")
            }
            .keyboardShortcut("r")
            .help(Text("Reload schema"))
        }
    }
}

/// The list of databases of the server, with a filter.
private struct DatabasePicker: View {
    let databases: [String]
    let current: String
    let choose: (String) -> Void
    @State private var filter = ""

    private var matches: [String] {
        let needle = filter.trimmingCharacters(in: .whitespaces).lowercased()
        return needle.isEmpty ? databases : databases.filter { $0.lowercased().contains(needle) }
    }

    var body: some View {
        VStack(spacing: 0) {
            TextField("Filter databases", text: $filter)
                .textFieldStyle(.roundedBorder)
                .padding(8)
                .onSubmit { if let first = matches.first { choose(first) } }
            List(matches, id: \.self) { name in
                Button {
                    choose(name)
                } label: {
                    HStack {
                        Text(verbatim: name)
                        Spacer()
                        if name == current { Image(systemName: "checkmark").foregroundStyle(.secondary) }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .listStyle(.plain)
        }
        .frame(width: 260, height: 300)
    }
}

/// Placeholder content of a table tab, replaced by the data grid.
struct TableTabView: View {
    let model: TableTabModel

    var body: some View {
        ContentUnavailableView {
            Label { Text(verbatim: model.ref.displayName) } icon: { Image(systemName: "tablecells") }
        } description: {
            if let error = model.errorMessage {
                Text(verbatim: error)
            } else if let structure = model.structure {
                Text("\(structure.columns.count) columns")
            }
        }
        .task { await model.loadStructure() }
    }
}

/// Placeholder content of a query tab, replaced by the SQL editor.
struct QueryTabView: View {
    @Bindable var model: QueryTabModel

    var body: some View {
        TextEditor(text: $model.text)
            .font(.system(size: 13, design: .monospaced))
            .scrollContentBackground(.hidden)
            .padding(8)
    }
}

// MARK: - Commands

struct WorkspaceFocusedKey: FocusedValueKey {
    typealias Value = WorkspaceModel
}

extension FocusedValues {
    var workspace: WorkspaceModel? {
        get { self[WorkspaceFocusedKey.self] }
        set { self[WorkspaceFocusedKey.self] = newValue }
    }
}

/// Menu commands that act on the frontmost work window.
struct WorkspaceCommands: Commands {
    @FocusedValue(\.workspace) private var workspace

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("New Query Tab") { workspace?.newQueryTab() }
                .keyboardShortcut("t")
                .disabled(workspace?.phase != .ready)
            Button("Close Tab") { workspace?.closeSelectedTab() }
                .keyboardShortcut("w", modifiers: [.command, .shift])
                .disabled(workspace?.selectedTab == nil)
        }
    }
}
