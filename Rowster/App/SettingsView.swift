import SwiftUI

struct SettingsView: View {
    @Environment(\.appEnvironment) private var env
    @AppStorage(AppSettings.unlockRequiresAuthentication) private var unlockRequiresAuthentication = false
    @AppStorage(AppSettings.editorRowLimit) private var editorRowLimit = AppSettings.defaultEditorRowLimit
    @AppStorage(AppSettings.historyEnabled) private var historyEnabled = true

    var body: some View {
        Form {
            Section {
                Toggle("Require Touch ID to unlock writing", isOn: $unlockRequiresAuthentication)
                    .disabled(!env.authenticator.isAvailable)
            } header: {
                Text("Safety")
            } footer: {
                Text("A read-only connection always asks for a confirmation before writing is unlocked. This adds Touch ID, or your Mac password.")
            }
            Section {
                Picker("Rows fetched per statement", selection: $editorRowLimit) {
                    ForEach([100, 500, 1000, 5000, 20000], id: \.self) { limit in
                        Text("\(limit) rows").tag(limit)
                    }
                }
                Toggle("Keep a history of the statements I run", isOn: $historyEnabled)
            } header: {
                Text("SQL Editor")
            } footer: {
                Text("The history stores statements only, never their results. It stays on this Mac.")
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
    }
}
