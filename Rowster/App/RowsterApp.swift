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
            WelcomeWindow(model: connections)
                .environment(\.appEnvironment, environment)
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 760, height: 480)

        WindowGroup(id: "connection", for: UUID.self) { $profileID in
            if let profileID, let profile = connections.profile(profileID) {
                WorkspaceWindow(profile: profile)
                    .environment(\.appEnvironment, environment)
            } else {
                ContentUnavailableView("This connection no longer exists", systemImage: "questionmark.circle")
                    .frame(minWidth: 480, minHeight: 320)
            }
        }
        .defaultSize(width: 1180, height: 760)
        .commands { WorkspaceCommands() }

        Settings {
            SettingsView()
                .environment(\.appEnvironment, environment)
        }
    }
}

/// The welcome window, wired to open a work window per connection.
private struct WelcomeWindow: View {
    @Environment(\.openWindow) private var openWindow
    let model: ConnectionsModel

    var body: some View {
        WelcomeView(model: model) { profile in
            openWindow(id: "connection", value: profile.id)
        }
    }
}

/// Owns the model of one work window: connects when the window appears, disconnects when it closes.
private struct WorkspaceWindow: View {
    @Environment(\.appEnvironment) private var env
    let profile: ConnectionProfile
    @State private var model: WorkspaceModel?

    var body: some View {
        Group {
            if let model {
                WorkspaceView(model: model)
            } else {
                Color.clear
            }
        }
        .frame(minWidth: 820, minHeight: 520)
        .task {
            guard model == nil else { return }
            let created = WorkspaceModel(profile: profile, env: env)
            model = created
            await created.start()
        }
        .onDisappear {
            let closing = model
            Task { await closing?.disconnect() }
        }
    }
}
