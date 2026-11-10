import Foundation

public enum EnvironmentLabel: String, Codable, CaseIterable, Sendable {
    case none, local, development, staging, production

    public var defaultColor: ConnectionColor {
        switch self {
        case .none: return .gray
        case .local: return .green
        case .development: return .blue
        case .staging: return .orange
        case .production: return .red
        }
    }
}

public enum ConnectionColor: String, Codable, CaseIterable, Sendable {
    case gray, blue, teal, green, yellow, orange, red, pink, purple
}

public enum TLSMode: String, Codable, CaseIterable, Sendable {
    /// Never use TLS.
    case disabled
    /// Use TLS when the server offers it, accept any certificate, fall back to clear text.
    case preferred
    /// Require TLS, accept any certificate.
    case required
    /// Require TLS and a certificate signed by a trusted authority.
    case verifyCA
    /// Require TLS, a trusted certificate and a matching host name.
    case verifyIdentity

    public var requiresTLS: Bool { self != .disabled && self != .preferred }
    public var verifiesCertificate: Bool { self == .verifyCA || self == .verifyIdentity }
}

public enum PasswordStorage: String, Codable, CaseIterable, Sendable {
    case keychain, askEveryTime
}

public struct SSHSettings: Codable, Hashable, Sendable {
    public var isEnabled = false
    /// Host name or an alias from `~/.ssh/config`.
    public var host = ""
    public var port: Int?
    public var user = ""
    public var identityFile = ""

    public init() {}
}

/// Everything needed to open a connection, except the password: this type has no field for a secret,
/// so nothing that encodes it can leak one.
public struct ConnectionProfile: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var engine: Engine
    public var label: EnvironmentLabel
    /// `nil` follows the label.
    public var color: ConnectionColor?
    public var groupID: UUID?

    public var host: String
    public var port: Int?
    /// Unix-domain socket path, used instead of host and port when not empty.
    public var socketPath: String
    public var user: String
    public var database: String
    /// SQLite database file.
    public var filePath: String

    public var tlsMode: TLSMode
    public var caFile: String
    public var passwordStorage: PasswordStorage
    public var opensReadOnly: Bool
    public var ssh: SSHSettings
    /// Statements the user wants run right after connecting.
    public var bootstrapSQL: String

    public init(id: UUID = UUID(), name: String = "", engine: Engine = .postgres) {
        self.id = id
        self.name = name
        self.engine = engine
        label = .none
        host = engine == .sqlite ? "" : "localhost"
        socketPath = ""
        user = ""
        database = ""
        filePath = ""
        tlsMode = .preferred
        caFile = ""
        passwordStorage = .keychain
        opensReadOnly = false
        ssh = SSHSettings()
        bootstrapSQL = ""
    }

    /// Production is always red: its color cannot be changed.
    public var effectiveColor: ConnectionColor {
        label == .production ? .red : (color ?? label.defaultColor)
    }

    /// A production connection always opens read-only.
    public var isReadOnlyOnOpen: Bool { label == .production || opensReadOnly }

    public var effectivePort: Int? { port ?? engine.defaultPort }

    public var usesPassword: Bool { engine != .sqlite }

    /// One line describing the target: `host:port/database`, the socket, or the file.
    public var summary: String {
        if engine == .sqlite { return (filePath as NSString).abbreviatingWithTildeInPath }
        var target = socketPath.isEmpty ? host : socketPath
        if socketPath.isEmpty, let port, port != engine.defaultPort { target += ":\(port)" }
        if !database.isEmpty { target += "/\(database)" }
        if ssh.isEnabled, !ssh.host.isEmpty { target += " ⇢ \(ssh.host)" }
        return target
    }

    public var displayName: String { name.isEmpty ? summary : name }
}

public struct ConnectionGroup: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var isCollapsed: Bool

    public init(id: UUID = UUID(), name: String, isCollapsed: Bool = false) {
        self.id = id
        self.name = name
        self.isCollapsed = isCollapsed
    }
}

public struct ConnectionLibrary: Codable, Equatable, Sendable {
    public var version = 1
    public var groups: [ConnectionGroup]
    public var connections: [ConnectionProfile]

    public init(groups: [ConnectionGroup] = [], connections: [ConnectionProfile] = []) {
        self.groups = groups
        self.connections = connections
    }

    /// Connections whose name, target, user or label contains every word of the query.
    public func search(_ query: String) -> [ConnectionProfile] {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return connections }
        return connections.filter { profile in
            let haystack = [profile.name, profile.summary, profile.user, profile.label.rawValue, profile.engine.displayName]
                .joined(separator: " ").lowercased()
            return words.allSatisfy { haystack.contains($0) }
        }
    }
}
