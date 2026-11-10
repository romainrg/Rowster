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
    let activity = Activity()
    /// Number of statements running on the primary connection, for the activity indicator.
    var runningStatements: Int { activity.running }

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

    // MARK: - Safety

    /// Whether this connection opens read-only, and so shows a lock.
    var hasLock: Bool { profile.isReadOnlyOnOpen }
    var actionError: String?

    /// Unlocks writing for this window only. The caller has already shown a confirmation; Touch ID is
    /// asked on top when the user turned it on.
    func unlockWriting() async {
        guard let session, isReadOnly else { return }
        if UserDefaults.standard.bool(forKey: AppSettings.unlockRequiresAuthentication) {
            let reason = String(localized: "unlock writing on \(profile.displayName)")
            guard await env.authenticator.authenticate(reason: reason) else { return }
        }
        do {
            try await session.setReadOnly(false)
            isReadOnly = false
        } catch {
            actionError = Self.describe(error)
        }
    }

    /// Makes the window read-only again. If the server refuses, the session is closed rather than left writable.
    func lockWriting() async {
        guard let session, !isReadOnly else { return }
        do {
            try await session.setReadOnly(true)
            isReadOnly = true
        } catch {
            self.session = nil
            phase = .failed(Self.describe(error))
        }
    }

    struct HazardRequest: Identifiable {
        let id = UUID()
        let statements: [(sql: String, hazard: StatementInfo.Hazard)]
        let answer: (Bool) -> Void
    }

    var hazardRequest: HazardRequest?

    /// Shows the destructive statements and waits for the user's decision. Nothing runs before it returns.
    func confirm(hazards statements: [(sql: String, hazard: StatementInfo.Hazard)]) async -> Bool {
        guard !statements.isEmpty else { return true }
        return await withCheckedContinuation { continuation in
            hazardRequest = HazardRequest(statements: statements) { continuation.resume(returning: $0) }
        }
    }

    func answerHazard(_ confirmed: Bool) {
        let request = hazardRequest
        hazardRequest = nil
        request?.answer(confirmed)
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
        let model = TableTabModel(
            ref: item.ref, kind: item.kind, session: session, dialect: dialect, connectionID: profile.id,
            viewState: env.viewState, activity: activity)
        model.isReadOnly = { [weak self] in self?.isReadOnly ?? true }
        model.onFollowForeignKey = { [weak self] table, column, value in
            self?.showRow(in: table, column: column, value: value)
        }
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

    /// Follows a foreign key: opens the referenced table filtered on the key value.
    private func showRow(in table: TableRef, column: String, value: SQLValue) {
        openTable(SidebarItem(ref: table, kind: .table), permanent: true)
        guard let target = selectedTab?.table, target.ref == table else { return }
        Task { await target.setFilter(column: column, equals: value) }
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
