import RowsterCore
import SwiftUI

struct ScreenshotScene {
    let name: String
    /// Window title: SwiftUI's navigation title does not reach an offscreen window.
    var title = "Rowster"
    let size: CGSize
    /// Builds the view. It may connect to the demo database first, so the scene renders loaded content.
    let make: @MainActor () async -> AnyView
}

enum ScreenshotScenes {
    @MainActor
    static var all: [ScreenshotScene] {
        welcomeScenes + workspaceScenes
    }

    @MainActor
    private static var welcomeScenes: [ScreenshotScene] {
        [
            ScreenshotScene(name: "welcome", size: CGSize(width: 760, height: 480)) {
                let env = AppEnvironment.demo()
                return AnyView(WelcomeView(model: ConnectionsModel(env: env)).environment(\.appEnvironment, env))
            },
            ScreenshotScene(name: "welcome-empty", size: CGSize(width: 760, height: 480)) {
                var env = AppEnvironment.demo()
                env.connections = MemoryConnectionStore()
                return AnyView(WelcomeView(model: ConnectionsModel(env: env)).environment(\.appEnvironment, env))
            },
            ScreenshotScene(name: "form-postgres", size: CGSize(width: 560, height: 640)) {
                let env = AppEnvironment.demo()
                let model = ConnectionsModel(env: env)
                return AnyView(
                    ConnectionFormView(
                        draft: DemoData.production, isNew: false, groups: DemoData.library.groups, model: model
                    ) { _, _ in }
                    .environment(\.appEnvironment, env))
            },
            ScreenshotScene(name: "form-sqlite", size: CGSize(width: 560, height: 640)) {
                let env = AppEnvironment.demo()
                let model = ConnectionsModel(env: env)
                return AnyView(
                    ConnectionFormView(draft: DemoData.local, isNew: true, groups: DemoData.library.groups, model: model) { _, _ in }
                        .environment(\.appEnvironment, env))
            }
        ]
    }

    /// A connected work window on the demo database.
    @MainActor
    static func workspace(_ profile: ConnectionProfile, configure: @MainActor (WorkspaceModel) async -> Void = { _ in }) async -> AnyView {
        let env = AppEnvironment.demo()
        let model = WorkspaceModel(profile: profile, env: env)
        await model.start()
        await configure(model)
        return AnyView(WorkspaceView(model: model).environment(\.appEnvironment, env))
    }

    private static let windowSize = CGSize(width: 1180, height: 720)

    /// Opens the customers table and makes one edit, one deletion and one new row, without committing.
    @MainActor
    private static func pendingChanges(_ model: WorkspaceModel) async {
        model.openTable(.init(ref: TableRef(name: "customers"), kind: .table), permanent: true)
        guard let customers = model.selectedTab?.table else { return }
        await customers.load()
        customers.gridCommit(text: "Ada Lovelace", row: 0, column: 1)
        customers.gridCommit(text: "1", row: 3, column: 4)
        customers.gridSelectionChanged(rows: IndexSet(integer: 5), column: nil)
        customers.gridDeleteSelection()
        customers.addRow()
        customers.gridCommit(text: "Grace O'Neil", row: customers.gridRowCount - 1, column: 1)
        customers.gridCommit(text: "grace@example.com", row: customers.gridRowCount - 1, column: 2)
        customers.gridCommit(text: "IE", row: customers.gridRowCount - 1, column: 3)
        customers.gridCommit(text: "2026-11-02 09:00:00", row: customers.gridRowCount - 1, column: 5)
    }

