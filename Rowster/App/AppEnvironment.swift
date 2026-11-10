import RowsterCore
import SwiftUI

// Injection pattern: `AppEnvironment` is a value placed in the SwiftUI environment through a custom key.
// RowsterApp does `.environment(\.appEnvironment, environment)` once; views read it with
// `@Environment(\.appEnvironment) private var env`. Each service is set in both `live()` and `demo()`.

struct AppEnvironment {
    let isDemo: Bool
    /// The list of connections. Never holds a password.
    var connections: any ConnectionStoring
    /// The only place passwords are kept.
    var secrets: any SecretStore
    /// The only way a connection to a database is created.
    var drivers: any DriverProviding
    /// Sort order and column widths remembered per table.
    var viewState: any ViewStateStoring
    /// Touch ID or the Mac password, when the user asks for it before unlocking writing.
    var authenticator: any UnlockAuthenticating
    /// The statements run in the editor. Never their results.
    var history: any HistoryStoring

    @MainActor
    static func live() -> AppEnvironment {
        AppEnvironment(
            isDemo: false,
            connections: FileConnectionStore(url: FileConnectionStore.defaultURL()),
            secrets: KeychainSecretStore(),
            drivers: LiveDriverProvider(),
            viewState: FileViewStateStore(directory: FileViewStateStore.defaultDirectory()),
            authenticator: SystemAuthenticator(),
            history: FileHistoryStore(directory: FileHistoryStore.defaultDirectory()))
    }

    /// Sample connections on an in-memory database: no network, no disk, no Keychain.
    @MainActor
    static func demo() -> AppEnvironment {
        AppEnvironment(
            isDemo: true,
            connections: MemoryConnectionStore(DemoData.library),
            secrets: MemorySecretStore(),
            drivers: DemoDriverProvider(),
            viewState: MemoryViewStateStore(),
            authenticator: DemoAuthenticator(),
            history: MemoryHistoryStore())
    }

    @MainActor
    static func current() -> AppEnvironment {
        CommandLine.arguments.contains("--demo") ? demo() : live()
    }
}

private struct AppEnvironmentKey: EnvironmentKey {
    @MainActor static var defaultValue: AppEnvironment { AppEnvironment.demo() }
}

extension EnvironmentValues {
    var appEnvironment: AppEnvironment {
        get { self[AppEnvironmentKey.self] }
        set { self[AppEnvironmentKey.self] = newValue }
    }
}
