import AppKit
import RowsterCore
import SwiftUI

/// The list of connections shown by the welcome window, and everything that changes it.
@MainActor
@Observable
final class ConnectionsModel {
    enum TestOutcome: Equatable {
        case success(String)
        case failure(String)
    }

    struct Section: Identifiable {
        let group: ConnectionGroup?
        let connections: [ConnectionProfile]
        var id: UUID? { group?.id }
    }

    private let env: AppEnvironment
    private(set) var library = ConnectionLibrary()
    var searchText = ""
    var errorMessage: String?

    init(env: AppEnvironment) {
        self.env = env
        do {
            library = try env.connections.load()
        } catch {
            errorMessage = ErrorText.describe(error)
        }
    }

    // MARK: - Reading

    var isEmpty: Bool { library.connections.isEmpty }

    /// Ungrouped connections first, then each group. Groups without a match are hidden while searching.
    var sections: [Section] {
        let matches = library.search(searchText)
        let isSearching = !searchText.trimmingCharacters(in: .whitespaces).isEmpty
        var sections: [Section] = []
        let knownGroups = Set(library.groups.map(\.id))
        let ungrouped = matches.filter { $0.groupID.map(knownGroups.contains) != true }
        if !ungrouped.isEmpty { sections.append(Section(group: nil, connections: ungrouped)) }
        for group in library.groups {
            let members = matches.filter { $0.groupID == group.id }
            if members.isEmpty, isSearching { continue }
            sections.append(Section(group: group, connections: members))
        }
        return sections
    }

    func profile(_ id: UUID) -> ConnectionProfile? {
        library.connections.first { $0.id == id }
    }

    func storedPassword(for profile: ConnectionProfile) -> String? {
        guard profile.usesPassword, profile.passwordStorage == .keychain else { return nil }
        return try? env.secrets.password(for: profile.id)
    }

    // MARK: - Changing

    /// Inserts or updates a connection. `password` is `nil` to leave the stored one untouched.
    func save(_ profile: ConnectionProfile, password: String?) {
        if let index = library.connections.firstIndex(where: { $0.id == profile.id }) {
            library.connections[index] = profile
        } else {
            library.connections.append(profile)
        }
        do {
            if profile.passwordStorage == .askEveryTime || !profile.usesPassword {
                try env.secrets.deletePassword(for: profile.id)
            } else if let password {
                try env.secrets.setPassword(password, for: profile.id)
            }
        } catch {
            errorMessage = ErrorText.describe(error)
        }
        persist()
    }

    func delete(_ id: UUID) {
        library.connections.removeAll { $0.id == id }
        try? env.secrets.deletePassword(for: id)
        persist()
    }

    func duplicate(_ id: UUID) {
        guard let original = profile(id) else { return }
        var copy = original
        copy.id = UUID()
        copy.name = String(localized: "\(original.displayName) copy")
        library.connections.append(copy)
        if let password = storedPassword(for: original) {
            try? env.secrets.setPassword(password, for: copy.id)
        }
        persist()
    }

    func addGroup(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        library.groups.append(ConnectionGroup(name: trimmed))
        persist()
    }

    func renameGroup(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let index = library.groups.firstIndex(where: { $0.id == id }) else { return }
        library.groups[index].name = trimmed
        persist()
    }

    /// Deletes a group; its connections stay, ungrouped.
    func deleteGroup(_ id: UUID) {
        library.groups.removeAll { $0.id == id }
        for index in library.connections.indices where library.connections[index].groupID == id {
            library.connections[index].groupID = nil
        }
        persist()
    }

    func toggleCollapsed(_ id: UUID) {
        guard let index = library.groups.firstIndex(where: { $0.id == id }) else { return }
        library.groups[index].isCollapsed.toggle()
        persist()
    }

    func copyURL(of id: UUID) {
        guard let profile = profile(id) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(ConnectionURL.string(for: profile), forType: .string)
    }

    // MARK: - Testing

    /// Opens the connection read-only, reads the server version and closes.
    func test(_ profile: ConnectionProfile, typedPassword: String) async -> TestOutcome {
        let password = typedPassword.isEmpty ? storedPassword(for: profile) : typedPassword
        // A test opens read-only, through the tunnel when there is one, and runs nothing: no bootstrap SQL.
        var readOnly = profile
        readOnly.opensReadOnly = true
        let session = env.makeSession(readOnly, password: password, runsBootstrap: false)
        do {
            try await session.open()
            let version = await session.serverVersion
            await session.close()
            return .success(version ?? profile.engine.displayName)
        } catch {
            await session.close()
            return .failure(WorkspaceModel.describe(error))
        }
    }

    private func persist() {
        do {
            try env.connections.save(library)
        } catch {
            errorMessage = ErrorText.describe(error)
        }
    }
}