    @MainActor
    private static var workspaceScenes: [ScreenshotScene] {
        [
            ScreenshotScene(name: "workspace-empty", title: DemoData.staging.name, size: windowSize) {
                await workspace(DemoData.staging)
            },
            ScreenshotScene(name: "workspace-production", title: DemoData.production.name, size: windowSize) {
                await workspace(DemoData.production) { model in
                    model.openTable(.init(ref: TableRef(name: "customers"), kind: .table), permanent: true)
                    model.openTable(.init(ref: TableRef(name: "orders"), kind: .table), permanent: false)
                    model.newQueryTab()
                    model.selectedTabID = model.tabs.first?.id
                }
            },
            ScreenshotScene(name: "data-grid", title: DemoData.staging.name, size: windowSize) {
                await workspace(DemoData.staging) { model in
                    model.openTable(.init(ref: TableRef(name: "customers"), kind: .table), permanent: true)
                    model.openTable(.init(ref: TableRef(name: "orders"), kind: .table), permanent: true)
                    guard let orders = model.selectedTab?.table else { return }
                    await orders.load()
                    orders.gridToggleSort(column: 2, additive: false)
                    orders.gridToggleSort(column: 3, additive: true)
                    orders.gridToggleSort(column: 3, additive: true)
                    try? await Task.sleep(for: .milliseconds(300))
                }
            },
            ScreenshotScene(name: "filters", title: DemoData.local.name, size: windowSize) {
                await workspace(DemoData.local) { model in
                    model.openTable(.init(ref: TableRef(name: "orders"), kind: .table), permanent: true)
                    guard let orders = model.selectedTab?.table else { return }
                    await orders.load()
                    orders.filters = [
                        FilterCondition(target: .column("status"), op: .isIn, value: "failed, cancelled"),
                        FilterCondition(target: .column("total"), op: .greaterOrEqual, value: "100"),
                        FilterCondition(target: .rawSQL, value: "note IS NOT NULL")
                    ]
                    orders.isFilterBarVisible = true
                    await orders.applyFilters()
                }
            },
            ScreenshotScene(name: "inspector", title: DemoData.local.name, size: windowSize) {
                await workspace(DemoData.local) { model in
                    model.openTable(.init(ref: TableRef(name: "products"), kind: .table), permanent: true)
                    guard let products = model.selectedTab?.table else { return }
                    await products.load()
                    products.isInspectorVisible = true
                    products.gridSelectionChanged(rows: IndexSet(integer: 3), column: 1)
                    await products.loadBlob(row: 3, column: 5)
                }
            },
            ScreenshotScene(name: "foreign-key-preview", title: "orders", size: CGSize(width: 320, height: 220)) {
                let env = AppEnvironment.demo()
                let model = WorkspaceModel(profile: DemoData.local, env: env)
                await model.start()
                model.openTable(.init(ref: TableRef(name: "orders"), kind: .table), permanent: true)
                guard let orders = model.selectedTab?.table else { return AnyView(EmptyView()) }
                await orders.load()
                guard let preview = await orders.gridForeignKeyPreview(row: 0, column: 1) else { return AnyView(EmptyView()) }
                return AnyView(ForeignKeyPreviewView(preview: preview).frame(maxWidth: .infinity, maxHeight: .infinity))
            },
            ScreenshotScene(name: "unlocked", title: DemoData.production.name, size: windowSize) {
                await workspace(DemoData.production) { model in
                    model.openTable(.init(ref: TableRef(name: "customers"), kind: .table), permanent: true)
                    await model.unlockWriting()
                }
            },
            ScreenshotScene(name: "hazard", title: DemoData.production.name, size: CGSize(width: 520, height: 330)) {
                let request = WorkspaceModel.HazardRequest(
                    statements: [
                        (sql: "DELETE FROM orders", hazard: .deleteWithoutWhere),
                        (sql: "DROP TABLE audit_log", hazard: .drop)
                    ]) { _ in }
                return AnyView(HazardSheet(request: request, profile: DemoData.production) { _ in })
            },
            ScreenshotScene(name: "settings", title: "Rowster", size: CGSize(width: 480, height: 360)) {
                AnyView(SettingsView().environment(\.appEnvironment, AppEnvironment.demo()))
            },
            ScreenshotScene(name: "pending-changes", title: DemoData.local.name, size: windowSize) {
                await workspace(DemoData.local) { model in await pendingChanges(model) }
            },
            ScreenshotScene(name: "change-preview", title: DemoData.local.name, size: CGSize(width: 620, height: 420)) {
                let env = AppEnvironment.demo()
                let model = WorkspaceModel(profile: DemoData.local, env: env)
                await model.start()
                await pendingChanges(model)
                guard let customers = model.selectedTab?.table else { return AnyView(EmptyView()) }
                return AnyView(ChangePreviewSheet(model: customers))
            },
            ScreenshotScene(name: "editor", title: DemoData.staging.name, size: windowSize) {
                await workspace(DemoData.staging) { model in
                    model.newQueryTab()
                    guard case .query(let query)? = model.selectedTab?.content else { return }
                    query.text = """
                    -- Revenue by country, delivered orders only
                    SELECT c.country, count(*) AS orders, round(sum(o.total), 2) AS revenue
                    FROM orders o
                    JOIN customers c ON c.id = o.customer_id
                    WHERE o.status = 'delivered' AND o.total > 20
                    GROUP BY c.country
                    ORDER BY revenue DESC;

                    SELECT name, price FROM products WHERE price > 50;

                    SELECT * FROM missing_table;
                    """
                    await query.runAll()
                    query.selectedResultID = query.results.first?.id
                }
            },
            ScreenshotScene(name: "editor-error", title: DemoData.production.name, size: windowSize) {
                await workspace(DemoData.production) { model in
                    model.newQueryTab()
                    guard case .query(let query)? = model.selectedTab?.content else { return }
                    query.text = "UPDATE customers SET vip = 1 WHERE country = 'FR';"
                    await query.runAll()
                }
            },
            ScreenshotScene(name: "structure", title: DemoData.local.name, size: windowSize) {
                await workspace(DemoData.local) { model in
                    model.openTable(.init(ref: TableRef(name: "orders"), kind: .table), permanent: true)
                    guard let orders = model.selectedTab?.table else { return }
                    await orders.load()
                    orders.isShowingStructure = true
                }
            },
            ScreenshotScene(name: "workspace-password", title: DemoData.events.name, size: windowSize) {
                var profile = DemoData.events
                profile.passwordStorage = .askEveryTime
                return await workspace(profile)
            }
        ]
    }
}
