import Foundation
import LocalAuthentication

/// Keys of the settings kept in `UserDefaults`.
enum AppSettings {
    /// Ask for Touch ID (or the Mac password) before unlocking writing on a read-only connection.
    static let unlockRequiresAuthentication = "unlockRequiresAuthentication"
    /// Maximum number of rows fetched for a statement run in the editor.
    static let editorRowLimit = "editorRowLimit"
    static let defaultEditorRowLimit = 1000
    /// Keep a history of the statements run in the editor.
    static let historyEnabled = "historyEnabled"
}

/// Confirms that the person at the keyboard is the owner of the Mac.
protocol UnlockAuthenticating: Sendable {
    var isAvailable: Bool { get }
    func authenticate(reason: String) async -> Bool
}

/// Touch ID, Apple Watch or the account password, through LocalAuthentication.
struct SystemAuthenticator: UnlockAuthenticating {
    var isAvailable: Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
    }

    func authenticate(reason: String) async -> Bool {
        do {
            return try await LAContext().evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
        } catch {
            return false
        }
    }
}

/// Demo mode never shows a system prompt.
struct DemoAuthenticator: UnlockAuthenticating {
    var isAvailable: Bool { true }
    func authenticate(reason: String) async -> Bool { true }
}
