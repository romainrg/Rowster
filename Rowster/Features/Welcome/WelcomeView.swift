import RowsterCore
import SwiftUI

/// The welcome window: the app on the left, the connections on the right.
struct WelcomeView: View {
    @Environment(\.appEnvironment) private var env
    @State var model: ConnectionsModel
    var onConnect: (ConnectionProfile) -> Void = { _ in }

    @State private var selection: UUID?
    @State private var editing: EditedConnection?
    @State private var groupPrompt: GroupPrompt?
    @State private var pendingDeletion: ConnectionProfile?

    struct EditedConnection: Identifiable {
        let profile: ConnectionProfile
        let isNew: Bool
        var id: UUID { profile.id }
    }

    struct GroupPrompt: Identifiable {
        let id = UUID()
        var groupID: UUID?
        var name: String
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            connections
        }
        .frame(minWidth: 760, minHeight: 480)
        .background { ThemeGround() }
        .sheet(item: $editing) { edited in
            ConnectionFormView(
                draft: edited.profile, isNew: edited.isNew, groups: model.library.groups, model: model
            ) { profile, password in
                model.save(profile, password: password)
                selection = profile.id
            }
        }
        .sheet(item: $groupPrompt) { prompt in
            GroupNameSheet(prompt: prompt) { name in
                if let id = prompt.groupID { model.renameGroup(id, to: name) } else { model.addGroup(named: name) }
            }
        }
        .confirmationDialog(
            Text("Delete “\(pendingDeletion?.displayName ?? "")”?"),
            isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } })
        ) {
            Button("Delete", role: .destructive) {
                if let profile = pendingDeletion { model.delete(profile.id) }
                pendingDeletion = nil
            }
        } message: {
            Text("The connection and its saved password are removed from Rowster. The database is not touched.")
        }
        .alert(
            "Something went wrong",
            isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(verbatim: model.errorMessage ?? "")
        }
    }

    // MARK: - Left

    private var sidebar: some View {
        VStack(spacing: 10) {
            Spacer(minLength: 12)
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
                .accessibilityHidden(true)
            Text(verbatim: "Rowster")
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .foregroundStyle(Theme.wordmark)
            Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0")")
                .font(.callout)
                .foregroundStyle(.secondary)
            if env.isDemo {
                Text("Demo mode")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.quaternary, in: Capsule())
            }
            Spacer(minLength: 12)
            VStack(spacing: 8) {
                Button {
                    editing = EditedConnection(profile: ConnectionProfile(), isNew: true)
                } label: {
                    Label("New Connection", systemImage: "plus").frame(maxWidth: .infinity)
                }
                .buttonStyle(.gradient)
                .keyboardShortcut("n")
                Button {
                    groupPrompt = GroupPrompt(groupID: nil, name: "")
                } label: {
                    Label("New Group", systemImage: "folder.badge.plus").frame(maxWidth: .infinity)
                }
                .buttonStyle(.soft)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
        .frame(width: 230)
    }

    // MARK: - Right

    private var connections: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search connections", text: $model.searchText)
                    .textFieldStyle(.plain)
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(Theme.softFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.softStroke))
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 10)

            if model.isEmpty {
                ContentUnavailableView {
                    Label("No connections yet", systemImage: "cylinder.split.1x2")
                } description: {
                    Text("Create a connection, or paste a URL such as postgres://user@host/database in the form.")
                }
            } else if model.sections.allSatisfy(\.connections.isEmpty) {
                ContentUnavailableView.search(text: model.searchText)
            } else {
                list
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var list: some View {
        List(selection: $selection) {
            ForEach(model.sections) { section in
                if let group = section.group {
                    Section {
                        if !group.isCollapsed {
                            ForEach(section.connections) { profile in
                                ConnectionRow(profile: profile).tag(profile.id)
                            }
                        }
                    } header: {
                        groupHeader(group, count: section.connections.count)
                    }
                } else {
                    ForEach(section.connections) { profile in
                        ConnectionRow(profile: profile).tag(profile.id)
                    }
                }
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .contextMenu(forSelectionType: UUID.self) { ids in
            if let id = ids.first, let profile = model.profile(id) {
                Button("Connect") { onConnect(profile) }
                Button("Edit…") { editing = EditedConnection(profile: profile, isNew: false) }
                Button("Duplicate") { model.duplicate(id) }
                Button("Copy as URL") { model.copyURL(of: id) }
                Divider()
                Button("Delete…", role: .destructive) { pendingDeletion = profile }
            }
        } primaryAction: { ids in
            if let id = ids.first, let profile = model.profile(id) { onConnect(profile) }
        }
    }

    private func groupHeader(_ group: ConnectionGroup, count: Int) -> some View {
        HStack(spacing: 6) {
            Button {
                model.toggleCollapsed(group.id)
            } label: {
                Image(systemName: group.isCollapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 10, weight: .bold))
                    .frame(width: 14)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(group.isCollapsed ? Text("Expand \(group.name)") : Text("Collapse \(group.name)"))
            Text(verbatim: group.name).font(.system(size: 12, weight: .semibold))
            Text(verbatim: "\(count)").font(.system(size: 11)).foregroundStyle(.tertiary).monospacedDigit()
            Spacer()
        }
        .foregroundStyle(.secondary)
        .contentShape(Rectangle())
        .contextMenu {
            Button("Rename…") { groupPrompt = GroupPrompt(groupID: group.id, name: group.name) }
            Button("Delete Group", role: .destructive) { model.deleteGroup(group.id) }
        }
    }
}

/// One connection in the list: engine, name, target and environment.
struct ConnectionRow: View {
    let profile: ConnectionProfile

    var body: some View {
        HStack(spacing: 10) {
            EngineIcon(engine: profile.engine, size: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: profile.displayName).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text(verbatim: profile.summary)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            if profile.isReadOnlyOnOpen, profile.label != .production {
                Image(systemName: "lock.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .help(Text("Opens read-only"))
                    .accessibilityLabel(Text("Opens read-only"))
            }
            EnvironmentBadge(label: profile.label, color: profile.effectiveColor)
        }
        .padding(.vertical, 3)
    }
}

private struct GroupNameSheet: View {
    @Environment(\.dismiss) private var dismiss
    let prompt: WelcomeView.GroupPrompt
    let onCommit: (String) -> Void
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(prompt.groupID == nil ? "New Group" : "Rename Group").font(.headline)
            TextField("Group name", text: $name)
                .textFieldStyle(.roundedBorder)
                .frame(width: 280)
                .onSubmit(commit)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save", action: commit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .onAppear { name = prompt.name }
    }

    private func commit() {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        onCommit(name)
        dismiss()
    }
}
