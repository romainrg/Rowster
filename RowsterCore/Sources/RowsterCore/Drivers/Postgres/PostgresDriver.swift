import Foundation

/// PostgreSQL over its wire protocol, with no C library. Also works with servers that speak the same
/// protocol (CockroachDB, Redshift, YugabyteDB, Supabase), as far as they implement it.
public final class PostgresDriver: DatabaseDriver, @unchecked Sendable {
    public let dialect: any SQLDialect = PostgresDialect()
    private let configuration: ServerConfiguration
    private var stream: ByteStream?
    private var serverParameters: [String: String] = [:]
    private var status = TransactionState.idle
    fileprivate var hasOpenCursor = false

    private let lock = NSLock()
    private var backendKey: (processID: Int32, secret: Int32)?

    public init(configuration: ServerConfiguration) {
        self.configuration = configuration
    }

    // MARK: - Messages

    fileprivate struct Message {
        let type: Character
        let body: Data
    }

    private func send(_ data: Data) async throws {
        guard let stream else { throw ConnectionError.closed }
        try await stream.write(data)
    }

    /// The next message that matters: notices, parameter changes and notifications are absorbed here.
    fileprivate func receive() async throws -> Message {
        guard let stream else { throw ConnectionError.closed }
        while true {
            var header = ByteReader(try await stream.read(exactly: 5))
            let type = Character(UnicodeScalar(header.byte()))
            let length = Int(header.int32BE()) - 4
            guard length >= 0, length < 1 << 30 else { throw ConnectionError.protocolViolation("message length") }
            let body = length == 0 ? Data() : try await stream.read(exactly: length)
            switch type {
            case "N", "A":
                continue
            case "S":
                var reader = ByteReader(body)
                let name = reader.cString()
                serverParameters[name] = reader.cString()
            case "Z":
                switch body.first {
                case UInt8(ascii: "T"): status = .inTransaction
                case UInt8(ascii: "E"): status = .failed
                default: status = .idle
                }
                return Message(type: type, body: body)
            default:
                return Message(type: type, body: body)
            }
        }
    }

    /// Reads up to ReadyForQuery, returning the first error met on the way.
    @discardableResult
    fileprivate func drainToReady() async throws -> (error: DatabaseError?, tag: String?) {
        var failure: DatabaseError?
        var tag: String?
        while true {
            let message = try await receive()
            switch message.type {
            case "E": if failure == nil { failure = PostgresMessage.error(message.body) }
            case "C":
                var reader = ByteReader(message.body)
                tag = reader.cString()
            case "Z": return (failure, tag)
            default: break
            }
        }
    }

    // MARK: - Connection

    public func connect() async throws {
        let stream = ByteStream(endpoint: configuration.endpoint, tls: configuration.tls, upgrade: .postgres)
        try await stream.open()
        self.stream = stream
        do {
            try await send(PostgresMessage.startup(user: configuration.user, database: configuration.database))
            try await authenticate(encrypted: stream.isEncrypted)
        } catch {
            stream.close()
            self.stream = nil
            throw error
        }
    }

    private func authenticate(encrypted: Bool) async throws {
        var scram: ScramSHA256?
        while true {
            let message = try await receive()
            switch message.type {
            case "R":
                var reader = ByteReader(message.body)
                let code = reader.int32BE()
                switch code {
                case 0:
                    break
                case 3:
                    guard encrypted || configuration.isLocalSocket else {
                        throw ConnectionError.unsupportedAuthentication("clear-text password on an unencrypted connection")
                    }
                    try await send(PostgresMessage.password(configuration.password ?? ""))
                case 5:
                    let response = PostgresMD5.response(
                        user: configuration.user, password: configuration.password ?? "", salt: reader.bytes(4))
                    try await send(PostgresMessage.password(response))
                case 10:
                    var mechanisms: [String] = []
                    while let next = reader.peek, next != 0 { mechanisms.append(reader.cString()) }
                    guard mechanisms.contains("SCRAM-SHA-256") else {
                        throw ConnectionError.unsupportedAuthentication(mechanisms.joined(separator: ", "))
                    }
                    let client = ScramSHA256(password: configuration.password ?? "")
                    scram = client
                    try await send(PostgresMessage.saslInitial(mechanism: "SCRAM-SHA-256", response: client.clientFirst))
                case 11:
                    let serverFirst = String(decoding: reader.remaining(), as: UTF8.self)
                    guard var client = scram, let final = client.clientFinal(serverFirst: serverFirst) else {
                        throw ConnectionError.protocolViolation("SCRAM server-first message")
                    }
                    scram = client
                    try await send(PostgresMessage.saslResponse(final))
                case 12:
                    let serverFinal = String(decoding: reader.remaining(), as: UTF8.self)
                    guard scram?.verify(serverFinal: serverFinal) == true else {
                        throw ConnectionError.authenticationFailed("the server did not prove it knows the password")
                    }
                case 2: throw ConnectionError.unsupportedAuthentication("Kerberos V5")
                case 7, 8: throw ConnectionError.unsupportedAuthentication("GSSAPI")
                case 9: throw ConnectionError.unsupportedAuthentication("SSPI")
                default: throw ConnectionError.unsupportedAuthentication("method \(code)")
                }
            case "K":
                var reader = ByteReader(message.body)
                let key = (reader.int32BE(), reader.int32BE())
                lock.withLock { backendKey = key }
            case "E":
                let error = PostgresMessage.error(message.body)
                if error.code?.hasPrefix("28") == true { throw ConnectionError.authenticationFailed(error.message) }
                throw ConnectionError.unreachable(error.message)
            case "Z":
                return
            default:
                break
            }
        }
    }

