import RowsterCore
import SwiftUI

/// The structure of a table, read-only: columns, indexes, constraints and the DDL.
struct StructureView: View {
    let table: TableDescription

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                section("Columns") {
                    Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 5) {
                        GridRow {
                            Text("Name")
                            Text("Type")
                            Text("Nullable")
                            Text("Default")
                        }
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        ForEach(table.columns, id: \.name) { column in
                            GridRow {
                                HStack(spacing: 4) {
                                    Text(verbatim: column.name).fontWeight(.medium)
                                    if column.primaryKeyPosition != nil {
                                        Image(systemName: "key.fill").font(.system(size: 9)).foregroundStyle(.secondary)
                                            .accessibilityLabel(Text("Primary key"))
                                    }
                                }
                                Text(verbatim: column.typeName).foregroundStyle(.secondary)
                                Text(column.isNullable ? "Yes" : "No")
                                Text(verbatim: column.isGenerated ? String(localized: "computed") : (column.defaultValue ?? ""))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                }
                if !table.indexes.isEmpty {
                    section("Indexes") {
                        ForEach(table.indexes, id: \.name) { index in
                            line(index.name, index.columns.joined(separator: ", "), badge: index.isPrimary ? "PRIMARY" : (index.isUnique ? "UNIQUE" : nil))
                        }
                    }
                }
                if !table.foreignKeys.isEmpty {
                    section("Foreign keys") {
                        ForEach(Array(table.foreignKeys.enumerated()), id: \.offset) { _, key in
                            line(
                                key.columns.joined(separator: ", "),
                                "→ \(key.referencedTable.displayName) (\(key.referencedColumns.joined(separator: ", ")))", badge: key.onDelete)
                        }
                    }
                }
                if !table.checks.isEmpty {
                    section("Checks") {
                        ForEach(Array(table.checks.enumerated()), id: \.offset) { _, check in
                            line(check.name ?? "", check.definition, badge: nil)
                        }
                    }
                }
                if let ddl = table.ddl {
                    section("DDL") {
                        if table.ddlIsReconstructed {
                            Text("Rebuilt from the catalogs: it describes the table, but is not the statement that created it.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Text(verbatim: ddl)
                            .font(.system(size: 12, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .background(Theme.softFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.softStroke))
                    }
                }
            }
            .font(.system(size: 12))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        }
    }

    private func section(_ title: LocalizedStringKey, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 13, weight: .bold))
            content()
        }
    }

    private func line(_ name: String, _ detail: String, badge: String?) -> some View {
        HStack(spacing: 8) {
            Text(verbatim: name).fontWeight(.medium)
            Text(verbatim: detail).foregroundStyle(.secondary).textSelection(.enabled)
            if let badge, !badge.isEmpty {
                Text(verbatim: badge)
                    .font(.system(size: 9.5, weight: .bold))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1.5)
                    .background(.quaternary, in: Capsule())
            }
        }
    }
}
