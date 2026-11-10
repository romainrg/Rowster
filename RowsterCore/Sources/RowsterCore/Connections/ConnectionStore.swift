import Foundation

/// Where the list of connections is kept. Passwords are never part of it.
public protocol ConnectionStoring: Sendable {
    func load() throws -> ConnectionLibrary
    func save(_ library: ConnectionLibrary) throws
}

/// A JSON file, written atomically and readable by the user only.
public struct FileConnectionStore: ConnectionStoring {
    public let url: URL

    public init(url: URL) { self.url = url }

    public static func defaultURL(fileManager: FileManager = .default) -> URL {
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("Rowster", isDirectory: true).appendingPathComponent("connections.json")
    }

    public func load() throws -> ConnectionLibrary {
        guard FileManager.default.fileExists(atPath: url.path) else { return ConnectionLibrary() }
        return try JSONDecoder().decode(ConnectionLibrary.self, from: Data(contentsOf: url))
    }

    public func save(_ library: ConnectionLibrary) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.encode(library).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// The exported form of a library. It is the stored form: neither contains a password.
    public static func encode(_ library: ConnectionLibrary) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(library)
    }
}

/// Keeps the library in memory: demo mode and tests.
public final class MemoryConnectionStore: ConnectionStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var library: ConnectionLibrary

    public init(_ library: ConnectionLibrary = ConnectionLibrary()) { self.library = library }

    public func load() throws -> ConnectionLibrary { lock.withLock { library } }
    public func save(_ library: ConnectionLibrary) throws { lock.withLock { self.library = library } }
}
