import Foundation

/// Reads and writes connection URLs such as `postgres://user:secret@host:5432/db?sslmode=require`.
public enum ConnectionURL {
    public struct Parsed: Equatable, Sendable {
        public var engine: Engine
        public var host = ""
        public var port: Int?
        public var user = ""
        public var database = ""
        public var filePath = ""
        public var tlsMode: TLSMode?
        /// The password found in the URL. The caller sends it to the secret store, never to the profile.
        public var password: String?
        /// Query parameters that were not understood, so the UI can list them instead of dropping them silently.
        public var unknownParameters: [String] = []

        /// Copies the parsed fields into a profile, leaving the rest of it untouched.
        public func apply(to profile: inout ConnectionProfile) {
            profile.engine = engine
            if engine == .sqlite {
                profile.filePath = filePath
                return
            }
            profile.host = host
            profile.port = port
            profile.user = user
            profile.database = database
            if let tlsMode { profile.tlsMode = tlsMode }
        }
    }

    private static let schemes: [String: Engine] = [
        "postgres": .postgres, "postgresql": .postgres, "mysql": .mysql, "mariadb": .mariadb,
        "sqlite": .sqlite, "sqlite3": .sqlite
    ]

    public static func parse(_ text: String) -> Parsed? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let colon = trimmed.firstIndex(of: ":"),
              let engine = schemes[trimmed[..<colon].lowercased()] else { return nil }

        if engine == .sqlite {
            var path = String(trimmed[trimmed.index(after: colon)...])
            if path.hasPrefix("//") { path.removeFirst(2) }
            path = path.removingPercentEncoding ?? path
            guard !path.isEmpty else { return nil }
            var parsed = Parsed(engine: .sqlite)
            parsed.filePath = path
            return parsed
        }

        guard let components = URLComponents(string: trimmed), var host = components.host, !host.isEmpty else { return nil }
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        var parsed = Parsed(engine: engine)
        parsed.host = host
        parsed.port = components.port
        parsed.user = components.user ?? ""
        parsed.password = components.password.flatMap { $0.isEmpty ? nil : $0 }
        parsed.database = String(components.path.drop { $0 == "/" })

        for item in components.queryItems ?? [] {
            let value = item.value?.lowercased() ?? ""
            switch item.name.lowercased() {
            case "sslmode", "ssl-mode", "ssl_mode":
                if let mode = tlsModes[value] { parsed.tlsMode = mode } else { parsed.unknownParameters.append(item.name) }
            case "ssl", "tls":
                parsed.tlsMode = ["1", "true", "yes", "on"].contains(value) ? .required : .disabled
            default:
                parsed.unknownParameters.append(item.name)
            }
        }
        return parsed
    }

    private static let tlsModes: [String: TLSMode] = [
        "disable": .disabled, "disabled": .disabled, "allow": .preferred, "prefer": .preferred, "preferred": .preferred,
        "require": .required, "required": .required, "verify-ca": .verifyCA, "verify_ca": .verifyCA,
        "verify-full": .verifyIdentity, "verify_identity": .verifyIdentity
    ]

    /// The URL of a profile, always without a password.
    public static func string(for profile: ConnectionProfile) -> String {
        if profile.engine == .sqlite { return "sqlite://" + profile.filePath }
        var components = URLComponents()
        components.scheme = profile.engine == .postgres ? "postgres" : profile.engine.rawValue
        components.host = profile.host
        components.port = profile.port
        if !profile.user.isEmpty { components.user = profile.user }
        components.path = "/" + profile.database
        if profile.tlsMode != .preferred {
            let name = profile.engine == .postgres ? "sslmode" : "ssl-mode"
            components.queryItems = [URLQueryItem(name: name, value: tlsValue(profile.tlsMode, engine: profile.engine))]
        }
        return components.string ?? ""
    }

    private static func tlsValue(_ mode: TLSMode, engine: Engine) -> String {
        switch (mode, engine == .postgres) {
        case (.disabled, true): return "disable"
        case (.disabled, false): return "DISABLED"
        case (.preferred, true): return "prefer"
        case (.preferred, false): return "PREFERRED"
        case (.required, true): return "require"
        case (.required, false): return "REQUIRED"
        case (.verifyCA, true): return "verify-ca"
        case (.verifyCA, false): return "VERIFY_CA"
        case (.verifyIdentity, true): return "verify-full"
        case (.verifyIdentity, false): return "VERIFY_IDENTITY"
        }
    }
}