    public func close() async {
        if let stream {
            try? await stream.write(PostgresMessage.terminate)
            stream.close()
        }
        stream = nil
        hasOpenCursor = false
    }

    public var transactionState: TransactionState {
        get async { status }
    }

    public var serverVersion: String? {
        get async { serverParameters["server_version"].map { "PostgreSQL \($0)" } }
    }

    public func makeIntrospector() -> any SchemaIntrospecting { PostgresIntrospector(driver: self) }

    /// Sends a CancelRequest on a connection of its own, as the protocol requires.
    public func cancel() async {
        guard let key = lock.withLock({ backendKey }) else { return }
        let canceller = ByteStream(endpoint: configuration.endpoint, tls: configuration.tls, upgrade: .postgres)
        guard (try? await canceller.open()) != nil else { return }
        try? await canceller.write(PostgresMessage.cancelRequest(processID: key.processID, secret: key.secret))
        canceller.close()
    }

    // MARK: - Statements

    /// Parses and binds the statement, and reads its row description. Rows are then pulled by the
    /// cursor with a row count on the portal, so the server sends no more than was asked for.
    public func execute(_ sql: String, parameters: [SQLValue]) async throws -> any ResultCursor {
        guard stream != nil else { throw ConnectionError.closed }
        guard !hasOpenCursor else { throw ConnectionError.busy }
        try await send(
            PostgresMessage.parse(sql) + PostgresMessage.bind(parameters) + PostgresMessage.describePortal + PostgresMessage.flush)
        while true {
            let message = try await receive()
            switch message.type {
            case "1", "2":
                continue
            case "T":
                hasOpenCursor = true
                return PostgresCursor(driver: self, columns: PostgresMessage.columns(message.body))
            case "n":
                hasOpenCursor = true
                return PostgresCursor(driver: self, columns: [])
            case "E":
                try await send(PostgresMessage.sync)
                try await drainToReady()
                throw PostgresMessage.error(message.body)
            default:
                throw ConnectionError.protocolViolation("message \(message.type) after Bind")
            }
        }
    }

    fileprivate func write(_ data: Data) async throws { try await send(data) }
}

private final class PostgresCursor: ResultCursor, @unchecked Sendable {
    private enum State {
        case ready, suspended, complete, closed
    }

    let columns: [ColumnInfo]
    private let types: [Int32]
    private let driver: PostgresDriver
    private var state = State.ready
    private var summary = CommandSummary()

    init(driver: PostgresDriver, columns: [(info: ColumnInfo, type: Int32)]) {
        self.driver = driver
        self.columns = columns.map(\.info)
        types = columns.map(\.type)
    }

    func next(maxRows: Int) async throws -> [Row]? {
        guard state == .ready || state == .suspended else { return nil }
        try await driver.write(PostgresMessage.execute(maxRows: max(1, maxRows)) + PostgresMessage.flush)
        var rows: [Row] = []
        while true {
            let message = try await driver.receive()
            switch message.type {
            case "D":
                rows.append(PostgresMessage.row(message.body, types: types))
            case "s":
                state = .suspended
                return rows
            case "C":
                complete(tag: message.body)
                return rows.isEmpty ? nil : rows
            case "I":
                state = .complete
                return rows.isEmpty ? nil : rows
            case "E":
                try await fail()
                throw PostgresMessage.error(message.body)
            default:
                continue
            }
        }
    }

    private func complete(tag body: Data) {
        var reader = ByteReader(body)
        summary = CommandSummary(rowsAffected: PostgresMessage.rowsAffected(tag: reader.cString()))
        state = .complete
    }

    /// After an error the server skips everything up to Sync: send it and wait for ReadyForQuery.
    private func fail() async throws {
        state = .closed
        driver.hasOpenCursor = false
        try await driver.write(PostgresMessage.sync)
        try await driver.drainToReady()
    }

    func close() async throws -> CommandSummary {
        guard state != .closed else { return summary }
        var request = Data()
        switch state {
        case .ready:
            // Not run yet: run it now. A statement that returns rows is asked for one row only.
            request = PostgresMessage.execute(maxRows: columns.isEmpty ? 0 : 1) + PostgresMessage.closePortal
        case .suspended:
            request = PostgresMessage.closePortal
        case .complete, .closed:
            break
        }
        state = .closed
        driver.hasOpenCursor = false
        try await driver.write(request + PostgresMessage.sync)
        let outcome = try await driver.drainToReady()
        if let error = outcome.error { throw error }
        if let tag = outcome.tag, summary.rowsAffected == nil {
            summary = CommandSummary(rowsAffected: PostgresMessage.rowsAffected(tag: tag))
        }
        return summary
    }
}
