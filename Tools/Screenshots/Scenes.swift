import RowsterCore
import SwiftUI

struct ScreenshotScene {
    let name: String
    let size: CGSize
    let make: @MainActor () -> AnyView
}

enum ScreenshotScenes {
    @MainActor
    static var all: [ScreenshotScene] {
        welcomeScenes
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
}
