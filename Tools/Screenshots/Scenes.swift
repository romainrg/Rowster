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
            ScreenshotScene(name: "workspace-password", title: DemoData.events.name, size: windowSize) {
                var profile = DemoData.events
                profile.passwordStorage = .askEveryTime
                return await workspace(profile)
            }
        ]
    }
}
