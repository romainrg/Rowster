import AppKit
import RowsterCore
import SwiftUI

/// The sheet that creates or edits a connection.
struct ConnectionFormView: View {
    @Environment(\.dismiss) private var dismiss
    @State var draft: ConnectionProfile
    let isNew: Bool
    let groups: [ConnectionGroup]
    let model: ConnectionsModel
    /// The password is `nil` when the field was left empty: the stored one is kept.
    let onSave: (ConnectionProfile, String?) -> Void

    @State private var password = ""
    @State private var urlText = ""
    @State private var urlNote: String?
    @State private var isTesting = false
    @State private var testOutcome: ConnectionsModel.TestOutcome?

    private var isValid: Bool {
        if draft.engine == .sqlite { return !draft.filePath.trimmingCharacters(in: .whitespaces).isEmpty }
        return !draft.host.trimmingCharacters(in: .whitespaces).isEmpty || !draft.socketPath.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Form {
                urlSection
                generalSection
                if draft.engine == .sqlite { fileSection } else { serverSection }
                safetySection
                if draft.engine != .sqlite { sshSection }
                bootstrapSection
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            Divider()
            footer
        }
        .frame(width: 560, height: 640)
        .background { ThemeGround() }
        .onChange(of: draft.label) { _, label in
            if label == .production { draft.opensReadOnly = true }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            EngineIcon(engine: draft.engine, size: 32)
            VStack(alignment: .leading, spacing: 1) {
                Text(isNew ? "New Connection" : "Edit Connection").font(.system(size: 16, weight: .bold, design: .rounded))
                Text(verbatim: draft.engine.displayName).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            EnvironmentBadge(label: draft.label, color: draft.effectiveColor, prominent: true)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    // MARK: - Sections

    private var urlSection: some View {
        Section {
            TextField("Connection URL", text: $urlText, prompt: Text(verbatim: "postgres://user:password@host:5432/database"))
                .onChange(of: urlText) { _, text in applyURL(text) }
            if let urlNote {
                Text(verbatim: urlNote).font(.caption).foregroundStyle(.secondary)
            }
        } footer: {
            Text("Paste a URL to fill the form. A password in the URL goes to the password field only.")
        }
    }

    private var generalSection: some View {
        Section {
            TextField("Name", text: $draft.name, prompt: Text("Optional"))
            Picker("Engine", selection: $draft.engine) {
                ForEach(Engine.allCases, id: \.self) { engine in
                    Text(verbatim: engine.displayName).tag(engine)
                }
            }
            Picker("Environment", selection: $draft.label) {
                ForEach(EnvironmentLabel.allCases, id: \.self) { label in
                    Text(label.title).tag(label)
                }
            }
            Picker("Color", selection: $draft.color) {
                Text("Automatic").tag(ConnectionColor?.none)
                ForEach(ConnectionColor.allCases, id: \.self) { color in
                    Text(color.title).tag(ConnectionColor?.some(color))
                }
            }
            .disabled(draft.label == .production)
            if !groups.isEmpty {
                Picker("Group", selection: $draft.groupID) {
                    Text("None").tag(UUID?.none)
                    ForEach(groups) { group in
                        Text(verbatim: group.name).tag(UUID?.some(group.id))
                    }
                }
            }
        }
    }

    private var serverSection: some View {
        Section("Server") {
            TextField("Host", text: $draft.host)
            TextField(
                "Port", value: $draft.port, format: .number.grouping(.never),
                prompt: Text(verbatim: draft.engine.defaultPort.map(String.init) ?? ""))
            TextField("User", text: $draft.user)
            SecureField("Password", text: $password, prompt: isNew ? nil : Text("Leave empty to keep the saved password"))
                .disabled(draft.passwordStorage == .askEveryTime)
            Picker("Password storage", selection: $draft.passwordStorage) {
                Text("Save in Keychain").tag(PasswordStorage.keychain)
                Text("Ask every time").tag(PasswordStorage.askEveryTime)
            }
            TextField("Database", text: $draft.database)
            TextField("Socket path", text: $draft.socketPath, prompt: Text("Optional, replaces host and port"))
            Picker("TLS", selection: $draft.tlsMode) {
                Text("Disabled").tag(TLSMode.disabled)
                Text("Preferred").tag(TLSMode.preferred)
                Text("Required").tag(TLSMode.required)
                Text("Verify CA").tag(TLSMode.verifyCA)
                Text("Verify identity").tag(TLSMode.verifyIdentity)
            }
            if draft.tlsMode.verifiesCertificate {
                TextField("CA certificate file", text: $draft.caFile, prompt: Text("Optional, PEM"))
            }
            if draft.label == .production, !draft.tlsMode.requiresTLS, !draft.ssh.isEnabled {
                Label("A production connection should at least require TLS.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    private var fileSection: some View {
        Section("Database file") {
            HStack {
                TextField("File", text: $draft.filePath, prompt: Text("Drop a file or choose one"))
                Button("Choose…") { chooseFile() }
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first, url.isFileURL else { return false }
            draft.filePath = url.path
            return true
        }
    }

    private var safetySection: some View {
        Section {
            Toggle("Open read-only", isOn: $draft.opensReadOnly)
                .disabled(draft.label == .production)
        } footer: {
            if draft.label == .production {
                Text("A production connection always opens read-only. Writing is unlocked for one window at a time.")
            } else {
                Text("Writing must be unlocked in the window before any change can be made.")
            }
        }
    }

    private var sshSection: some View {
        Section {
            Toggle("Connect through SSH", isOn: $draft.ssh.isEnabled)
            if draft.ssh.isEnabled {
                TextField("SSH host", text: $draft.ssh.host, prompt: Text("Host name or alias from ~/.ssh/config"))
                TextField("SSH port", value: $draft.ssh.port, format: .number.grouping(.never), prompt: Text(verbatim: "22"))
                TextField("SSH user", text: $draft.ssh.user, prompt: Text("Optional"))
                TextField("Identity file", text: $draft.ssh.identityFile, prompt: Text("Optional"))
            }
        } footer: {
            if draft.ssh.isEnabled {
                Text("Rowster uses the system OpenSSH: your ~/.ssh/config, agents and ProxyJump apply.")
            }
        }
    }

    private var bootstrapSection: some View {
        Section {
            TextEditor(text: $draft.bootstrapSQL)
                .font(.system(size: 12, design: .monospaced))
                .frame(height: 56)
                .accessibilityLabel(Text("Bootstrap SQL"))
        } header: {
            Text("Bootstrap SQL")
        } footer: {
            Text("Statements run right after connecting. Nothing else runs by itself.")
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button {
                Task { await test() }
            } label: {
                Text("Test")
            }
            .buttonStyle(.soft)
            .disabled(!isValid || isTesting)
            testStatus
            Spacer(minLength: 8)
            Button("Cancel", role: .cancel) { dismiss() }
                .buttonStyle(.soft)
                .keyboardShortcut(.cancelAction)
            Button("Save") { save() }
                .buttonStyle(.gradient)
                .keyboardShortcut(.defaultAction)
                .disabled(!isValid)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    @ViewBuilder private var testStatus: some View {
        if isTesting {
            ProgressView().controlSize(.small)
        } else if let testOutcome {
            switch testOutcome {
            case .success(let version):
                Label { Text(verbatim: version) } icon: { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
                    .font(.callout)
                    .lineLimit(1)
            case .failure(let message):
                Label { Text(verbatim: message) } icon: { Image(systemName: "xmark.octagon.fill").foregroundStyle(.red) }
                    .font(.callout)
                    .lineLimit(2)
                    .help(Text(verbatim: message))
            }
        }
    }

    // MARK: - Actions

    private func applyURL(_ text: String) {
        guard let parsed = ConnectionURL.parse(text) else {
            urlNote = nil
            return
        }
        parsed.apply(to: &draft)
        if let found = parsed.password {
            password = found
            // The URL field must not keep showing the secret.
            var cleaned = draft
            cleaned.name = ""
            urlText = ConnectionURL.string(for: cleaned)
        }
        urlNote = parsed.unknownParameters.isEmpty
            ? nil
            : String(localized: "Ignored parameters: \(parsed.unknownParameters.joined(separator: ", "))")
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { draft.filePath = url.path }
    }

    private func test() async {
        isTesting = true
        testOutcome = nil
        testOutcome = await model.test(draft, typedPassword: password)
        isTesting = false
    }

    private func save() {
        onSave(draft, password.isEmpty ? nil : password)
        dismiss()
    }
}
