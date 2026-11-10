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

    @MainActor
    static func live() -> AppEnvironment {
        AppEnvironment(
            isDemo: false,
            connections: FileConnectionStore(url: FileConnectionStore.defaultURL()),
            secrets: KeychainSecretStore(),
            drivers: LiveDriverProvider())
    }

    /// Sample connections on an in-memory database: no network, no disk, no Keychain.
    @MainActor
    static func demo() -> AppEnvironment {
        AppEnvironment(
            isDemo: true,
            connections: MemoryConnectionStore(DemoData.library),
            secrets: MemorySecretStore(),
            drivers: DemoDriverProvider())
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
