import Foundation

/// What Rowster remembers about how a table is displayed.
public struct TableViewState: Codable, Equatable, Sendable {
    public var sort: [SortTerm]
    public var columnWidths: [String: Double]

    public init(sort: [SortTerm] = [], columnWidths: [String: Double] = [:]) {
        self.sort = sort
        self.columnWidths = columnWidths
    }
}

public protocol ViewStateStoring: Sendable {
    func state(connection: UUID, table: TableRef) -> TableViewState
    func save(_ state: TableViewState, connection: UUID, table: TableRef)
}

/// One JSON file per connection. Only display preferences are stored: never data, never a filter value.
public final class FileViewStateStore: ViewStateStoring, @unchecked Sendable {
    private struct File: Codable {
        var tables: [String: TableViewState] = [:]
    }

    private let directory: URL
    private let lock = NSLock()
    private var cache: [UUID: File] = [:]

    public init(directory: URL) { self.directory = directory }

    public static func defaultDirectory(fileManager: FileManager = .default) -> URL {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Rowster", isDirectory: true).appendingPathComponent("state", isDirectory: true)
    }

    private func url(_ connection: UUID) -> URL {
        directory.appendingPathComponent("\(connection.uuidString).json")
    }

    private func file(_ connection: UUID) -> File {
        if let cached = cache[connection] { return cached }
        let loaded = (try? Data(contentsOf: url(connection))).flatMap { try? JSONDecoder().decode(File.self, from: $0) } ?? File()
        cache[connection] = loaded
        return loaded
    }

    public func state(connection: UUID, table: TableRef) -> TableViewState {
        lock.withLock { file(connection).tables[table.displayName] ?? TableViewState() }
    }

    public func save(_ state: TableViewState, connection: UUID, table: TableRef) {
        lock.withLock {
            var current = file(connection)
            guard current.tables[table.displayName] != state else { return }
            current.tables[table.displayName] = state
            cache[connection] = current
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? encoder.encode(current).write(to: url(connection), options: .atomic)
        }
    }
}

public final class MemoryViewStateStore: ViewStateStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var states: [String: TableViewState] = [:]

    public init() {}

    public func state(connection: UUID, table: TableRef) -> TableViewState {
        lock.withLock { states["\(connection)/\(table.displayName)"] ?? TableViewState() }
    }

    public func save(_ state: TableViewState, connection: UUID, table: TableRef) {
        lock.withLock { states["\(connection)/\(table.displayName)"] = state }
    }
}
