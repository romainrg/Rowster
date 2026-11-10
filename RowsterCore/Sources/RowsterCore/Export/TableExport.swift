import Foundation

public enum ExportFormat: String, Sendable, CaseIterable {
    case csv, json

    public var fileExtension: String { rawValue }
}

/// Writes the rows of a cursor to a file as they arrive, so the size of an export is not limited by memory.
public enum TableExport {
    /// Returns the number of rows written. Stops, leaving a partial file, when the task is cancelled.
    public static func write(
        _ cursor: any ResultCursor, to url: URL, format: ExportFormat, progress: @Sendable (Int) -> Void = { _ in }
    ) async throws -> Int {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw CocoaError(.fileWriteNoPermission)
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        let names = cursor.columns.map(\.name)
        var count = 0

        switch format {
        case .csv: try handle.write(contentsOf: Data((TabularText.csvLine(names.map(SQLValue.text)) + "\n").utf8))
        case .json: try handle.write(contentsOf: Data("[\n".utf8))
        }
        while let rows = try await cursor.next(maxRows: 1000) {
            try Task.checkCancellation()
            var chunk = ""
            for row in rows {
                switch format {
                case .csv:
                    chunk += TabularText.csvLine(row) + "\n"
                case .json:
                    chunk += (count == 0 ? "  " : ",\n  ") + TabularText.jsonObject(columns: names, row: row)
                }
                count += 1
            }
            try handle.write(contentsOf: Data(chunk.utf8))
            progress(count)
        }
        if format == .json { try handle.write(contentsOf: Data("\n]\n".utf8)) }
        return count
    }
}

public extension Session {
    /// Runs a read statement and streams its whole result to a file.
    func export(
        _ sql: String, parameters: [SQLValue] = [], to url: URL, format: ExportFormat, progress: @Sendable @escaping (Int) -> Void = { _ in }
    ) async throws -> Int {
        try await withCursor(sql, parameters: parameters) { cursor in
            try await TableExport.write(cursor, to: url, format: format, progress: progress)
        }
    }
}

public extension BrowseQuery {
    /// Every row matching the filter, in the current order, with binary values in full: what an export reads.
    func selectAll(dialect: any SQLDialect) -> SQLFragment {
        var unbounded = self
        unbounded.defersBinary = false
        unbounded.offset = 0
        unbounded.limit = Int.max - 1
        let paged = unbounded.select(dialect: dialect)
        // Drop the pagination that `select` always adds.
        guard let range = paged.sql.range(of: " LIMIT ", options: .backwards) else { return paged }
        return SQLFragment(sql: String(paged.sql[..<range.lowerBound]), parameters: paged.parameters)
    }
}
