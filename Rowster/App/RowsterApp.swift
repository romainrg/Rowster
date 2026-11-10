import RowsterCore
import SwiftUI

@main
struct RowsterApp: App {
    @State private var environment: AppEnvironment
    @State private var connections: ConnectionsModel

    init() {
        let environment = AppEnvironment.current()
        _environment = State(initialValue: environment)
        _connections = State(initialValue: ConnectionsModel(env: environment))
    }

    var body: some Scene {
        Window("Rowster", id: "welcome") {
            WelcomeView(model: connections)
                .environment(\.appEnvironment, environment)
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 760, height: 480)
    }
}
