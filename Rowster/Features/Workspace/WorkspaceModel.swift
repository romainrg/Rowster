import RowsterCore
import SwiftUI

/// The state of one work window: its session, the schema shown in the sidebar and the open tabs.
@MainActor
@Observable
final class WorkspaceModel {
    enum Phase: Equatable {
        case needsPassword
        case connecting
        case failed(String)
        case ready
    }

    struct SidebarItem: Hashable {
        let ref: TableRef
        let kind: SchemaObjectKind
    }

    let profile: ConnectionProfile
    private let env: AppEnvironment
    private(set) var session: Session?

    private(set) var phase: Phase = .connecting
    private(set) var isReadOnly: Bool
    private(set) var serverVersion: String?
    private(set) var dialect: any SQLDialect
    private(set) var namespaces: [SchemaNamespace] = []
    private(set) var databases: [String] = []
    private(set) var currentDatabase: String
    private(set) var isLoadingSchema = false
    var schemaError: String?
    var sidebarSearch = ""

    private(set) var tabs: [WorkspaceTab] = []
    var selectedTabID: UUID?
    private var queryCount = 0
    /// Number of statements running on the primary connection, for the activity indicator.
    var runningStatements = 0

    init(profile: ConnectionProfile, env: AppEnvironment) {
        self.profile = profile
        self.env = env
        isReadOnly = profile.isReadOnlyOnOpen
        dialect = profile.engine.dialect
        currentDatabase = profile.database
    }

    var selectedTab: WorkspaceTab? { tabs.first { $0.id == selectedTabID } }

    // MARK: - Connecting

    /// Connects with the saved password, or asks for one when the connection is set to ask every time.
    func start() async {
        guard profile.usesPassword else { return await connect(password: nil) }
        if profile.passwordStorage == .askEveryTime {
            phase = .needsPassword
        } else {
            await connect(password: try? env.secrets.password(for: profile.id))
        }
    }

    func connect(password: String?) async {
        phase = .connecting
        let session = Session(profile: profile, password: password, provider: env.drivers)
        do {
            try await session.open()
        } catch {
            phase = .failed(Self.describe(error))
            return
        }
        self.session = session
        dialect = await session.dialect
        isReadOnly = await session.isReadOnly
        serverVersion = await session.serverVersion
        phase = .ready
        await reloadSchema()
        databases = (try? await session.databases()) ?? []
    }

    func disconnect() async {
        await session?.close()
        session = nil
    }

    func reloadSchema() async {
        guard let session else { return }
        isLoadingSchema = true
        defer { isLoadingSchema = false }
        do {
            namespaces = try await session.namespaces()
            schemaError = nil
        } catch {
            schemaError = Self.describe(error)
        }
    }

    /// Reconnects to another database of the same server. Open tabs belong to the old one and are closed.
    func switchDatabase(_ name: String) async {
        guard let session, name != currentDatabase else { return }
        phase = .connecting
        tabs = []
        selectedTabID = nil
        namespaces = []
        do {
            try await session.switchDatabase(name)
            currentDatabase = name
            phase = .ready
            await reloadSchema()
        } catch {
            phase = .failed(Self.describe(error))
        }
    }

    func cancelRunningStatement() async {
        await session?.cancel()
    }

    // MARK: - Sidebar

    /// The namespaces with only the objects whose name matches the sidebar search.
    var filteredNamespaces: [SchemaNamespace] {
        let needle = sidebarSearch.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return namespaces }
        return namespaces.compactMap { namespace in
            var filtered = namespace
            filtered.tables = namespace.tables.filter { $0.lowercased().contains(needle) }
            filtered.views = namespace.views.filter { $0.lowercased().contains(needle) }
            filtered.functions = namespace.functions.filter { $0.lowercased().contains(needle) }
            return filtered.tables.isEmpty && filtered.views.isEmpty && filtered.functions.isEmpty ? nil : filtered
        }
    }

    // MARK: - Tabs

    /// Opens a table. A single click opens a preview tab, which the next single click replaces;
    /// a double click makes the tab permanent.
    func openTable(_ item: SidebarItem, permanent: Bool) {
        guard let session else { return }
        if let existing = tabs.first(where: { $0.table?.ref == item.ref }) {
            if permanent { existing.isPreview = false }
            selectedTabID = existing.id
            return
        }
        let model = TableTabModel(ref: item.ref, kind: item.kind, session: session, dialect: dialect)
        let tab = WorkspaceTab(content: .table(model), isPreview: !permanent)
        if let previewIndex = tabs.firstIndex(where: \.isPreview) {
            tabs[previewIndex] = tab
        } else if let blankIndex = tabs.firstIndex(where: Self.isBlankQuery) {
            tabs[blankIndex] = tab
        } else {
            tabs.append(tab)
        }
        selectedTabID = tab.id
    }

    func newQueryTab() {
        if let blank = tabs.first(where: Self.isBlankQuery) {
            selectedTabID = blank.id
            return
        }
        queryCount += 1
        let tab = WorkspaceTab(content: .query(QueryTabModel(number: queryCount)))
        tabs.append(tab)
        selectedTabID = tab.id
    }

    func closeTab(_ id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs.remove(at: index)
        if selectedTabID == id {
            selectedTabID = tabs.indices.contains(index) ? tabs[index].id : tabs.last?.id
        }
    }

    func closeSelectedTab() {
        if let selectedTabID { closeTab(selectedTabID) }
    }

    private static func isBlankQuery(_ tab: WorkspaceTab) -> Bool {
        if case .query(let model) = tab.content { return model.isBlank }
        return false
    }

    static func describe(_ error: Error) -> String {
        switch error {
        case SessionError.readOnly(let verb):
            return String(localized: "This connection is read-only: \(verb) was not sent. Unlock writing to run it.")
        case SessionError.needsConfirmation:
            return String(localized: "This statement must be confirmed before it runs.")
        case SessionError.notOpen:
            return String(localized: "The connection is closed.")
        default:
            return ErrorText.describe(error)
        }
    }
}
