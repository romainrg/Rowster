import Foundation

/// A statement the user ran. Results are never part of it: only a count.
public struct HistoryEntry: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var sql: String
    public var date: Date
    public var duration: Double
    public var succeeded: Bool
    /// The number of rows returned or affected, when the statement succeeded.
    public var rowCount: Int?

    public init(id: UUID = UUID(), sql: String, date: Date = Date(), duration: Double, succeeded: Bool, rowCount: Int? = nil) {
        self.id = id
        self.sql = sql
        self.date = date
        self.duration = duration
        self.succeeded = succeeded
        self.rowCount = rowCount
    }
}

public extension Array where Element == HistoryEntry {
    /// Entries whose statement contains every word of the query, most recent first.
    func search(_ query: String) -> [HistoryEntry] {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace)
        let matches = words.isEmpty ? self : filter { entry in
            let text = entry.sql.lowercased()
            return words.allSatisfy { text.contains($0) }
        }
        return matches.sorted { $0.date > $1.date }
    }
}

public protocol HistoryStoring: Sendable {
    func entries(connection: UUID) -> [HistoryEntry]
    func add(_ entry: HistoryEntry, connection: UUID)
    func clear(connection: UUID)
}

/// One JSON file per connection, readable by the user only, holding the most recent statements.
public final class FileHistoryStore: HistoryStoring, @unchecked Sendable {
    public static let limit = 500
    private let directory: URL
    private let lock = NSLock()
    private var cache: [UUID: [HistoryEntry]] = [:]

    public init(directory: URL) { self.directory = directory }

    public static func defaultDirectory(fileManager: FileManager = .default) -> URL {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Rowster", isDirectory: true).appendingPathComponent("history", isDirectory: true)
    }

    private func url(_ connection: UUID) -> URL { directory.appendingPathComponent("\(connection.uuidString).json") }

    private func load(_ connection: UUID) -> [HistoryEntry] {
        if let cached = cache[connection] { return cached }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let loaded = (try? Data(contentsOf: url(connection))).flatMap { try? decoder.decode([HistoryEntry].self, from: $0) } ?? []
        cache[connection] = loaded
        return loaded
    }

    private func save(_ entries: [HistoryEntry], connection: UUID) {
        cache[connection] = entries
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let data = try? encoder.encode(entries) else { return }
        try? data.write(to: url(connection), options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url(connection).path)
    }

    public func entries(connection: UUID) -> [HistoryEntry] {
        lock.withLock { load(connection) }
    }

    public func add(_ entry: HistoryEntry, connection: UUID) {
        lock.withLock {
            var entries = load(connection)
            entries.append(entry)
            if entries.count > Self.limit { entries.removeFirst(entries.count - Self.limit) }
            save(entries, connection: connection)
        }
    }

    public func clear(connection: UUID) {
        lock.withLock {
            cache[connection] = []
            try? FileManager.default.removeItem(at: url(connection))
        }
    }
}

public final class MemoryHistoryStore: HistoryStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var all: [UUID: [HistoryEntry]] = [:]

    public init() {}

    public func entries(connection: UUID) -> [HistoryEntry] { lock.withLock { all[connection] ?? [] } }
    public func add(_ entry: HistoryEntry, connection: UUID) { lock.withLock { all[connection, default: []].append(entry) } }
    public func clear(connection: UUID) { lock.withLock { all[connection] = nil } }
}

/// Hides password literals before a statement is written to the history.
public enum HistoryRedactor {
    /// Replaces the string that follows `PASSWORD` or `IDENTIFIED BY` with `'***'`.
    public static func redact(_ sql: String, dialect: any SQLDialect) -> String {
        let tokens = dialect.tokenizer.tokenize(sql).filter(\.isSignificant)
        var replacements: [Range<String.Index>] = []
        var sawIdentified = false
        var expectsSecret = false
        for token in tokens {
            switch token.kind {
            case .word:
                let word = sql[token.range].uppercased()
                if word == "IDENTIFIED" { sawIdentified = true }
                expectsSecret = word == "PASSWORD" || (word == "BY" && sawIdentified)
            case .string:
                if expectsSecret { replacements.append(token.range) }
                expectsSecret = false
            case .punctuation:
                let symbol = sql[token.range]
                if symbol != "=" && symbol != "(" { expectsSecret = false }
            default:
                expectsSecret = false
            }
        }
        var out = sql
        for range in replacements.reversed() { out.replaceSubrange(range, with: "'***'") }
        return out
    }
}
