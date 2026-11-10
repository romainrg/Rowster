import AppKit
import RowsterCore

/// Shows a question from OpenSSH: a passphrase, a password, or whether to trust a host key.
/// The answer goes back to ssh and is not kept.
enum AskpassPanel {
    @MainActor
    static func ask(_ request: AskpassRequest) async -> String? {
        let alert = NSAlert()
        alert.messageText = String(localized: "SSH")
        alert.informativeText = request.prompt
        alert.alertStyle = .informational
        switch request.kind {
        case .secret:
            let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
            alert.accessoryView = field
            alert.addButton(withTitle: String(localized: "OK"))
            alert.addButton(withTitle: String(localized: "Cancel"))
            alert.window.initialFirstResponder = field
            return alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil
        case .confirm:
            alert.addButton(withTitle: String(localized: "No"))
            alert.addButton(withTitle: String(localized: "Yes"))
            return alert.runModal() == .alertSecondButtonReturn ? "yes" : "no"
        case .info:
            alert.addButton(withTitle: String(localized: "OK"))
            alert.runModal()
            return ""
        }
    }
}
