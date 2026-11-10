import Foundation

public enum DriverProviderError: Error, Equatable, Sendable {
    case unsupportedEngine(Engine)
    case missingFilePath
    case missingHost
}

/// Builds the driver of a connection. It is the single place where a connection to the outside is
/// created: the demo provider never opens a socket, a file or a process.
public protocol DriverProviding: Sendable {
    /// - Parameters:
    ///   - database: replaces the profile's database when the user switched to another one.
    ///   - readOnly: open read-only from the start, for engines that can (SQLite).
    func makeDriver(
        for profile: ConnectionProfile, password: String?, database: String?, readOnly: Bool
    ) throws -> any DatabaseDriver
}

public struct LiveDriverProvider: DriverProviding {
    public init() {}

    public func makeDriver(
        for profile: ConnectionProfile, password: String?, database: String?, readOnly: Bool
    ) throws -> any DatabaseDriver {
        switch profile.engine {
        case .sqlite:
            guard !profile.filePath.isEmpty else { throw DriverProviderError.missingFilePath }
            let path = (profile.filePath as NSString).expandingTildeInPath
            return SQLiteDriver(configuration: SQLiteConfiguration(path: path, readOnly: readOnly))
        case .postgres:
            return PostgresDriver(configuration: try Self.serverConfiguration(profile, password: password, database: database))
        case .mysql, .mariadb:
            return MySQLDriver(
                configuration: try Self.serverConfiguration(profile, password: password, database: database),
                engine: profile.engine)
        }
    }

    /// Where a network driver connects, from a profile: a Unix socket when one is set, the host otherwise.
    static func serverConfiguration(
        _ profile: ConnectionProfile, password: String?, database: String?
    ) throws -> ServerConfiguration {
        let endpoint: TransportEndpoint
        if !profile.socketPath.isEmpty {
            endpoint = .unix(path: (profile.socketPath as NSString).expandingTildeInPath)
        } else {
            let host = profile.host.trimmingCharacters(in: .whitespaces)
            guard !host.isEmpty, let port = profile.effectivePort else { throw DriverProviderError.missingHost }
            endpoint = .tcp(host: host, port: port)
        }
        return ServerConfiguration(
            endpoint: endpoint,
            tls: TLSSettings(mode: profile.tlsMode, serverName: profile.host, caFile: profile.caFile),
            user: profile.user, password: password, database: database ?? profile.database)
    }
}

public extension DriverProviding {
    /// Opens the connection read-only, asks the server for its version and closes. Runs nothing else.
    func test(_ profile: ConnectionProfile, password: String?) async throws -> String? {
        let driver = try makeDriver(for: profile, password: password, database: nil, readOnly: true)
        try await driver.connect()
        let version = await driver.serverVersion
        await driver.close()
        return version
    }
}
