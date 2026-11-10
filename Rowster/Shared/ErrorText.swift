import Foundation
import RowsterCore

/// Turns the errors of RowsterCore into text for the user. Server messages are shown as the server wrote them.
enum ErrorText {
    static func describe(_ error: Error) -> String {
        switch error {
        case let error as DatabaseError:
            var text = error.message
            if let detail = error.detail, !detail.isEmpty { text += "\n" + detail }
            if let hint = error.hint, !hint.isEmpty { text += "\n" + hint }
            return text
        case let error as ConnectionError:
            switch error {
            case .unreachable(let reason):
                return String(localized: "Cannot connect: \(reason)")
            case .tlsRequiredButUnavailable:
                return String(localized: "The server does not offer TLS, and this connection requires it.")
            case .tlsFailed(let reason):
                return String(localized: "The TLS handshake failed: \(reason)")
            case .authenticationFailed(let reason):
                return String(localized: "Authentication failed: \(reason)")
            case .unsupportedAuthentication(let method):
                return String(localized: "The server asks for an authentication method Rowster does not support: \(method)")
            case .protocolViolation(let reason):
                return String(localized: "Unexpected answer from the server: \(reason)")
            case .closed:
                return String(localized: "The connection is closed.")
            case .busy:
                return String(localized: "Another statement is still running on this connection.")
            }
        case let error as DriverProviderError:
            switch error {
            case .unsupportedEngine(let engine):
                return String(localized: "\(engine.displayName) is not supported yet.")
            case .missingFilePath:
                return String(localized: "Choose a database file.")
            case .missingHost:
                return String(localized: "Enter a host or a socket path.")
            }
        case let error as SecretStoreError:
            return String(localized: "Keychain: \(error.message)")
        default:
            return error.localizedDescription
        }
    }
}
