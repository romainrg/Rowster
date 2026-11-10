import RowsterCore
import SwiftUI

/// The lock in the toolbar of a connection that opens read-only: unlocks writing after a confirmation,
/// re-locks it at once.
struct LockButton: View {
    let model: WorkspaceModel
    @State private var isConfirming = false

    var body: some View {
        if model.isReadOnly {
            Button {
                isConfirming = true
            } label: {
                Label("Read-only", systemImage: "lock.fill").labelStyle(.titleAndIcon)
            }
            .help(Text("This connection is read-only. Click to unlock writing in this window."))
            .confirmationDialog(
                Text("Unlock writing on “\(model.profile.displayName)”?"), isPresented: $isConfirming
            ) {
                Button("Unlock Writing") { Task { await model.unlockWriting() } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Statements that change data will be allowed in this window until you lock it again or close it.")
            }
        } else {
            Button {
                Task { await model.lockWriting() }
            } label: {
                Label("Writing unlocked", systemImage: "lock.open.fill").labelStyle(.titleAndIcon)
            }
            .foregroundStyle(.orange)
            .help(Text("Writing is unlocked in this window. Click to lock it again."))
        }
    }
}

/// Asks before destructive statements run, showing each one in full.
struct HazardSheet: View {
    let request: WorkspaceModel.HazardRequest
    let profile: ConnectionProfile
    let answer: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 26)).foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(request.statements.count == 1 ? "Run this statement?" : "Run these \(request.statements.count) statements?")
                        .font(.headline)
                    HStack(spacing: 6) {
                        Text(verbatim: profile.displayName).foregroundStyle(.secondary)
                        EnvironmentBadge(label: profile.label, color: profile.effectiveColor, prominent: true)
                    }
                    .font(.callout)
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(request.statements.enumerated()), id: \.offset) { _, statement in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(statement.hazard.explanation).font(.caption.weight(.semibold)).foregroundStyle(.orange)
                            Text(verbatim: statement.sql)
                                .font(.system(size: 12, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(8)
                        .background(Theme.softFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.softStroke))
                    }
                }
            }
            .frame(maxHeight: 260)
            HStack {
                Spacer()
                Button("Run Anyway", role: .destructive) { answer(true) }
                Button("Cancel", role: .cancel) { answer(false) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}

extension StatementInfo.Hazard {
    var explanation: LocalizedStringKey {
        switch self {
        case .drop: return "Drops an object and everything it contains"
        case .truncate: return "Removes every row of the table"
        case .deleteWithoutWhere: return "DELETE without WHERE: removes every row"
        case .updateWithoutWhere: return "UPDATE without WHERE: changes every row"
        }
    }
}
